const { randomUUID } = require('node:crypto');
const { assessMaterialSafety } = require('./material-safety');
const { currentTenant, rawCollection, youthUnitsAreLinked } = require('./tenancy');

const ACTIVE_RESERVATION_STATUSES = new Set(['Ausstehend', 'Freigegeben']);
const ACTIVE_MAINTENANCE_STATUSES = new Set(['Geplant', 'In Arbeit']);
const RESERVATION_STATUSES = new Set([
  'Ausstehend', 'Freigegeben', 'Abgelehnt', 'Storniert', 'Ausgegeben', 'Abgeschlossen',
]);
const MAINTENANCE_STATUSES = new Set(['Geplant', 'In Arbeit', 'Abgeschlossen', 'Abgebrochen']);
const MAX_RANGE_DAYS = 370;
const MAX_EVENTS = 10_000;
const MAX_ITEMS = 100;
const MAX_RETENTION_MONTHS = 240;

function registerCalendarRoutes({
  vehicles = [],
  vehicleReservations = [],
  vehicleMaintenanceEvents = [],
  app,
  authMiddleware,
  requirePermission,
  hasPermission,
  reservations,
  maintenanceEvents,
  materials,
  materialMovements,
  departments,
  locations,
  users,
  logEvent,
  nextId,
  defectManagement,
  organizations,
  organizationUnits,
}) {
  const number = (value, fallback = 0) => {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : fallback;
  };

  function parseInstant(value, label) {
    const raw = String(value || '').trim();
    const parsed = raw ? new Date(raw) : null;
    if (!parsed || !Number.isFinite(parsed.getTime())) return { error: `${label} ist ungültig.` };
    return { value: parsed };
  }

  function parseRange(source, { defaultDays = 42 } = {}) {
    const now = new Date();
    const defaultFrom = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1));
    const defaultTo = new Date(defaultFrom.getTime() + defaultDays * 86_400_000);
    const fromResult = source.from ? parseInstant(source.from, 'Beginn') : { value: defaultFrom };
    const toResult = source.to ? parseInstant(source.to, 'Ende') : { value: defaultTo };
    if (fromResult.error || toResult.error) return { error: fromResult.error || toResult.error };
    const from = fromResult.value;
    const to = toResult.value;
    if (to <= from) return { error: 'Das Ende muss nach dem Beginn liegen.' };
    if (to.getTime() - from.getTime() > MAX_RANGE_DAYS * 86_400_000) {
      return { error: `Der abgefragte Zeitraum darf höchstens ${MAX_RANGE_DAYS} Tage umfassen.` };
    }
    return { from, to };
  }

  const overlaps = (startAt, endAt, from, to) => (
    new Date(startAt).getTime() < to.getTime() && new Date(endAt).getTime() > from.getTime()
  );

  const allMaterials = () => rawCollection(materials);
  const allReservations = () => rawCollection(reservations);
  const allMaintenanceEvents = () => rawCollection(maintenanceEvents);
  const allMaterialMovements = () => rawCollection(materialMovements);
  const allLocations = () => rawCollection(locations);
  const allVehicles = () => rawCollection(vehicles);
  const allVehicleReservations = () => rawCollection(vehicleReservations);
  const allVehicleMaintenanceEvents = () => rawCollection(vehicleMaintenanceEvents);

  function vehicleAccessible(vehicle) {
    const tenant = currentTenant();
    return Boolean(vehicle && tenant && vehicle.organizationId === tenant.organizationId
      && (vehicle.unitId === tenant.unitId
        || youthUnitsAreLinked(organizationUnits, tenant.organizationId,
          tenant.unitId, vehicle.unitId)
        || vehicle.viewAllowedUnitIds?.includes(tenant.unitId)
        || vehicle.reservationAllowedUnitIds?.includes(tenant.unitId)));
  }

  function visibleVehicles() {
    return allVehicles().filter(vehicleAccessible);
  }

  function vehicleName(vehicle) {
    return vehicle.radioCallName || vehicle.registrationNumber || 'Fahrzeug';
  }

  function sourceUnitFor(item) {
    return organizationUnits.find((entry) => entry.id === item?.unitId
      && entry.organizationId === item?.organizationId && entry.status === 'active');
  }

  function materialAccessible(item, { requireReservationGrant = false } = {}) {
    const tenant = currentTenant();
    if (!item || item.archived || !tenant || item.organizationId !== tenant.organizationId) return false;
    if (item.unitId === tenant.unitId) return true;
    if (youthUnitsAreLinked(organizationUnits, tenant.organizationId,
      tenant.unitId, item.unitId)) return true;
    const source = sourceUnitFor(item);
    if (!source?.inventoryVisibleToUnitIds?.includes(tenant.unitId)) return false;
    return !requireReservationGrant
      || item.reservationAllowedUnitIds?.includes(tenant.unitId) === true;
  }

  function materialFor(id, options) {
    const item = allMaterials().find((entry) => entry.id === id);
    return materialAccessible(item, options) ? item : null;
  }

  function ownedMaterialFor(id) {
    const tenant = currentTenant();
    return allMaterials().find((entry) => entry.id === id && !entry.archived
      && tenant && entry.organizationId === tenant.organizationId && entry.unitId === tenant.unitId);
  }

  function materialForReservationItem(reference) {
    const tenant = currentTenant();
    if (!tenant) return null;
    const item = allMaterials().find((entry) => entry.id === reference.materialId
      && entry.organizationId === tenant.organizationId
      && (!reference.materialUnitId || entry.unitId === reference.materialUnitId));
    return item && !item.archived ? item : null;
  }

  function publicMaterial(item) {
    return {
      id: item.id,
      inventoryNumber: item.inventoryNumber,
      name: item.name,
      quantity: number(item.quantity),
      issuedQuantity: number(item.issuedQuantity),
      status: item.status,
      locationId: item.locationId,
      department: item.department || '',
      sourceUnitId: item.unitId,
      sourceUnitName: sourceUnitFor(item)?.name || '',
      externalReservation: item.unitId !== currentTenant()?.unitId,
      reservationApprovalRequired: item.reservationApprovalRequired === true,
      nextInspectionDate: item.nextInspectionDate || null,
      nextMaintenanceDate: item.nextMaintenanceDate || null,
      safetyCritical: item.safetyCritical === true,
      safetyStatus: assessMaterialSafety(item),
    };
  }

  function publicReservation(entry) {
    return {
      ...entry,
      note: entry.note || '',
      canEditOwn: ACTIVE_RESERVATION_STATUSES.has(entry.status),
    };
  }

  function departmentNames(user) {
    const allowed = new Set(user?.departmentIds || []);
    return new Set(departments
      .filter((entry) => allowed.has(entry.id))
      .map((entry) => String(entry.name || '').trim().toLowerCase()));
  }

  function managesAllReservations(user) {
    return user?.roles?.some((role) => ['Admin', 'Materialwart'].includes(role));
  }

  function mayManageReservation(user, entry) {
    if (!hasPermission(user, 'reservations.manage')) return false;
    const tenant = currentTenant();
    if (!tenant) return false;
    const youthLinkedReservation = (entry.items || []).some((item) =>
      youthUnitsAreLinked(organizationUnits, tenant.organizationId,
        entry.requesterUnitId || entry.unitId, item.materialUnitId));
    if (youthLinkedReservation && !(entry.items || []).every((item) =>
      item.materialOrganizationId === tenant.organizationId
      && item.materialUnitId === tenant.unitId)) return false;
    if (managesAllReservations(user)) return true;
    const allowed = departmentNames(user);
    if (allowed.size === 0) return false;
    return entry.items.every(({ materialId }) => {
      const item = materialFor(materialId);
      return item && allowed.has(String(item.department || '').trim().toLowerCase());
    });
  }

  function mayChangeOwn(user, entry) {
    return entry.requesterUserId === user.id && ACTIVE_RESERVATION_STATUSES.has(entry.status);
  }

  function normalizeItems(rawItems) {
    if (!Array.isArray(rawItems) || rawItems.length === 0 || rawItems.length > MAX_ITEMS) {
      return { error: `Zwischen 1 und ${MAX_ITEMS} Materialpositionen sind erforderlich.` };
    }
    const combined = new Map();
    for (const raw of rawItems) {
      const materialId = String(raw?.materialId || '').trim();
      const quantity = number(raw?.quantity, 1);
      const item = materialFor(materialId, { requireReservationGrant: true });
      if (!item || !String(item.inventoryNumber || '').trim()) {
        return { error: 'Reserviert werden kann nur freigegebenes, aktives Einzelmaterial mit Inventarnummer.' };
      }
      if (item.itemType !== 'individual' || number(item.quantity) !== 1) {
        return { error: `„${item.inventoryNumber}“ ist ein Mengenartikel und kann nicht reserviert werden.` };
      }
      if (quantity !== 1) {
        return { error: 'Bei Einzelartikeln muss die reservierte Menge genau 1 betragen.' };
      }
      const existing = combined.get(materialId);
      if (existing) return { error: 'Ein Einzelartikel darf nur einmal in einer Reservierung enthalten sein.' };
      combined.set(materialId, {
        materialId,
        inventoryNumber: item.inventoryNumber,
        materialName: item.name,
        materialUnitId: item.unitId,
        materialOrganizationId: item.organizationId,
        department: item.department || '',
        locationId: item.locationId || null,
        quantity: 1,
      });
    }
    const items = [...combined.values()];
    const tenant = currentTenant();
    const includesYouthLink = tenant && items.some((item) =>
      youthUnitsAreLinked(organizationUnits, tenant.organizationId,
        tenant.unitId, item.materialUnitId));
    if (includesYouthLink && new Set(items.map((item) => item.materialUnitId)).size > 1) {
      return { error: 'Eine Reservierung darf nur Inventar einer besitzenden Gliederung enthalten.' };
    }
    return { items };
  }

  function reservationVisible(entry) {
    const tenant = currentTenant();
    return Boolean(tenant && entry.organizationId === tenant.organizationId
      && (entry.unitId === tenant.unitId
        || (entry.items || []).some((item) => item.materialUnitId === tenant.unitId)));
  }

  function unavailableReason(item) {
    const safety = assessMaterialSafety(item);
    if (safety.blocked) {
      return `„${item.inventoryNumber}“ ist aus Sicherheitsgründen gesperrt: ${safety.reasons.join(' ')}`;
    }
    if (['Defekt', 'In Reparatur', 'Ausgesondert', 'Verloren'].includes(item.status)) {
      return `„${item.inventoryNumber}“ ist wegen des Status „${item.status}“ nicht reservierbar.`;
    }
    return null;
  }

  function reservedQuantity(materialId, from, to, ignoredReservationId = null) {
    const tenant = currentTenant();
    return allReservations().reduce((sum, entry) => {
      if (!tenant || entry.organizationId !== tenant.organizationId) return sum;
      if (entry.id === ignoredReservationId || !ACTIVE_RESERVATION_STATUSES.has(entry.status)
          || !overlaps(entry.startAt, entry.endAt, from, to)) return sum;
      const item = entry.items.find((candidate) => candidate.materialId === materialId);
      return sum + number(item?.quantity);
    }, 0);
  }

  function maintenanceConflict(materialId, from, to, ignoredMaintenanceId = null) {
    const tenant = currentTenant();
    return allMaintenanceEvents().some((entry) => tenant
      && entry.organizationId === tenant.organizationId
      && entry.id !== ignoredMaintenanceId
      && entry.materialId === materialId
      && ACTIVE_MAINTENANCE_STATUSES.has(entry.status)
      && overlaps(entry.startAt, entry.endAt, from, to));
  }

  function validateReservationAvailability(items, from, to, ignoredReservationId = null) {
    for (const requested of items) {
      const item = materialFor(requested.materialId, { requireReservationGrant: true });
      if (!item) return 'Material nicht gefunden.';
      const blocked = unavailableReason(item);
      if (blocked) return blocked;
      if (maintenanceConflict(item.id, from, to)) {
        return `„${item.inventoryNumber}“ befindet sich im gewählten Zeitraum in Wartung.`;
      }
      const available = number(item.quantity) - number(item.issuedQuantity)
        - reservedQuantity(item.id, from, to, ignoredReservationId);
      if (requested.quantity > available) {
        return `Für „${item.inventoryNumber}“ sind im gewählten Zeitraum nur ${Math.max(available, 0)} verfügbar.`;
      }
    }
    return null;
  }

  function reservationValues(body, existing = null) {
    const purpose = String(body.purpose ?? existing?.purpose ?? '').trim();
    const note = String(body.note ?? existing?.note ?? '').trim();
    if (!purpose || purpose.length > 255) return { error: 'Zweck/Veranstaltung ist erforderlich und darf höchstens 255 Zeichen lang sein.' };
    if (note.length > 5_000) return { error: 'Die Notiz darf höchstens 5.000 Zeichen lang sein.' };
    const range = parseRange({
      from: body.startAt ?? existing?.startAt,
      to: body.endAt ?? existing?.endAt,
    });
    if (range.error) return range;
    const normalized = normalizeItems(body.items ?? existing?.items);
    if (normalized.error) return normalized;
    return {
      purpose,
      note,
      startAt: range.from.toISOString(),
      endAt: range.to.toISOString(),
      allDay: (body.allDay ?? existing?.allDay) === true,
      items: normalized.items,
    };
  }

  function maintenanceValues(body, existing = null) {
    const materialId = String(body.materialId ?? existing?.materialId ?? '').trim();
    const item = ownedMaterialFor(materialId);
    if (!item || !String(item.inventoryNumber || '').trim()) {
      return { error: 'Eine gültige Inventarnummer ist erforderlich.' };
    }
    const range = parseRange({
      from: body.startAt ?? existing?.startAt,
      to: body.endAt ?? existing?.endAt,
    });
    if (range.error) return range;
    const type = String(body.type ?? existing?.type ?? '').trim();
    const responsible = String(body.responsible ?? existing?.responsible ?? '').trim();
    const description = String(body.description ?? existing?.description ?? '').trim();
    const provider = String(body.provider ?? existing?.provider ?? '').trim();
    const completionNote = String(body.completionNote ?? existing?.completionNote ?? '').trim();
    const status = String(body.status ?? existing?.status ?? 'Geplant').trim();
    const costRaw = body.cost ?? existing?.cost ?? null;
    const cost = costRaw === '' || costRaw == null ? null : number(costRaw, Number.NaN);
    if (!type || !responsible || !description) return { error: 'Art, Verantwortlicher und Beschreibung sind erforderlich.' };
    if ([type, responsible, provider].some((value) => value.length > 255)
        || description.length > 5_000 || completionNote.length > 5_000) {
      return { error: 'Mindestens ein Textfeld ist zu lang.' };
    }
    if (!MAINTENANCE_STATUSES.has(status)) return { error: 'Der Wartungsstatus ist ungültig.' };
    if (cost != null && (!Number.isFinite(cost) || cost < 0 || cost > 10_000_000)) {
      return { error: 'Die Kostenangabe ist ungültig.' };
    }
    return {
      materialId,
      inventoryNumber: item.inventoryNumber,
      materialName: item.name,
      startAt: range.from.toISOString(),
      endAt: range.to.toISOString(),
      type,
      responsible,
      status,
      description,
      provider,
      cost,
      completionNote,
    };
  }

  function calendarEvents(from, to, user) {
    const events = [];
    const materialIndex = new Map(allMaterials().map((entry) => [entry.id, entry]));
    allReservations().filter(reservationVisible).forEach((entry) => {
      if (overlaps(entry.startAt, entry.endAt, from, to)) {
        const reservationMaterials = entry.items.map((item) => materialIndex.get(item.materialId)).filter(Boolean);
        const canManage = mayManageReservation(user, entry);
        const canEditOwn = mayChangeOwn(user, entry);
        const maySeePersonalDetails = canManage || entry.requesterUserId === user.id;
        events.push({
          id: entry.id,
          kind: 'reservation',
          title: maySeePersonalDetails ? entry.purpose : 'Reserviert',
          startAt: entry.startAt,
          endAt: entry.endAt,
          status: entry.status,
          inventoryNumbers: entry.items.map((item) => item.inventoryNumber),
          materialNames: entry.items.map((item) => item.materialName),
          locationIds: [...new Set(reservationMaterials.map((item) => item.locationId).filter(Boolean))],
          departments: [...new Set(reservationMaterials.map((item) => item.department).filter(Boolean))],
          requesterName: maySeePersonalDetails ? entry.requesterName : null,
          note: maySeePersonalDetails ? entry.note || '' : '',
          approvalRequired: entry.approvalRequired === true,
          canManage,
          canEditOwn,
        });
      }
    });
    maintenanceEvents.forEach((entry) => {
      if (overlaps(entry.startAt, entry.endAt, from, to)) {
        const item = materialIndex.get(entry.materialId);
        events.push({
          ...entry,
          kind: 'maintenance',
          title: entry.type,
          locationIds: item?.locationId ? [item.locationId] : [],
          departments: item?.department ? [item.department] : [],
        });
      }
    });
    allMaterials().filter((item) => materialAccessible(item) && item.inventoryNumber).forEach((item) => {
      for (const [kind, field, title] of [
        ['inspection', 'nextInspectionDate', 'Geplante Prüfung'],
        ['maintenance-due', 'nextMaintenanceDate', 'Geplante Wartung'],
      ]) {
        if (!item[field]) continue;
        const start = new Date(`${item[field]}T00:00:00.000Z`);
        const end = new Date(start.getTime() + 86_400_000);
        if (overlaps(start, end, from, to)) {
          events.push({
            id: `${kind}-${item.id}-${item[field]}`,
            kind,
            title,
            startAt: start.toISOString(),
            endAt: end.toISOString(),
            allDay: true,
            status: 'Geplant',
            materialId: item.id,
            inventoryNumber: item.inventoryNumber,
            materialName: item.name,
            locationIds: item.locationId ? [item.locationId] : [],
            departments: item.department ? [item.department] : [],
          });
        }
      }
    });
    const vehicleIndex = new Map(visibleVehicles().map((vehicle) => [vehicle.id, vehicle]));
    const tenant = currentTenant();
    allVehicleReservations().forEach((entry) => {
      const vehicle = vehicleIndex.get(entry.vehicleId);
      if (!vehicle || ['Abgelehnt', 'Storniert'].includes(entry.status)
          || !overlaps(entry.startAt, entry.endAt, from, to)) return;
      const mayManage = vehicle.unitId === tenant?.unitId
        && hasPermission(user, 'vehicle_reservations.manage');
      const mayApproveOperationally = entry.operationalApprovalRequired === true
        && hasPermission(user, 'vehicle_reservations.operational_approve');
      const maySeePersonalDetails = entry.requesterUserId === user.id
        || mayManage || mayApproveOperationally;
      events.push({
        id: entry.id,
        kind: 'vehicle-reservation',
        title: maySeePersonalDetails ? entry.title || entry.purpose : 'Fahrzeug reserviert',
        startAt: entry.startAt,
        endAt: entry.endAt,
        status: entry.status,
        vehicleId: vehicle.id,
        vehicleName: vehicleName(vehicle),
        inventoryNumbers: [vehicle.registrationNumber],
        materialNames: [vehicleName(vehicle)],
        locationIds: [vehicle.parkingLocationId].filter(Boolean),
        requesterName: maySeePersonalDetails ? entry.requesterName : null,
        destination: maySeePersonalDetails ? entry.destination : null,
        contact: maySeePersonalDetails ? entry.contact : null,
        note: maySeePersonalDetails ? entry.note || '' : '',
        approvalRequired: entry.operationalApprovalRequired === true,
        readOnly: true,
      });
    });
    allVehicleMaintenanceEvents().forEach((entry) => {
      const vehicle = vehicleIndex.get(entry.vehicleId);
      if (!vehicle || ['Abgeschlossen', 'Abgebrochen'].includes(entry.status)) return;
      const startAt = entry.startAt || (entry.dueDate ? `${entry.dueDate}T00:00:00.000Z` : null);
      if (!startAt) return;
      const endAt = entry.endAt || (entry.dueDate ? `${entry.dueDate}T23:59:59.999Z` : startAt);
      if (!overlaps(startAt, endAt, from, to)) return;
      events.push({
        id: entry.id,
        kind: 'vehicle-maintenance',
        title: entry.type || 'Fahrzeugwartung',
        startAt,
        endAt,
        allDay: !entry.startAt,
        status: entry.status,
        vehicleId: vehicle.id,
        vehicleName: vehicleName(vehicle),
        inventoryNumbers: [vehicle.registrationNumber],
        materialNames: [vehicleName(vehicle)],
        locationIds: [vehicle.parkingLocationId].filter(Boolean),
        responsible: entry.workshop || null,
        description: entry.description || '',
        readOnly: true,
      });
    });
    return events.sort((left, right) => left.startAt.localeCompare(right.startAt)).slice(0, MAX_EVENTS);
  }

  function canOverrideMaintenanceConflict(user) {
    return user?.roles?.some((role) => ['Admin', 'Materialwart'].includes(role));
  }

  function retentionMonthsFor(organizationId, unitId) {
    const unit = organizationUnits.find((entry) => entry.id === unitId
      && entry.organizationId === organizationId);
    const organization = organizations.find((entry) => entry.id === organizationId);
    return unit?.calendarRetentionMonths == null
      ? Number(organization?.calendarRetentionMonths ?? 0)
      : Number(unit.calendarRetentionMonths);
  }

  function terminalTimestamp(entry, maintenance = false) {
    const terminal = maintenance
      ? ['Abgeschlossen', 'Abgebrochen'].includes(entry.status)
      : ['Abgelehnt', 'Storniert', 'Abgeschlossen'].includes(entry.status);
    if (!terminal) return null;
    const value = entry.returnedAt || entry.cancelledAt || entry.completedAt
      || entry.updatedAt || entry.endAt;
    const parsed = Date.parse(value || '');
    return Number.isFinite(parsed) ? parsed : null;
  }

  function cutoffForMonths(referenceTime, months) {
    const cutoff = new Date(referenceTime);
    cutoff.setUTCMonth(cutoff.getUTCMonth() - months);
    return cutoff.getTime();
  }

  async function applyCalendarRetentionPolicy(referenceTime = Date.now()) {
    let removedReservations = 0;
    let removedMaintenanceEvents = 0;
    for (const [collection, maintenance] of [
      [allReservations(), false], [allMaintenanceEvents(), true],
    ]) {
      for (let index = collection.length - 1; index >= 0; index -= 1) {
        const entry = collection[index];
        const months = retentionMonthsFor(entry.organizationId, entry.unitId);
        const timestamp = terminalTimestamp(entry, maintenance);
        if (months > 0 && timestamp != null
            && timestamp < cutoffForMonths(referenceTime, months)) {
          collection.splice(index, 1);
          if (maintenance) removedMaintenanceEvents += 1;
          else removedReservations += 1;
        }
      }
    }
    return { removedReservations, removedMaintenanceEvents };
  }

  app.locals.applyCalendarRetentionPolicy = applyCalendarRetentionPolicy;

  app.get('/api/calendar', authMiddleware, requirePermission('calendar.read'), (req, res) => {
    const range = parseRange(req.query);
    if (range.error) return res.status(400).json({ error: range.error });
    const accessibleMaterials = allMaterials().filter((item) => materialAccessible(item));
    const accessibleUnitIds = new Set([
      ...accessibleMaterials.map((item) => item.unitId),
      ...visibleVehicles().map((vehicle) => vehicle.unitId),
    ]);
    const accessibleLocations = allLocations().filter((entry) => entry.organizationId === req.tenant.organizationId
      && accessibleUnitIds.has(entry.unitId));
    return res.json({
      from: range.from.toISOString(),
      to: range.to.toISOString(),
      events: calendarEvents(range.from, range.to, req.user),
      filterOptions: {
        locations: accessibleLocations.map((entry) => ({ id: entry.id, name: entry.name })),
        departments: [...new Set(accessibleMaterials.map((entry) => entry.department).filter(Boolean))].sort(),
      },
      capabilities: {
        canOverrideMaintenanceConflict: canOverrideMaintenanceConflict(req.user),
      },
    });
  });

  app.get('/api/calendar/materials', authMiddleware, requirePermission('calendar.read'), (req, res) => {
    const query = String(req.query.query || '').trim().toLowerCase().slice(0, 255);
    const limit = Math.min(Math.max(Number(req.query.limit) || 50, 1), 100);
    const entries = allMaterials().filter((item) => materialAccessible(item, { requireReservationGrant: true })
      && item.itemType === 'individual' && number(item.quantity) === 1 && item.inventoryNumber
      && (!query || `${item.inventoryNumber} ${item.name}`.toLowerCase().includes(query)))
      .sort((left, right) => String(left.inventoryNumber).localeCompare(String(right.inventoryNumber), 'de'))
      .slice(0, limit).map(publicMaterial);
    return res.json(entries);
  });

  app.get('/api/calendar/settings', authMiddleware, requirePermission('calendar.read'), (req, res) => {
    const organization = organizations.find((entry) => entry.id === req.tenant.organizationId);
    const unit = organizationUnits.find((entry) => entry.id === req.tenant.unitId
      && entry.organizationId === req.tenant.organizationId);
    if (!organization || !unit) return res.status(404).json({ error: 'Organisationskontext nicht gefunden.' });
    return res.json({
      organizationRetentionMonths: Number(organization.calendarRetentionMonths ?? 0),
      unitRetentionMonths: unit.calendarRetentionMonths ?? null,
      effectiveRetentionMonths: retentionMonthsFor(organization.id, unit.id),
      canManage: req.user.roles?.includes('Admin')
        && hasPermission(req.user, 'organizations.write'),
    });
  });

  app.put('/api/calendar/settings', authMiddleware, requirePermission('organizations.write'), (req, res) => {
    if (!req.user.roles?.includes('Admin')) {
      return res.status(403).json({ error: 'Nur Administratoren dürfen die Kalenderaufbewahrung ändern.' });
    }
    const scope = String(req.body.scope || '').trim();
    const rawMonths = req.body.retentionMonths;
    if (!['organization', 'unit'].includes(scope)) {
      return res.status(400).json({ error: 'Der Geltungsbereich muss Organisation oder Einheit sein.' });
    }
    if (scope === 'unit' && rawMonths == null) {
      const unit = organizationUnits.find((entry) => entry.id === req.tenant.unitId
        && entry.organizationId === req.tenant.organizationId);
      if (!unit) return res.status(404).json({ error: 'Organisationseinheit nicht gefunden.' });
      unit.calendarRetentionMonths = null;
    } else {
      const months = Number(rawMonths);
      if (!Number.isInteger(months) || months < 0 || months > MAX_RETENTION_MONTHS) {
        return res.status(400).json({
          error: `Die Aufbewahrung muss 0 (unbegrenzt) oder 1 bis ${MAX_RETENTION_MONTHS} Monate betragen.`,
        });
      }
      if (scope === 'organization') {
        const organization = organizations.find((entry) => entry.id === req.tenant.organizationId);
        if (!organization) return res.status(404).json({ error: 'Organisation nicht gefunden.' });
        organization.calendarRetentionMonths = months;
      } else {
        const unit = organizationUnits.find((entry) => entry.id === req.tenant.unitId
          && entry.organizationId === req.tenant.organizationId);
        if (!unit) return res.status(404).json({ error: 'Organisationseinheit nicht gefunden.' });
        unit.calendarRetentionMonths = months;
      }
    }
    const result = {
      organizationRetentionMonths: Number(organizations.find((entry) =>
        entry.id === req.tenant.organizationId)?.calendarRetentionMonths ?? 0),
      unitRetentionMonths: organizationUnits.find((entry) => entry.id === req.tenant.unitId
        && entry.organizationId === req.tenant.organizationId)?.calendarRetentionMonths ?? null,
      effectiveRetentionMonths: retentionMonthsFor(req.tenant.organizationId, req.tenant.unitId),
      canManage: true,
    };
    logEvent('update', 'CalendarRetention', {
      scope,
      retentionMonths: scope === 'unit' ? result.unitRetentionMonths : result.organizationRetentionMonths,
    }, req.user.username);
    return res.json(result);
  });

  app.get('/api/reservations/:id', authMiddleware, requirePermission('calendar.read'), (req, res) => {
    const entry = allReservations().find((candidate) => candidate.id === req.params.id
      && candidate.organizationId === req.tenant.organizationId);
    if (!entry || !reservationVisible(entry)) {
      return res.status(404).json({ error: 'Reservierung nicht gefunden.' });
    }
    if (entry.requesterUserId !== req.user.id && !mayManageReservation(req.user, entry)) {
      return res.status(403).json({ error: 'Reservierungsdetails dürfen nur durch die anfragende oder verwaltende Person eingesehen werden.' });
    }
    return res.json({
      ...publicReservation(entry),
      canManage: mayManageReservation(req.user, entry),
      canEditOwn: mayChangeOwn(req.user, entry),
    });
  });

  app.post('/api/reservations', authMiddleware, requirePermission('reservations.create'), (req, res) => {
    if (allReservations().filter((entry) =>
      entry.organizationId === req.tenant.organizationId).length >= MAX_EVENTS) {
      return res.status(507).json({ error: 'Die maximale Anzahl an Reservierungen ist erreicht.' });
    }
    const values = reservationValues(req.body);
    if (values.error) return res.status(400).json({ error: values.error });
    const conflict = validateReservationAvailability(values.items, new Date(values.startAt), new Date(values.endAt));
    if (conflict) return res.status(409).json({ error: conflict });
    const approvalRequired = values.items.some(({ materialId, materialUnitId }) =>
      youthUnitsAreLinked(organizationUnits, req.tenant.organizationId,
        req.tenant.unitId, materialUnitId)
      || materialFor(materialId)?.reservationApprovalRequired === true);
    const entry = {
      id: `reservation-${randomUUID()}`,
      organizationId: req.tenant.organizationId,
      unitId: req.tenant.unitId,
      ...values,
      requesterUserId: req.user.id,
      requesterName: req.user.name || req.user.username,
      requesterUnitId: req.tenant.unitId,
      status: approvalRequired ? 'Ausstehend' : 'Freigegeben',
      approvalRequired,
      createdBy: req.user.username,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };
    allReservations().push(entry);
    logEvent('create', 'Reservation', {
      id: entry.id,
      inventoryNumbers: entry.items.map((item) => item.inventoryNumber),
      requesterUnitId: req.tenant.unitId,
      ownerUnitId: entry.items[0]?.materialUnitId || req.tenant.unitId,
    }, req.user.username);
    return res.status(201).json(publicReservation(entry));
  });

  app.put('/api/reservations/:id', authMiddleware, requirePermission('reservations.create'), (req, res) => {
    const entry = allReservations().find((candidate) => candidate.id === req.params.id
      && candidate.organizationId === req.tenant.organizationId);
    if (!entry || !reservationVisible(entry)) {
      return res.status(404).json({ error: 'Reservierung nicht gefunden.' });
    }
    if (!mayChangeOwn(req.user, entry) && !mayManageReservation(req.user, entry)) {
      return res.status(403).json({ error: 'Diese Reservierung darf nicht bearbeitet werden.' });
    }
    const values = reservationValues(req.body, entry);
    if (values.error) return res.status(400).json({ error: values.error });
    const conflict = validateReservationAvailability(values.items, new Date(values.startAt), new Date(values.endAt), entry.id);
    if (conflict) return res.status(409).json({ error: conflict });
    const approvalRequired = values.items.some(({ materialId, materialUnitId }) =>
      youthUnitsAreLinked(organizationUnits, req.tenant.organizationId,
        req.tenant.unitId, materialUnitId)
      || materialFor(materialId)?.reservationApprovalRequired === true);
    Object.assign(entry, values, {
      approvalRequired,
      status: approvalRequired ? 'Ausstehend' : 'Freigegeben',
      approvedAt: null,
      approvedBy: null,
      updatedAt: new Date().toISOString(),
    });
    logEvent('update', 'Reservation', { id: entry.id }, req.user.username);
    return res.json(publicReservation(entry));
  });

  app.post('/api/reservations/:id/decision', authMiddleware, requirePermission('reservations.manage'), (req, res) => {
    const entry = allReservations().find((candidate) => candidate.id === req.params.id
      && candidate.organizationId === req.tenant.organizationId);
    if (!entry) return res.status(404).json({ error: 'Reservierung nicht gefunden.' });
    if (!mayManageReservation(req.user, entry)) return res.status(403).json({ error: 'Diese Reservierung darf nicht freigegeben werden.' });
    if (entry.status !== 'Ausstehend') return res.status(409).json({ error: 'Nur ausstehende Reservierungen können entschieden werden.' });
    const approved = req.body.approved === true;
    if (approved) {
      const conflict = validateReservationAvailability(entry.items, new Date(entry.startAt), new Date(entry.endAt), entry.id);
      if (conflict) return res.status(409).json({ error: conflict });
    }
    entry.status = approved ? 'Freigegeben' : 'Abgelehnt';
    entry.approvedAt = approved ? new Date().toISOString() : null;
    entry.approvedBy = approved ? req.user.username : null;
    entry.rejectionReason = approved ? null : String(req.body.reason || '').trim().slice(0, 1_000);
    entry.updatedAt = new Date().toISOString();
    logEvent(approved ? 'approve' : 'reject', 'Reservation', { id: entry.id }, req.user.username);
    return res.json(publicReservation(entry));
  });

  app.post('/api/reservations/:id/cancel', authMiddleware, requirePermission('reservations.create'), (req, res) => {
    const entry = allReservations().find((candidate) => candidate.id === req.params.id
      && candidate.organizationId === req.tenant.organizationId);
    if (!entry || !reservationVisible(entry)) {
      return res.status(404).json({ error: 'Reservierung nicht gefunden.' });
    }
    if (!mayChangeOwn(req.user, entry) && !mayManageReservation(req.user, entry)) {
      return res.status(403).json({ error: 'Diese Reservierung darf nicht storniert werden.' });
    }
    if (!ACTIVE_RESERVATION_STATUSES.has(entry.status)) return res.status(409).json({ error: 'Die Reservierung kann nicht mehr storniert werden.' });
    entry.status = 'Storniert';
    entry.cancelledAt = new Date().toISOString();
    entry.cancelledBy = req.user.username;
    entry.updatedAt = entry.cancelledAt;
    logEvent('cancel', 'Reservation', { id: entry.id }, req.user.username);
    return res.json(publicReservation(entry));
  });

  app.post('/api/reservations/:id/issue', authMiddleware, requirePermission('reservations.manage'), (req, res) => {
    const entry = allReservations().find((candidate) => candidate.id === req.params.id
      && candidate.organizationId === req.tenant.organizationId);
    if (!entry) return res.status(404).json({ error: 'Reservierung nicht gefunden.' });
    if (!mayManageReservation(req.user, entry)) return res.status(403).json({ error: 'Diese Reservierung darf nicht ausgegeben werden.' });
    if (entry.status !== 'Freigegeben') return res.status(409).json({ error: 'Nur freigegebene Reservierungen können ausgegeben werden.' });
    const checked = entry.items.map((reserved) => ({
      reserved, item: materialForReservationItem(reserved),
    }));
    if (checked.some(({ reserved, item }) => !item || unavailableReason(item)
      || number(item.quantity) - number(item.issuedQuantity) < reserved.quantity)) {
      return res.status(409).json({ error: 'Mindestens eine Materialposition ist nicht mehr verfügbar.' });
    }
    const createdAt = new Date().toISOString();
    entry.issuedMovements = checked.map(({ reserved, item }) => {
      item.issuedQuantity = number(item.issuedQuantity) + reserved.quantity;
      item.status = 'Ausgegeben';
      const movement = {
        id: `movement-${randomUUID()}`,
        organizationId: item.organizationId,
        unitId: item.unitId,
        materialId: item.id,
        action: 'issue',
        quantity: reserved.quantity,
        recipientType: 'person',
        recipient: entry.requesterName,
        plannedReturnDate: entry.endAt.slice(0, 10),
        notes: `Reservierung: ${entry.purpose}`,
        actor: req.user.username,
        createdAt,
      };
      allMaterialMovements().push(movement);
      return movement.id;
    });
    entry.status = 'Ausgegeben';
    entry.issuedAt = createdAt;
    entry.issuedBy = req.user.username;
    entry.updatedAt = createdAt;
    logEvent('issue', 'Reservation', { id: entry.id }, req.user.username);
    return res.json(publicReservation(entry));
  });

  app.post('/api/reservations/:id/return', authMiddleware, requirePermission('reservations.manage'), (req, res) => {
    const entry = allReservations().find((candidate) => candidate.id === req.params.id
      && candidate.organizationId === req.tenant.organizationId);
    if (!entry) return res.status(404).json({ error: 'Reservierung nicht gefunden.' });
    if (!mayManageReservation(req.user, entry)) return res.status(403).json({ error: 'Diese Reservierung darf nicht zurückgenommen werden.' });
    if (entry.status !== 'Ausgegeben') return res.status(409).json({ error: 'Nur ausgegebene Reservierungen können zurückgenommen werden.' });
    const checked = entry.items.map((reserved) => ({
      reserved, item: materialForReservationItem(reserved),
    }));
    if (checked.some(({ reserved, item }) => !item || number(item.issuedQuantity) < reserved.quantity)) {
      return res.status(409).json({ error: 'Die Rückgabe kann wegen eines inkonsistenten Bestands nicht gebucht werden.' });
    }
    const createdAt = new Date().toISOString();
    checked.forEach(({ reserved, item }) => {
      item.issuedQuantity = number(item.issuedQuantity) - reserved.quantity;
      item.status = defectManagement?.hasOpenDefect('MaterialItem', item.id)
        ? 'Defekt' : item.issuedQuantity > 0 ? 'Ausgegeben' : 'Lagernd';
      allMaterialMovements().push({
        id: `movement-${randomUUID()}`,
        organizationId: item.organizationId,
        unitId: item.unitId,
        materialId: item.id,
        action: 'return',
        quantity: reserved.quantity,
        recipientType: null,
        recipient: null,
        plannedReturnDate: null,
        notes: `Reservierung: ${entry.purpose}`,
        actor: req.user.username,
        createdAt,
      });
    });
    entry.status = 'Abgeschlossen';
    entry.returnedAt = createdAt;
    entry.returnedBy = req.user.username;
    entry.updatedAt = createdAt;
    logEvent('return', 'Reservation', { id: entry.id }, req.user.username);
    return res.json(publicReservation(entry));
  });

  app.post('/api/maintenance', authMiddleware, requirePermission('maintenance.manage'), (req, res) => {
    if (maintenanceEvents.length >= MAX_EVENTS) return res.status(507).json({ error: 'Die maximale Anzahl an Wartungen ist erreicht.' });
    const values = maintenanceValues(req.body);
    if (values.error) return res.status(400).json({ error: values.error });
    const start = new Date(values.startAt);
    const end = new Date(values.endAt);
    const reserved = reservedQuantity(values.materialId, start, end);
    if (reserved > 0 && req.body.overrideConflict !== true) {
      return res.status(409).json({ error: 'Im gewählten Zeitraum besteht bereits eine Reservierung.' });
    }
    if (reserved > 0 && req.body.overrideConflict === true
        && !canOverrideMaintenanceConflict(req.user)) {
      return res.status(403).json({
        error: 'Nur Administratoren oder Materialwarte dürfen einen Reservierungskonflikt übersteuern.',
      });
    }
    if (maintenanceConflict(values.materialId, start, end)) return res.status(409).json({ error: 'Im gewählten Zeitraum besteht bereits eine Wartung.' });
    if (reserved > 0 && !String(req.body.overrideReason || '').trim()) {
      return res.status(400).json({ error: 'Für die Konfliktübersteuerung ist eine Begründung erforderlich.' });
    }
    const entry = {
      id: `maintenance-${randomUUID()}`,
      ...values,
      overrideReason: reserved > 0 ? String(req.body.overrideReason).trim().slice(0, 1_000) : null,
      createdBy: req.user.username,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };
    maintenanceEvents.push(entry);
    logEvent('create', 'MaintenanceEvent', { id: entry.id, inventoryNumber: entry.inventoryNumber, overrideReason: entry.overrideReason }, req.user.username);
    return res.status(201).json(entry);
  });

  app.put('/api/maintenance/:id', authMiddleware, requirePermission('maintenance.manage'), (req, res) => {
    const entry = maintenanceEvents.find((candidate) => candidate.id === req.params.id);
    if (!entry) return res.status(404).json({ error: 'Wartung nicht gefunden.' });
    const values = maintenanceValues(req.body, entry);
    if (values.error) return res.status(400).json({ error: values.error });
    const start = new Date(values.startAt);
    const end = new Date(values.endAt);
    const reserved = ACTIVE_MAINTENANCE_STATUSES.has(values.status)
      ? reservedQuantity(values.materialId, start, end) : 0;
    if (reserved > 0 && req.body.overrideConflict !== true) {
      return res.status(409).json({ error: 'Im gewählten Zeitraum besteht bereits eine Reservierung.' });
    }
    if (reserved > 0 && req.body.overrideConflict === true
        && !canOverrideMaintenanceConflict(req.user)) {
      return res.status(403).json({
        error: 'Nur Administratoren oder Materialwarte dürfen einen Reservierungskonflikt übersteuern.',
      });
    }
    if (ACTIVE_MAINTENANCE_STATUSES.has(values.status)
        && maintenanceConflict(values.materialId, start, end, entry.id)) {
      return res.status(409).json({ error: 'Im gewählten Zeitraum besteht bereits eine Wartung.' });
    }
    if (reserved > 0 && !String(req.body.overrideReason || entry.overrideReason || '').trim()) {
      return res.status(400).json({ error: 'Für die Konfliktübersteuerung ist eine Begründung erforderlich.' });
    }
    let nextMaintenanceDate;
    if (values.status === 'Abgeschlossen' && req.body.nextMaintenanceDate != null) {
      nextMaintenanceDate = String(req.body.nextMaintenanceDate || '').trim();
      if (nextMaintenanceDate && !/^\d{4}-\d{2}-\d{2}$/.test(nextMaintenanceDate)) {
        return res.status(400).json({ error: 'Der nächste Wartungstermin ist ungültig.' });
      }
    }
    Object.assign(entry, values, {
      overrideReason: reserved > 0
        ? String(req.body.overrideReason || entry.overrideReason).trim().slice(0, 1_000) : null,
      updatedAt: new Date().toISOString(),
      completedAt: values.status === 'Abgeschlossen' ? new Date().toISOString() : entry.completedAt || null,
    });
    if (nextMaintenanceDate !== undefined) {
      const item = ownedMaterialFor(values.materialId);
      item.nextMaintenanceDate = nextMaintenanceDate || null;
    }
    logEvent('update', 'MaintenanceEvent', { id: entry.id, status: entry.status }, req.user.username);
    return res.json(entry);
  });

  app.get('/api/calendar/export', authMiddleware, requirePermission('calendar.read'), (req, res) => {
    const range = parseRange(req.query);
    if (range.error) return res.status(400).json({ error: range.error });
    const escape = (value) => String(value || '').replace(/([,;\\])/g, '\\$1').replace(/\r?\n/g, '\\n');
    const stamp = (value) => new Date(value).toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
    const lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//MaterialKompass//Kalender//DE', 'CALSCALE:GREGORIAN'];
    calendarEvents(range.from, range.to, req.user).forEach((entry) => {
      lines.push('BEGIN:VEVENT');
      lines.push(`UID:${escape(entry.id)}@materialkompass`);
      lines.push(`DTSTAMP:${stamp(new Date())}`);
      lines.push(`DTSTART:${stamp(entry.startAt)}`);
      lines.push(`DTEND:${stamp(entry.endAt)}`);
      lines.push(`SUMMARY:${escape(entry.title)}`);
      const details = [entry.inventoryNumber, ...(entry.inventoryNumbers || []), entry.materialName, ...(entry.materialNames || [])].filter(Boolean);
      if (details.length) lines.push(`DESCRIPTION:${escape([...new Set(details)].join(' · '))}`);
      lines.push('END:VEVENT');
    });
    lines.push('END:VCALENDAR');
    const content = `${lines.join('\r\n')}\r\n`;
    return res.json({
      fileName: `materialkompass-kalender-${range.from.toISOString().slice(0, 10)}.ics`,
      mimeType: 'text/calendar;charset=utf-8',
      fileBase64: Buffer.from(content, 'utf8').toString('base64'),
    });
  });
}

module.exports = { registerCalendarRoutes };
