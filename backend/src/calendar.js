const { randomUUID } = require('node:crypto');

const ACTIVE_RESERVATION_STATUSES = new Set(['Ausstehend', 'Freigegeben']);
const ACTIVE_MAINTENANCE_STATUSES = new Set(['Geplant', 'In Arbeit']);
const RESERVATION_STATUSES = new Set([
  'Ausstehend', 'Freigegeben', 'Abgelehnt', 'Storniert', 'Ausgegeben', 'Abgeschlossen',
]);
const MAINTENANCE_STATUSES = new Set(['Geplant', 'In Arbeit', 'Abgeschlossen', 'Abgebrochen']);
const MAX_RANGE_DAYS = 370;
const MAX_EVENTS = 10_000;
const MAX_ITEMS = 100;

function registerCalendarRoutes({
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

  function materialFor(id) {
    return materials.find((entry) => entry.id === id && !entry.archived);
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
      reservationApprovalRequired: item.reservationApprovalRequired === true,
      nextInspectionDate: item.nextInspectionDate || null,
      nextMaintenanceDate: item.nextMaintenanceDate || null,
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
      const item = materialFor(materialId);
      if (!item || !String(item.inventoryNumber || '').trim()) {
        return { error: 'Reserviert werden kann nur aktives Material mit Inventarnummer.' };
      }
      if (!Number.isInteger(quantity) || quantity < 1) {
        return { error: 'Die reservierte Menge muss eine positive ganze Zahl sein.' };
      }
      const existing = combined.get(materialId);
      combined.set(materialId, {
        materialId,
        inventoryNumber: item.inventoryNumber,
        materialName: item.name,
        quantity: quantity + (existing?.quantity || 0),
      });
    }
    return { items: [...combined.values()] };
  }

  function unavailableReason(item) {
    if (['Defekt', 'In Reparatur', 'Ausgesondert', 'Verloren'].includes(item.status)) {
      return `„${item.inventoryNumber}“ ist wegen des Status „${item.status}“ nicht reservierbar.`;
    }
    return null;
  }

  function reservedQuantity(materialId, from, to, ignoredReservationId = null) {
    return reservations.reduce((sum, entry) => {
      if (entry.id === ignoredReservationId || !ACTIVE_RESERVATION_STATUSES.has(entry.status)
          || !overlaps(entry.startAt, entry.endAt, from, to)) return sum;
      const item = entry.items.find((candidate) => candidate.materialId === materialId);
      return sum + number(item?.quantity);
    }, 0);
  }

  function maintenanceConflict(materialId, from, to, ignoredMaintenanceId = null) {
    return maintenanceEvents.some((entry) => entry.id !== ignoredMaintenanceId
      && entry.materialId === materialId
      && ACTIVE_MAINTENANCE_STATUSES.has(entry.status)
      && overlaps(entry.startAt, entry.endAt, from, to));
  }

  function validateReservationAvailability(items, from, to, ignoredReservationId = null) {
    for (const requested of items) {
      const item = materialFor(requested.materialId);
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
      allDay: body.allDay ?? existing?.allDay ?? false,
      items: normalized.items,
    };
  }

  function maintenanceValues(body, existing = null) {
    const materialId = String(body.materialId ?? existing?.materialId ?? '').trim();
    const item = materialFor(materialId);
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
    reservations.forEach((entry) => {
      if (overlaps(entry.startAt, entry.endAt, from, to)) {
        const reservationMaterials = entry.items.map((item) => materialFor(item.materialId)).filter(Boolean);
        events.push({
          id: entry.id,
          kind: 'reservation',
          title: entry.purpose,
          startAt: entry.startAt,
          endAt: entry.endAt,
          status: entry.status,
          inventoryNumbers: entry.items.map((item) => item.inventoryNumber),
          materialNames: entry.items.map((item) => item.materialName),
          locationIds: [...new Set(reservationMaterials.map((item) => item.locationId).filter(Boolean))],
          departments: [...new Set(reservationMaterials.map((item) => item.department).filter(Boolean))],
          requesterName: entry.requesterName,
          note: entry.note || '',
          approvalRequired: entry.approvalRequired === true,
          canManage: mayManageReservation(user, entry),
          canEditOwn: mayChangeOwn(user, entry),
        });
      }
    });
    maintenanceEvents.forEach((entry) => {
      if (overlaps(entry.startAt, entry.endAt, from, to)) {
        const item = materialFor(entry.materialId);
        events.push({
          ...entry,
          kind: 'maintenance',
          title: entry.type,
          locationIds: item?.locationId ? [item.locationId] : [],
          departments: item?.department ? [item.department] : [],
        });
      }
    });
    materials.filter((item) => !item.archived && item.inventoryNumber).forEach((item) => {
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
    return events.sort((left, right) => left.startAt.localeCompare(right.startAt)).slice(0, MAX_EVENTS);
  }

  app.get('/api/calendar', authMiddleware, requirePermission('calendar.read'), (req, res) => {
    const range = parseRange(req.query);
    if (range.error) return res.status(400).json({ error: range.error });
    return res.json({
      from: range.from.toISOString(),
      to: range.to.toISOString(),
      events: calendarEvents(range.from, range.to, req.user),
      filterOptions: {
        locations: locations.map((entry) => ({ id: entry.id, name: entry.name })),
        departments: [...new Set(materials.map((entry) => entry.department).filter(Boolean))].sort(),
      },
    });
  });

  app.get('/api/calendar/materials', authMiddleware, requirePermission('calendar.read'), (req, res) => {
    const query = String(req.query.query || '').trim().toLowerCase().slice(0, 255);
    const limit = Math.min(Math.max(Number(req.query.limit) || 50, 1), 100);
    const entries = materials.filter((item) => !item.archived && item.inventoryNumber
      && (!query || `${item.inventoryNumber} ${item.name}`.toLowerCase().includes(query)))
      .slice(0, limit).map(publicMaterial);
    return res.json(entries);
  });

  app.get('/api/reservations/:id', authMiddleware, requirePermission('calendar.read'), (req, res) => {
    const entry = reservations.find((candidate) => candidate.id === req.params.id);
    if (!entry) return res.status(404).json({ error: 'Reservierung nicht gefunden.' });
    return res.json({
      ...publicReservation(entry),
      canManage: mayManageReservation(req.user, entry),
      canEditOwn: mayChangeOwn(req.user, entry),
    });
  });

  app.post('/api/reservations', authMiddleware, requirePermission('reservations.create'), (req, res) => {
    if (reservations.length >= MAX_EVENTS) return res.status(507).json({ error: 'Die maximale Anzahl an Reservierungen ist erreicht.' });
    const values = reservationValues(req.body);
    if (values.error) return res.status(400).json({ error: values.error });
    const conflict = validateReservationAvailability(values.items, new Date(values.startAt), new Date(values.endAt));
    if (conflict) return res.status(409).json({ error: conflict });
    const approvalRequired = values.items.some(({ materialId }) => materialFor(materialId)?.reservationApprovalRequired === true);
    const entry = {
      id: `reservation-${randomUUID()}`,
      ...values,
      requesterUserId: req.user.id,
      requesterName: req.user.name || req.user.username,
      status: approvalRequired ? 'Ausstehend' : 'Freigegeben',
      approvalRequired,
      createdBy: req.user.username,
      createdAt: new Date().toISOString(),
      updatedAt: new Date().toISOString(),
    };
    reservations.push(entry);
    logEvent('create', 'Reservation', { id: entry.id, inventoryNumbers: entry.items.map((item) => item.inventoryNumber) }, req.user.username);
    return res.status(201).json(publicReservation(entry));
  });

  app.put('/api/reservations/:id', authMiddleware, requirePermission('reservations.create'), (req, res) => {
    const entry = reservations.find((candidate) => candidate.id === req.params.id);
    if (!entry) return res.status(404).json({ error: 'Reservierung nicht gefunden.' });
    if (!mayChangeOwn(req.user, entry) && !mayManageReservation(req.user, entry)) {
      return res.status(403).json({ error: 'Diese Reservierung darf nicht bearbeitet werden.' });
    }
    const values = reservationValues(req.body, entry);
    if (values.error) return res.status(400).json({ error: values.error });
    const conflict = validateReservationAvailability(values.items, new Date(values.startAt), new Date(values.endAt), entry.id);
    if (conflict) return res.status(409).json({ error: conflict });
    const approvalRequired = values.items.some(({ materialId }) => materialFor(materialId)?.reservationApprovalRequired === true);
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
    const entry = reservations.find((candidate) => candidate.id === req.params.id);
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
    const entry = reservations.find((candidate) => candidate.id === req.params.id);
    if (!entry) return res.status(404).json({ error: 'Reservierung nicht gefunden.' });
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
    const entry = reservations.find((candidate) => candidate.id === req.params.id);
    if (!entry) return res.status(404).json({ error: 'Reservierung nicht gefunden.' });
    if (!mayManageReservation(req.user, entry)) return res.status(403).json({ error: 'Diese Reservierung darf nicht ausgegeben werden.' });
    if (entry.status !== 'Freigegeben') return res.status(409).json({ error: 'Nur freigegebene Reservierungen können ausgegeben werden.' });
    const checked = entry.items.map((reserved) => ({ reserved, item: materialFor(reserved.materialId) }));
    if (checked.some(({ reserved, item }) => !item || unavailableReason(item)
      || number(item.quantity) - number(item.issuedQuantity) < reserved.quantity)) {
      return res.status(409).json({ error: 'Mindestens eine Materialposition ist nicht mehr verfügbar.' });
    }
    const createdAt = new Date().toISOString();
    entry.issuedMovements = checked.map(({ reserved, item }) => {
      item.issuedQuantity = number(item.issuedQuantity) + reserved.quantity;
      item.status = 'Ausgegeben';
      const movement = {
        id: nextId('movement', materialMovements),
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
      materialMovements.push(movement);
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
    const entry = reservations.find((candidate) => candidate.id === req.params.id);
    if (!entry) return res.status(404).json({ error: 'Reservierung nicht gefunden.' });
    if (!mayManageReservation(req.user, entry)) return res.status(403).json({ error: 'Diese Reservierung darf nicht zurückgenommen werden.' });
    if (entry.status !== 'Ausgegeben') return res.status(409).json({ error: 'Nur ausgegebene Reservierungen können zurückgenommen werden.' });
    const checked = entry.items.map((reserved) => ({ reserved, item: materialFor(reserved.materialId) }));
    if (checked.some(({ reserved, item }) => !item || number(item.issuedQuantity) < reserved.quantity)) {
      return res.status(409).json({ error: 'Die Rückgabe kann wegen eines inkonsistenten Bestands nicht gebucht werden.' });
    }
    const createdAt = new Date().toISOString();
    checked.forEach(({ reserved, item }) => {
      item.issuedQuantity = number(item.issuedQuantity) - reserved.quantity;
      item.status = defectManagement?.hasOpenDefect('MaterialItem', item.id)
        ? 'Defekt' : item.issuedQuantity > 0 ? 'Ausgegeben' : 'Lagernd';
      materialMovements.push({
        id: nextId('movement', materialMovements),
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
    if (ACTIVE_MAINTENANCE_STATUSES.has(values.status)
        && maintenanceConflict(values.materialId, start, end, entry.id)) {
      return res.status(409).json({ error: 'Im gewählten Zeitraum besteht bereits eine Wartung.' });
    }
    if (reserved > 0 && !String(req.body.overrideReason || entry.overrideReason || '').trim()) {
      return res.status(400).json({ error: 'Für die Konfliktübersteuerung ist eine Begründung erforderlich.' });
    }
    Object.assign(entry, values, {
      overrideReason: reserved > 0
        ? String(req.body.overrideReason || entry.overrideReason).trim().slice(0, 1_000) : null,
      updatedAt: new Date().toISOString(),
      completedAt: values.status === 'Abgeschlossen' ? new Date().toISOString() : entry.completedAt || null,
    });
    if (values.status === 'Abgeschlossen' && req.body.nextMaintenanceDate != null) {
      const item = materialFor(values.materialId);
      const date = String(req.body.nextMaintenanceDate || '').trim();
      if (date && !/^\d{4}-\d{2}-\d{2}$/.test(date)) return res.status(400).json({ error: 'Der nächste Wartungstermin ist ungültig.' });
      item.nextMaintenanceDate = date || null;
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
