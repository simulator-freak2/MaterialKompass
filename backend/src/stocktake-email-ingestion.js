const { simpleParser } = require('mailparser');

const MAX_MAIL_BYTES = 25 * 1024 * 1024;
const MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024;
const ALLOWED_TYPES = new Set([
  'application/pdf', 'image/jpeg', 'image/png',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'application/vnd.oasis.opendocument.spreadsheet',
]);

function text(value, max = 10_000) {
  return String(value ?? '').trim().slice(0, max);
}

function createStocktakeEmailService({
  stocktakeEmailImports, stocktakes, nextId, persistData = async () => {},
}) {
  function findStocktake(value) {
    const haystack = String(value || '').toLowerCase();
    const id = haystack.match(/stocktake-\d+/)?.[0];
    if (id) return stocktakes.find((entry) => entry.id.toLowerCase() === id);
    return stocktakes.find((entry) => haystack.includes(entry.name.toLowerCase()));
  }

  async function ingestSource(source, sourceInfo = {}) {
    const bytes = Buffer.isBuffer(source) ? source : Buffer.from(source || '');
    if (!bytes.length || bytes.length > MAX_MAIL_BYTES) throw new Error('Die Inventur-E-Mail ist leer oder größer als 25 MB.');
    const parsed = await simpleParser(bytes, { skipHtmlToText: false, skipTextToHtml: true });
    const searchText = [parsed.subject, parsed.text, parsed.html,
      ...parsed.attachments.map((attachment) => attachment.filename)].join('\n');
    const stocktake = findStocktake(searchText);
    const attachments = parsed.attachments.filter((attachment) => {
      const type = String(attachment.contentType || '').toLowerCase();
      return ALLOWED_TYPES.has(type) && attachment.content?.length > 0
        && attachment.content.length <= MAX_ATTACHMENT_BYTES;
    }).map((attachment, index) => ({
      id: `attachment-${index + 1}`,
      fileName: text(attachment.filename || `inventur-anlage-${index + 1}`, 255),
      mimeType: String(attachment.contentType || 'application/octet-stream'),
      sizeBytes: attachment.content.length,
      fileBase64: attachment.content.toString('base64'),
    }));
    const createdAt = new Date().toISOString();
    const entry = {
      id: nextId('stocktake-email', stocktakeEmailImports),
      stocktakeId: stocktake?.id || null,
      status: !stocktake ? 'unzugeordnet' : attachments.length ? 'offen' : 'fehlerhaft',
      sender: text(parsed.from?.value?.[0]?.address, 255).toLowerCase(),
      senderName: text(parsed.from?.value?.[0]?.name, 255),
      subject: text(parsed.subject || 'Inventur ohne Betreff', 255),
      messageText: text(parsed.text, 5000),
      attachments,
      problem: !stocktake
        ? 'Keine Inventur-ID oder eindeutige Bezeichnung gefunden.'
        : attachments.length ? null : 'Kein unterstützter Anhang gefunden.',
      createdAt, processedAt: null, processedBy: null,
      emailSource: { ...sourceInfo },
    };
    stocktakeEmailImports.push(entry);
    await persistData();
    return { entry };
  }

  async function recordFailure(sourceInfo, error) {
    const entry = {
      id: nextId('stocktake-email', stocktakeEmailImports), stocktakeId: null,
      status: 'fehlerhaft', sender: '', senderName: '', subject: 'Nicht lesbare Inventur-E-Mail',
      messageText: '', attachments: [], problem: text(error?.message || error, 1000),
      createdAt: new Date().toISOString(), processedAt: null, processedBy: null,
      emailSource: { ...sourceInfo },
    };
    stocktakeEmailImports.push(entry); await persistData(); return entry;
  }

  async function updateMoved(entry, moved) {
    entry.emailSource = { ...(entry.emailSource || {}), ...moved };
    await persistData();
  }

  return { ingestSource, recordFailure, updateMoved, stop: async () => {} };
}

function publicEntry(entry) {
  return {
    ...entry,
    attachments: entry.attachments.map(({ fileBase64, ...metadata }) => metadata),
  };
}

function registerStocktakeEmailRoutes({
  app, authMiddleware, requirePermission, stocktakeEmailImports, stocktakes,
  users, logEvent, deleteMessage,
}) {
  function visible(req, entry) {
    if (req.user.roles?.includes('Admin') || req.user.roles?.includes('Jugendvorsitzender') || req.user.roles?.includes('Jugendvorsitz')) return true;
    const stocktake = stocktakes.find((candidate) => candidate.id === entry.stocktakeId);
    if (!stocktake) return false;
    return (stocktake.entityTypes.includes('MaterialItem') && req.user.roles?.includes('Materialwart'))
      || (stocktake.entityTypes.includes('ClothingItem') && req.user.roles?.includes('Kleiderwart'));
  }

  function find(req, res) {
    const entry = stocktakeEmailImports.find((candidate) => candidate.id === req.params.id);
    if (!entry || !visible(req, entry)) { res.status(404).json({ error: 'E-Mail-Import nicht gefunden.' }); return null; }
    return entry;
  }

  app.get('/api/stocktake-email-imports', authMiddleware, requirePermission('stocktakes.read'), (req, res) => {
    const stocktakeId = text(req.query.stocktakeId, 64);
    res.json(stocktakeEmailImports.filter((entry) => visible(req, entry)
      && (!stocktakeId || entry.stocktakeId === stocktakeId)).slice().reverse().map(publicEntry));
  });

  app.get('/api/stocktake-email-imports/:id/attachments/:attachmentId', authMiddleware, requirePermission('stocktakes.read'), (req, res) => {
    const entry = find(req, res); if (!entry) return;
    const attachment = entry.attachments.find((candidate) => candidate.id === req.params.attachmentId);
    if (!attachment) return res.status(404).json({ error: 'Anhang nicht gefunden.' });
    res.json(attachment);
  });

  app.post('/api/stocktake-email-imports/:id/assign', authMiddleware, requirePermission('stocktakes.email.import'), (req, res) => {
    const entry = stocktakeEmailImports.find((candidate) => candidate.id === req.params.id);
    const stocktake = stocktakes.find((candidate) => candidate.id === req.body.stocktakeId);
    if (!entry || !stocktake) return res.status(404).json({ error: 'E-Mail oder Inventur nicht gefunden.' });
    entry.stocktakeId = stocktake.id; entry.status = entry.attachments.length ? 'offen' : 'fehlerhaft'; entry.problem = entry.attachments.length ? null : entry.problem;
    logEvent('assign', 'Stocktake', { id: stocktake.id, emailImportId: entry.id }, req.user.username);
    res.json(publicEntry(entry));
  });

  app.post('/api/stocktake-email-imports/:id/processed', authMiddleware, requirePermission('stocktakes.count'), (req, res) => {
    const entry = find(req, res); if (!entry) return;
    entry.status = 'verarbeitet'; entry.processedAt = new Date().toISOString(); entry.processedBy = req.user.username;
    logEvent('email-import', 'Stocktake', { id: entry.stocktakeId, emailImportId: entry.id }, req.user.username);
    res.json(publicEntry(entry));
  });

  app.post('/api/stocktake-email-imports/:id/discard', authMiddleware, requirePermission('stocktakes.count'), async (req, res) => {
    const entry = find(req, res); if (!entry) return;
    if (entry.status === 'verarbeitet') {
      return res.status(409).json({ error: 'Diese E-Mail wurde bereits verarbeitet.' });
    }
    const reason = text(req.body.reason || 'Manuell verworfen', 1000);
    try {
      await deleteMessage(entry.emailSource);
    } catch (error) {
      console.error(`Inventur-E-Mail ${entry.id} konnte nicht gelöscht werden:`, error.message);
      return res.status(502).json({
        error: 'Die E-Mail konnte im Inventur-Postfach nicht endgültig gelöscht werden. Sie bleibt erhalten.',
      });
    }
    stocktakeEmailImports.splice(stocktakeEmailImports.indexOf(entry), 1);
    logEvent('discard', 'StocktakeEmailImport', { id: entry.id, reason }, req.user.username);
    return res.json({ success: true, id: entry.id });
  });
}

module.exports = { createStocktakeEmailService, registerStocktakeEmailRoutes };
