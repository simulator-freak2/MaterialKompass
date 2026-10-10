const { randomUUID } = require('node:crypto');
const { rawCollection } = require('./tenancy');
const { assessMaterialSafety, validDateOnly } = require('./material-safety');

const VEHICLE_TYPES = Object.freeze([
  'Kraftfahrzeug', 'Anhänger', 'Boot', 'Einsatzfahrzeug', 'Vereinsfahrzeug', 'Sonstiges',
]);
const VEHICLE_STATUSES = Object.freeze(['Verfügbar', 'In Wartung', 'Defekt', 'Außer Dienst']);
const RESERVATION_TERMINAL = new Set(['Abgelehnt', 'Storniert', 'Abgeschlossen']);
const MAINTENANCE_STATUSES = Object.freeze(['Geplant', 'In Arbeit', 'Abgeschlossen', 'Abgebrochen']);
const MAX_VEHICLES = 10_000;
const MAX_RELATED_RECORDS = 100_000;

let pdfLibModule;
function pdfLib() {
  pdfLibModule ||= require('pdf-lib');
  return pdfLibModule;
}

function text(value, maximum = 255) {
  return String(value ?? '').trim().slice(0, maximum);
}

function normalizeIdentifier(value) {
  return text(value, 64).toUpperCase().replace(/\s+/g, ' ');
}

function parseInstant(value, label) {
  const parsed = new Date(value);
  if (!value || !Number.isFinite(parsed.getTime())) {
    return { error: `${label} ist ungültig.` };
  }
  return { value: parsed.toISOString() };
}

function nullableNumber(value, { integer = false, maximum = Number.MAX_SAFE_INTEGER } = {}) {
  if (value === '' || value === null || value === undefined) return null;
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed < 0 || parsed > maximum || (integer && !Number.isInteger(parsed))) {
    return undefined;
  }
  return parsed;
}

function overlaps(leftStart, leftEnd, rightStart, rightEnd) {
  return new Date(leftStart).getTime() < new Date(rightEnd).getTime()
    && new Date(leftEnd).getTime() > new Date(rightStart).getTime();
}

function displayName(vehicle) {
  return vehicle.radioCallName || vehicle.registrationNumber || 'Fahrzeug';
}

function registerVehicleRoutes({
  app,
  authMiddleware,
  requirePermission,
  hasPermission,
  vehicles,
  vehicleReservations,
  vehicleMaintenanceEvents,
  vehicleLoadAssignments,
  vehicleLoadLists,
  materials,
  materialMovements,
  locations,
  organizations,
  organizationUnits,
  defectReports,
  logEvent,
  nextId,
}) {
  const all = (collection) => rawCollection(collection);
  const nowIso = () => new Date().toISOString();

  function organizationSetting(organizationId) {
    return organizations.find((entry) => entry.id === organizationId)?.primaryVehicleApprovalRequired === true;
  }

  function visibleTo(req, vehicle) {
    if (!vehicle || vehicle.organizationId !== req.tenant.organizationId) return false;
    return vehicle.unitId === req.tenant.unitId
      || vehicle.viewAllowedUnitIds?.includes(req.tenant.unitId)
      || vehicle.reservationAllowedUnitIds?.includes(req.tenant.unitId);
  }

  function reservableBy(req, vehicle) {
    return vehicle?.unitId === req.tenant.unitId
      || vehicle?.reservationAllowedUnitIds?.includes(req.tenant.unitId);
  }

  function ownedBy(req, vehicle) {
    return vehicle?.organizationId === req.tenant.organizationId
      && vehicle?.unitId === req.tenant.unitId;
  }

  function visibleVehicle(req, id) {
    return all(vehicles).find((entry) => entry.id === id && visibleTo(req, entry));
  }

  function ownedVehicle(req, id) {
    return all(vehicles).find((entry) => entry.id === id && ownedBy(req, entry));
  }

  function activeDefects(vehicle) {
    return all(defectReports).filter((entry) => entry.organizationId === vehicle.organizationId
      && entry.entityType === 'Vehicle' && entry.entityId === vehicle.id
      && !entry.archivedAt && entry.status !== 'Geprüft/Geschlossen');
  }

  function assessVehicleSafety(vehicle, at = new Date()) {
    const reasons = [];
    const criticalReasons = [];
    if (vehicle.archivedAt || vehicle.status === 'Außer Dienst') {
      criticalReasons.push('Das Fahrzeug ist außer Dienst.');
    }
    if (vehicle.status === 'Defekt') criticalReasons.push('Das Fahrzeug ist als defekt gekennzeichnet.');
    const defects = activeDefects(vehicle);
    for (const defect of defects) {
      const reason = `Offener Mangel ${defect.defectNumber || defect.id}.`;
      if (defect.priority === 'Kritisch' || defect.operationalSafety === 'Nicht einsatzfähig') {
        criticalReasons.push(reason);
      } else {
        reasons.push(reason);
      }
    }
    const timestamp = at.getTime();
    for (const event of all(vehicleMaintenanceEvents).filter((entry) =>
      entry.vehicleId === vehicle.id && !['Abgeschlossen', 'Abgebrochen'].includes(entry.status))) {
      const due = event.dueDate ? Date.parse(`${event.dueDate}T23:59:59.999Z`) : NaN;
      const active = event.startAt && event.endAt
        && Date.parse(event.startAt) <= timestamp && Date.parse(event.endAt) > timestamp;
      const overdue = Number.isFinite(due) && due < timestamp;
      if (!active && !overdue) continue;
      const reason = overdue
        ? `Die Wartung „${event.type}“ ist überfällig.`
        : `Die Wartung „${event.type}“ ist aktiv.`;
      if (event.safetyCritical === true) criticalReasons.push(reason);
      else reasons.push(reason);
    }
    if (vehicle.status === 'In Wartung') reasons.push('Das Fahrzeug ist in Wartung.');
    return {
      blocked: reasons.length > 0 || criticalReasons.length > 0,
      critical: criticalReasons.length > 0,
      reasons: [...criticalReasons, ...reasons],
    };
  }

  function publicVehicle(vehicle) {
    const owner = organizationUnits.find((entry) => entry.id === vehicle.unitId);
    const parking = all(locations).find((entry) => entry.id === vehicle.parkingLocationId);
    const loadLocation = all(locations).find((entry) => entry.id === vehicle.loadLocationId);
    const actualLoad = all(vehicleLoadAssignments).filter((entry) => entry.vehicleId === vehicle.id);
    const activeList = all(vehicleLoadLists).find((entry) =>
      entry.vehicleId === vehicle.id && entry.status === 'Aktiv');
    return {
      ...vehicle,
      ownerUnitName: owner?.name || null,
      parkingLocationName: parking?.name || null,
      loadLocationName: loadLocation?.name || displayName(vehicle),
      safetyStatus: assessVehicleSafety(vehicle),
      loadCount: actualLoad.length,
      activeLoadListVersion: activeList?.version || null,
      primaryApprovalRequired: vehicle.primaryResponseVehicle === true
        && organizationSetting(vehicle.organizationId),
    };
  }

  function vehicleValues(req, body, existing = null) {
    const registrationNumber = normalizeIdentifier(body.registrationNumber ?? existing?.registrationNumber);
    const vin = normalizeIdentifier(body.vin ?? existing?.vin);
    const radioCallName = text(body.radioCallName ?? existing?.radioCallName, 100);
    const parkingLocationId = text(body.parkingLocationId ?? existing?.parkingLocationId, 64) || null;
    const parkingDetails = text(body.parkingDetails ?? existing?.parkingDetails, 160);
    const year = nullableNumber(body.year ?? existing?.year, { integer: true, maximum: 9999 });
    const manufacturer = text(body.manufacturer ?? existing?.manufacturer, 120);
    const model = text(body.model ?? existing?.model, 120);
    const type = text(body.type ?? existing?.type ?? 'Kraftfahrzeug', 80);
    const status = text(body.status ?? existing?.status ?? 'Verfügbar', 40);
    const mileage = nullableNumber(body.mileage ?? existing?.mileage, { maximum: 100_000_000 });
    const operatingHours = nullableNumber(body.operatingHours ?? existing?.operatingHours, { maximum: 10_000_000 });
    const notes = text(body.notes ?? existing?.notes, 5000);
    if (!registrationNumber || !vin) return { error: 'Kennzeichen und Fahrgestellnummer sind Pflichtfelder.' };
    if (year === undefined || (year !== null && (year < 1800 || year > 2200))) {
      return { error: 'Das Baujahr muss vierstellig und plausibel sein.' };
    }
    if (!VEHICLE_TYPES.includes(type) || !VEHICLE_STATUSES.includes(status)) {
      return { error: 'Fahrzeugtyp oder Status ist ungültig.' };
    }
    if (mileage === undefined || operatingHours === undefined) {
      return { error: 'Kilometerstand oder Betriebsstunden sind ungültig.' };
    }
    if (parkingLocationId && !all(locations).some((entry) => entry.id === parkingLocationId
      && entry.organizationId === req.tenant.organizationId && !entry.vehicleId)) {
      return { error: 'Der gewählte Stellplatz ist ungültig.' };
    }
    const duplicate = all(vehicles).find((entry) => entry.id !== existing?.id
      && entry.organizationId === req.tenant.organizationId && !entry.purgedAt
      && (normalizeIdentifier(entry.registrationNumber) === registrationNumber
        || normalizeIdentifier(entry.vin) === vin));
    if (duplicate) return { error: 'Kennzeichen und Fahrgestellnummer müssen innerhalb der Organisation eindeutig sein.', status: 409 };
    return {
      registrationNumber, vin, radioCallName, parkingLocationId, parkingDetails,
      year, manufacturer, model, type, status, mileage, operatingHours, notes,
      primaryResponseVehicle: body.primaryResponseVehicle ?? existing?.primaryResponseVehicle ?? false,
    };
  }

  function locationCode(registrationNumber) {
    const base = registrationNumber.replace(/[^A-Z0-9_-]/g, '').slice(0, 24) || 'FZG';
    let candidate = `FZG-${base}`.slice(0, 32);
    let suffix = 2;
    while (all(locations).some((entry) => String(entry.code).toUpperCase() === candidate)) {
      candidate = `${`FZG-${base}`.slice(0, 27)}-${suffix}`;
      suffix += 1;
    }
    return candidate;
  }

  function createLoadLocation(vehicle) {
    const location = {
      id: `vehicle-location-${randomUUID()}`,
      organizationId: vehicle.organizationId,
      unitId: vehicle.unitId,
      vehicleId: vehicle.id,
      name: `Fahrzeug ${displayName(vehicle)}`,
      code: locationCode(vehicle.registrationNumber),
      type: 'Fahrzeug', street: '', houseNumber: '', postalCode: '', city: '', country: '',
    };
    all(locations).push(location);
    vehicle.loadLocationId = location.id;
    return location;
  }

  function syncLoadLocation(vehicle) {
    const location = all(locations).find((entry) => entry.id === vehicle.loadLocationId);
    if (location) location.name = `Fahrzeug ${displayName(vehicle)}`;
  }

  function reservationStatus(entry) {
    if (RESERVATION_TERMINAL.has(entry.status) || entry.status === 'Ausgegeben') return entry.status;
    if (!entry.vehicleApprovedAt) return 'Ausstehend';
    if (entry.operationalApprovalRequired && !entry.operationalApprovedAt) return 'TLE-Freigabe ausstehend';
    return 'Freigegeben';
  }

  function publicReservation(entry) {
    const vehicle = all(vehicles).find((candidate) => candidate.id === entry.vehicleId);
    return { ...entry, status: reservationStatus(entry), vehicleName: vehicle ? displayName(vehicle) : 'Gelöschtes Fahrzeug' };
  }

  function reservationVisible(req, entry) {
    const vehicle = all(vehicles).find((candidate) => candidate.id === entry.vehicleId);
    return entry.requesterUserId === req.user.id
      || (vehicle && ownedBy(req, vehicle)
        && hasPermission(req.user, 'vehicle_reservations.manage'))
      || (entry.operationalApprovalRequired
        && hasPermission(req.user, 'vehicle_reservations.operational_approve')
        && entry.organizationId === req.tenant.organizationId);
  }

  function reservationInput(body, existing = null) {
    const start = parseInstant(body.startAt ?? existing?.startAt, 'Beginn');
    const end = parseInstant(body.endAt ?? existing?.endAt, 'Ende');
    const title = text(body.title ?? existing?.title ?? body.purpose ?? existing?.purpose, 255);
    const purpose = text(body.purpose ?? existing?.purpose, 500);
    const destination = text(body.destination ?? existing?.destination, 500);
    const contact = text(body.contact ?? existing?.contact, 255);
    const note = text(body.note ?? existing?.note, 5000);
    if (start.error || end.error) return { error: start.error || end.error };
    if (Date.parse(end.value) <= Date.parse(start.value)) return { error: 'Das Ende muss nach dem Beginn liegen.' };
    if (!title || !purpose || !destination || !contact) return { error: 'Zeitraum, Titel, Zweck, Ziel und Kontakt sind erforderlich.' };
    if (Date.parse(end.value) - Date.parse(start.value) > 370 * 24 * 60 * 60 * 1000) {
      return { error: 'Eine Reservierung darf höchstens 370 Tage umfassen.' };
    }
    return { startAt: start.value, endAt: end.value, title, purpose, destination, contact, note };
  }

  function hasReservationConflict(vehicleId, startAt, endAt, ignoredId = null) {
    return all(vehicleReservations).some((entry) => entry.id !== ignoredId
      && entry.vehicleId === vehicleId && !RESERVATION_TERMINAL.has(entry.status)
      && overlaps(startAt, endAt, entry.startAt, entry.endAt));
  }

  function maintenanceConflict(vehicleId, startAt, endAt) {
    return all(vehicleMaintenanceEvents).find((entry) => entry.vehicleId === vehicleId
      && !['Abgeschlossen', 'Abgebrochen'].includes(entry.status)
      && entry.startAt && entry.endAt && overlaps(startAt, endAt, entry.startAt, entry.endAt));
  }

  function activeLoadList(vehicleId) {
    return all(vehicleLoadLists).find((entry) => entry.vehicleId === vehicleId && entry.status === 'Aktiv');
  }

  function materialLoadedQuantity(materialId, ignoredAssignmentId = null) {
    return all(vehicleLoadAssignments).reduce((sum, entry) =>
      entry.materialId === materialId && entry.id !== ignoredAssignmentId ? sum + Number(entry.quantity || 0) : sum, 0);
  }

  function publicAssignment(entry) {
    const material = all(materials).find((candidate) => candidate.id === entry.materialId);
    return {
      ...entry,
      inventoryNumber: material?.inventoryNumber || entry.inventoryNumberSnapshot || null,
      materialName: material?.name || entry.materialNameSnapshot || 'Gelöschter Artikel',
      unit: material?.unit || 'Stück',
    };
  }

  app.get('/api/vehicles', authMiddleware, requirePermission('vehicles.read'), (req, res) => {
    const includeArchived = req.query.includeArchived === 'true';
    const query = text(req.query.query, 120).toLowerCase();
    const limit = Math.min(Math.max(Number(req.query.limit) || 250, 1), 1000);
    const result = all(vehicles).filter((entry) => visibleTo(req, entry)
      && (includeArchived || !entry.archivedAt)
      && (!query || [entry.registrationNumber, entry.vin, entry.radioCallName,
        entry.manufacturer, entry.model].some((value) => String(value || '').toLowerCase().includes(query))))
      .slice(0, limit).map(publicVehicle);
    return res.json(result);
  });

  app.get('/api/vehicles/options', authMiddleware, requirePermission('vehicles.read'), (req, res) => {
    return res.json({
      types: VEHICLE_TYPES,
      statuses: VEHICLE_STATUSES,
      maintenanceStatuses: MAINTENANCE_STATUSES,
      parkingLocations: all(locations).filter((entry) => entry.organizationId === req.tenant.organizationId
        && entry.unitId === req.tenant.unitId && !entry.vehicleId).map((entry) => ({
        id: entry.id, name: entry.name, path: entry.path || entry.name,
      })),
      organizationSettings: {
        primaryVehicleApprovalRequired: organizationSetting(req.tenant.organizationId),
      },
    });
  });

  app.get('/api/vehicles/sharing-candidates', authMiddleware, requirePermission('vehicles.share'), (req, res) => {
    return res.json(organizationUnits.filter((entry) => entry.organizationId === req.tenant.organizationId
      && entry.status === 'active' && entry.id !== req.tenant.unitId).map((entry) => ({
      id: entry.id, name: entry.name, type: entry.type,
    })));
  });

  app.get('/api/vehicles/:id', authMiddleware, requirePermission('vehicles.read'), (req, res) => {
    const vehicle = visibleVehicle(req, req.params.id);
    if (!vehicle) return res.status(404).json({ error: 'Fahrzeug nicht gefunden.' });
    return res.json({
      ...publicVehicle(vehicle),
      reservations: all(vehicleReservations).filter((entry) => entry.vehicleId === vehicle.id
        && reservationVisible(req, entry)).map(publicReservation),
      maintenance: all(vehicleMaintenanceEvents).filter((entry) => entry.vehicleId === vehicle.id),
      loadAssignments: all(vehicleLoadAssignments).filter((entry) => entry.vehicleId === vehicle.id)
        .map(publicAssignment),
      loadLists: all(vehicleLoadLists).filter((entry) => entry.vehicleId === vehicle.id)
        .sort((left, right) => Number(right.version) - Number(left.version)),
      defects: activeDefects(vehicle).map((entry) => ({
        id: entry.id, defectNumber: entry.defectNumber, title: entry.title,
        priority: entry.priority, status: entry.status,
      })),
    });
  });

  app.post('/api/vehicles', authMiddleware, requirePermission('vehicles.write'), (req, res) => {
    if (all(vehicles).length >= MAX_VEHICLES) return res.status(507).json({ error: 'Die maximale Anzahl an Fahrzeugen ist erreicht.' });
    const values = vehicleValues(req, req.body);
    if (values.error) return res.status(values.status || 400).json({ error: values.error });
    const createdAt = nowIso();
    const vehicle = {
      id: `vehicle-${randomUUID()}`,
      organizationId: req.tenant.organizationId,
      unitId: req.tenant.unitId,
      ...values,
      viewAllowedUnitIds: [], reservationAllowedUnitIds: [],
      archivedAt: values.status === 'Außer Dienst' ? createdAt : null,
      offDutyAt: values.status === 'Außer Dienst' ? createdAt : null,
      createdAt, createdBy: req.user.username, updatedAt: createdAt,
    };
    all(vehicles).push(vehicle);
    createLoadLocation(vehicle);
    logEvent('create', 'Vehicle', { id: vehicle.id, registrationNumber: vehicle.registrationNumber }, req.user.username);
    return res.status(201).json(publicVehicle(vehicle));
  });

  app.put('/api/vehicles/:id', authMiddleware, requirePermission('vehicles.write'), (req, res) => {
    const vehicle = ownedVehicle(req, req.params.id);
    if (!vehicle) return res.status(404).json({ error: 'Fahrzeug nicht gefunden oder nicht in dieser Gliederung verwaltbar.' });
    const values = vehicleValues(req, req.body, vehicle);
    if (values.error) return res.status(values.status || 400).json({ error: values.error });
    const now = nowIso();
    Object.assign(vehicle, values, { updatedAt: now, updatedBy: req.user.username });
    if (values.status === 'Außer Dienst') {
      vehicle.offDutyAt ||= now;
      vehicle.archivedAt ||= now;
    } else {
      vehicle.offDutyAt = null;
      vehicle.archivedAt = null;
    }
    syncLoadLocation(vehicle);
    logEvent('update', 'Vehicle', { id: vehicle.id, registrationNumber: vehicle.registrationNumber }, req.user.username);
    return res.json(publicVehicle(vehicle));
  });

  app.put('/api/vehicles/:id/sharing', authMiddleware, requirePermission('vehicles.share'), (req, res) => {
    const vehicle = ownedVehicle(req, req.params.id);
    if (!vehicle) return res.status(404).json({ error: 'Fahrzeug nicht gefunden.' });
    const allowed = new Set(organizationUnits.filter((entry) =>
      entry.organizationId === vehicle.organizationId && entry.status === 'active'
      && entry.id !== vehicle.unitId).map((entry) => entry.id));
    const views = [...new Set(Array.isArray(req.body.viewUnitIds) ? req.body.viewUnitIds.map(String) : [])]
      .filter((id) => allowed.has(id));
    const reservationsAllowed = [...new Set(Array.isArray(req.body.reservationUnitIds)
      ? req.body.reservationUnitIds.map(String) : [])].filter((id) => allowed.has(id));
    vehicle.reservationAllowedUnitIds = reservationsAllowed;
    vehicle.viewAllowedUnitIds = [...new Set([...views, ...reservationsAllowed])];
    vehicle.updatedAt = nowIso();
    logEvent('share', 'Vehicle', {
      id: vehicle.id, viewUnitIds: vehicle.viewAllowedUnitIds,
      reservationUnitIds: vehicle.reservationAllowedUnitIds,
    }, req.user.username);
    return res.json(publicVehicle(vehicle));
  });

  app.get('/api/vehicle-settings', authMiddleware, requirePermission('vehicles.read'), (req, res) => {
    return res.json({ primaryVehicleApprovalRequired: organizationSetting(req.tenant.organizationId) });
  });

  app.put('/api/vehicle-settings', authMiddleware, requirePermission('organizations.write'), (req, res) => {
    const organization = organizations.find((entry) => entry.id === req.tenant.organizationId);
    if (!organization) return res.status(404).json({ error: 'Organisation nicht gefunden.' });
    organization.primaryVehicleApprovalRequired = req.body.primaryVehicleApprovalRequired === true;
    logEvent('settings', 'Vehicle', {
      primaryVehicleApprovalRequired: organization.primaryVehicleApprovalRequired,
    }, req.user.username);
    return res.json({ primaryVehicleApprovalRequired: organization.primaryVehicleApprovalRequired });
  });

  app.get('/api/vehicle-reservations', authMiddleware, requirePermission('vehicles.read'), (req, res) => {
    return res.json(all(vehicleReservations).filter((entry) => reservationVisible(req, entry))
      .map(publicReservation));
  });

  app.post('/api/vehicle-reservations', authMiddleware,
    requirePermission('vehicle_reservations.create'), (req, res) => {
      if (all(vehicleReservations).length >= MAX_RELATED_RECORDS) return res.status(507).json({ error: 'Die maximale Anzahl an Fahrzeugreservierungen ist erreicht.' });
      const vehicle = visibleVehicle(req, text(req.body.vehicleId, 64));
      if (!vehicle || !reservableBy(req, vehicle) || vehicle.archivedAt) {
        return res.status(404).json({ error: 'Das Fahrzeug ist nicht reservierbar.' });
      }
      const values = reservationInput(req.body);
      if (values.error) return res.status(400).json({ error: values.error });
      if (hasReservationConflict(vehicle.id, values.startAt, values.endAt)) {
        return res.status(409).json({ error: 'Das Fahrzeug ist im gewählten Zeitraum bereits reserviert.' });
      }
      const maintenance = maintenanceConflict(vehicle.id, values.startAt, values.endAt);
      const safety = assessVehicleSafety(vehicle, new Date(values.startAt));
      const overrideReason = text(req.body.overrideReason, 1000);
      const mayOverride = hasPermission(req.user, 'vehicle_maintenance.manage') || req.user.roles?.includes('Admin');
      if ((maintenance || safety.blocked) && (safety.critical || !mayOverride || !overrideReason)) {
        return res.status(409).json({
          error: safety.critical
            ? 'Das Fahrzeug ist sicherheitskritisch gesperrt und darf nicht reserviert werden.'
            : 'Wartung oder Fahrzeugstatus blockieren den Zeitraum. Eine berechtigte Übersteuerung benötigt eine Begründung.',
          reasons: safety.reasons,
        });
      }
      const createdAt = nowIso();
      const entry = {
        id: `vehicle-reservation-${randomUUID()}`,
        organizationId: vehicle.organizationId, unitId: vehicle.unitId,
        vehicleId: vehicle.id, ...values,
        requesterUserId: req.user.id,
        requesterName: req.user.name || req.user.username,
        requesterUnitId: req.tenant.unitId,
        vehicleApprovedAt: null, vehicleApprovedBy: null,
        operationalApprovalRequired: vehicle.primaryResponseVehicle === true
          && organizationSetting(vehicle.organizationId),
        operationalApprovedAt: null, operationalApprovedBy: null,
        overrideReason: overrideReason || null,
        status: 'Ausstehend', createdAt, updatedAt: createdAt,
      };
      all(vehicleReservations).push(entry);
      logEvent('create', 'VehicleReservation', { id: entry.id, vehicleId: vehicle.id }, req.user.username);
      return res.status(201).json(publicReservation(entry));
    });

  app.put('/api/vehicle-reservations/:id', authMiddleware,
    requirePermission('vehicle_reservations.create'), (req, res) => {
      const entry = all(vehicleReservations).find((candidate) => candidate.id === req.params.id
        && candidate.organizationId === req.tenant.organizationId);
      if (!entry || !reservationVisible(req, entry)) return res.status(404).json({ error: 'Reservierung nicht gefunden.' });
      if (entry.requesterUserId !== req.user.id || entry.status === 'Ausgegeben'
        || RESERVATION_TERMINAL.has(entry.status)) {
        return res.status(409).json({ error: 'Diese Reservierung kann nicht mehr geändert werden.' });
      }
      const values = reservationInput(req.body, entry);
      if (values.error) return res.status(400).json({ error: values.error });
      if (hasReservationConflict(entry.vehicleId, values.startAt, values.endAt, entry.id)) {
        return res.status(409).json({ error: 'Das Fahrzeug ist im gewählten Zeitraum bereits reserviert.' });
      }
      Object.assign(entry, values, {
        vehicleApprovedAt: null, vehicleApprovedBy: null,
        operationalApprovedAt: null, operationalApprovedBy: null,
        status: 'Ausstehend', updatedAt: nowIso(),
      });
      return res.json(publicReservation(entry));
    });

  app.post('/api/vehicle-reservations/:id/decision', authMiddleware,
    requirePermission('vehicle_reservations.manage'), (req, res) => {
      const entry = all(vehicleReservations).find((candidate) => candidate.id === req.params.id);
      const vehicle = entry && ownedVehicle(req, entry.vehicleId);
      if (!entry || !vehicle) return res.status(404).json({ error: 'Reservierung nicht gefunden.' });
      if (RESERVATION_TERMINAL.has(entry.status) || entry.status === 'Ausgegeben') {
        return res.status(409).json({ error: 'Die Reservierung ist bereits abgeschlossen.' });
      }
      if (req.body.approved !== true) {
        const reason = text(req.body.reason, 1000);
        if (!reason) return res.status(400).json({ error: 'Eine Ablehnung benötigt eine Begründung.' });
        entry.status = 'Abgelehnt';
        entry.decisionReason = reason;
      } else {
        entry.vehicleApprovedAt = nowIso();
        entry.vehicleApprovedBy = req.user.username;
        entry.status = reservationStatus(entry);
      }
      entry.updatedAt = nowIso();
      logEvent('decision', 'VehicleReservation', { id: entry.id, status: entry.status }, req.user.username);
      return res.json(publicReservation(entry));
    });

  app.post('/api/vehicle-reservations/:id/operational-decision', authMiddleware,
    requirePermission('vehicle_reservations.operational_approve'), (req, res) => {
      const entry = all(vehicleReservations).find((candidate) => candidate.id === req.params.id
        && candidate.organizationId === req.tenant.organizationId);
      if (!entry || !entry.operationalApprovalRequired) return res.status(404).json({ error: 'TLE-Freigabe nicht erforderlich oder Reservierung nicht gefunden.' });
      if (req.body.approved !== true) {
        const reason = text(req.body.reason, 1000);
        if (!reason) return res.status(400).json({ error: 'Eine Ablehnung benötigt eine Begründung.' });
        entry.status = 'Abgelehnt';
        entry.decisionReason = reason;
      } else {
        entry.operationalApprovedAt = nowIso();
        entry.operationalApprovedBy = req.user.username;
        entry.status = reservationStatus(entry);
      }
      entry.updatedAt = nowIso();
      logEvent('operational-decision', 'VehicleReservation', { id: entry.id, status: entry.status }, req.user.username);
      return res.json(publicReservation(entry));
    });

  app.post('/api/vehicle-reservations/:id/cancel', authMiddleware,
    requirePermission('vehicle_reservations.create'), (req, res) => {
      const entry = all(vehicleReservations).find((candidate) => candidate.id === req.params.id);
      if (!entry || !reservationVisible(req, entry)) return res.status(404).json({ error: 'Reservierung nicht gefunden.' });
      const vehicle = all(vehicles).find((candidate) => candidate.id === entry.vehicleId);
      if (entry.requesterUserId !== req.user.id
        && !(vehicle && ownedBy(req, vehicle) && hasPermission(req.user, 'vehicle_reservations.manage'))) {
        return res.status(403).json({ error: 'Diese Reservierung darf nicht storniert werden.' });
      }
      if (entry.status === 'Ausgegeben' || RESERVATION_TERMINAL.has(entry.status)) {
        return res.status(409).json({ error: 'Die Reservierung kann nicht storniert werden.' });
      }
      entry.status = 'Storniert'; entry.updatedAt = nowIso();
      return res.json(publicReservation(entry));
    });

  app.post('/api/vehicle-reservations/:id/issue', authMiddleware,
    requirePermission('vehicle_reservations.manage'), (req, res) => {
      const entry = all(vehicleReservations).find((candidate) => candidate.id === req.params.id);
      const vehicle = entry && ownedVehicle(req, entry.vehicleId);
      if (!entry || !vehicle) return res.status(404).json({ error: 'Reservierung nicht gefunden.' });
      if (reservationStatus(entry) !== 'Freigegeben') return res.status(409).json({ error: 'Nur vollständig freigegebene Reservierungen können übergeben werden.' });
      const safety = assessVehicleSafety(vehicle);
      if (safety.blocked) return res.status(409).json({ error: 'Das Fahrzeug ist gesperrt und darf nicht übergeben werden.', reasons: safety.reasons });
      const mileage = nullableNumber(req.body.mileage, { maximum: 100_000_000 });
      if (mileage === undefined) return res.status(400).json({ error: 'Der Kilometerstand ist ungültig.' });
      entry.status = 'Ausgegeben'; entry.issuedAt = nowIso(); entry.issuedBy = req.user.username;
      entry.issueMileage = mileage; entry.issueFuelLevel = text(req.body.fuelLevel, 80);
      entry.issueNotes = text(req.body.notes, 2000); entry.updatedAt = nowIso();
      if (mileage !== null) vehicle.mileage = Math.max(Number(vehicle.mileage || 0), mileage);
      logEvent('issue', 'VehicleReservation', { id: entry.id, vehicleId: vehicle.id }, req.user.username);
      return res.json(publicReservation(entry));
    });

  app.post('/api/vehicle-reservations/:id/return', authMiddleware,
    requirePermission('vehicle_reservations.manage'), (req, res) => {
      const entry = all(vehicleReservations).find((candidate) => candidate.id === req.params.id);
      const vehicle = entry && ownedVehicle(req, entry.vehicleId);
      if (!entry || !vehicle) return res.status(404).json({ error: 'Reservierung nicht gefunden.' });
      if (entry.status !== 'Ausgegeben') return res.status(409).json({ error: 'Das Fahrzeug ist nicht ausgegeben.' });
      const mileage = nullableNumber(req.body.mileage, { maximum: 100_000_000 });
      if (mileage === undefined || (mileage !== null && mileage < Number(entry.issueMileage || 0))) {
        return res.status(400).json({ error: 'Der Rückgabe-Kilometerstand ist ungültig.' });
      }
      entry.status = 'Abgeschlossen'; entry.returnedAt = nowIso(); entry.returnedBy = req.user.username;
      entry.returnMileage = mileage; entry.returnFuelLevel = text(req.body.fuelLevel, 80);
      entry.returnNotes = text(req.body.notes, 2000); entry.damageReported = req.body.damageReported === true;
      entry.updatedAt = nowIso();
      if (mileage !== null) vehicle.mileage = mileage;
      logEvent('return', 'VehicleReservation', { id: entry.id, vehicleId: vehicle.id, damageReported: entry.damageReported }, req.user.username);
      return res.json(publicReservation(entry));
    });

  app.post('/api/vehicles/:vehicleId/maintenance', authMiddleware,
    requirePermission('vehicle_maintenance.manage'), (req, res) => {
      const vehicle = ownedVehicle(req, req.params.vehicleId);
      if (!vehicle) return res.status(404).json({ error: 'Fahrzeug nicht gefunden.' });
      if (all(vehicleMaintenanceEvents).length >= MAX_RELATED_RECORDS) return res.status(507).json({ error: 'Die maximale Anzahl an Wartungen ist erreicht.' });
      const type = text(req.body.type, 160);
      const status = text(req.body.status || 'Geplant', 40);
      const start = req.body.startAt ? parseInstant(req.body.startAt, 'Beginn') : { value: null };
      const end = req.body.endAt ? parseInstant(req.body.endAt, 'Ende') : { value: null };
      const dueDate = req.body.dueDate ? validDateOnly(req.body.dueDate) : null;
      const intervalMonths = nullableNumber(req.body.intervalMonths, { integer: true, maximum: 1200 });
      const mileage = nullableNumber(req.body.mileage, { maximum: 100_000_000 });
      const cost = nullableNumber(req.body.cost, { maximum: 100_000_000 });
      if (!type || !MAINTENANCE_STATUSES.includes(status) || start.error || end.error
        || (start.value && end.value && Date.parse(end.value) <= Date.parse(start.value))
        || (req.body.dueDate && !dueDate) || intervalMonths === undefined || mileage === undefined || cost === undefined) {
        return res.status(400).json({ error: 'Die Wartungsangaben sind ungültig.' });
      }
      const entry = {
        id: `vehicle-maintenance-${randomUUID()}`,
        organizationId: vehicle.organizationId, unitId: vehicle.unitId, vehicleId: vehicle.id,
        type, status, startAt: start.value, endAt: end.value, dueDate,
        intervalMonths, mileage, provider: text(req.body.provider, 255), cost,
        description: text(req.body.description, 5000), result: text(req.body.result, 5000),
        nextDueDate: req.body.nextDueDate ? validDateOnly(req.body.nextDueDate) : null,
        safetyCritical: req.body.safetyCritical === true,
        createdAt: nowIso(), createdBy: req.user.username,
      };
      if (req.body.nextDueDate && !entry.nextDueDate) return res.status(400).json({ error: 'Der Folgetermin ist ungültig.' });
      all(vehicleMaintenanceEvents).push(entry);
      logEvent('maintenance', 'VehicleMaintenance', { id: entry.id, vehicleId: vehicle.id }, req.user.username);
      return res.status(201).json(entry);
    });

  app.put('/api/vehicles/:vehicleId/maintenance/:id', authMiddleware,
    requirePermission('vehicle_maintenance.manage'), (req, res) => {
      const vehicle = ownedVehicle(req, req.params.vehicleId);
      const entry = all(vehicleMaintenanceEvents).find((candidate) =>
        candidate.id === req.params.id && candidate.vehicleId === vehicle?.id);
      if (!entry) return res.status(404).json({ error: 'Wartung nicht gefunden.' });
      const status = text(req.body.status ?? entry.status, 40);
      if (!MAINTENANCE_STATUSES.includes(status)) return res.status(400).json({ error: 'Der Wartungsstatus ist ungültig.' });
      const nextDueDate = req.body.nextDueDate === null || req.body.nextDueDate === ''
        ? null : validDateOnly(req.body.nextDueDate ?? entry.nextDueDate);
      if ((req.body.nextDueDate ?? entry.nextDueDate) && !nextDueDate) return res.status(400).json({ error: 'Der Folgetermin ist ungültig.' });
      Object.assign(entry, {
        status, result: text(req.body.result ?? entry.result, 5000), nextDueDate,
        cost: nullableNumber(req.body.cost ?? entry.cost, { maximum: 100_000_000 }),
        provider: text(req.body.provider ?? entry.provider, 255),
        description: text(req.body.description ?? entry.description, 5000),
        safetyCritical: req.body.safetyCritical ?? entry.safetyCritical,
        completedAt: status === 'Abgeschlossen' ? nowIso() : entry.completedAt || null,
        completedBy: status === 'Abgeschlossen' ? req.user.username : entry.completedBy || null,
        updatedAt: nowIso(),
      });
      if (entry.cost === undefined) return res.status(400).json({ error: 'Die Kosten sind ungültig.' });
      logEvent('maintenance-update', 'VehicleMaintenance', { id: entry.id, vehicleId: vehicle.id, status }, req.user.username);
      return res.json(entry);
    });

  app.get('/api/vehicles/:vehicleId/load-materials', authMiddleware,
    requirePermission('vehicles.load.read'), (req, res) => {
      const vehicle = visibleVehicle(req, req.params.vehicleId);
      if (!vehicle) return res.status(404).json({ error: 'Fahrzeug nicht gefunden.' });
      const query = text(req.query.query, 120).toLowerCase();
      const result = all(materials).filter((item) => item.organizationId === vehicle.organizationId
        && item.unitId === vehicle.unitId
        && !item.archived && (!query || `${item.inventoryNumber} ${item.name}`.toLowerCase().includes(query)))
        .slice(0, 100).map((item) => ({
          id: item.id, inventoryNumber: item.inventoryNumber, name: item.name,
          itemType: item.itemType, quantity: Number(item.quantity || 1), unit: item.unit,
          loadedQuantity: materialLoadedQuantity(item.id),
          availableQuantity: Math.max(0, Number(item.quantity || 1)
            - Number(item.issuedQuantity || 0) - materialLoadedQuantity(item.id)),
        }));
      return res.json(result);
    });

  app.post('/api/vehicles/:vehicleId/load', authMiddleware,
    requirePermission('vehicles.load.manage'), (req, res) => {
      const vehicle = ownedVehicle(req, req.params.vehicleId);
      if (!vehicle || vehicle.archivedAt) return res.status(404).json({ error: 'Fahrzeug nicht gefunden oder außer Dienst.' });
      const material = all(materials).find((entry) => entry.id === text(req.body.materialId, 64)
        && entry.organizationId === vehicle.organizationId && entry.unitId === vehicle.unitId
        && !entry.archived);
      const quantity = Number(req.body.quantity ?? 1);
      if (!material || !Number.isFinite(quantity) || quantity <= 0 || !Number.isInteger(quantity)) {
        return res.status(400).json({ error: 'Material und positive ganze Menge sind erforderlich.' });
      }
      const available = Number(material.quantity || 1) - Number(material.issuedQuantity || 0)
        - materialLoadedQuantity(material.id);
      if (quantity > available || (material.itemType === 'individual' && quantity !== 1)) {
        return res.status(409).json({ error: 'Die gewünschte Menge ist nicht verfügbar.' });
      }
      const materialSafety = assessMaterialSafety(material);
      if (materialSafety.blocked) return res.status(409).json({ error: 'Das Material ist sicherheitsbedingt gesperrt.', reasons: materialSafety.reasons });
      const at = nowIso();
      const assignment = {
        id: `vehicle-load-${randomUUID()}`,
        organizationId: vehicle.organizationId, unitId: vehicle.unitId,
        vehicleId: vehicle.id, materialId: material.id, quantity,
        position: text(req.body.position, 160), notes: text(req.body.notes, 1000),
        previousLocationId: material.locationId || null,
        previousStockStructureId: material.stockStructureId || null,
        inventoryNumberSnapshot: material.inventoryNumber,
        materialNameSnapshot: material.name,
        createdAt: at, createdBy: req.user.username,
      };
      all(vehicleLoadAssignments).push(assignment);
      if (material.itemType === 'individual') {
        material.locationId = vehicle.loadLocationId;
        material.stockStructureId = null;
      }
      all(materialMovements).push({
        id: nextId('movement', all(materialMovements)), materialId: material.id,
        action: 'vehicle-load', quantity, fromLocationId: assignment.previousLocationId,
        fromStockStructureId: assignment.previousStockStructureId,
        toLocationId: vehicle.loadLocationId, toStockStructureId: null,
        vehicleId: vehicle.id, notes: assignment.notes, actor: req.user.username, createdAt: at,
        organizationId: vehicle.organizationId, unitId: material.unitId,
      });
      logEvent('load', 'VehicleLoad', { id: assignment.id, vehicleId: vehicle.id, materialId: material.id, quantity }, req.user.username);
      return res.status(201).json(publicAssignment(assignment));
    });

  app.post('/api/vehicles/:vehicleId/load/:id/unload', authMiddleware,
    requirePermission('vehicles.load.manage'), (req, res) => {
      const vehicle = ownedVehicle(req, req.params.vehicleId);
      const assignments = all(vehicleLoadAssignments);
      const index = assignments.findIndex((entry) => entry.id === req.params.id
        && entry.vehicleId === vehicle?.id);
      if (index < 0) return res.status(404).json({ error: 'Beladungsbuchung nicht gefunden.' });
      const assignment = assignments[index];
      const material = all(materials).find((entry) => entry.id === assignment.materialId);
      const destinationLocationId = text(req.body.locationId || assignment.previousLocationId, 64);
      const destinationStockStructureId = text(req.body.stockStructureId || assignment.previousStockStructureId, 64) || null;
      const destination = all(locations).find((entry) => entry.id === destinationLocationId
        && entry.organizationId === vehicle.organizationId && !entry.vehicleId);
      if (!material || !destination) return res.status(400).json({ error: 'Ein gültiger Ziel-Lagerort ist erforderlich.' });
      if (material.itemType === 'individual') {
        material.locationId = destination.id; material.stockStructureId = destinationStockStructureId;
      }
      assignments.splice(index, 1);
      const at = nowIso();
      all(materialMovements).push({
        id: nextId('movement', all(materialMovements)), materialId: material.id,
        action: 'vehicle-unload', quantity: assignment.quantity,
        fromLocationId: vehicle.loadLocationId, toLocationId: destination.id,
        toStockStructureId: destinationStockStructureId, vehicleId: vehicle.id,
        notes: text(req.body.notes, 1000), actor: req.user.username, createdAt: at,
        organizationId: vehicle.organizationId, unitId: material.unitId,
      });
      logEvent('unload', 'VehicleLoad', { id: assignment.id, vehicleId: vehicle.id, materialId: material.id }, req.user.username);
      return res.json({ success: true });
    });

  app.post('/api/vehicles/:vehicleId/load-lists', authMiddleware,
    requirePermission('vehicles.load.manage'), (req, res) => {
      const vehicle = ownedVehicle(req, req.params.vehicleId);
      if (!vehicle) return res.status(404).json({ error: 'Fahrzeug nicht gefunden.' });
      const name = text(req.body.name || 'Beladung', 160);
      const items = Array.isArray(req.body.items) ? req.body.items : [];
      if (!name || items.length > 1000) return res.status(400).json({ error: 'Bezeichnung oder Umfang der Beladungsliste ist ungültig.' });
      const normalized = [];
      for (const item of items) {
        const material = all(materials).find((entry) => entry.id === text(item.materialId, 64)
          && entry.organizationId === vehicle.organizationId && entry.unitId === vehicle.unitId);
        const targetQuantity = Number(item.targetQuantity);
        if (!material || !Number.isInteger(targetQuantity) || targetQuantity < 1) {
          return res.status(400).json({ error: 'Jede Listenposition benötigt gültiges Material und eine Sollmenge.' });
        }
        normalized.push({
          materialId: material.id, targetQuantity,
          position: text(item.position, 160), notes: text(item.notes, 1000),
          inventoryNumberSnapshot: material.inventoryNumber, materialNameSnapshot: material.name,
        });
      }
      const version = all(vehicleLoadLists).filter((entry) => entry.vehicleId === vehicle.id)
        .reduce((highest, entry) => Math.max(highest, Number(entry.version || 0)), 0) + 1;
      const activate = req.body.activate !== false;
      if (activate) all(vehicleLoadLists).filter((entry) => entry.vehicleId === vehicle.id)
        .forEach((entry) => { if (entry.status === 'Aktiv') entry.status = 'Ersetzt'; });
      const list = {
        id: `vehicle-load-list-${randomUUID()}`,
        organizationId: vehicle.organizationId, unitId: vehicle.unitId,
        vehicleId: vehicle.id, name, version, status: activate ? 'Aktiv' : 'Entwurf',
        items: normalized, createdAt: nowIso(), createdBy: req.user.username,
      };
      all(vehicleLoadLists).push(list);
      logEvent('load-list', 'VehicleLoad', { id: list.id, vehicleId: vehicle.id, version }, req.user.username);
      return res.status(201).json(list);
    });

  app.get('/api/vehicles/:vehicleId/load-list/print', authMiddleware,
    requirePermission('vehicles.print'), async (req, res) => {
      const vehicle = visibleVehicle(req, req.params.vehicleId);
      if (!vehicle) return res.status(404).json({ error: 'Fahrzeug nicht gefunden.' });
      const list = activeLoadList(vehicle.id);
      if (!list) return res.status(404).json({ error: 'Für das Fahrzeug ist keine aktive Soll-Beladungsliste vorhanden.' });
      const actual = all(vehicleLoadAssignments).filter((entry) => entry.vehicleId === vehicle.id);
      const { PDFDocument, StandardFonts, rgb } = pdfLib();
      const pdf = await PDFDocument.create();
      const font = await pdf.embedFont(StandardFonts.Helvetica);
      const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
      let page = pdf.addPage([595, 842]); let y = 800;
      const line = (value, options = {}) => {
        if (y < 55) { page = pdf.addPage([595, 842]); y = 800; }
        page.drawText(String(value).slice(0, 110), {
          x: options.x || 42, y, size: options.size || 9,
          font: options.bold ? bold : font, color: options.color || rgb(0, 0, 0),
        });
        y -= options.gap || 15;
      };
      line('Beladungsliste', { size: 18, bold: true, gap: 25 });
      line(`Fahrzeug: ${displayName(vehicle)} | Kennzeichen: ${vehicle.registrationNumber}`, { bold: true });
      line(`Typ: ${vehicle.type} | Stellplatz: ${vehicle.parkingDetails || vehicle.parkingLocationId || '-'}`);
      line(`Liste: ${list.name} | Version: ${list.version} | Stand: ${new Date().toLocaleString('de-DE', { timeZone: 'Europe/Berlin' })}`);
      y -= 8;
      line('Inventarnummer | Bezeichnung | Position | Soll | Ist | Abweichung', { bold: true, gap: 18 });
      for (const item of list.items) {
        const material = all(materials).find((entry) => entry.id === item.materialId);
        const actualQuantity = actual.filter((entry) => entry.materialId === item.materialId)
          .reduce((sum, entry) => sum + Number(entry.quantity || 0), 0);
        const deviation = actualQuantity - Number(item.targetQuantity || 0);
        line(`${material?.inventoryNumber || item.inventoryNumberSnapshot || '-'} | ${material?.name || item.materialNameSnapshot || '-'} | ${item.position || '-'} | ${item.targetQuantity} | ${actualQuantity} | ${deviation >= 0 ? '+' : ''}${deviation}`,
          { color: deviation < 0 ? rgb(0.75, 0, 0) : rgb(0, 0, 0) });
      }
      y -= 20;
      line('Geprüft am: ____________________   durch: ______________________________');
      line('Unterschrift: ________________________________________________________');
      const bytes = await pdf.save();
      logEvent('print', 'VehicleLoad', { vehicleId: vehicle.id, loadListId: list.id }, req.user.username);
      return res.json({
        fileName: `beladungsliste-${vehicle.registrationNumber.replace(/[^A-Za-z0-9_-]/g, '-')}-v${list.version}.pdf`,
        mimeType: 'application/pdf', fileBase64: Buffer.from(bytes).toString('base64'),
      });
    });

  async function applyVehicleRetentionPolicy(referenceTime = Date.now()) {
    const cutoffDate = new Date(referenceTime);
    cutoffDate.setUTCFullYear(cutoffDate.getUTCFullYear() - 10);
    const cutoff = cutoffDate.getTime();
    let removedVehicles = 0;
    const source = all(vehicles);
    for (let index = source.length - 1; index >= 0; index -= 1) {
      const vehicle = source[index];
      const offDuty = Date.parse(vehicle.offDutyAt || vehicle.archivedAt || '');
      if (!Number.isFinite(offDuty) || offDuty > cutoff || activeDefects(vehicle).length) continue;
      if (all(vehicleLoadAssignments).some((entry) => entry.vehicleId === vehicle.id)) continue;
      for (const collection of [vehicleReservations, vehicleMaintenanceEvents, vehicleLoadLists]) {
        const raw = all(collection);
        for (let child = raw.length - 1; child >= 0; child -= 1) {
          if (raw[child].vehicleId === vehicle.id) raw.splice(child, 1);
        }
      }
      const locationIndex = all(locations).findIndex((entry) => entry.id === vehicle.loadLocationId);
      if (locationIndex >= 0) all(locations).splice(locationIndex, 1);
      source.splice(index, 1); removedVehicles += 1;
    }
    return { removedVehicles };
  }

  return { assessVehicleSafety, applyVehicleRetentionPolicy };
}

module.exports = { registerVehicleRoutes, VEHICLE_TYPES, VEHICLE_STATUSES };
