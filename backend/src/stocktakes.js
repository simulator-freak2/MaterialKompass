let pdfLibModule;
function pdfLib() {
  pdfLibModule ||= require('pdf-lib');
  return pdfLibModule;
}

const STOCKTAKE_STATUSES = Object.freeze(['Angelegt', 'In Arbeit', 'Auswertung', 'Abgeschlossen']);
const ENTITY_TYPES = Object.freeze(['MaterialItem', 'ClothingItem']);
const METHODS = Object.freeze(['online', 'offline']);
const COUNT_MODES = Object.freeze(['blind', 'open']);
const INDIVIDUAL_RESULTS = Object.freeze(['vorhanden', 'beschädigt', 'nicht vorhanden']);
const MAX_IMPORT_BYTES = 5 * 1024 * 1024;
const MAX_IMPORT_ROWS = 5000;

function text(value, max = 10_000) {
  return String(value ?? '').trim().slice(0, max);
}

function uniqueStrings(value) {
  return [...new Set((Array.isArray(value) ? value : []).map((entry) => text(entry, 128)).filter(Boolean))];
}

function number(value) {
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

function registerStocktakeRoutes({
  app, authMiddleware, requirePermission, hasPermission, stocktakes, materials,
  clothingItems, locations, stockStructures, departments, users, logEvent, nextId,
  XLSX, defectManagement,
}) {
  const nowIso = () => new Date().toISOString();

  function roles(user) {
    return new Set(user?.roles || []);
  }

  function isChair(user) {
    const assigned = roles(user);
    return assigned.has('Admin') || assigned.has('Jugendvorsitzender') || assigned.has('Jugendvorsitz');
  }

  function canSee(user, stocktake) {
    if (isChair(user)) return true;
    const assigned = roles(user);
    return (stocktake.entityTypes.includes('MaterialItem') && assigned.has('Materialwart'))
      || (stocktake.entityTypes.includes('ClothingItem') && assigned.has('Kleiderwart'));
  }

  function mayCreateTypes(user, entityTypes) {
    if (isChair(user)) return true;
    const assigned = roles(user);
    return entityTypes.every((type) =>
      (type === 'MaterialItem' && assigned.has('Materialwart'))
      || (type === 'ClothingItem' && assigned.has('Kleiderwart')));
  }

  function findStocktake(req, res) {
    const stocktake = stocktakes.find((entry) => entry.id === req.params.id);
    if (!stocktake || !canSee(req.user, stocktake)) {
      res.status(404).json({ error: 'Inventur nicht gefunden.' });
      return null;
    }
    return stocktake;
  }

  function entityFor(entry) {
    const source = entry.entityType === 'MaterialItem' ? materials : clothingItems;
    return source.find((item) => item.id === entry.entityId);
  }

  function locationName(id) {
    return locations.find((entry) => entry.id === id)?.name || id || '';
  }

  function stockName(id) {
    return stockStructures.find((entry) => entry.id === id)?.name || id || '';
  }

  function matchesScope(item, scope) {
    if (scope.locationIds.length && !scope.locationIds.includes(String(item.locationId || ''))) return false;
    if (scope.stockStructureIds.length && !scope.stockStructureIds.includes(String(item.stockStructureId || ''))) return false;
    if (scope.departments.length && !scope.departments.includes(String(item.department || ''))) return false;
    return true;
  }

  function snapshotEntry(item, entityType, index) {
    const isBulk = entityType === 'MaterialItem' && item.itemType === 'bulk';
    return {
      id: `stocktake-entry-${index + 1}`,
      entityType,
      entityId: item.id,
      inventoryNumber: item.inventoryNumber,
      name: item.name,
      itemType: isBulk ? 'bulk' : 'individual',
      unit: item.unit || 'Stück',
      expectedQuantity: isBulk ? Number(item.quantity || 0) : 1,
      expectedLocationId: item.locationId || null,
      expectedStockStructureId: item.stockStructureId || null,
      expectedStatus: item.status || '',
      actualQuantity: null,
      result: null,
      actualLocationId: null,
      actualStockStructureId: null,
      notes: '',
      countedAt: null,
      countedBy: null,
      countedByName: null,
      attempts: [],
      defectId: null,
      shortageDefectId: null,
    };
  }

  function progress(stocktake) {
    const counted = stocktake.entries.filter((entry) => entry.countedAt).length;
    const discrepancies = stocktake.entries.filter((entry) => discrepancy(entry).length).length;
    return { total: stocktake.entries.length, counted, open: stocktake.entries.length - counted, discrepancies };
  }

  function discrepancy(entry) {
    if (!entry.countedAt) return [];
    const result = [];
    if (entry.itemType === 'bulk' && Number(entry.actualQuantity) !== Number(entry.expectedQuantity)) result.push('Mengenabweichung');
    if (entry.itemType === 'individual' && entry.result === 'nicht vorhanden') result.push('Fehlbestand');
    if (entry.result === 'beschädigt') result.push('Mangel');
    if (entry.actualLocationId && entry.actualLocationId !== entry.expectedLocationId) result.push('Falscher Standort');
    if ((entry.actualStockStructureId || null) !== (entry.expectedStockStructureId || null)
      && (entry.actualStockStructureId || entry.expectedStockStructureId)) result.push('Falscher Lagerplatz');
    return result;
  }

  function publicStocktake(stocktake, includeEntries = false) {
    const result = { ...stocktake, progress: progress(stocktake) };
    if (!includeEntries) delete result.entries;
    if (includeEntries) result.entries = stocktake.entries.map((entry) => ({
      ...entry,
      discrepancies: discrepancy(entry),
      expectedLocationName: locationName(entry.expectedLocationId),
      expectedStockStructureName: stockName(entry.expectedStockStructureId),
      actualLocationName: locationName(entry.actualLocationId),
      actualStockStructureName: stockName(entry.actualStockStructureId),
    }));
    return result;
  }

  function addHistory(stocktake, user, action, details = {}) {
    stocktake.history.push({
      id: nextId('stocktake-history', stocktake.history),
      at: nowIso(), actor: user.username, actorName: user.name || user.username,
      action, details,
    });
    stocktake.updatedAt = nowIso();
    stocktake.revision += 1;
  }

  function validateCreation(body, user) {
    const name = text(body.name, 160);
    const responsibleUserId = text(body.responsibleUserId, 64);
    const responsible = users.find((entry) => entry.id === responsibleUserId && entry.active);
    const method = text(body.method, 16).toLowerCase();
    const startDate = text(body.startDate, 10);
    const entityTypes = uniqueStrings(body.entityTypes).filter((entry) => ENTITY_TYPES.includes(entry));
    if (!name || !responsible || !METHODS.includes(method) || !/^\d{4}-\d{2}-\d{2}$/.test(startDate)) {
      return { error: 'Bezeichnung, verantwortliche Person, Art und Beginn sind Pflichtfelder.' };
    }
    if (!entityTypes.length || !mayCreateTypes(user, entityTypes)) {
      return { error: 'Für den gewählten Inventurbereich fehlt die Berechtigung.' };
    }
    const countMode = COUNT_MODES.includes(body.countMode) ? body.countMode : 'blind';
    return {
      name, responsible, method, startDate, entityTypes, countMode,
      notes: text(body.notes),
      scope: {
        locationIds: uniqueStrings(body.scope?.locationIds),
        stockStructureIds: uniqueStrings(body.scope?.stockStructureIds),
        departments: uniqueStrings(body.scope?.departments),
      },
    };
  }

  app.get('/api/stocktakes/options', authMiddleware, requirePermission('stocktakes.read'), (req, res) => {
    res.json({
      locations,
      stockStructures,
      departments,
      responsibleUsers: users.filter((entry) => entry.active).map((entry) => ({
        id: entry.id, name: entry.name, username: entry.username, roles: entry.roles,
      })),
      allowedEntityTypes: ENTITY_TYPES.filter((type) => mayCreateTypes(req.user, [type])),
      canEvaluate: isChair(req.user) && hasPermission(req.user, 'stocktakes.evaluate'),
    });
  });

  app.get('/api/stocktakes', authMiddleware, requirePermission('stocktakes.read'), (req, res) => {
    res.json(stocktakes.filter((entry) => canSee(req.user, entry)).slice().reverse()
      .map((entry) => publicStocktake(entry)));
  });

  app.get('/api/stocktakes/:id', authMiddleware, requirePermission('stocktakes.read'), (req, res) => {
    const stocktake = findStocktake(req, res);
    if (stocktake) res.json(publicStocktake(stocktake, true));
  });

  app.post('/api/stocktakes', authMiddleware, requirePermission('stocktakes.create'), (req, res) => {
    const values = validateCreation(req.body, req.user);
    if (values.error) return res.status(400).json({ error: values.error });
    const selected = [];
    if (values.entityTypes.includes('MaterialItem')) {
      selected.push(...materials.filter((item) => !item.archived && matchesScope(item, values.scope))
        .map((item) => ({ item, entityType: 'MaterialItem' })));
    }
    if (values.entityTypes.includes('ClothingItem')) {
      selected.push(...clothingItems.filter((item) => !item.archived && matchesScope(item, values.scope))
        .map((item) => ({ item, entityType: 'ClothingItem' })));
    }
    if (!selected.length) return res.status(409).json({ error: 'Im gewählten Bereich wurden keine inventarisierbaren Artikel gefunden.' });
    const createdAt = nowIso();
    const stocktake = {
      id: nextId('stocktake', stocktakes),
      name: values.name,
      responsibleUserId: values.responsible.id,
      responsibleName: values.responsible.name || values.responsible.username,
      method: values.method,
      countMode: values.countMode,
      startDate: values.startDate,
      notes: values.notes,
      entityTypes: values.entityTypes,
      scope: values.scope,
      status: 'Angelegt',
      entries: selected.map(({ item, entityType }, index) => snapshotEntry(item, entityType, index)),
      findings: [], history: [], revision: 0,
      createdAt, createdBy: req.user.username, updatedAt: createdAt,
      startedAt: null, evaluationStartedAt: null, completedAt: null, completedBy: null,
    };
    stocktakes.push(stocktake);
    addHistory(stocktake, req.user, 'angelegt', { itemCount: stocktake.entries.length });
    logEvent('create', 'Stocktake', { id: stocktake.id, itemName: stocktake.name }, req.user.username);
    return res.status(201).json(publicStocktake(stocktake, true));
  });

  app.post('/api/stocktakes/:id/start', authMiddleware, requirePermission('stocktakes.count'), (req, res) => {
    const stocktake = findStocktake(req, res);
    if (!stocktake) return;
    if (stocktake.status !== 'Angelegt') return res.status(409).json({ error: 'Nur angelegte Inventuren können gestartet werden.' });
    stocktake.status = 'In Arbeit'; stocktake.startedAt = nowIso();
    addHistory(stocktake, req.user, 'gestartet');
    res.json(publicStocktake(stocktake, true));
  });

  app.put('/api/stocktakes/:id/entries/:entryId', authMiddleware, requirePermission('stocktakes.count'), (req, res) => {
    const stocktake = findStocktake(req, res);
    if (!stocktake) return;
    if (stocktake.status !== 'In Arbeit') return res.status(409).json({ error: 'Zählungen sind nur im Status „In Arbeit“ möglich.' });
    const entry = stocktake.entries.find((candidate) => candidate.id === req.params.entryId);
    if (!entry) return res.status(404).json({ error: 'Inventurposition nicht gefunden.' });
    const actualLocationId = text(req.body.actualLocationId, 64) || entry.expectedLocationId;
    const actualStockStructureId = text(req.body.actualStockStructureId, 64) || null;
    if (actualLocationId && !locations.some((candidate) => candidate.id === actualLocationId)) return res.status(400).json({ error: 'Der erfasste Standort ist ungültig.' });
    if (actualStockStructureId && !stockStructures.some((candidate) => candidate.id === actualStockStructureId && candidate.locationId === actualLocationId)) return res.status(400).json({ error: 'Der Lagerplatz gehört nicht zum erfassten Standort.' });
    let actualQuantity = null; let result = null;
    if (entry.itemType === 'bulk') {
      actualQuantity = number(req.body.actualQuantity);
      if (actualQuantity === null) return res.status(400).json({ error: 'Eine gültige Ist-Menge ist erforderlich.' });
      result = actualQuantity === 0 ? 'nicht vorhanden' : 'vorhanden';
    } else {
      result = text(req.body.result, 32).toLowerCase();
      if (!INDIVIDUAL_RESULTS.includes(result)) return res.status(400).json({ error: 'Der Zustand ist ungültig.' });
      actualQuantity = result === 'nicht vorhanden' ? 0 : 1;
    }
    const attempt = {
      id: nextId('count', entry.attempts), actualQuantity, result,
      actualLocationId, actualStockStructureId,
      notes: text(req.body.notes, 2000), at: nowIso(),
      actor: req.user.username, actorName: req.user.name || req.user.username,
    };
    entry.attempts.push(attempt);
    entry.actualQuantity = attempt.actualQuantity;
    entry.result = attempt.result;
    entry.actualLocationId = attempt.actualLocationId;
    entry.actualStockStructureId = attempt.actualStockStructureId;
    entry.notes = attempt.notes;
    entry.countedAt = attempt.at;
    entry.countedBy = attempt.actor;
    entry.countedByName = attempt.actorName;
    addHistory(stocktake, req.user, 'gezählt', { entryId: entry.id, inventoryNumber: entry.inventoryNumber, attempt: entry.attempts.length });
    res.json(publicStocktake(stocktake, true));
  });

  app.post('/api/stocktakes/:id/findings', authMiddleware, requirePermission('stocktakes.count'), (req, res) => {
    const stocktake = findStocktake(req, res);
    if (!stocktake) return;
    if (stocktake.status !== 'In Arbeit') return res.status(409).json({ error: 'Fundstücke können nur während der Zählung erfasst werden.' });
    const code = text(req.body.inventoryNumber, 128);
    if (!code) return res.status(400).json({ error: 'Eine Inventarnummer oder Kennzeichnung ist erforderlich.' });
    const finding = { id: nextId('finding', stocktake.findings), inventoryNumber: code, notes: text(req.body.notes, 2000), createdAt: nowIso(), createdBy: req.user.username };
    stocktake.findings.push(finding);
    addHistory(stocktake, req.user, 'fundstück-erfasst', { findingId: finding.id, inventoryNumber: code });
    res.status(201).json(finding);
  });

  app.post('/api/stocktakes/:id/evaluate', authMiddleware, requirePermission('stocktakes.evaluate'), (req, res) => {
    const stocktake = findStocktake(req, res);
    if (!stocktake) return;
    if (!isChair(req.user)) return res.status(403).json({ error: 'Nur der Jugendvorsitz darf Inventuren auswerten.' });
    if (stocktake.status !== 'In Arbeit') return res.status(409).json({ error: 'Nur laufende Inventuren können ausgewertet werden.' });
    stocktake.status = 'Auswertung'; stocktake.evaluationStartedAt = nowIso();
    for (const entry of stocktake.entries) {
      const issues = discrepancy(entry);
      const missing = issues.includes('Fehlbestand') || (issues.includes('Mengenabweichung') && Number(entry.actualQuantity) < Number(entry.expectedQuantity));
      const damaged = issues.includes('Mangel');
      if (missing && !entry.shortageDefectId) {
        const missingQuantity = Math.max(1, Number(entry.expectedQuantity) - Number(entry.actualQuantity || 0));
        const result = defectManagement.createFromStocktake({
          entityType: entry.entityType, entityId: entry.entityId,
          affectedQuantity: Math.min(missingQuantity, Number(entry.expectedQuantity) || 1),
          title: 'Fehlbestand aus Inventur',
          description: `Inventur „${stocktake.name}“: Soll ${entry.expectedQuantity}, Ist ${entry.actualQuantity ?? 'nicht gezählt'}.`,
          stocktakeId: stocktake.id, user: req.user,
        });
        if (result?.report) entry.shortageDefectId = result.report.id;
      }
      if (damaged && !entry.defectId) {
        const result = defectManagement.createFromStocktake({
          entityType: entry.entityType, entityId: entry.entityId, affectedQuantity: 1,
          title: 'Mangel aus Inventur',
          description: entry.notes || `Bei der Inventur „${stocktake.name}“ wurde der Artikel als beschädigt erfasst.`,
          stocktakeId: stocktake.id, user: req.user,
        });
        if (result?.report) entry.defectId = result.report.id;
      }
    }
    addHistory(stocktake, req.user, 'auswertung-gestartet', progress(stocktake));
    res.json(publicStocktake(stocktake, true));
  });

  app.post('/api/stocktakes/:id/complete', authMiddleware, requirePermission('stocktakes.evaluate'), (req, res) => {
    const stocktake = findStocktake(req, res);
    if (!stocktake) return;
    if (!isChair(req.user)) return res.status(403).json({ error: 'Nur der Jugendvorsitz darf Inventuren abschließen.' });
    if (stocktake.status !== 'Auswertung') return res.status(409).json({ error: 'Die Inventur muss sich in der Auswertung befinden.' });
    const applyCorrections = req.body.applyCorrections === true;
    if (applyCorrections) {
      stocktake.entries.filter((entry) => entry.countedAt).forEach((entry) => {
        const entity = entityFor(entry);
        if (!entity) return;
        if (entry.itemType === 'bulk') entity.quantity = Math.max(Number(entry.actualQuantity), Number(entity.issuedQuantity || 0));
        if (entry.itemType === 'individual' && entry.result === 'nicht vorhanden') entity.status = 'Verloren';
        if (entry.actualLocationId) entity.locationId = entry.actualLocationId;
        entity.stockStructureId = entry.actualStockStructureId || null;
      });
    }
    stocktake.status = 'Abgeschlossen'; stocktake.completedAt = nowIso(); stocktake.completedBy = req.user.username;
    stocktake.correctionsApplied = applyCorrections;
    addHistory(stocktake, req.user, 'abgeschlossen', { applyCorrections });
    logEvent('complete', 'Stocktake', { id: stocktake.id, itemName: stocktake.name, applyCorrections }, req.user.username);
    res.json(publicStocktake(stocktake, true));
  });

  app.post('/api/stocktakes/:id/import', authMiddleware, requirePermission('stocktakes.count'), (req, res) => {
    const stocktake = findStocktake(req, res);
    if (!stocktake) return;
    if (stocktake.status !== 'In Arbeit') return res.status(409).json({ error: 'Listen können nur in laufende Inventuren importiert werden.' });
    const fileName = text(req.body.fileName, 255); const extension = fileName.split('.').pop().toLowerCase();
    const fileBase64 = String(req.body.fileBase64 || '');
    if (!['xlsx', 'ods'].includes(extension) || !fileBase64) return res.status(400).json({ error: 'Eine XLSX- oder ODS-Datei ist erforderlich.' });
    const bytes = Buffer.from(fileBase64, 'base64');
    if (!bytes.length || bytes.length > MAX_IMPORT_BYTES) return res.status(413).json({ error: 'Die Datei darf höchstens 5 MB groß sein.' });
    let rows;
    try {
      const workbook = XLSX.read(bytes, { type: 'buffer', sheetRows: MAX_IMPORT_ROWS + 2 });
      rows = XLSX.utils.sheet_to_json(workbook.Sheets[workbook.SheetNames[0]], { defval: '', raw: false });
    } catch (_) { return res.status(400).json({ error: 'Die Tabelle konnte nicht gelesen werden.' }); }
    if (rows.length > MAX_IMPORT_ROWS) return res.status(413).json({ error: `Die Tabelle darf höchstens ${MAX_IMPORT_ROWS} Zeilen enthalten.` });
    let imported = 0; const skippedRows = [];
    rows.forEach((row, index) => {
      const normalized = Object.fromEntries(Object.entries(row).map(([key, value]) => [key.toLowerCase().replace(/[^a-z0-9äöüß]/g, ''), value]));
      const inventoryNumber = text(normalized.inventarnummer || normalized.inventorynumber, 128);
      const entry = stocktake.entries.find((candidate) => candidate.inventoryNumber.toLowerCase() === inventoryNumber.toLowerCase());
      if (!entry) { skippedRows.push({ row: index + 2, reason: 'Inventarnummer nicht in dieser Inventur' }); return; }
      const rawResult = text(normalized.ergebnis || normalized.zustand, 32).toLowerCase();
      const actualQuantity = number(normalized.istmenge || normalized.ist);
      if ((entry.itemType === 'bulk' && actualQuantity === null)
        || (entry.itemType === 'individual' && !INDIVIDUAL_RESULTS.includes(rawResult))) {
        skippedRows.push({ row: index + 2, reason: 'Ist-Menge oder Ergebnis fehlt/ist ungültig' }); return;
      }
      const result = entry.itemType === 'bulk' ? (actualQuantity === 0 ? 'nicht vorhanden' : 'vorhanden') : rawResult;
      const attempt = {
        id: nextId('count', entry.attempts),
        actualQuantity: entry.itemType === 'bulk' ? actualQuantity : (result === 'nicht vorhanden' ? 0 : 1),
        result, actualLocationId: entry.expectedLocationId,
        actualStockStructureId: entry.expectedStockStructureId,
        notes: text(normalized.notizen || normalized.bemerkung, 2000),
        at: nowIso(), actor: req.user.username, actorName: req.user.name || req.user.username,
        source: 'table-import',
      };
      entry.attempts.push(attempt);
      entry.actualQuantity = attempt.actualQuantity;
      entry.result = attempt.result;
      entry.actualLocationId = attempt.actualLocationId;
      entry.actualStockStructureId = attempt.actualStockStructureId;
      entry.notes = attempt.notes;
      entry.countedAt = attempt.at;
      entry.countedBy = attempt.actor;
      entry.countedByName = attempt.actorName;
      imported += 1;
    });
    addHistory(stocktake, req.user, 'liste-importiert', { imported, skipped: skippedRows.length, fileName });
    res.json({ imported, skipped: skippedRows.length, skippedRows, stocktake: publicStocktake(stocktake, true) });
  });

  app.get('/api/stocktakes/:id/export', authMiddleware, requirePermission('stocktakes.export'), async (req, res) => {
    const stocktake = findStocktake(req, res);
    if (!stocktake) return;
    const format = text(req.query.format || 'xlsx', 16).toLowerCase();
    const blank = String(req.query.blank || '') === 'true';
    const differencesOnly = String(req.query.differences || '') === 'true';
    if (!['xlsx', 'ods', 'pdf'].includes(format)) return res.status(400).json({ error: 'Das Exportformat ist ungültig.' });
    const exportedEntries = stocktake.entries.filter((entry) => !differencesOnly || discrepancy(entry).length);
    const rows = exportedEntries.map((entry) => ({
      Inventarnummer: entry.inventoryNumber,
      Bezeichnung: entry.name,
      Bereich: entry.entityType === 'MaterialItem' ? 'Inventar' : 'Kleiderkammer',
      Standort: locationName(entry.expectedLocationId),
      Lagerplatz: stockName(entry.expectedStockStructureId),
      Einheit: entry.unit,
      Sollmenge: stocktake.countMode === 'blind' && blank ? '' : entry.expectedQuantity,
      Istmenge: blank ? '' : entry.actualQuantity ?? '',
      Ergebnis: blank ? '' : entry.result || '',
      Abweichung: blank ? '' : discrepancy(entry).join(', '),
      Notizen: blank ? '' : entry.notes || '',
    }));
    let bytes; let mimeType;
    if (format === 'xlsx' || format === 'ods') {
      const workbook = XLSX.utils.book_new(); const sheet = XLSX.utils.json_to_sheet(rows);
      sheet['!cols'] = [{ wch: 24 }, { wch: 28 }, { wch: 16 }, { wch: 20 }, { wch: 18 }, { wch: 10 }, { wch: 12 }, { wch: 12 }, { wch: 20 }, { wch: 24 }, { wch: 30 }];
      XLSX.utils.book_append_sheet(workbook, sheet, blank ? 'Zählliste' : 'Ergebnis');
      bytes = XLSX.write(workbook, { type: 'buffer', bookType: format });
      mimeType = format === 'xlsx' ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' : 'application/vnd.oasis.opendocument.spreadsheet';
    } else {
      const { PDFDocument, StandardFonts, rgb } = pdfLib();
      const pdf = await PDFDocument.create(); const font = await pdf.embedFont(StandardFonts.Helvetica); const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
      const pageWidth = 842; const pageHeight = 595; const margin = 28; const rowHeight = 20;
      let page; let y;
      const addPage = () => {
        page = pdf.addPage([pageWidth, pageHeight]); y = pageHeight - margin;
        page.drawText(`MaterialKompass - ${blank ? 'Zaehlliste' : differencesOnly ? 'Differenzliste' : 'Inventurergebnis'}`, { x: margin, y, size: 14, font: bold, color: rgb(0.72, 0.1, 0.1) });
        y -= 20; page.drawText(`${stocktake.name} | Beginn ${stocktake.startDate} | Verantwortlich ${stocktake.responsibleName}`, { x: margin, y, size: 9, font });
        y -= 24;
      };
      addPage();
      for (const entry of exportedEntries) {
        if (y < 55) addPage();
        const target = `${entry.inventoryNumber} | ${entry.name} | ${locationName(entry.expectedLocationId)} / ${stockName(entry.expectedStockStructureId)}`.slice(0, 120);
        page.drawText(target, { x: margin, y, size: 8, font: bold }); y -= 10;
        let detail = entry.itemType === 'bulk'
          ? `Ist-Menge: ${blank ? '____________' : entry.actualQuantity ?? '-'} ${entry.unit}    Notiz: ${blank ? '____________________________' : entry.notes || '-'}`
          : `Ergebnis: ${blank ? '[ ] vorhanden   [ ] beschaedigt   [ ] nicht vorhanden' : entry.result || '-'}    Notiz: ${blank ? '________________' : entry.notes || '-'}`;
        if (!blank && discrepancy(entry).length) detail += `    Abweichung: ${discrepancy(entry).join(', ')}`;
        page.drawText(detail.slice(0, 135), { x: margin + 8, y, size: 8, font }); y -= rowHeight;
        page.drawLine({ start: { x: margin, y: y + 7 }, end: { x: pageWidth - margin, y: y + 7 }, thickness: 0.4, color: rgb(0.75, 0.75, 0.75) });
      }
      bytes = Buffer.from(await pdf.save()); mimeType = 'application/pdf';
    }
    const suffix = blank ? 'zaehlliste' : differencesOnly ? 'differenzliste' : 'ergebnis';
    logEvent('export', 'Stocktake', { id: stocktake.id, format, blank, differencesOnly }, req.user.username);
    res.json({ fileName: `inventur-${stocktake.id}-${suffix}.${format}`, mimeType, fileBase64: bytes.toString('base64') });
  });
}

module.exports = { registerStocktakeRoutes, STOCKTAKE_STATUSES };
