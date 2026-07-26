const BOX_STATUSES = ['aktiv', 'gesperrt', 'defekt', 'unterwegs', 'deaktiviert', 'archiviert'];
const STOCKTAKE_STATUSES = ['Geplant', 'Laufend', 'Abgeschlossen'];
const SCOPE_TYPES = ['location', 'rack', 'level', 'place', 'box', 'inventory', 'wardrobe', 'category'];

function text(value) {
  return String(value ?? '').trim();
}

function finiteNumber(value, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function csvCell(value) {
  const string = String(value ?? '');
  return /[;"\r\n]/.test(string) ? `"${string.replaceAll('"', '""')}"` : string;
}

function pdfBuffer(inputPages) {
  const pages = Array.isArray(inputPages[0]) ? inputPages : [inputPages];
  const escape = (value) => String(value)
    .replaceAll('\\', '\\\\').replaceAll('(', '\\(').replaceAll(')', '\\)')
    .replace(/[^\x20-\x7e]/g, '?');
  const pageCount = pages.length;
  const fontId = 3 + pageCount * 2;
  const objects = [
    '<< /Type /Catalog /Pages 2 0 R >>',
    `<< /Type /Pages /Kids [${pages.map((_, index) => `${3 + index * 2} 0 R`).join(' ')}] /Count ${pageCount} >>`,
  ];
  pages.forEach((lines, pageIndex) => {
    const content = ['BT', '/F1 9 Tf', '40 800 Td'];
    lines.slice(0, 52).forEach((line, index) => {
      if (index) content.push('0 -14 Td');
      content.push(`(${escape(line).slice(0, 115)}) Tj`);
    });
    content.push('ET');
    const stream = content.join('\n');
    objects.push(
      `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 ${fontId} 0 R >> >> /Contents ${4 + pageIndex * 2} 0 R >>`,
      `<< /Length ${Buffer.byteLength(stream)} >>\nstream\n${stream}\nendstream`,
    );
  });
  objects.push('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
  let output = '%PDF-1.4\n';
  const offsets = [0];
  objects.forEach((object, index) => {
    offsets.push(Buffer.byteLength(output));
    output += `${index + 1} 0 obj\n${object}\nendobj\n`;
  });
  const xref = Buffer.byteLength(output);
  output += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  offsets.slice(1).forEach((offset) => { output += `${String(offset).padStart(10, '0')} 00000 n \n`; });
  output += `trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF`;
  return Buffer.from(output, 'binary');
}

function registerStorageManagementRoutes({
  app, authMiddleware, requirePermission, data, locations, materials, clothingItems,
  categories, logEvent, nextId, XLSX,
}) {
  const racks = (data.storageRacks ||= []);
  const levels = (data.storageLevels ||= []);
  const places = (data.storagePlaces ||= []);
  const boxes = (data.storageBoxes ||= []);
  const assignments = (data.storageAssignments ||= []);
  const stocktakes = (data.stocktakes ||= []);
  const storageHistory = (data.storageHistory ||= []);
  const managedLocations = () => locations.filter((entry) => entry.storageModelVersion === 2);

  const active = (entry) => entry && entry.active !== false && !entry.archivedAt;
  const locationForRack = (rack) => locations.find((entry) => entry.id === rack?.locationId);
  const rackForLevel = (level) => racks.find((entry) => entry.id === level?.rackId);
  const levelForPlace = (place) => levels.find((entry) => entry.id === place?.levelId);
  const rackForPlace = (place) => rackForLevel(levelForPlace(place));
  const locationForPlace = (place) => locationForRack(rackForPlace(place));

  function placeCode(place) {
    const level = levelForPlace(place);
    const rack = rackForLevel(level);
    const location = locationForRack(rack);
    if (!location || !rack || !level) return '';
    return `${location.code}-R${String(rack.number).padStart(3, '0')}-E${String(level.number).padStart(2, '0')}-P${String(place.number).padStart(2, '0')}`;
  }

  function record(action, entityType, entityId, details, user) {
    const entry = {
      id: nextId('storage-history', storageHistory), action, entityType, entityId,
      details, actor: user.username, createdAt: new Date().toISOString(),
    };
    storageHistory.push(entry);
    logEvent(action, entityType, { id: entityId, ...details }, user.username);
  }

  function hierarchyResponse() {
    return managedLocations().map((location) => ({
      ...location,
      racks: racks.filter((rack) => rack.locationId === location.id)
        .sort((a, b) => finiteNumber(a.sortOrder, a.number) - finiteNumber(b.sortOrder, b.number))
        .map((rack) => ({
          ...rack,
          levels: levels.filter((level) => level.rackId === rack.id)
            .sort((a, b) => finiteNumber(a.sortOrder, a.number) - finiteNumber(b.sortOrder, b.number))
            .map((level) => ({
              ...level,
              places: places.filter((place) => place.levelId === level.id)
                .sort((a, b) => finiteNumber(a.sortOrder, a.number) - finiteNumber(b.sortOrder, b.number))
                .map((place) => ({
                  ...place,
                  code: placeCode(place),
                  boxes: boxes.filter((box) => box.storagePlaceId === place.id),
                })),
            })),
        })),
    }));
  }

  function validateLocationBody(body, existing = {}) {
    const result = {
      name: text(body.name ?? existing.name),
      code: text(body.code ?? existing.code).toUpperCase(),
      type: text(body.type ?? existing.type),
      street: text(body.street ?? existing.street),
      houseNumber: text(body.houseNumber ?? existing.houseNumber),
      postalCode: text(body.postalCode ?? existing.postalCode),
      city: text(body.city ?? existing.city),
      country: text(body.country ?? existing.country),
      addressExtra: text(body.addressExtra ?? existing.addressExtra),
      building: text(body.building ?? existing.building),
      contactName: text(body.contactName ?? existing.contactName),
      contactPhone: text(body.contactPhone ?? existing.contactPhone),
      notes: text(body.notes ?? existing.notes),
      storageModelVersion: 2,
      active: body.active ?? existing.active ?? true,
      sortOrder: finiteNumber(body.sortOrder, existing.sortOrder ?? managedLocations().length),
    };
    if (!result.name || !result.code || !result.type || !result.street || !result.houseNumber
      || !result.postalCode || !result.city || !result.country) {
      return { error: 'Name, Kürzel, Typ und die vollständige Adresse sind erforderlich.' };
    }
    if (!/^[A-Z0-9_-]{1,16}$/.test(result.code)) {
      return { error: 'Das Kürzel darf nur Buchstaben, Zahlen, _ und - enthalten.' };
    }
    return result;
  }

  app.get('/api/storage/hierarchy', authMiddleware, requirePermission('locations.read'), (_req, res) => {
    res.json(hierarchyResponse());
  });

  app.get('/api/storage/history', authMiddleware, requirePermission('locations.read'), (_req, res) => {
    res.json(storageHistory.slice().reverse());
  });

  app.post('/api/storage/locations', authMiddleware, requirePermission('locations.write'), (req, res) => {
    const values = validateLocationBody(req.body);
    if (values.error) return res.status(400).json({ error: values.error });
    if (locations.some((entry) => entry.name.toLowerCase() === values.name.toLowerCase()
      || entry.code.toLowerCase() === values.code.toLowerCase())) {
      return res.status(409).json({ error: 'Name oder Kürzel wird bereits verwendet.' });
    }
    const location = { id: nextId('loc', locations), ...values, createdAt: new Date().toISOString() };
    locations.push(location);
    record('create', 'Location', location.id, {}, req.user);
    return res.status(201).json(location);
  });

  app.put('/api/storage/locations/:id', authMiddleware, requirePermission('locations.write'), (req, res) => {
    const location = managedLocations().find((entry) => entry.id === req.params.id);
    if (!location) return res.status(404).json({ error: 'Standort nicht gefunden.' });
    const values = validateLocationBody(req.body, location);
    if (values.error) return res.status(400).json({ error: values.error });
    if (locations.some((entry) => entry.id !== location.id
      && (entry.name.toLowerCase() === values.name.toLowerCase()
        || entry.code.toLowerCase() === values.code.toLowerCase()))) {
      return res.status(409).json({ error: 'Name oder Kürzel wird bereits verwendet.' });
    }
    Object.assign(location, values, { updatedAt: new Date().toISOString() });
    record('update', 'Location', location.id, {}, req.user);
    return res.json(location);
  });

  function hierarchyEntityRoutes({
    path, collection, parentCollection, parentField, parentLabel, entityType, prefix, digits,
  }) {
    const parents = () => typeof parentCollection === 'function' ? parentCollection() : parentCollection;
    app.post(`/api/storage/${path}`, authMiddleware, requirePermission('locations.write'), (req, res) => {
      const parentId = text(req.body[parentField]);
      const number = Number.parseInt(req.body.number, 10);
      const name = text(req.body.name) || `${entityType} ${number}`;
      if (!parents().some((entry) => entry.id === parentId) || !Number.isInteger(number) || number < 1) {
        return res.status(400).json({ error: `${parentLabel}, Bezeichnung und eine positive Nummer sind erforderlich.` });
      }
      if (collection.some((entry) => entry[parentField] === parentId
        && (entry.number === number || entry.name.toLowerCase() === name.toLowerCase()))) {
        return res.status(409).json({ error: 'Nummer oder Bezeichnung ist innerhalb der übergeordneten Ebene bereits vorhanden.' });
      }
      const entity = {
        id: nextId(prefix, collection), [parentField]: parentId, number, name,
        sortOrder: finiteNumber(req.body.sortOrder, number), active: req.body.active !== false,
        createdAt: new Date().toISOString(),
      };
      collection.push(entity);
      record('create', entityType, entity.id, { [parentField]: parentId }, req.user);
      return res.status(201).json(entityType === 'StoragePlace' ? { ...entity, code: placeCode(entity) } : entity);
    });

    app.put(`/api/storage/${path}/:id`, authMiddleware, requirePermission('locations.write'), (req, res) => {
      const entity = collection.find((entry) => entry.id === req.params.id);
      if (!entity) return res.status(404).json({ error: `${entityType} nicht gefunden.` });
      const parentId = text(req.body[parentField] ?? entity[parentField]);
      const number = Number.parseInt(req.body.number ?? entity.number, 10);
      const name = text(req.body.name ?? entity.name);
      if (!parents().some((entry) => entry.id === parentId) || !name || !Number.isInteger(number) || number < 1) {
        return res.status(400).json({ error: `${parentLabel}, Bezeichnung und eine positive Nummer sind erforderlich.` });
      }
      if (collection.some((entry) => entry.id !== entity.id && entry[parentField] === parentId
        && (entry.number === number || entry.name.toLowerCase() === name.toLowerCase()))) {
        return res.status(409).json({ error: 'Nummer oder Bezeichnung ist innerhalb der übergeordneten Ebene bereits vorhanden.' });
      }
      const previousParentId = entity[parentField];
      Object.assign(entity, {
        [parentField]: parentId, number, name,
        sortOrder: finiteNumber(req.body.sortOrder, entity.sortOrder ?? number),
        active: req.body.active ?? entity.active ?? true, updatedAt: new Date().toISOString(),
      });
      record('update', entityType, entity.id, { previousParentId, [parentField]: parentId }, req.user);
      return res.json(entityType === 'StoragePlace' ? { ...entity, code: placeCode(entity) } : entity);
    });

    app.post(`/api/storage/${path}/:id/deactivate`, authMiddleware, requirePermission('locations.write'), (req, res) => {
      const entity = collection.find((entry) => entry.id === req.params.id);
      if (!entity) return res.status(404).json({ error: `${entityType} nicht gefunden.` });
      entity.active = false;
      entity.deactivatedAt = new Date().toISOString();
      record('deactivate', entityType, entity.id, {}, req.user);
      return res.json(entity);
    });
  }

  hierarchyEntityRoutes({
    path: 'racks', collection: racks, parentCollection: managedLocations, parentField: 'locationId',
    parentLabel: 'Standort', entityType: 'Rack', prefix: 'rack', digits: 3,
  });
  hierarchyEntityRoutes({
    path: 'levels', collection: levels, parentCollection: racks, parentField: 'rackId',
    parentLabel: 'Regal', entityType: 'Level', prefix: 'level', digits: 2,
  });
  hierarchyEntityRoutes({
    path: 'places', collection: places, parentCollection: levels, parentField: 'levelId',
    parentLabel: 'Ebene', entityType: 'StoragePlace', prefix: 'place', digits: 2,
  });

  app.post('/api/storage/bulk-create', authMiddleware, requirePermission('locations.write'), (req, res) => {
    const location = managedLocations().find((entry) => entry.id === text(req.body.locationId));
    const rackStart = Number.parseInt(req.body.rackStart ?? 1, 10);
    const rackCount = Number.parseInt(req.body.rackCount, 10);
    const levelsPerRack = Number.parseInt(req.body.levelsPerRack, 10);
    const placesPerLevel = Number.parseInt(req.body.placesPerLevel, 10);
    if (!location || ![rackStart, rackCount, levelsPerRack, placesPerLevel].every((value) => Number.isInteger(value) && value > 0)
      || rackCount * levelsPerRack * placesPerLevel > 5000) {
      return res.status(400).json({ error: 'Gültige Mengen sind erforderlich; maximal 5.000 Lagerplätze pro Vorgang.' });
    }
    const created = { racks: 0, levels: 0, places: 0 };
    for (let rackOffset = 0; rackOffset < rackCount; rackOffset += 1) {
      const rackNumber = rackStart + rackOffset;
      let rack = racks.find((entry) => entry.locationId === location.id && entry.number === rackNumber);
      if (!rack) {
        rack = { id: nextId('rack', racks), locationId: location.id, number: rackNumber, name: `Regal ${rackNumber}`, sortOrder: rackNumber, active: true, createdAt: new Date().toISOString() };
        racks.push(rack); created.racks += 1;
      }
      for (let levelNumber = 1; levelNumber <= levelsPerRack; levelNumber += 1) {
        let level = levels.find((entry) => entry.rackId === rack.id && entry.number === levelNumber);
        if (!level) {
          level = { id: nextId('level', levels), rackId: rack.id, number: levelNumber, name: `Ebene ${levelNumber}`, sortOrder: levelNumber, active: true, createdAt: new Date().toISOString() };
          levels.push(level); created.levels += 1;
        }
        for (let placeNumber = 1; placeNumber <= placesPerLevel; placeNumber += 1) {
          if (!places.some((entry) => entry.levelId === level.id && entry.number === placeNumber)) {
            places.push({ id: nextId('place', places), levelId: level.id, number: placeNumber, name: `Platz ${placeNumber}`, sortOrder: placeNumber, active: true, createdAt: new Date().toISOString() });
            created.places += 1;
          }
        }
      }
    }
    record('bulk-create', 'StorageStructure', location.id, created, req.user);
    return res.status(201).json(created);
  });

  function nextBoxNumber(location) {
    const pattern = new RegExp(`^${location.code.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}-K(\\d{5})$`, 'i');
    const highest = boxes.reduce((max, box) => {
      const match = pattern.exec(box.inventoryNumber);
      return match ? Math.max(max, Number(match[1])) : max;
    }, 0);
    return `${location.code}-K${String(highest + 1).padStart(5, '0')}`;
  }

  app.get('/api/storage/boxes', authMiddleware, requirePermission('locations.read'), (_req, res) => {
    res.json(boxes.map((box) => ({
      ...box,
      contents: assignments.filter((entry) => entry.boxId === box.id),
      placeCode: placeCode(places.find((entry) => entry.id === box.storagePlaceId)),
    })));
  });

  app.post('/api/storage/boxes', authMiddleware, requirePermission('locations.write'), (req, res) => {
    const place = places.find((entry) => entry.id === text(req.body.storagePlaceId));
    const location = locationForPlace(place);
    const status = text(req.body.status) || 'aktiv';
    if (!active(place) || !active(location) || !text(req.body.name) || !BOX_STATUSES.includes(status)) {
      return res.status(400).json({ error: 'Bezeichnung, aktiver Lagerplatz und gültiger Status sind erforderlich.' });
    }
    const inventoryNumber = text(req.body.inventoryNumber) || nextBoxNumber(location);
    if (boxes.some((entry) => entry.inventoryNumber.toLowerCase() === inventoryNumber.toLowerCase())) {
      return res.status(409).json({ error: 'Die Kistennummer ist bereits vorhanden.' });
    }
    const dimensions = req.body.dimensions || {};
    const box = {
      id: nextId('box', boxes), inventoryNumber, name: text(req.body.name),
      type: text(req.body.type), storagePlaceId: place.id, status,
      dimensionsCm: {
        length: finiteNumber(dimensions.length), width: finiteNumber(dimensions.width),
        height: finiteNumber(dimensions.height),
      },
      maxLoadKg: finiteNumber(req.body.maxLoadKg),
      active: status !== 'deaktiviert' && status !== 'archiviert',
      createdAt: new Date().toISOString(),
    };
    boxes.push(box);
    record('create', 'StorageBox', box.id, { storagePlaceId: place.id }, req.user);
    return res.status(201).json(box);
  });

  app.put('/api/storage/boxes/:id', authMiddleware, requirePermission('locations.write'), (req, res) => {
    const box = boxes.find((entry) => entry.id === req.params.id);
    if (!box) return res.status(404).json({ error: 'Kiste nicht gefunden.' });
    const place = places.find((entry) => entry.id === text(req.body.storagePlaceId ?? box.storagePlaceId));
    const status = text(req.body.status ?? box.status);
    if (!place || !text(req.body.name ?? box.name) || !BOX_STATUSES.includes(status)) {
      return res.status(400).json({ error: 'Bezeichnung, Lagerplatz und gültiger Status sind erforderlich.' });
    }
    const previousStoragePlaceId = box.storagePlaceId;
    const dimensions = req.body.dimensions ?? box.dimensionsCm ?? {};
    Object.assign(box, {
      name: text(req.body.name ?? box.name), type: text(req.body.type ?? box.type),
      storagePlaceId: place.id, status,
      dimensionsCm: {
        length: finiteNumber(dimensions.length), width: finiteNumber(dimensions.width),
        height: finiteNumber(dimensions.height),
      },
      maxLoadKg: finiteNumber(req.body.maxLoadKg, box.maxLoadKg),
      active: status !== 'deaktiviert' && status !== 'archiviert',
      updatedAt: new Date().toISOString(),
    });
    record(previousStoragePlaceId === place.id ? 'update' : 'relocate', 'StorageBox', box.id, {
      previousStoragePlaceId, storagePlaceId: place.id,
      movedAssignmentIds: assignments.filter((entry) => entry.boxId === box.id).map((entry) => entry.id),
    }, req.user);
    return res.json(box);
  });

  function itemFor(entityType, entityId) {
    return entityType === 'material'
      ? materials.find((entry) => entry.id === entityId)
      : entityType === 'clothing' ? clothingItems.find((entry) => entry.id === entityId) : null;
  }

  app.get('/api/storage/assignments', authMiddleware, requirePermission('inventory.read'), (_req, res) => {
    res.json(assignments);
  });

  app.post('/api/storage/assignments', authMiddleware, requirePermission('inventory.write'), (req, res) => {
    const entityType = text(req.body.entityType);
    const entityId = text(req.body.entityId);
    const item = itemFor(entityType, entityId);
    const box = text(req.body.boxId) ? boxes.find((entry) => entry.id === text(req.body.boxId)) : null;
    const place = box
      ? places.find((entry) => entry.id === box.storagePlaceId)
      : places.find((entry) => entry.id === text(req.body.storagePlaceId));
    const isBulk = entityType === 'material' && item?.itemType === 'bulk';
    const quantity = isBulk ? finiteNumber(req.body.quantity) : 1;
    if (!item || !active(place) || (text(req.body.boxId) && !box) || quantity <= 0) {
      return res.status(400).json({ error: 'Artikel, Lagerplatz/Kiste und Menge sind ungültig.' });
    }
    const assigned = assignments.filter((entry) => entry.entityType === entityType && entry.entityId === entityId)
      .reduce((sum, entry) => sum + finiteNumber(entry.quantity), 0);
    if ((!isBulk && assigned >= 1) || (isBulk && assigned + quantity > finiteNumber(item.quantity))) {
      return res.status(409).json({ error: 'Die zuweisbare Artikelmenge wird überschritten.' });
    }
    const assignment = {
      id: nextId('storage-assignment', assignments), entityType, entityId,
      storagePlaceId: place.id, boxId: box?.id || null, quantity,
      createdAt: new Date().toISOString(), createdBy: req.user.username,
    };
    assignments.push(assignment);
    record('assign', 'StorageAssignment', assignment.id, { entityType, entityId, quantity }, req.user);
    return res.status(201).json(assignment);
  });

  app.put('/api/storage/assignments/:id', authMiddleware, requirePermission('inventory.relocate'), (req, res) => {
    const assignment = assignments.find((entry) => entry.id === req.params.id);
    if (!assignment) return res.status(404).json({ error: 'Zuordnung nicht gefunden.' });
    const box = text(req.body.boxId) ? boxes.find((entry) => entry.id === text(req.body.boxId)) : null;
    const place = box
      ? places.find((entry) => entry.id === box.storagePlaceId)
      : places.find((entry) => entry.id === text(req.body.storagePlaceId ?? assignment.storagePlaceId));
    const item = itemFor(assignment.entityType, assignment.entityId);
    const isBulk = assignment.entityType === 'material' && item?.itemType === 'bulk';
    const quantity = isBulk ? finiteNumber(req.body.quantity, assignment.quantity) : 1;
    const otherQuantity = assignments.filter((entry) => entry.id !== assignment.id
      && entry.entityType === assignment.entityType && entry.entityId === assignment.entityId)
      .reduce((sum, entry) => sum + finiteNumber(entry.quantity), 0);
    if (!active(place) || (text(req.body.boxId) && !box) || quantity <= 0
      || (isBulk && otherQuantity + quantity > finiteNumber(item.quantity))) {
      return res.status(400).json({ error: 'Ziel oder Menge ist ungültig.' });
    }
    const previous = { storagePlaceId: assignment.storagePlaceId, boxId: assignment.boxId, quantity: assignment.quantity };
    Object.assign(assignment, {
      storagePlaceId: place.id, boxId: box?.id || null, quantity,
      updatedAt: new Date().toISOString(), updatedBy: req.user.username,
    });
    record('relocate', 'StorageAssignment', assignment.id, { previous, current: assignment }, req.user);
    return res.json(assignment);
  });

  function scopeIncludes(scopeType, scopeId, assignment, item) {
    const place = places.find((entry) => entry.id === assignment?.storagePlaceId);
    const level = levelForPlace(place);
    const rack = rackForLevel(level);
    if (scopeType === 'location') return rack?.locationId === scopeId;
    if (scopeType === 'rack') return rack?.id === scopeId;
    if (scopeType === 'level') return level?.id === scopeId;
    if (scopeType === 'place') return place?.id === scopeId;
    if (scopeType === 'box') return assignment?.boxId === scopeId;
    if (scopeType === 'inventory') return assignment?.entityType === 'material';
    if (scopeType === 'wardrobe') return assignment?.entityType === 'clothing';
    if (scopeType === 'category') {
      return assignment?.entityType === 'clothing'
        ? item?.categoryId === scopeId
        : item?.categoryCode === scopeId || item?.subcategoryCode === scopeId;
    }
    return false;
  }

  function assignmentAvailability(assignment, item) {
    if (assignment.entityType === 'clothing') {
      const issued = item.status === 'Ausgegeben' || Boolean(item.assignedPerson);
      return { available: issued ? 0 : 1, issued: issued ? 1 : 0 };
    }
    const related = assignments
      .filter((entry) => entry.entityType === 'material' && entry.entityId === item.id)
      .sort((left, right) => String(left.id).localeCompare(String(right.id)));
    let issuedRemaining = finiteNumber(item.issuedQuantity);
    for (const candidate of related) {
      const quantity = finiteNumber(candidate.quantity);
      const issued = Math.min(quantity, issuedRemaining);
      if (candidate.id === assignment.id) {
        return { available: Math.max(0, quantity - issued), issued };
      }
      issuedRemaining -= issued;
    }
    return { available: finiteNumber(assignment.quantity), issued: 0 };
  }

  function buildSnapshot(scopeType, scopeId) {
    const entries = assignments.filter((assignment) => {
      const item = itemFor(assignment.entityType, assignment.entityId);
      return item && scopeIncludes(scopeType, scopeId, assignment, item);
    }).map((assignment) => {
      const item = itemFor(assignment.entityType, assignment.entityId);
      const availability = assignmentAvailability(assignment, item);
      return {
        id: `entry-${assignment.id}`, assignmentId: assignment.id,
        entityType: assignment.entityType, entityId: assignment.entityId,
        inventoryNumber: item.inventoryNumber, name: item.name,
        itemType: assignment.entityType === 'material' ? item.itemType : 'individual',
        expectedQuantity: availability.available,
        snapshotIssuedQuantity: availability.issued,
        storagePlaceId: assignment.storagePlaceId, placeCode: placeCode(places.find((entry) => entry.id === assignment.storagePlaceId)),
        boxId: assignment.boxId || null,
        boxNumber: boxes.find((entry) => entry.id === assignment.boxId)?.inventoryNumber || null,
        counts: [], resolvedQuantity: null, condition: null, foundStoragePlaceId: null, notes: '',
      };
    });
    const includedPlaceIds = new Set(entries.map((entry) => entry.storagePlaceId));
    places.filter((place) => {
      const dummy = { storagePlaceId: place.id, boxId: null };
      return scopeIncludes(scopeType, scopeId, dummy, null) && !includedPlaceIds.has(place.id);
    }).forEach((place) => entries.push({
      id: `empty-${place.id}`, assignmentId: null, entityType: 'empty-place', entityId: place.id,
      inventoryNumber: '', name: 'Leerer Lagerplatz', itemType: 'individual',
      expectedQuantity: 0, storagePlaceId: place.id, placeCode: placeCode(place),
      boxId: null, boxNumber: null, counts: [], resolvedQuantity: null,
      condition: null, foundStoragePlaceId: null, notes: '',
    }));
    if (scopeType === 'box' && entries.length === 0) {
      const box = boxes.find((entry) => entry.id === scopeId);
      const place = places.find((entry) => entry.id === box?.storagePlaceId);
      if (box && place) {
        entries.push({
          id: `empty-box-${box.id}`, assignmentId: null, entityType: 'empty-box',
          entityId: box.id, inventoryNumber: box.inventoryNumber, name: 'Leere Kiste',
          itemType: 'individual', expectedQuantity: 0, storagePlaceId: place.id,
          placeCode: placeCode(place), boxId: box.id, boxNumber: box.inventoryNumber,
          counts: [], resolvedQuantity: null, condition: null,
          foundStoragePlaceId: null, notes: '',
        });
      }
    }
    return entries;
  }

  app.get('/api/stocktakes', authMiddleware, requirePermission('inventory.read'), (_req, res) => {
    res.json(stocktakes.slice().reverse());
  });

  app.post('/api/stocktakes', authMiddleware, requirePermission('inventory.write'), (req, res) => {
    const name = text(req.body.name);
    const scopeType = text(req.body.scopeType);
    const scopeId = text(req.body.scopeId);
    if (!name || !SCOPE_TYPES.includes(scopeType)
      || (!['inventory', 'wardrobe'].includes(scopeType) && !scopeId)) {
      return res.status(400).json({ error: 'Name und gültiger Inventurbereich sind erforderlich.' });
    }
    const stocktake = {
      id: nextId('stocktake', stocktakes), name, scopeType, scopeId: scopeId || null,
      plannedDate: text(req.body.plannedDate) || null, status: 'Geplant',
      entries: [], createdBy: req.user.username, createdAt: new Date().toISOString(),
    };
    stocktakes.push(stocktake);
    record('create', 'Stocktake', stocktake.id, { scopeType, scopeId }, req.user);
    return res.status(201).json(stocktake);
  });

  app.post('/api/stocktakes/:id/start', authMiddleware, requirePermission('inventory.write'), (req, res) => {
    const stocktake = stocktakes.find((entry) => entry.id === req.params.id);
    if (!stocktake) return res.status(404).json({ error: 'Inventur nicht gefunden.' });
    if (stocktake.status !== 'Geplant') return res.status(409).json({ error: 'Nur geplante Inventuren können gestartet werden.' });
    stocktake.entries = buildSnapshot(stocktake.scopeType, stocktake.scopeId);
    stocktake.status = 'Laufend';
    stocktake.startedAt = new Date().toISOString();
    stocktake.startedBy = req.user.username;
    record('start', 'Stocktake', stocktake.id, { entryCount: stocktake.entries.length }, req.user);
    return res.json(stocktake);
  });

  app.post('/api/stocktakes/:id/counts', authMiddleware, requirePermission('inventory.write'), (req, res) => {
    const stocktake = stocktakes.find((entry) => entry.id === req.params.id);
    const entry = stocktake?.entries.find((candidate) => candidate.id === text(req.body.entryId));
    if (!stocktake || stocktake.status !== 'Laufend' || !entry) {
      return res.status(404).json({ error: 'Laufende Inventur oder Position nicht gefunden.' });
    }
    const quantity = entry.itemType === 'individual'
      ? (req.body.present === true ? 1 : 0) : finiteNumber(req.body.quantity, -1);
    if (quantity < 0) return res.status(400).json({ error: 'Eine gültige Zählmenge ist erforderlich.' });
    const count = {
      id: nextId('count', entry.counts), quantity,
      condition: text(req.body.condition), notes: text(req.body.notes),
      foundStoragePlaceId: text(req.body.foundStoragePlaceId) || null,
      control: req.body.control === true, actor: req.user.username, createdAt: new Date().toISOString(),
    };
    entry.counts.push(count);
    const quantities = new Set(entry.counts.filter((candidate) => !candidate.control).map((candidate) => candidate.quantity));
    const control = entry.counts.filter((candidate) => candidate.control).at(-1);
    entry.needsRecount = quantities.size > 1 && !control;
    entry.resolvedQuantity = control?.quantity ?? (quantities.size === 1 ? count.quantity : null);
    entry.condition = count.condition || entry.condition;
    entry.notes = count.notes || entry.notes;
    entry.foundStoragePlaceId = count.foundStoragePlaceId || entry.foundStoragePlaceId;
    record('count', 'Stocktake', stocktake.id, { entryId: entry.id, quantity, control: count.control }, req.user);
    return res.status(201).json(entry);
  });

  app.post('/api/stocktakes/:id/complete', authMiddleware, requirePermission('inventory.write'), (req, res) => {
    const stocktake = stocktakes.find((entry) => entry.id === req.params.id);
    if (!stocktake || stocktake.status !== 'Laufend') return res.status(404).json({ error: 'Laufende Inventur nicht gefunden.' });
    const unresolved = stocktake.entries.filter((entry) => !entry.entityType.startsWith('empty-')
      && (entry.resolvedQuantity === null || entry.needsRecount));
    if (unresolved.length) {
      return res.status(409).json({ error: 'Alle Positionen müssen eindeutig gezählt sein.', unresolvedEntryIds: unresolved.map((entry) => entry.id) });
    }
    stocktake.entries.forEach((entry) => {
      if (!entry.assignmentId) return;
      const assignment = assignments.find((candidate) => candidate.id === entry.assignmentId);
      const item = itemFor(entry.entityType, entry.entityId);
      if (!assignment || !item) return;
      const previousQuantity = finiteNumber(assignment.quantity);
      const liveAvailability = assignmentAvailability(assignment, item);
      entry.effectiveExpectedQuantity = liveAvailability.available;
      assignment.quantity = entry.resolvedQuantity + liveAvailability.issued;
      if (entry.foundStoragePlaceId && places.some((place) => place.id === entry.foundStoragePlaceId)) {
        assignment.storagePlaceId = entry.foundStoragePlaceId;
        assignment.boxId = null;
      }
      if (entry.entityType === 'material') {
        if (item.itemType === 'bulk') {
          const assignedTotal = assignments.filter((candidate) => candidate.entityType === 'material' && candidate.entityId === item.id)
            .reduce((sum, candidate) => sum + finiteNumber(candidate.quantity), 0);
          item.quantity = Math.max(assignedTotal, finiteNumber(item.issuedQuantity));
        } else if (entry.resolvedQuantity === 0 && liveAvailability.issued === 0) {
          item.status = 'Verloren';
        } else if (item.status === 'Verloren') {
          item.status = 'Lagernd';
        }
      } else if (entry.entityType === 'clothing') {
        if (liveAvailability.issued === 0) {
          item.status = entry.resolvedQuantity === 0 ? 'Verloren' : (item.status === 'Verloren' ? 'Lagernd' : item.status);
        }
      }
      entry.adjustment = entry.resolvedQuantity - liveAvailability.available;
      entry.appliedAt = new Date().toISOString();
    });
    stocktake.status = 'Abgeschlossen';
    stocktake.completedAt = new Date().toISOString();
    stocktake.completedBy = req.user.username;
    record('complete', 'Stocktake', stocktake.id, {}, req.user);
    return res.json(stocktake);
  });

  function inventoryRows(stocktake) {
    return stocktake.entries.map((entry) => ({
      PositionsID: entry.id,
      Lagerplatz: entry.placeCode,
      Kiste: entry.boxNumber || '',
      Inventarnummer: entry.inventoryNumber,
      Bezeichnung: entry.name,
      Art: entry.itemType === 'bulk' ? 'Mengenartikel' : 'Einzelartikel',
      Sollmenge: entry.expectedQuantity,
      Istmenge: entry.resolvedQuantity ?? '',
      Zustand: entry.condition || '',
      Bemerkung: entry.notes || '',
    }));
  }

  app.get('/api/stocktakes/:id/export', authMiddleware, requirePermission('inventory.export'), (req, res) => {
    const stocktake = stocktakes.find((entry) => entry.id === req.params.id);
    const format = text(req.query.format || 'xlsx').toLowerCase();
    if (!stocktake || !['xlsx', 'ods', 'csv', 'pdf'].includes(format)) {
      return res.status(400).json({ error: 'Inventur und Format müssen gültig sein.' });
    }
    const rows = inventoryRows(stocktake);
    let buffer;
    if (format === 'csv') {
      const headers = Object.keys(rows[0] || { PositionsID: '', Lagerplatz: '', Kiste: '', Inventarnummer: '', Bezeichnung: '', Art: '', Sollmenge: '', Istmenge: '', Zustand: '', Bemerkung: '' });
      buffer = Buffer.from(`\uFEFF${headers.join(';')}\r\n${rows.map((row) => headers.map((header) => csvCell(row[header])).join(';')).join('\r\n')}`, 'utf8');
    } else if (format === 'pdf') {
      const groups = new Map();
      rows.forEach((row) => {
        const rack = row.Lagerplatz.split('-').find((part) => /^R\d+$/.test(part)) || 'Ohne Regal';
        if (!groups.has(rack)) groups.set(rack, []);
        groups.get(rack).push(row);
      });
      if (!groups.size) groups.set('Ohne Positionen', []);
      const pages = [];
      for (const [rack, group] of groups) {
        const lines = group.map((row) => `${row.Lagerplatz} | ${row.Kiste} | ${row.Inventarnummer} | ${row.Bezeichnung} | Soll ${row.Sollmenge} | Ist ${row.Istmenge}`);
        for (let offset = 0; offset < Math.max(1, lines.length); offset += 48) {
          pages.push([
            `Inventur: ${stocktake.name}`, `Status: ${stocktake.status}`, `Regal: ${rack}`, '',
            ...lines.slice(offset, offset + 48),
          ]);
        }
      }
      buffer = pdfBuffer(pages);
    } else {
      const workbook = XLSX.utils.book_new();
      const groups = new Map();
      rows.forEach((row) => {
        const rack = row.Lagerplatz.split('-').find((part) => /^R\d+$/.test(part)) || 'Ohne Regal';
        if (!groups.has(rack)) groups.set(rack, []);
        groups.get(rack).push(row);
      });
      for (const [rack, group] of groups) {
        XLSX.utils.book_append_sheet(workbook, XLSX.utils.json_to_sheet(group), rack.slice(0, 31));
      }
      if (!groups.size) XLSX.utils.book_append_sheet(workbook, XLSX.utils.json_to_sheet(rows), 'Inventur');
      buffer = XLSX.write(workbook, { type: 'buffer', bookType: format });
    }
    return res.json({
      fileName: `inventur-${stocktake.id}.${format}`,
      mimeType: format === 'pdf' ? 'application/pdf' : format === 'csv' ? 'text/csv' : 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      fileBase64: buffer.toString('base64'),
    });
  });

  app.post('/api/stocktakes/:id/import', authMiddleware, requirePermission('inventory.import'), (req, res) => {
    const stocktake = stocktakes.find((entry) => entry.id === req.params.id);
    if (!stocktake || stocktake.status !== 'Laufend') return res.status(404).json({ error: 'Laufende Inventur nicht gefunden.' });
    let rows;
    try {
      const workbook = XLSX.read(Buffer.from(text(req.body.fileBase64), 'base64'), { type: 'buffer' });
      rows = workbook.SheetNames.flatMap((name) => XLSX.utils.sheet_to_json(workbook.Sheets[name], { defval: '' }));
    } catch (_) {
      return res.status(400).json({ error: 'Die Inventurliste konnte nicht gelesen werden.' });
    }
    let imported = 0;
    const skipped = [];
    rows.forEach((row, index) => {
      const entryId = text(row.PositionsID || row.positionsid);
      const entry = stocktake.entries.find((candidate) => candidate.id === entryId);
      const quantity = finiteNumber(row.Istmenge ?? row.istmenge, -1);
      if (!entry || quantity < 0) {
        skipped.push({ row: index + 2, reason: 'PositionsID oder Istmenge ungültig' });
        return;
      }
      entry.importedCount = { quantity, actor: req.user.username, createdAt: new Date().toISOString() };
      entry.resolvedQuantity = quantity;
      entry.needsRecount = false;
      imported += 1;
    });
    record('import', 'Stocktake', stocktake.id, { imported, skipped: skipped.length }, req.user);
    return res.json({ imported, skipped: skipped.length, skippedRows: skipped, preview: true });
  });
}

module.exports = {
  registerStorageManagementRoutes,
  BOX_STATUSES,
  STOCKTAKE_STATUSES,
  SCOPE_TYPES,
};
