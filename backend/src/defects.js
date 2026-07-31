const DEFECT_STATUSES = Object.freeze([
  'Neu', 'In Prüfung', 'Zugewiesen', 'In Bearbeitung', 'Behoben',
  'Geprüft/Geschlossen',
]);
const DEFECT_PRIORITIES = Object.freeze(['Niedrig', 'Normal', 'Hoch', 'Kritisch']);
const ENTITY_TYPES = Object.freeze(['MaterialItem', 'ClothingItem']);
const CLOSED_STATUSES = new Set(['Geprüft/Geschlossen']);
const NEXT_STATUS = Object.freeze({
  Neu: 'In Prüfung',
  'In Prüfung': 'Zugewiesen',
  Zugewiesen: 'In Bearbeitung',
  'In Bearbeitung': 'Behoben',
  Behoben: 'Geprüft/Geschlossen',
});
const IMAGE_MIME_TYPES = new Set(['image/jpeg', 'image/png']);
const MAX_IMAGES = 10;
const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
const REPORT_MIME_TYPES = new Set(['application/pdf', 'image/jpeg', 'image/png']);
const MAX_REPORT_BYTES = 10 * 1024 * 1024;

function text(value, max = 10_000) {
  return String(value ?? '').trim().slice(0, max);
}

function numberOrNull(value) {
  if (value === '' || value === null || value === undefined) return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : null;
}

function similarity(left, right) {
  const tokens = (value) => new Set(String(value || '').toLowerCase()
    .normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    .split(/[^a-z0-9]+/).filter((entry) => entry.length > 2));
  const a = tokens(left); const b = tokens(right);
  if (!a.size || !b.size) return 0;
  const intersection = [...a].filter((entry) => b.has(entry)).length;
  return intersection / new Set([...a, ...b]).size;
}

function csvCell(value) {
  return `"${String(value ?? '').replace(/"/g, '""')}"`;
}

function pdfEscape(value) {
  return String(value ?? '').replace(/\\/g, '\\\\').replace(/\(/g, '\\(').replace(/\)/g, '\\)');
}

function createSimplePdf(title, lines) {
  const pages = [];
  const allLines = [title, '', ...lines];
  for (let index = 0; index < allLines.length; index += 44) pages.push(allLines.slice(index, index + 44));
  if (!pages.length) pages.push([title]);
  const objects = new Map();
  const pageIds = pages.map((_, index) => 4 + index * 2);
  objects.set(1, '<< /Type /Catalog /Pages 2 0 R >>');
  objects.set(2, `<< /Type /Pages /Kids [${pageIds.map((id) => `${id} 0 R`).join(' ')}] /Count ${pages.length} >>`);
  objects.set(3, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>');
  pages.forEach((pageLines, index) => {
    const pageId = pageIds[index];
    const contentId = pageId + 1;
    const commands = ['BT', '/F1 10 Tf', '48 790 Td'];
    pageLines.forEach((line, lineIndex) => {
      if (lineIndex) commands.push('0 -17 Td');
      commands.push(`(${pdfEscape(line).slice(0, 130)}) Tj`);
    });
    commands.push('ET');
    const stream = commands.join('\n');
    objects.set(pageId, `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R >> >> /Contents ${contentId} 0 R >>`);
    objects.set(contentId, `<< /Length ${Buffer.byteLength(stream, 'latin1')} >>\nstream\n${stream}\nendstream`);
  });
  const maxId = Math.max(...objects.keys());
  const chunks = ['%PDF-1.4\n'];
  const offsets = [0];
  let offset = Buffer.byteLength(chunks[0], 'latin1');
  for (let id = 1; id <= maxId; id += 1) {
    offsets[id] = offset;
    const chunk = `${id} 0 obj\n${objects.get(id)}\nendobj\n`;
    chunks.push(chunk);
    offset += Buffer.byteLength(chunk, 'latin1');
  }
  const xrefOffset = offset;
  let xref = `xref\n0 ${maxId + 1}\n0000000000 65535 f \n`;
  for (let id = 1; id <= maxId; id += 1) xref += `${String(offsets[id]).padStart(10, '0')} 00000 n \n`;
  chunks.push(`${xref}trailer\n<< /Size ${maxId + 1} /Root 1 0 R >>\nstartxref\n${xrefOffset}\n%%EOF`);
  return Buffer.from(chunks.join(''), 'latin1');
}

function registerDefectManagement({
  app, authMiddleware, requirePermission, hasPermission, defectReports,
  materials, clothingItems, users, notifications, logEvent, nextId, XLSX,
}) {
  const nowIso = () => new Date().toISOString();

  function entityFor(type, id) {
    if (type === 'MaterialItem') return materials.find((entry) => entry.id === id);
    if (type === 'ClothingItem') return clothingItems.find((entry) => entry.id === id);
    return null;
  }

  function scopeFor(user, entityType) {
    const roles = new Set(user?.roles || []);
    if (roles.has('Admin') || roles.has('Vorsitz')) return true;
    if (entityType === 'MaterialItem') return roles.has('Materialwart');
    if (entityType === 'ClothingItem') return roles.has('Kleiderwart') || roles.has('Sachkundiger PSAgE');
    return false;
  }

  function can(user, permission, defect = null) {
    if (!hasPermission(user, permission) && !hasPermission(user, 'defects.write')) return false;
    return !defect || scopeFor(user, defect.entityType);
  }

  function normalizeLegacy(report, index) {
    const createdAt = report.createdAt || nowIso();
    report.id ||= `defect-${index + 1}`;
    report.defectNumber ||= `M-${createdAt.slice(0, 4)}-${String(index + 1).padStart(4, '0')}`;
    report.entityType = report.entityType === 'ClothingItem' ? 'ClothingItem' : 'MaterialItem';
    report.title ||= text(report.description, 80) || 'Übernommener Mangel';
    report.description ||= report.title;
    report.status = DEFECT_STATUSES.includes(report.status) ? report.status : report.status === 'Behoben' ? 'Behoben' : 'Neu';
    report.priority = DEFECT_PRIORITIES.includes(report.priority) ? report.priority : 'Normal';
    report.reportedAt ||= createdAt;
    report.reportedBy ||= 'system';
    report.reportedByName ||= report.reportedBy;
    report.affectedQuantity = Number(report.affectedQuantity || 1);
    report.damageType ||= '';
    if (report.emailSource && !report.measuresTaken && report.cause) {
      report.measuresTaken = report.cause;
      report.cause = '';
    }
    report.cause ||= '';
    report.riskLevel ||= 'Keine Angabe';
    report.operationalSafety ||= 'Nicht einsatzfähig';
    report.assignee ||= '';
    report.responsibleDepartment ||= '';
    report.measuresTaken ||= '';
    report.contactName ||= report.reportedByName || '';
    report.contactEmail ||= '';
    report.contactPhone ||= '';
    report.dueDate ||= null;
    report.estimatedCost ??= null;
    report.actualCost ??= null;
    report.comments ||= [];
    report.checklist ||= [];
    report.images ||= [];
    report.documents ||= [];
    report.history ||= [{ at: createdAt, actor: report.reportedBy, action: 'migration', details: 'Bestehenden Mangel übernommen' }];
    report.followUpTasks ||= [];
    report.relatedActions ||= [];
    report.archivedAt ||= null;
    report.archivedBy ||= null;
    return report;
  }
  defectReports.forEach(normalizeLegacy);

  function nextDefectNumber() {
    const year = new Date().getFullYear();
    const highest = defectReports.reduce((max, report) => {
      const match = String(report.defectNumber || '').match(new RegExp(`^M-${year}-(\\d+)$`));
      return match ? Math.max(max, Number(match[1])) : max;
    }, 0);
    return `M-${year}-${String(highest + 1).padStart(4, '0')}`;
  }

  function addHistory(report, actor, action, details = '') {
    report.history.push({ id: nextId('history', report.history), at: nowIso(), actor, action, details });
    report.updatedAt = nowIso();
  }

  function changeDetails(field, from, to) {
    return { changes: { [field]: { from: from ?? null, to: to ?? null } } };
  }

  function publicDefect(report, includeImageData = false) {
    const entity = entityFor(report.entityType, report.entityId);
    return {
      ...report,
      entityName: entity?.name || 'Gelöschter Artikel',
      inventoryNumber: entity?.inventoryNumber || null,
      images: report.images.map((image) => includeImageData ? image : ({
        id: image.id, fileName: image.fileName, mimeType: image.mimeType,
        sizeBytes: image.sizeBytes, createdAt: image.createdAt, createdBy: image.createdBy,
      })),
      documents: report.documents.map((document) => includeImageData ? document : ({
        id: document.id, fileName: document.fileName, mimeType: document.mimeType,
        sizeBytes: document.sizeBytes, createdAt: document.createdAt, createdBy: document.createdBy,
      })),
    };
  }

  function activeForEntity(entityType, entityId, exceptId = null) {
    return defectReports.filter((report) => report.id !== exceptId && report.entityType === entityType &&
      report.entityId === entityId && !report.doesNotAffectEntityStatus
      && !report.archivedAt && !CLOSED_STATUSES.has(report.status));
  }

  function markEntityDefective(report) {
    const entity = entityFor(report.entityType, report.entityId);
    if (!entity) return;
    const existingBaseline = activeForEntity(report.entityType, report.entityId, report.id)
      .find((entry) => entry.previousEntityStatus && entry.previousEntityStatus !== 'Defekt')
      ?.previousEntityStatus;
    report.previousEntityStatus ||= existingBaseline || entity.status || 'Lagernd';
    entity.status = 'Defekt';
  }

  function restoreEntityIfResolved(report) {
    const entity = entityFor(report.entityType, report.entityId);
    if (!entity || activeForEntity(report.entityType, report.entityId, report.id).length) return;
    if (report.entityType === 'MaterialItem') {
      entity.status = Number(entity.issuedQuantity || 0) > 0 ? 'Ausgegeben' :
        ['Defekt', 'In Reparatur', 'Ausgegeben'].includes(report.previousEntityStatus)
          ? 'Lagernd' : report.previousEntityStatus || 'Lagernd';
    } else {
      entity.status = entity.assignedPerson ? 'Ausgegeben' : 'Lagernd';
    }
  }

  function createNotifications(report, actorId) {
    const targetRole = report.entityType === 'MaterialItem' ? 'Materialwart' : 'Kleiderwart';
    users.filter((user) => user.active && user.id !== actorId &&
      (user.roles?.includes(targetRole) || user.roles?.includes('Admin') ||
        (report.priority === 'Kritisch' && user.roles?.includes('Vorsitz'))))
      .forEach((user) => notifications.push({
        id: nextId('notification', notifications), userId: user.id, type: 'new-defect',
        title: `Neuer Mangel ${report.defectNumber}`,
        message: `${report.title} · ${report.priority}`,
        defectId: report.id, readAt: null, createdAt: nowIso(),
      }));
  }

  function validateCreate(body) {
    const entityType = text(body.entityType, 32);
    const entityId = text(body.entityId, 64);
    const entity = entityFor(entityType, entityId);
    const title = text(body.title, 160);
    const description = text(body.description, 10_000);
    const priority = text(body.priority || 'Normal', 32);
    const contactEmail = text(body.contactEmail, 255).toLowerCase();
    const affectedQuantity = Number(body.affectedQuantity ?? 1);
    if (!ENTITY_TYPES.includes(entityType) || !entity) return { error: 'Der betroffene Artikel ist ungültig.' };
    if (!title || !description) return { error: 'Titel und Beschreibung sind Pflichtfelder.' };
    if (!DEFECT_PRIORITIES.includes(priority)) return { error: 'Die Priorität ist ungültig.' };
    if (contactEmail && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(contactEmail)) {
      return { error: 'Die Kontakt-E-Mail-Adresse ist ungültig.' };
    }
    const maximum = entityType === 'MaterialItem' ? Number(entity.quantity || 1) : 1;
    if (!Number.isFinite(affectedQuantity) || affectedQuantity <= 0 || affectedQuantity > maximum) return { error: 'Die betroffene Menge ist ungültig.' };
    return { entityType, entityId, entity, title, description, priority, affectedQuantity };
  }

  function createReport(body, user, source = {}) {
    const values = validateCreate(body);
    if (values.error) return values;
    const createdAt = nowIso();
    const comparable = `${values.title} ${values.description}`;
    const possibleDuplicate = defectReports.find((entry) =>
      !entry.archivedAt && !CLOSED_STATUSES.has(entry.status) &&
      entry.entityType === values.entityType && entry.entityId === values.entityId &&
      similarity(comparable, `${entry.title} ${entry.description}`) >= 0.6);
    const possibleRecurrence = defectReports.slice().reverse().find((entry) =>
      CLOSED_STATUSES.has(entry.status) && entry.entityType === values.entityType &&
      entry.entityId === values.entityId &&
      (similarity(comparable, `${entry.title} ${entry.description}`) >= 0.6 ||
        (body.damageType && entry.damageType === body.damageType)));
    const report = {
      id: nextId('defect', defectReports), defectNumber: nextDefectNumber(),
      entityType: values.entityType, entityId: values.entityId,
      affectedQuantity: values.affectedQuantity, title: values.title,
      description: values.description, priority: values.priority, status: 'Neu',
      damageType: text(body.damageType, 120), cause: text(body.cause, 2000),
      measuresTaken: text(body.measuresTaken, 5000),
      riskLevel: text(body.riskLevel || 'Keine Angabe', 80),
      operationalSafety: text(body.operationalSafety || 'Nicht einsatzfähig', 80),
      assignee: text(body.assignee, 255), responsibleDepartment: text(body.responsibleDepartment, 255),
      contactName: text(body.contactName || user.name || user.username, 255),
      contactEmail: text(body.contactEmail || user.email, 255).toLowerCase(),
      contactPhone: text(body.contactPhone, 80),
      dueDate: body.dueDate || null, estimatedCost: numberOrNull(body.estimatedCost), actualCost: null,
      resolution: '', reportedAt: createdAt, reportedBy: source.reportedBy || user.id,
      reportedByName: source.reportedByName || user.name || user.username, createdAt, updatedAt: createdAt,
      linkedInspectionId: source.inspectionId || null,
      doesNotAffectEntityStatus: source.preserveEntityStatus === true,
      recurrenceOfId: body.recurrenceOfId || possibleRecurrence?.id || null,
      duplicateOfId: body.duplicateOfId || possibleDuplicate?.id || null,
      duplicateDetectedAutomatically: !body.duplicateOfId && Boolean(possibleDuplicate),
      relatedActions: [], followUpTasks: [],
      comments: [], checklist: [], images: [], documents: [], history: [],
      emailSource: source.emailSource || null,
      archivedAt: null, archivedBy: null,
    };
    defectReports.push(report);
    addHistory(
      report,
      user.username,
      'create',
      source.inspectionId
        ? 'Automatisch aus Prüfung erstellt'
        : source.emailSource
          ? 'Automatisch aus E-Mail erstellt'
          : 'Mangel gemeldet',
    );
    if (!source.preserveEntityStatus) markEntityDefective(report);
    createNotifications(report, user.id);
    logEvent('create', 'DefectReport', {
      id: report.id, itemName: values.entity.name, inventoryNumber: values.entity.inventoryNumber,
      defectNumber: report.defectNumber,
    }, user.username);
    return { report };
  }

  function findVisible(req, includeArchived = false) {
    return defectReports.filter((report) => scopeFor(req.user, report.entityType) &&
      (includeArchived || !report.archivedAt));
  }

  function findDefect(req, res) {
    const report = defectReports.find((entry) => entry.id === req.params.id);
    if (!report || !scopeFor(req.user, report.entityType)) {
      res.status(404).json({ error: 'Mangel nicht gefunden.' });
      return null;
    }
    return report;
  }

  app.get('/api/defects', authMiddleware, requirePermission('defects.read'), (req, res) => {
    const includeArchived = String(req.query.archived || '') === 'all' || String(req.query.archived) === 'true';
    res.json(findVisible(req, includeArchived).slice().reverse().map((report) => publicDefect(report)));
  });

  app.get('/api/defects/summary', authMiddleware, requirePermission('defects.read'), (req, res) => {
    const visible = findVisible(req);
    res.json({
      open: visible.filter((entry) => !CLOSED_STATUSES.has(entry.status)).length,
      inProgress: visible.filter((entry) => entry.status === 'In Bearbeitung').length,
    });
  });

  app.get('/api/defects/export', authMiddleware, requirePermission('defects.export'), (req, res) => {
    const format = text(req.query.format || 'xlsx', 16).toLowerCase();
    if (!['xlsx', 'ods', 'csv', 'pdf', 'print'].includes(format)) return res.status(400).json({ error: 'Ungültiges Exportformat.' });
    const rows = findVisible(req, true).map((report) => {
      const entity = entityFor(report.entityType, report.entityId);
      return {
        Mangelnummer: report.defectNumber, Titel: report.title,
        Bereich: report.entityType === 'MaterialItem' ? 'Inventar' : 'Kleidung',
        Artikel: entity?.name || '', Inventarnummer: entity?.inventoryNumber || '',
        Menge: report.affectedQuantity, Status: report.status, Priorität: report.priority,
        Verantwortlich: report.assignee, Frist: report.dueDate || '',
        'Getroffene Maßnahmen': report.measuresTaken || '',
        Kontakt: report.contactName || '', 'Kontakt E-Mail': report.contactEmail || '',
        'Kontakt Telefon': report.contactPhone || '',
        'Gemeldet am': report.reportedAt, Beschreibung: report.description,
        'Geschätzte Kosten': report.estimatedCost ?? '', 'Tatsächliche Kosten': report.actualCost ?? '',
      };
    });
    const date = nowIso().slice(0, 10);
    let buffer; let fileName; let mimeType;
    if (format === 'xlsx' || format === 'ods') {
      const workbook = XLSX.utils.book_new();
      const sheet = XLSX.utils.json_to_sheet(rows);
      sheet['!cols'] = Object.keys(rows[0] || { Mangelnummer: '' }).map(() => ({ wch: 22 }));
      XLSX.utils.book_append_sheet(workbook, sheet, 'Mängel');
      buffer = XLSX.write(workbook, { type: 'buffer', bookType: format });
      fileName = `maengel-${date}.${format}`;
      mimeType = format === 'xlsx' ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' : 'application/vnd.oasis.opendocument.spreadsheet';
    } else if (format === 'csv') {
      const headers = Object.keys(rows[0] || { Mangelnummer: '' });
      buffer = Buffer.from(`\uFEFF${headers.map(csvCell).join(';')}\r\n${rows.map((row) => headers.map((header) => csvCell(row[header])).join(';')).join('\r\n')}`, 'utf8');
      fileName = `maengel-${date}.csv`; mimeType = 'text/csv';
    } else if (format === 'pdf') {
      buffer = createSimplePdf('MaterialKompass - Mängelbericht', rows.map((row) =>
        `${row.Mangelnummer} | ${row.Priorität} | ${row.Status} | ${row.Artikel} | ${row.Titel}`));
      fileName = `maengel-${date}.pdf`; mimeType = 'application/pdf';
    } else {
      const escapeHtml = (value) => String(value ?? '').replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]));
      const headers = Object.keys(rows[0] || { Mangelnummer: '' });
      const html = `<!doctype html><html lang="de"><head><meta charset="utf-8"><title>Mängelliste</title><style>body{font:12px Arial}table{border-collapse:collapse;width:100%}th,td{border:1px solid #999;padding:5px;text-align:left}@media print{button{display:none}}</style></head><body><button onclick="print()">Drucken</button><h1>Mängelliste</h1><table><thead><tr>${headers.map((h) => `<th>${escapeHtml(h)}</th>`).join('')}</tr></thead><tbody>${rows.map((row) => `<tr>${headers.map((h) => `<td>${escapeHtml(row[h])}</td>`).join('')}</tr>`).join('')}</tbody></table></body></html>`;
      buffer = Buffer.from(html, 'utf8'); fileName = `maengel-druckansicht-${date}.html`; mimeType = 'text/html';
    }
    logEvent('export', 'DefectReport', { format, itemCount: rows.length }, req.user.username);
    return res.json({ fileName, mimeType, fileBase64: buffer.toString('base64') });
  });

  app.post('/api/defects', authMiddleware, requirePermission('defects.report'), (req, res) => {
    if (!scopeFor(req.user, req.body.entityType)) return res.status(403).json({ error: 'Für diesen Bereich fehlt die Berechtigung.' });
    const result = createReport(req.body, req.user);
    if (result.error) return res.status(400).json({ error: result.error });
    return res.status(201).json(publicDefect(result.report));
  });

  app.get('/api/defects/:id', authMiddleware, requirePermission('defects.read'), (req, res) => {
    const report = findDefect(req, res); if (!report) return;
    return res.json(publicDefect(report, true));
  });

  app.put('/api/defects/:id', authMiddleware, requirePermission('defects.edit'), (req, res) => {
    const report = findDefect(req, res); if (!report) return;
    if (!can(req.user, 'defects.edit', report) || report.archivedAt) return res.status(403).json({ error: 'Der Mangel darf nicht bearbeitet werden.' });
    const before = structuredClone(report);
    if (req.body.title !== undefined) report.title = text(req.body.title, 160);
    if (req.body.description !== undefined) report.description = text(req.body.description, 10_000);
    if (!report.title || !report.description) return res.status(400).json({ error: 'Titel und Beschreibung sind Pflichtfelder.' });
    if (req.body.priority !== undefined) {
      if (!DEFECT_PRIORITIES.includes(req.body.priority)) return res.status(400).json({ error: 'Ungültige Priorität.' });
      report.priority = req.body.priority;
    }
    ['damageType', 'cause', 'measuresTaken', 'riskLevel', 'operationalSafety', 'responsibleDepartment',
      'contactName', 'contactEmail', 'contactPhone', 'resolution']
      .forEach((field) => {
        if (req.body[field] !== undefined) {
          report[field] = text(
            req.body[field],
            ['cause', 'measuresTaken', 'resolution'].includes(field) ? 5000 : 255,
          );
        }
      });
    report.contactEmail = report.contactEmail.toLowerCase();
    if (report.contactEmail && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(report.contactEmail)) {
      return res.status(400).json({ error: 'Die Kontakt-E-Mail-Adresse ist ungültig.' });
    }
    if (req.body.dueDate !== undefined) report.dueDate = req.body.dueDate || null;
    if (req.body.estimatedCost !== undefined) report.estimatedCost = numberOrNull(req.body.estimatedCost);
    if (req.body.actualCost !== undefined) report.actualCost = numberOrNull(req.body.actualCost);
    if (req.body.recurrenceOfId !== undefined) report.recurrenceOfId = req.body.recurrenceOfId || null;
    if (req.body.duplicateOfId !== undefined) report.duplicateOfId = req.body.duplicateOfId || null;
    if (req.body.relatedActions !== undefined && Array.isArray(req.body.relatedActions)) report.relatedActions = req.body.relatedActions.slice(0, 50);
    if (req.body.followUpTasks !== undefined && Array.isArray(req.body.followUpTasks)) report.followUpTasks = req.body.followUpTasks.slice(0, 100);
    const trackedFields = [
      'title', 'description', 'priority', 'damageType', 'cause', 'measuresTaken', 'riskLevel',
      'operationalSafety', 'responsibleDepartment', 'contactName', 'contactEmail',
      'contactPhone', 'dueDate', 'estimatedCost',
      'actualCost', 'resolution', 'recurrenceOfId', 'duplicateOfId',
      'relatedActions', 'followUpTasks',
    ];
    const changes = Object.fromEntries(trackedFields.filter((field) =>
      JSON.stringify(before[field] ?? null) !== JSON.stringify(report[field] ?? null)
    ).map((field) => [field, { from: before[field] ?? null, to: report[field] ?? null }]));
    addHistory(report, req.user.username, 'update', { changes });
    logEvent('update', 'DefectReport', { id: report.id, defectNumber: report.defectNumber }, req.user.username);
    return res.json(publicDefect(report));
  });

  app.post('/api/defects/:id/assign', authMiddleware, requirePermission('defects.assign'), (req, res) => {
    const report = findDefect(req, res); if (!report) return;
    if (!can(req.user, 'defects.assign', report) || report.archivedAt) return res.status(403).json({ error: 'Zuweisung nicht erlaubt.' });
    const oldAssignment = {
      assignee: report.assignee, responsibleDepartment: report.responsibleDepartment,
      dueDate: report.dueDate,
    };
    report.assignee = text(req.body.assignee, 255);
    report.responsibleDepartment = text(req.body.responsibleDepartment, 255);
    report.dueDate = req.body.dueDate || report.dueDate || null;
    if (!report.assignee) return res.status(400).json({ error: 'Eine verantwortliche Person ist erforderlich.' });
    addHistory(report, req.user.username, 'assign', {
      changes: {
        assignee: { from: oldAssignment.assignee, to: report.assignee },
        responsibleDepartment: { from: oldAssignment.responsibleDepartment, to: report.responsibleDepartment },
        dueDate: { from: oldAssignment.dueDate, to: report.dueDate },
      },
    });
    return res.json(publicDefect(report));
  });

  app.post('/api/defects/:id/transition', authMiddleware, (req, res) => {
    const report = findDefect(req, res); if (!report) return;
    const target = text(req.body.status, 64);
    const reopening = report.status === 'Geprüft/Geschlossen' && target === 'Neu';
    const requiredPermission = ['Behoben', 'Geprüft/Geschlossen'].includes(target) ? 'defects.close' : 'defects.edit';
    if (!can(req.user, requiredPermission, report) || report.archivedAt) return res.status(403).json({ error: 'Statuswechsel nicht erlaubt.' });
    if (!reopening && NEXT_STATUS[report.status] !== target) return res.status(409).json({ error: `Von „${report.status}“ ist dieser Statuswechsel nicht möglich.` });
    if (target === 'Zugewiesen' && !report.assignee) return res.status(409).json({ error: 'Vor der Zuweisung muss eine verantwortliche Person eingetragen sein.' });
    if (target === 'Geprüft/Geschlossen' && !text(report.resolution)) return res.status(409).json({ error: 'Vor dem Schließen muss die Behebung dokumentiert werden.' });
    const previousStatus = report.status;
    report.status = target;
    if (target === 'Behoben') report.resolvedAt = nowIso();
    if (target === 'Geprüft/Geschlossen') { report.closedAt = nowIso(); restoreEntityIfResolved(report); }
    if (reopening) { report.closedAt = null; report.resolvedAt = null; markEntityDefective(report); }
    addHistory(report, req.user.username, reopening ? 'reopen' : 'status',
      changeDetails('status', previousStatus, target));
    logEvent(reopening ? 'reopen' : 'update', 'DefectReport', { id: report.id, status: target }, req.user.username);
    return res.json(publicDefect(report));
  });

  app.post('/api/defects/:id/comments', authMiddleware, requirePermission('defects.edit'), (req, res) => {
    const report = findDefect(req, res); if (!report) return;
    const value = text(req.body.text, 5000);
    if (!value || report.archivedAt) return res.status(400).json({ error: 'Ein Kommentartext ist erforderlich.' });
    const comment = { id: nextId('comment', report.comments), text: value, author: req.user.name || req.user.username, authorId: req.user.id, createdAt: nowIso() };
    report.comments.push(comment); addHistory(report, req.user.username, 'comment', changeDetails('comment', null, comment));
    return res.status(201).json(comment);
  });

  app.post('/api/defects/:id/checklist', authMiddleware, requirePermission('defects.edit'), (req, res) => {
    const report = findDefect(req, res); if (!report) return;
    const label = text(req.body.label, 500);
    if (!label || report.archivedAt) return res.status(400).json({ error: 'Eine Aufgabenbeschreibung ist erforderlich.' });
    const item = { id: nextId('check', report.checklist), label, done: false, doneAt: null, doneBy: null };
    report.checklist.push(item); addHistory(report, req.user.username, 'checklist', changeDetails('checklistItem', null, item));
    return res.status(201).json(item);
  });

  app.patch('/api/defects/:id/checklist/:itemId', authMiddleware, requirePermission('defects.edit'), (req, res) => {
    const report = findDefect(req, res); if (!report) return;
    const item = report.checklist.find((entry) => entry.id === req.params.itemId);
    if (!item || report.archivedAt) return res.status(404).json({ error: 'Checklistenpunkt nicht gefunden.' });
    const oldDone = item.done;
    item.done = req.body.done === true; item.doneAt = item.done ? nowIso() : null; item.doneBy = item.done ? req.user.username : null;
    addHistory(report, req.user.username, 'checklist', changeDetails(`checklist.${item.id}.done`, oldDone, item.done));
    return res.json(item);
  });

  app.post('/api/defects/:id/related-actions', authMiddleware, requirePermission('defects.edit'), (req, res) => {
    const report = findDefect(req, res); if (!report) return;
    const actionType = text(req.body.type, 64);
    const label = text(req.body.label, 500);
    if (!['Reparatur', 'Beschaffung', 'Aussonderung'].includes(actionType) || !label || report.archivedAt) {
      return res.status(400).json({ error: 'Art und Bezeichnung der Verknüpfung sind erforderlich.' });
    }
    const action = {
      id: nextId('related', report.relatedActions), type: actionType, label,
      referenceId: text(req.body.referenceId, 128) || null,
      createdAt: nowIso(), createdBy: req.user.username,
    };
    report.relatedActions.push(action);
    addHistory(report, req.user.username, 'related-action', changeDetails('relatedAction', null, action));
    return res.status(201).json(action);
  });

  app.post('/api/defects/:id/follow-up-tasks', authMiddleware, requirePermission('defects.edit'), (req, res) => {
    const report = findDefect(req, res); if (!report) return;
    const label = text(req.body.label, 500);
    if (!label || report.archivedAt) return res.status(400).json({ error: 'Eine Folgeaufgabe ist erforderlich.' });
    const task = {
      id: nextId('follow-up', report.followUpTasks), label,
      assignee: text(req.body.assignee, 255), dueDate: req.body.dueDate || null,
      done: false, doneAt: null, createdAt: nowIso(), createdBy: req.user.username,
    };
    report.followUpTasks.push(task);
    addHistory(report, req.user.username, 'follow-up', changeDetails('followUpTask', null, task));
    return res.status(201).json(task);
  });

  app.patch('/api/defects/:id/follow-up-tasks/:taskId', authMiddleware, requirePermission('defects.edit'), (req, res) => {
    const report = findDefect(req, res); if (!report) return;
    const task = report.followUpTasks.find((entry) => entry.id === req.params.taskId);
    if (!task || report.archivedAt) return res.status(404).json({ error: 'Folgeaufgabe nicht gefunden.' });
    const oldDone = task.done;
    task.done = req.body.done === true; task.doneAt = task.done ? nowIso() : null;
    addHistory(report, req.user.username, 'follow-up', changeDetails(`followUp.${task.id}.done`, oldDone, task.done));
    return res.json(task);
  });

  app.post('/api/defects/:id/images', authMiddleware, requirePermission('defects.edit'), (req, res) => {
    const report = findDefect(req, res); if (!report) return;
    if (report.archivedAt || report.images.length >= MAX_IMAGES) return res.status(409).json({ error: `Maximal ${MAX_IMAGES} Bilder sind erlaubt.` });
    const mimeType = text(req.body.mimeType, 64).toLowerCase();
    const fileBase64 = String(req.body.fileBase64 || '').replace(/^data:[^;]+;base64,/, '');
    if (!IMAGE_MIME_TYPES.has(mimeType) || !fileBase64 || !/^[A-Za-z0-9+/]*={0,2}$/.test(fileBase64)) return res.status(400).json({ error: 'Nur gültige JPEG- oder PNG-Bilder sind erlaubt.' });
    const bytes = Buffer.from(fileBase64, 'base64');
    if (bytes.length > MAX_IMAGE_BYTES) return res.status(413).json({ error: 'Ein Bild darf höchstens 8 MB groß sein.' });
    const validSignature = mimeType === 'image/png'
      ? bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
      : bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
    if (!validSignature) return res.status(400).json({ error: 'Der Dateiinhalt ist kein gültiges JPEG- oder PNG-Bild.' });
    const image = { id: nextId('image', report.images), fileName: text(req.body.fileName || 'bild', 255), mimeType, sizeBytes: bytes.length, fileBase64, createdAt: nowIso(), createdBy: req.user.username };
    report.images.push(image); addHistory(report, req.user.username, 'image', changeDetails('image', null, { ...image, fileBase64: '[binary]' }));
    const { fileBase64: omitted, ...metadata } = image; return res.status(201).json(metadata);
  });

  app.delete('/api/defects/:id/images/:imageId', authMiddleware, requirePermission('defects.edit'), (req, res) => {
    const report = findDefect(req, res); if (!report) return;
    const index = report.images.findIndex((entry) => entry.id === req.params.imageId);
    if (index < 0 || report.archivedAt) return res.status(404).json({ error: 'Bild nicht gefunden.' });
    const [removed] = report.images.splice(index, 1); addHistory(report, req.user.username, 'image-delete', changeDetails('image', { ...removed, fileBase64: '[binary]' }, null));
    return res.json({ success: true });
  });

  app.post('/api/defects/:id/archive', authMiddleware, requirePermission('defects.archive'), (req, res) => {
    const report = findDefect(req, res); if (!report) return;
    if (report.status !== 'Geprüft/Geschlossen') return res.status(409).json({ error: 'Nur geschlossene Mängel können archiviert werden.' });
    report.archivedAt = nowIso(); report.archivedBy = req.user.username;
    if (report.emailSource) report.emailSource.deleteRequestedAt = nowIso();
    addHistory(report, req.user.username, 'archive', changeDetails('archivedAt', null, report.archivedAt));
    return res.json(publicDefect(report));
  });

  app.delete('/api/defects/:id', authMiddleware, requirePermission('defects.delete'), (req, res) => {
    const report = findDefect(req, res); if (!report) return;
    if (report.status !== 'Geprüft/Geschlossen') {
      return res.status(409).json({ error: 'Ein Mangel muss vor dem Löschen geschlossen werden.' });
    }
    if (!report.archivedAt) {
      report.archivedAt = nowIso(); report.archivedBy = req.user.username;
      if (report.emailSource) report.emailSource.deleteRequestedAt = nowIso();
      addHistory(report, req.user.username, 'soft-delete', changeDetails('archivedAt', null, report.archivedAt));
    }
    return res.json({ success: true, archived: true, deleteAfter: new Date(
      new Date(report.archivedAt).setUTCFullYear(new Date(report.archivedAt).getUTCFullYear() + 2)
    ).toISOString() });
  });

  app.get('/api/notifications', authMiddleware, (req, res) => {
    if (req.user.roles?.includes('Vorsitz') || req.user.roles?.includes('Admin')) {
      const today = nowIso().slice(0, 10);
      defectReports.filter((report) => !report.archivedAt && !CLOSED_STATUSES.has(report.status) &&
        (report.priority === 'Kritisch' || (report.dueDate && report.dueDate < today)))
        .forEach((report) => {
          const type = report.dueDate && report.dueDate < today ? 'overdue-defect' : 'critical-defect';
          if (!notifications.some((entry) => entry.userId === req.user.id && entry.defectId === report.id && entry.type === type)) {
            notifications.push({
              id: nextId('notification', notifications), userId: req.user.id, type,
              title: type === 'overdue-defect' ? `Mangel ${report.defectNumber} überfällig` : `Kritischer Mangel ${report.defectNumber}`,
              message: report.title, defectId: report.id, readAt: null, createdAt: nowIso(),
            });
          }
        });
    }
    res.json(notifications.filter((entry) => entry.userId === req.user.id).slice().reverse());
  });

  app.patch('/api/notifications/:id/read', authMiddleware, (req, res) => {
    const notification = notifications.find((entry) => entry.id === req.params.id && entry.userId === req.user.id);
    if (!notification) return res.status(404).json({ error: 'Benachrichtigung nicht gefunden.' });
    notification.readAt = nowIso(); return res.json(notification);
  });

  async function applyRetentionPolicy(referenceDate = new Date()) {
    const cutoffDate = new Date(referenceDate);
    cutoffDate.setUTCFullYear(cutoffDate.getUTCFullYear() - 2);
    const cutoff = cutoffDate.getTime();
    for (let index = defectReports.length - 1; index >= 0; index -= 1) {
      const archivedAt = Date.parse(defectReports[index].archivedAt || '');
      if (Number.isFinite(archivedAt) && archivedAt <= cutoff) defectReports.splice(index, 1);
    }
    const notificationCutoff = cutoff;
    for (let index = notifications.length - 1; index >= 0; index -= 1) {
      if (Date.parse(notifications[index].createdAt || '') <= notificationCutoff) notifications.splice(index, 1);
    }
  }

  return {
    statuses: DEFECT_STATUSES,
    canScope: (user, entityType) => scopeFor(user, entityType),
    hasOpenDefect: (entityType, entityId) => activeForEntity(entityType, entityId).length > 0,
    createFromEmail({
      body,
      source,
      reportDocuments = [],
      images = [],
      emailComment = '',
      actor = {
        id: 'system-email-eingang',
        username: 'E-Mail-Eingang',
        name: 'E-Mail-Eingang',
        email: '',
      },
    }) {
      const result = createReport(body, actor, {
        emailSource: source,
        reportedBy: 'system-email-eingang',
        reportedByName: body.contactName,
      });
      if (result.error) return result;
      const report = result.report;
      for (const document of reportDocuments) {
        const bytes = Buffer.from(document.fileBase64 || '', 'base64');
        if (!REPORT_MIME_TYPES.has(document.mimeType) || !bytes.length
          || bytes.length > MAX_REPORT_BYTES) {
          defectReports.splice(defectReports.indexOf(report), 1);
          restoreEntityIfResolved(report);
          return { error: 'Der angehängte Mängelbericht ist ungültig oder zu groß.' };
        }
        report.documents.push({
          id: nextId('document', report.documents),
          fileName: text(document.fileName || 'maengelbericht', 255),
          mimeType: document.mimeType,
          sizeBytes: bytes.length,
          fileBase64: bytes.toString('base64'),
          createdAt: nowIso(),
          createdBy: actor.username,
        });
      }
      for (const input of images.slice(0, MAX_IMAGES)) {
        const bytes = Buffer.from(input.fileBase64 || '', 'base64');
        if (!IMAGE_MIME_TYPES.has(input.mimeType) || !bytes.length
          || bytes.length > MAX_IMAGE_BYTES) continue;
        report.images.push({
          id: nextId('image', report.images),
          fileName: text(input.fileName || 'bild', 255),
          mimeType: input.mimeType,
          sizeBytes: bytes.length,
          fileBase64: bytes.toString('base64'),
          createdAt: nowIso(),
          createdBy: actor.username,
        });
      }
      const commentValue = text(emailComment, 5000);
      if (commentValue) {
        report.comments.push({
          id: nextId('comment', report.comments),
          text: commentValue,
          author: 'E-Mail-Eingang',
          authorId: 'system-email-eingang',
          createdAt: nowIso(),
        });
      }
      addHistory(report, actor.username, 'email-import', {
        reportDocuments: report.documents.length,
        images: report.images.length,
        messageId: source?.messageId || null,
      });
      return { report: publicDefect(report, true) };
    },
    createFromInspection({ entityType, entityId, inspectionId, notes, user }) {
      return createReport({
        entityType, entityId, affectedQuantity: 1,
        title: 'Mangel aus fehlgeschlagener Prüfung',
        description: text(notes, 10_000) || 'Bei der Prüfung wurde ein Mangel festgestellt.',
        priority: 'Hoch', damageType: 'Prüfmangel', riskLevel: 'Hoch',
        operationalSafety: 'Nicht einsatzfähig',
      }, user, { inspectionId });
    },
    createFromStocktake({
      entityType, entityId, affectedQuantity, title, description, stocktakeId, user,
    }) {
      const isShortage = title.startsWith('Fehlbestand');
      const result = createReport({
        entityType, entityId, affectedQuantity, title, description,
        priority: 'Hoch',
        damageType: isShortage ? 'Fehlbestand' : 'Inventurmangel',
        riskLevel: 'Nicht bewertet', operationalSafety: 'Nicht einsatzfähig',
      }, user, { preserveEntityStatus: isShortage });
      if (result.report) {
        result.report.linkedStocktakeId = stocktakeId;
        addHistory(result.report, user.username, 'stocktake-link', { stocktakeId });
      }
      return result;
    },
    applyRetentionPolicy,
  };
}

module.exports = { registerDefectManagement, DEFECT_STATUSES, DEFECT_PRIORITIES };
