const MATERIAL_STATUSES = [
  'Lagernd', 'Ausgegeben', 'Reserviert', 'In Prüfung', 'Defekt',
  'In Reparatur', 'Ausgesondert', 'Verloren',
];
const { nextInventoryNumber } = require('./inventory-number');

const IMPORT_ALIASES = {
  inventarnummer: 'inventoryNumber', bezeichnung: 'name', name: 'name',
  hauptkategorie: 'categoryCode', hauptkategorieid: 'categoryCode',
  unterkategorie: 'subcategoryCode', unterkategorieid: 'subcategoryCode',
  standort: 'locationId', lagerplatz: 'stockStructureId', regalfach: 'stockStructureId',
  status: 'status', anzahl: 'quantity', einheit: 'unit', typ: 'itemType',
  hersteller: 'manufacturer', modell: 'model', seriennummer: 'serialNumber',
  anschaffungsdatum: 'purchaseDate', kaufpreis: 'purchasePrice',
  beschreibung: 'description', notizen: 'notes', fachbereich: 'department',
  prufintervallmonate: 'inspectionIntervalMonths', nachsterpruftermin: 'nextInspectionDate',
};

function normalizeHeader(value) {
  return String(value || '').trim().toLowerCase().normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '').replace(/[^a-z0-9]/g, '');
}

function registerInventoryRoutes({
  app, authMiddleware, requirePermission, materials, deletedMaterials, materialMovements,
  materialInspections, materialDocuments, defectReports, categories, locations, stockStructures,
  logEvent, nextId, XLSX, defectManagement,
}) {
  const number = (value, fallback = 0) => {
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : fallback;
  };

  function categoryPair(categoryCode, subcategoryCode) {
    const main = categories.find((entry) => entry.id === categoryCode && !entry.parentId);
    const child = subcategoryCode
      ? categories.find((entry) => entry.id === subcategoryCode || entry.id === `${categoryCode}-${subcategoryCode}`)
      : null;
    return { main, child: child?.parentId === main?.id ? child : null };
  }

  function inventoryNumber(categoryCode, subcategoryCode) {
    return nextInventoryNumber([...materials, ...deletedMaterials], categoryCode, subcategoryCode);
  }

  function validate(body, existing = null) {
    const name = String(body.name ?? existing?.name ?? '').trim();
    const categoryCode = String(body.categoryCode ?? existing?.categoryCode ?? '').trim();
    const subcategoryCode = String(body.subcategoryCode ?? existing?.subcategoryCode ?? '').trim();
    const locationId = String(body.locationId ?? existing?.locationId ?? '').trim();
    const stockStructureId = String(body.stockStructureId ?? existing?.stockStructureId ?? '').trim();
    const status = String(body.status ?? existing?.status ?? 'Lagernd').trim();
    const itemType = String(body.itemType ?? existing?.itemType ?? 'individual').trim();
    const quantity = itemType === 'individual' ? 1 : number(body.quantity ?? existing?.quantity, 0);
    const pair = categoryPair(categoryCode, subcategoryCode);
    if (!name || !categoryCode || !locationId || !status) return { error: 'Bezeichnung, Kategorie, Standort und Status sind Pflichtfelder.' };
    if (!pair.main || (subcategoryCode && !pair.child)) return { error: 'Die gewählte Haupt-/Unterkategorie ist ungültig.' };
    if (!locations.some((entry) => entry.id === locationId)) return { error: 'Der gewählte Standort ist ungültig.' };
    if (stockStructureId && !stockStructures.some((entry) => entry.id === stockStructureId && entry.locationId === locationId)) return { error: 'Der Lagerplatz gehört nicht zum gewählten Standort.' };
    if (!MATERIAL_STATUSES.includes(status)) return { error: 'Der gewählte Status ist ungültig.' };
    if (!['individual', 'bulk'].includes(itemType) || quantity <= 0) return { error: 'Art und Anzahl des Artikels sind ungültig.' };
    if (existing && quantity < number(existing.issuedQuantity)) return { error: 'Die Anzahl darf nicht unter die ausgegebene Menge fallen.' };
    return { name, categoryCode, subcategoryCode: pair.child?.id || '', locationId, stockStructureId: stockStructureId || null, status, itemType, quantity };
  }

  function responseItem(item) {
    return {
      ...item,
      availableQuantity: number(item.quantity) - number(item.issuedQuantity),
      movements: materialMovements.filter((entry) => entry.materialId === item.id).slice().reverse(),
      inspections: materialInspections.filter((entry) => entry.materialId === item.id).slice().reverse(),
      documents: materialDocuments.filter((entry) => entry.materialId === item.id).map(({ fileBase64, ...entry }) => entry),
      defects: defectReports.filter((entry) => entry.entityType === 'MaterialItem' && entry.entityId === item.id).slice().reverse(),
    };
  }

  app.get('/api/material', authMiddleware, requirePermission('inventory.read'), (req, res) => {
    const archived = String(req.query.archived || 'false') === 'true';
    res.json(materials.filter((item) => item.archived === archived).map(responseItem));
  });

  app.get('/api/material/history', authMiddleware, requirePermission('inventory.read'), (req, res) => {
    res.json(materialMovements.slice().reverse());
  });

  app.get('/api/material/:id', authMiddleware, requirePermission('inventory.read'), (req, res) => {
    const item = materials.find((entry) => entry.id === req.params.id);
    if (!item) return res.status(404).json({ error: 'Material nicht gefunden.' });
    res.json(responseItem(item));
  });

  app.post('/api/material', authMiddleware, requirePermission('inventory.write'), (req, res) => {
    const values = validate(req.body);
    if (values.error) return res.status(400).json({ error: values.error });
    const requested = String(req.body.inventoryNumber || '').trim();
    const generated = inventoryNumber(values.categoryCode, values.subcategoryCode);
    const inv = requested || generated;
    if ([...materials, ...deletedMaterials].some((entry) => entry.inventoryNumber.toLowerCase() === inv.toLowerCase())) return res.status(409).json({ error: 'Die Inventarnummer existiert bereits.' });
    const item = {
      ...req.body, ...values, id: nextId('material', [...materials, ...deletedMaterials]), inventoryNumber: inv,
      unit: String(req.body.unit || 'Stück').trim() || 'Stück', issuedQuantity: 0,
      manufacturer: String(req.body.manufacturer || '').trim(), model: String(req.body.model || '').trim(),
      serialNumber: String(req.body.serialNumber || '').trim(), purchaseDate: req.body.purchaseDate || null,
      purchasePrice: req.body.purchasePrice === '' || req.body.purchasePrice == null ? null : number(req.body.purchasePrice),
      description: String(req.body.description || '').trim(), notes: String(req.body.notes || '').trim(),
      department: String(req.body.department || '').trim(),
      inspectionIntervalMonths: req.body.inspectionIntervalMonths ? number(req.body.inspectionIntervalMonths) : null,
      lastInspectionDate: null, nextInspectionDate: req.body.nextInspectionDate || null,
      archived: false, createdAt: new Date().toISOString(),
    };
    materials.push(item);
    logEvent('create', 'MaterialItem', {
      id: item.id,
      itemName: item.name,
      inventoryNumber: inv,
      categoryCode: item.categoryCode,
      subcategoryCode: item.subcategoryCode,
    }, req.user.username);
    res.status(201).json(responseItem(item));
  });

  app.put('/api/material/:id', authMiddleware, requirePermission('inventory.write'), (req, res) => {
    const item = materials.find((entry) => entry.id === req.params.id);
    if (!item) return res.status(404).json({ error: 'Material nicht gefunden.' });
    if (item.archived) return res.status(409).json({ error: 'Archiviertes Material kann nicht bearbeitet werden.' });
    if (req.body.inventoryNumber && req.body.inventoryNumber !== item.inventoryNumber) return res.status(400).json({ error: 'Die Inventarnummer kann nachträglich nicht geändert werden.' });
    const values = validate(req.body, item);
    if (values.error) return res.status(400).json({ error: values.error });
    Object.assign(item, req.body, values, {
      id: item.id, inventoryNumber: item.inventoryNumber, issuedQuantity: item.issuedQuantity,
      archived: false, updatedAt: new Date().toISOString(),
    });
    logEvent('update', 'MaterialItem', { id: item.id }, req.user.username);
    res.json(responseItem(item));
  });

  app.post('/api/material/:id/archive', authMiddleware, requirePermission('inventory.archive'), (req, res) => {
    const item = materials.find((entry) => entry.id === req.params.id);
    if (!item) return res.status(404).json({ error: 'Material nicht gefunden.' });
    if (number(item.issuedQuantity) > 0) return res.status(409).json({ error: 'Ausgegebenes Material kann nicht archiviert werden.' });
    item.archived = true; item.archivedAt = new Date().toISOString(); item.archivedBy = req.user.username;
    logEvent('archive', 'MaterialItem', { id: item.id }, req.user.username);
    res.json(responseItem(item));
  });

  app.post('/api/material/:id/restore', authMiddleware, requirePermission('inventory.archive'), (req, res) => {
    const item = materials.find((entry) => entry.id === req.params.id);
    if (!item) return res.status(404).json({ error: 'Material nicht gefunden.' });
    item.archived = false; item.archivedAt = null; item.archivedBy = null;
    logEvent('restore', 'MaterialItem', { id: item.id }, req.user.username);
    res.json(responseItem(item));
  });

  app.delete('/api/material/:id', authMiddleware, requirePermission('inventory.archive'), (req, res) => {
    const index = materials.findIndex((entry) => entry.id === req.params.id);
    if (index === -1) return res.status(404).json({ error: 'Material nicht gefunden.' });
    const item = materials[index];
    if (!item.archived) return res.status(409).json({ error: 'Material muss vor dem Löschen archiviert werden.' });
    if (number(item.issuedQuantity) > 0) return res.status(409).json({ error: 'Ausgegebenes Material kann nicht gelöscht werden.' });

    const removedItem = materials.splice(index, 1)[0];
    deletedMaterials.push({
      ...removedItem,
      deletedAt: new Date().toISOString(),
      deletedBy: req.user.username,
    });
    logEvent('delete', 'MaterialItem', {
      id: removedItem.id,
      inventoryNumber: removedItem.inventoryNumber,
    }, req.user.username);
    res.json({ success: true, id: removedItem.id });
  });

  app.post('/api/material/transactions/bulk', authMiddleware, requirePermission('inventory.transactions'), (req, res) => {
    const action = String(req.body.action || '');
    const entries = Array.isArray(req.body.items) ? req.body.items : [];
    const recipient = String(req.body.recipient || '').trim();
    if (!['issue', 'return'].includes(action) || !entries.length) return res.status(400).json({ error: 'Aktion und Materialpositionen sind erforderlich.' });
    if (action === 'issue' && !recipient) return res.status(400).json({ error: 'Ein Empfänger oder Verwendungsziel ist erforderlich.' });
    const checked = entries.map((entry) => {
      const item = materials.find((candidate) => candidate.id === entry.materialId);
      const quantity = number(entry.quantity, 0);
      let error = null;
      if (!item || item.archived) error = 'not_found';
      else if (quantity <= 0) error = 'invalid_quantity';
      else if (action === 'issue' && ['Defekt', 'In Reparatur', 'Ausgesondert', 'Verloren'].includes(item.status)) error = 'invalid_status';
      else if (action === 'issue' && quantity > number(item.quantity) - number(item.issuedQuantity)) error = 'insufficient_stock';
      else if (action === 'return' && quantity > number(item.issuedQuantity)) error = 'too_much_returned';
      return { item, quantity, error };
    });
    if (checked.some((entry) => entry.error)) return res.status(409).json({ error: 'Die Sammelbuchung wurde nicht durchgeführt.', details: checked.filter((entry) => entry.error).map((entry) => ({ materialId: entry.item?.id, error: entry.error })) });
    const created = checked.map(({ item, quantity }) => {
      item.issuedQuantity = number(item.issuedQuantity) + (action === 'issue' ? quantity : -quantity);
      item.status = defectManagement?.hasOpenDefect('MaterialItem', item.id)
        ? 'Defekt'
        : item.issuedQuantity > 0 ? 'Ausgegeben' : 'Lagernd';
      const movement = {
        id: nextId('movement', materialMovements), materialId: item.id, action, quantity,
        recipientType: action === 'issue' ? String(req.body.recipientType || 'purpose') : null,
        recipient: action === 'issue' ? recipient : null, plannedReturnDate: req.body.plannedReturnDate || null,
        notes: String(req.body.notes || '').trim(), actor: req.user.username, createdAt: new Date().toISOString(),
      };
      materialMovements.push(movement); return movement;
    });
    logEvent(action, 'MaterialMovement', { materialIds: checked.map((entry) => entry.item.id) }, req.user.username);
    res.status(201).json(created);
  });

  app.post('/api/material/relocate/bulk', authMiddleware, requirePermission('inventory.relocate'), (req, res) => {
    const ids = Array.from(new Set(Array.isArray(req.body.materialIds) ? req.body.materialIds : []));
    const locationId = String(req.body.locationId || '').trim();
    const stockStructureId = String(req.body.stockStructureId || '').trim();
    const targetLocation = locations.find((entry) => entry.id === locationId);
    const targetStock = stockStructureId ? stockStructures.find((entry) => entry.id === stockStructureId && entry.locationId === locationId) : null;
    const items = ids.map((id) => materials.find((entry) => entry.id === id));
    if (!ids.length || !targetLocation || (stockStructureId && !targetStock)) return res.status(400).json({ error: 'Material, Standort oder Lagerplatz ist ungültig.' });
    if (items.some((item) => !item || item.archived || number(item.issuedQuantity) > 0)) return res.status(409).json({ error: 'Die Sammelumbuchung wurde nicht durchgeführt. Ausgegebenes oder archiviertes Material ist nicht zulässig.' });
    const created = items.map((item) => {
      const movement = { id: nextId('movement', materialMovements), materialId: item.id, action: 'relocate', quantity: item.quantity, fromLocationId: item.locationId, fromStockStructureId: item.stockStructureId, toLocationId: locationId, toStockStructureId: stockStructureId || null, notes: String(req.body.notes || '').trim(), actor: req.user.username, createdAt: new Date().toISOString() };
      item.locationId = locationId; item.stockStructureId = stockStructureId || null; materialMovements.push(movement); return movement;
    });
    logEvent('relocate', 'MaterialMovement', { materialIds: ids, locationId }, req.user.username);
    res.status(201).json(created);
  });

  app.post('/api/material/:id/inspections', authMiddleware, requirePermission('inventory.write'), (req, res) => {
    const item = materials.find((entry) => entry.id === req.params.id);
    const result = String(req.body.result || '');
    if (!item) return res.status(404).json({ error: 'Material nicht gefunden.' });
    if (!req.body.inspectionDate || !String(req.body.inspector || '').trim() || !['Bestanden', 'Mangel', 'Nicht bestanden'].includes(result)) return res.status(400).json({ error: 'Datum, Prüfer und gültiges Ergebnis sind erforderlich.' });
    const inspection = { id: nextId('inspection', materialInspections), materialId: item.id, inspectionDate: req.body.inspectionDate, inspector: String(req.body.inspector).trim(), result, notes: String(req.body.notes || '').trim(), nextInspectionDate: req.body.nextInspectionDate || null, createdAt: new Date().toISOString() };
    materialInspections.push(inspection); item.lastInspectionDate = inspection.inspectionDate; item.nextInspectionDate = inspection.nextInspectionDate;
    if (result === 'Mangel' || result === 'Nicht bestanden') {
      defectManagement?.createFromInspection({
        entityType: 'MaterialItem', entityId: item.id, inspectionId: inspection.id,
        notes: inspection.notes, user: req.user,
      });
    }
    logEvent('inspection', 'MaterialItem', { id: item.id, result }, req.user.username);
    res.status(201).json(inspection);
  });

  app.post('/api/material/:id/documents', authMiddleware, requirePermission('inventory.write'), (req, res) => {
    const item = materials.find((entry) => entry.id === req.params.id);
    const fileBase64 = String(req.body.fileBase64 || '');
    if (!item) return res.status(404).json({ error: 'Material nicht gefunden.' });
    if (!String(req.body.fileName || '').trim() || !fileBase64) return res.status(400).json({ error: 'Dateiname und Datei sind erforderlich.' });
    if (fileBase64.length > 7_000_000) return res.status(413).json({ error: 'Die Datei ist zu groß. Maximal 5 MB sind erlaubt.' });
    const document = { id: nextId('material-document', materialDocuments), materialId: item.id, title: String(req.body.title || req.body.fileName).trim(), documentType: String(req.body.documentType || 'Anleitung'), mimeType: req.body.mimeType || null, fileName: String(req.body.fileName).trim(), fileBase64, createdAt: new Date().toISOString() };
    materialDocuments.push(document); logEvent('document', 'MaterialItem', { id: item.id, documentId: document.id }, req.user.username);
    const { fileBase64: omitted, ...metadata } = document; res.status(201).json(metadata);
  });

  app.get('/api/material/:id/documents/:documentId', authMiddleware, requirePermission('inventory.read'), (req, res) => {
    const document = materialDocuments.find((entry) => entry.id === req.params.documentId && entry.materialId === req.params.id);
    if (!document) return res.status(404).json({ error: 'Dokument nicht gefunden.' });
    res.json(document);
  });

  app.post('/api/material/import', authMiddleware, requirePermission('inventory.import'), (req, res) => {
    const fileName = String(req.body.fileName || ''); const extension = fileName.split('.').pop().toLowerCase();
    if (!['xlsx', 'ods'].includes(extension) || !req.body.fileBase64) return res.status(400).json({ error: 'Eine XLSX- oder ODS-Datei ist erforderlich.' });
    let rows;
    try {
      const workbook = XLSX.read(Buffer.from(req.body.fileBase64, 'base64'), { type: 'buffer' });
      rows = XLSX.utils.sheet_to_json(workbook.Sheets[workbook.SheetNames[0]], { defval: '', raw: false }).map((row) => Object.entries(row).reduce((result, [key, value]) => { const field = IMPORT_ALIASES[normalizeHeader(key)]; if (field) result[field] = String(value ?? '').trim(); return result; }, {}));
    } catch (_) { return res.status(400).json({ error: 'Die Tabelle konnte nicht gelesen werden.' }); }
    const skippedRows = []; const imported = [];
    rows.forEach((row, index) => {
      const values = validate(row); const requested = String(row.inventoryNumber || '').trim();
      if (values.error || (requested && [...materials, ...deletedMaterials].some((entry) => entry.inventoryNumber === requested))) { skippedRows.push({ row: index + 2, reason: values.error || 'Inventarnummer existiert bereits' }); return; }
      const item = { ...row, ...values, id: nextId('material', [...materials, ...deletedMaterials]), inventoryNumber: requested || inventoryNumber(values.categoryCode, values.subcategoryCode), unit: row.unit || 'Stück', issuedQuantity: 0, archived: false, createdAt: new Date().toISOString() };
      materials.push(item); imported.push(item);
    });
    logEvent('import', 'MaterialItem', { imported: imported.length, skipped: skippedRows.length }, req.user.username);
    res.json({ imported: imported.length, skipped: skippedRows.length, skippedRows });
  });

  app.get('/api/material/export/table', authMiddleware, requirePermission('inventory.export'), (req, res) => {
    const format = String(req.query.format || 'xlsx').toLowerCase(); const archived = String(req.query.archived || 'false') === 'true';
    if (!['xlsx', 'ods'].includes(format)) return res.status(400).json({ error: 'Format muss xlsx oder ods sein.' });
    const rows = materials.filter((item) => item.archived === archived).map((item) => ({ Inventarnummer: item.inventoryNumber, Bezeichnung: item.name, Hauptkategorie: item.categoryCode, Unterkategorie: item.subcategoryCode || '', Standort: item.locationId, 'Regal/Fach': item.stockStructureId || '', Status: item.status, Anzahl: item.quantity, Verfügbar: number(item.quantity) - number(item.issuedQuantity), Einheit: item.unit, Hersteller: item.manufacturer || '', Modell: item.model || '', Seriennummer: item.serialNumber || '', Anschaffungsdatum: item.purchaseDate || '', Kaufpreis: item.purchasePrice ?? '', Beschreibung: item.description || '', Notizen: item.notes || '', Fachbereich: item.department || '', 'Prüfintervall Monate': item.inspectionIntervalMonths || '', 'Nächster Prüftermin': item.nextInspectionDate || '' }));
    const workbook = XLSX.utils.book_new(); XLSX.utils.book_append_sheet(workbook, XLSX.utils.json_to_sheet(rows), archived ? 'Archiv' : 'Inventar');
    const fileName = `${archived ? 'inventar-archiv' : 'inventar'}-${new Date().toISOString().slice(0, 10)}.${format}`;
    res.json({ fileName, fileBase64: XLSX.write(workbook, { type: 'buffer', bookType: format }).toString('base64') });
  });
}

module.exports = { registerInventoryRoutes, MATERIAL_STATUSES };
