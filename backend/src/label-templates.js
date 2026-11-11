const { randomUUID, createHash } = require('node:crypto');
const { descendantsOf } = require('./tenancy');
const { validBase64 } = require('./security-utils');

const FORMATS = Object.freeze({ Zebra: ['nlbl', 'lbl'], DYMO: ['dymo', 'label'], Epson: ['leb'], Brother: ['lbx', 'lbl'] });
const FIELDS = Object.freeze({ serialNumber: 'Seriennummer', inventoryNumber: 'Inventarnummer', name: 'Bezeichnung', manufacturingYear: 'Baujahr', size: 'Größe' });
const MAX_BYTES = 5 * 1024 * 1024;
const MAX_TEMPLATES = 100;
const MAX_STORAGE_BYTES = 32 * 1024 * 1024;

// A trusted, administrator-configured service opens proprietary files using
// licensed manufacturer software. Never infer a printable layout from a suffix.
function createLabelRenderer({ url = process.env.LABEL_RENDERER_URL, token = process.env.LABEL_RENDERER_TOKEN, fetchImpl = fetch } = {}) {
  if (!url) return null;
  const base = new URL(url);
  if (!['https:', 'http:'].includes(base.protocol) || base.username || base.password || base.search || base.hash) throw new Error('LABEL_RENDERER_URL ist ungültig.');
  return async (operation, payload) => {
    const response = await fetchImpl(`${base.href.replace(/\/$/, '')}/${operation}`, {
      method: 'POST', redirect: 'error', signal: AbortSignal.timeout(45000),
      headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: JSON.stringify(payload),
    });
    if (!response.ok) throw new Error('Der Herstellerdienst konnte diese Vorlage nicht verarbeiten.');
    // Bound streamed responses, even if the peer omits Content-Length.
    const chunks = []; let size = 0;
    for await (const chunk of response.body) {
      size += chunk.length;
      if (size > 16 * 1024 * 1024) { await response.body.cancel?.().catch(() => {}); throw new Error('Antwort des Herstellerdiensts ist zu groß.'); }
      chunks.push(chunk);
    }
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  };
}

function registerLabelTemplateRoutes({ app, templates, categories, units, memberships, users, materials, clothingItems, authMiddleware, logEvent, renderer = createLabelRenderer() }) {
  const rolesFor = (req, type) => req.tenant.organizationAdmin || req.user.roles.includes(type === 'inventory' ? 'Materialwart' : 'Kleiderwart');
  const manage = (req, t) => t.organizationId === req.tenant.organizationId && t.unitId === req.tenant.unitId && rolesFor(req, t.type);
  const subtree = (req, unitId) => descendantsOf(units, req.tenant.organizationId, unitId);
  const visible = (req, t) => t.organizationId === req.tenant.organizationId && (manage(req, t)
    || t.scope === 'organization'
    || t.scope === 'descendants' && subtree(req, t.unitId).has(req.tenant.unitId)
    || t.scope === 'users' && t.userIds.includes(req.user.id) && subtree(req, t.unitId).has(req.tenant.unitId));
  const categoryIsClothing = (c) => c.useInWardrobe === true || categories.find(x => x.id === c.parentId)?.useInWardrobe === true;
  const categoryAllowed = (req, c, type, scope, ownerUnitId) => c && categoryIsClothing(c) === (type === 'clothing')
    && (c.scope !== 'unit' || c.unitId === ownerUnitId && !['organization', 'descendants'].includes(scope));
  const summary = (req, t) => {
    const { fileBase64, ...metadata } = t;
    return { ...metadata, canManage: manage(req, t), rendererAvailable: Boolean(renderer) };
  };
  const find = (req) => templates.find(t => t.id === req.params.id && visible(req, t));
  const guard = (req, res, next) => {
    if (req.device || !req.tenant || !req.user) return res.status(403).json({ error: 'Ein persönlicher Organisationszugang ist erforderlich.' });
    next();
  };

  app.get('/api/label-templates', authMiddleware, guard, (req, res) => {
    res.json(templates.filter(t => visible(req, t)).map(t => summary(req, t)));
  });
  app.get('/api/label-templates/options', authMiddleware, guard, (req, res) => {
    const descendantIds = subtree(req, req.tenant.unitId);
    const eligibleIds = new Set(memberships.filter(m => m.organizationId === req.tenant.organizationId && m.status === 'active'
      && m.scopes.some(s => descendantIds.has(s.unitId))).map(m => m.userId));
    res.json({ formats: FORMATS, fields: FIELDS, maxFileBytes: MAX_BYTES, rendererAvailable: Boolean(renderer),
      manageableTypes: ['inventory', 'clothing'].filter(t => rolesFor(req, t)),
      organizationSharingAllowed: req.tenant.organizationAdmin || units.find(u => u.id === req.tenant.unitId)?.parentId === null,
      categories: categories.map(c => ({ id: c.id, name: c.name, type: categoryIsClothing(c) ? 'clothing' : 'inventory', scope: c.scope, unitId: c.unitId })),
      users: ['inventory', 'clothing'].some(t => rolesFor(req, t))
        ? users.filter(u => eligibleIds.has(u.id)).map(u => ({ id: u.id, name: u.name || u.username || u.id })) : [],
    });
  });

  function input(req, previous) {
    const b = req.body;
    if (!['inventory', 'clothing'].includes(b.type) || !rolesFor(req, b.type)) return { status: 403, error: 'Keine Berechtigung für diesen Vorlagenbereich.' };
    const name = typeof b.name === 'string' ? b.name.trim() : '';
    if (!name || name.length > 100) return { error: 'Bitte einen Vorlagennamen mit höchstens 100 Zeichen angeben.' };
    const scope = b.scope;
    if (!['private', 'organization', 'descendants', 'users'].includes(scope)) return { error: 'Ungültige Freigabe.' };
    if (scope === 'organization' && !req.tenant.organizationAdmin && units.find(u => u.id === req.tenant.unitId)?.parentId !== null) return { status: 403, error: 'Die gesamte Organisation kann nur von der Organisationsebene freigegeben werden.' };
    const categoryIds = Array.isArray(b.categoryIds) ? [...new Set(b.categoryIds)] : [];
    if (!categoryIds.length || categoryIds.length > 100 || categoryIds.some(id => typeof id !== 'string' || !categoryAllowed(req, categories.find(c => c.id === id), b.type, scope, req.tenant.unitId))) return { error: 'Bitte gültige Kategorien dieses Bereichs wählen. Einheitskategorien können nicht organisationsweit oder an Untereinheiten freigegeben werden.' };
    const userIds = scope === 'users' && Array.isArray(b.userIds) ? [...new Set(b.userIds)] : [];
    const descendantIds = subtree(req, req.tenant.unitId);
    if (userIds.length > 500 || scope === 'users' && !userIds.length || userIds.some(id => !memberships.some(m => m.userId === id && m.organizationId === req.tenant.organizationId && m.status === 'active' && m.scopes.some(s => descendantIds.has(s.unitId))))) return { error: 'Bitte zugeordnete Nutzer der eigenen oder unterliegenden Einheiten auswählen.' };
    if (!Array.isArray(b.variables) || b.variables.length > 50) return { error: 'Ungültige Variablenzuordnung.' };
    const variables = []; const names = new Set();
    for (const v of b.variables) {
      if (!v || typeof v.name !== 'string' || !/^[\p{L}\p{N}_. -]{1,80}$/u.test(v.name) || !Object.hasOwn(FIELDS, v.field) || names.has(v.name)) return { error: 'Variablennamen müssen eindeutig sein und einem unterstützten Datenfeld entsprechen.' };
      names.add(v.name); variables.push({ name: v.name, field: v.field });
    }
    const fileName = b.fileName ?? previous?.fileName;
    const fileBase64 = b.fileBase64 ?? previous?.fileBase64;
    const manufacturer = b.manufacturer;
    if (typeof fileName !== 'string' || fileName.length > 150 || /[\\/\x00-\x1f]/.test(fileName)) return { error: 'Ungültiger Dateiname.' };
    const extension = fileName.split('.').pop().toLowerCase();
    if (!FORMATS[manufacturer]?.includes(extension)) return { error: 'Dateiformat und Hersteller passen nicht zusammen.' };
    if (typeof fileBase64 !== 'string' || fileBase64.length > Math.ceil(MAX_BYTES / 3) * 4 || !validBase64(fileBase64)) return { error: 'Ungültige oder zu große Datei (maximal 5 MB).' };
    const bytes = Buffer.from(fileBase64, 'base64');
    if (!bytes.length || bytes.length > MAX_BYTES) return { error: 'Die Datei ist leer oder größer als 5 MB.' };
    const storedBytes = templates.reduce((sum, t) => sum + (t.id === previous?.id ? 0 : t.fileBytes || 0), 0);
    if (storedBytes + bytes.length > MAX_STORAGE_BYTES) return { error: 'Der Vorlagenspeicher dieser Organisation ist voll (32 MB). Bitte nicht benötigte Vorlagen entfernen.' };
    return { value: { name, type: b.type, scope, categoryIds, userIds, variables, fileName, fileBase64, manufacturer, fileBytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex') } };
  }

  app.get('/api/label-templates/:id', authMiddleware, guard, (req, res) => {
    const t = find(req);
    if (!t) return res.status(404).json({ error: 'Vorlage nicht gefunden.' });
    return res.json(summary(req, t));
  });
  app.post('/api/label-templates', authMiddleware, guard, (req, res) => {
    const result = input(req);
    if (result.error) return res.status(result.status || 400).json({ error: result.error });
    if (templates.length >= MAX_TEMPLATES) return res.status(409).json({ error: 'Maximal 100 Vorlagen je Organisation.' });
    const t = { ...result.value, id: randomUUID(), organizationId: req.tenant.organizationId, unitId: req.tenant.unitId, createdBy: req.user.id, createdAt: new Date().toISOString(), updatedAt: new Date().toISOString() };
    templates.push(t); logEvent('create', 'LabelTemplate', { id: t.id, name: t.name }, req.user.username);
    return res.status(201).json(summary(req, t));
  });
  app.put('/api/label-templates/:id', authMiddleware, guard, (req, res) => {
    const t = find(req);
    if (!t) return res.status(404).json({ error: 'Vorlage nicht gefunden.' });
    if (!manage(req, t)) return res.status(403).json({ error: 'Nur im berechtigten Vorlagenbereich der herausgebenden Einheit bearbeitbar.' });
    if (req.body.updatedAt !== t.updatedAt) return res.status(409).json({ error: 'Die Vorlage wurde inzwischen geändert. Bitte neu laden.' });
    const result = input(req, t);
    if (result.error) return res.status(result.status || 400).json({ error: result.error });
    Object.assign(t, result.value, { updatedAt: new Date().toISOString() });
    logEvent('update', 'LabelTemplate', { id: t.id, name: t.name }, req.user.username);
    return res.json(summary(req, t));
  });
  app.delete('/api/label-templates/:id', authMiddleware, guard, (req, res) => {
    const t = find(req);
    if (!t) return res.status(404).json({ error: 'Vorlage nicht gefunden.' });
    if (!manage(req, t)) return res.status(403).json({ error: 'Keine Berechtigung zum Löschen.' });
    templates.splice(templates.indexOf(t), 1);
    logEvent('delete', 'LabelTemplate', { id: t.id, name: t.name }, req.user.username);
    return res.json({ deleted: true });
  });
  app.get('/api/label-templates/:id/file', authMiddleware, guard, (req, res) => {
    const t = find(req);
    if (!t) return res.status(404).json({ error: 'Vorlage nicht gefunden.' });
    res.set('Cache-Control', 'no-store');
    return res.json({ fileName: t.fileName, fileBase64: t.fileBase64, mimeType: 'application/octet-stream' });
  });

  app.post('/api/label-templates/:id/render', authMiddleware, guard, async (req, res) => {
    const t = find(req);
    if (!t) return res.status(404).json({ error: 'Vorlage nicht gefunden.' });
    const requiredPermission = t.type === 'inventory' ? 'inventory.read' : 'clothing.read';
    if (!req.user.permissions.includes(requiredPermission)) return res.status(403).json({ error: 'Keine Leseberechtigung für diesen Datenbereich.' });
    const lines = req.body.lines;
    if (!Array.isArray(lines) || !lines.length || lines.length > 100) return res.status(400).json({ error: 'Bitte 1 bis 100 Datensätze auswählen.' });
    const records = []; const missing = []; let total = 0;
    for (const line of lines) {
      if (!line || typeof line.itemId !== 'string' || !Number.isInteger(line.copies) || line.copies < 1 || line.copies > 1000 || (total += line.copies) > 1000) return res.status(400).json({ error: 'Ungültige Anzahl; maximal 1000 Etiketten je Auftrag.' });
      const item = (t.type === 'inventory' ? materials : clothingItems).find(i => i.id === line.itemId);
      if (!item) return res.status(404).json({ error: 'Datensatz nicht gefunden oder nicht zugänglich.' });
      const categoryId = item.categoryId || item.subcategoryCode || item.categoryCode;
      const category = categories.find(c => c.id === categoryId);
      if (!t.categoryIds.includes(categoryId) && !t.categoryIds.includes(category?.parentId)) return res.status(400).json({ error: 'Die Vorlage ist für mindestens eine gewählte Kategorie nicht freigegeben.' });
      const values = Object.create(null);
      for (const v of t.variables) {
        values[v.name] = String(item[v.field] ?? '').trim();
        if (!values[v.name]) missing.push({ itemId: item.id, itemName: item.name, field: v.field, label: FIELDS[v.field] });
      }
      records.push({ copies: line.copies, values });
    }
    if (req.body.checkOnly === true) return res.json({ missing, rendererAvailable: Boolean(renderer), total });
    if (missing.length && req.body.allowMissing !== true) return res.status(422).json({ error: 'Etikettendaten fehlen. Bitte ergänzen oder den Druck mit leeren Feldern ausdrücklich bestätigen.', missing });
    if (!renderer) return res.status(503).json({ error: 'Der Herstellerdienst für Originalvorlagen ist noch nicht eingerichtet. Die Vorlage ist gespeichert; ein Originaldruck ist derzeit nicht möglich.' });
    try {
      const result = await renderer('render', { manufacturer: t.manufacturer, fileName: t.fileName, fileBase64: t.fileBase64, sha256: t.sha256, records, output: 'pdf', useTemplatePageSize: true });
      if (typeof result.fileBase64 !== 'string' || result.fileBase64.length > 15 * 1024 * 1024) throw new Error('Ungültige Druckdaten vom Herstellerdienst.');
      const bytes = Buffer.from(result.fileBase64, 'base64');
      if (bytes.subarray(0, 5).toString() !== '%PDF-') throw new Error('Der Herstellerdienst hat kein PDF geliefert.');
      res.set('Cache-Control', 'no-store');
      return res.json({ fileName: 'etiketten.pdf', mimeType: 'application/pdf', fileBase64: bytes.toString('base64') });
    } catch (_) {
      return res.status(502).json({ error: 'Der Herstellerdienst konnte die Vorlage nicht drucken. Bitte Format, Variablennamen und Dienstkonfiguration prüfen.' });
    }
  });
}

module.exports = { registerLabelTemplateRoutes, createLabelRenderer, FORMATS, FIELDS };
