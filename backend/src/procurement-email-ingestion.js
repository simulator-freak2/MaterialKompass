const { simpleParser } = require('mailparser');

const MAX_MAIL_BYTES = 25 * 1024 * 1024;
const MAX_ATTACHMENT_BYTES = 5 * 1024 * 1024;
const ALLOWED_EXTENSIONS = new Set(['pdf', 'png', 'jpg', 'jpeg', 'docx', 'xlsx', 'ods']);

function text(value, max = 10_000) {
  return String(value ?? '').trim().slice(0, max);
}

function publicEntry(entry, includeSource = false) {
  const result = {
    ...entry,
    attachments: entry.attachments.map(({ fileBase64, ...metadata }) => metadata),
  };
  if (!includeSource) delete result.emailSource;
  return result;
}

function createProcurementEmailService({
  procurementEmailImports, procurementRequests, suppliers, nextId,
  persistData = async () => {},
}) {
  function findRequest(value) {
    const haystack = String(value || '').toLowerCase();
    return procurementRequests.find((request) => haystack.includes(String(request.number || '').toLowerCase()));
  }

  function findSupplier(address) {
    const normalized = String(address || '').trim().toLowerCase();
    return suppliers.find((supplier) => String(supplier.email || '').trim().toLowerCase() === normalized);
  }

  async function ingestSource(source, sourceInfo = {}) {
    const bytes = Buffer.isBuffer(source) ? source : Buffer.from(source || '');
    if (!bytes.length || bytes.length > MAX_MAIL_BYTES) {
      throw new Error('Die Angebots-E-Mail ist leer oder größer als 25 MB.');
    }
    const parsed = await simpleParser(bytes, { skipHtmlToText: false, skipTextToHtml: true });
    const sender = text(parsed.from?.value?.[0]?.address, 255).toLowerCase();
    const searchText = [parsed.subject, parsed.text, parsed.html,
      ...parsed.attachments.map((attachment) => attachment.filename)].join('\n');
    const request = findRequest(searchText);
    const supplier = findSupplier(sender);
    const attachments = parsed.attachments.filter((attachment) => {
      const extension = text(attachment.filename, 255).split('.').pop().toLowerCase();
      return ALLOWED_EXTENSIONS.has(extension) && attachment.content?.length > 0
        && attachment.content.length <= MAX_ATTACHMENT_BYTES;
    }).map((attachment, index) => ({
      id: `attachment-${index + 1}`,
      fileName: text(attachment.filename || `angebot-${index + 1}`, 255),
      mimeType: text(attachment.contentType || 'application/octet-stream', 255),
      sizeBytes: attachment.content.length,
      fileBase64: attachment.content.toString('base64'),
    }));
    const entry = {
      id: nextId('procurement-email', procurementEmailImports),
      requestId: request?.id || null,
      supplierId: supplier?.id || null,
      status: attachments.length ? 'offen' : 'fehlerhaft',
      sender,
      senderName: text(parsed.from?.value?.[0]?.name, 255),
      subject: text(parsed.subject || 'Angebot ohne Betreff', 255),
      messageText: text(parsed.text, 10_000),
      attachments,
      problem: attachments.length ? null : 'Kein unterstützter Anhang bis 5 MB gefunden.',
      createdAt: new Date().toISOString(),
      processedAt: null,
      processedBy: null,
      offerId: null,
      emailSource: { ...sourceInfo },
    };
    procurementEmailImports.push(entry);
    await persistData();
    return { entry };
  }

  async function recordFailure(sourceInfo, error) {
    const entry = {
      id: nextId('procurement-email', procurementEmailImports), requestId: null,
      supplierId: null, status: 'fehlerhaft', sender: '', senderName: '',
      subject: 'Nicht lesbare Angebots-E-Mail', messageText: '', attachments: [],
      problem: text(error?.message || error, 1000), createdAt: new Date().toISOString(),
      processedAt: null, processedBy: null, offerId: null, emailSource: { ...sourceInfo },
    };
    procurementEmailImports.push(entry);
    await persistData();
    return entry;
  }

  async function updateMoved(entry, moved) {
    entry.emailSource = { ...(entry.emailSource || {}), ...moved };
    await persistData();
  }

  return { ingestSource, recordFailure, updateMoved, stop: async () => {} };
}

function registerProcurementEmailRoutes({
  app, authMiddleware, requirePermission, procurementEmailImports,
  procurementRequests, procurementOffers, procurementDocuments, suppliers,
  nextId, logEvent,
}) {
  const address = process.env.PROCUREMENT_EMAIL_ADDRESS
    || process.env.PROCUREMENT_IMAP_USER
    || `angebote@${process.env.SCANNER_EMAIL_DOMAIN || 'materialkompass.org'}`;
  const roles = (user) => new Set(user?.roles || []);
  const canSee = (req, entry) => {
    const elevated = ['Admin', 'Vorsitz', 'Schatzmeister', 'Materialwart', 'Kleiderwart'];
    if (elevated.some((role) => roles(req.user).has(role))) return true;
    const request = procurementRequests.find((candidate) => candidate.id === entry.requestId);
    return !!request && (request.requestedByEmail === req.user.email
      || (request.departmentId && (req.user.departmentIds || []).includes(request.departmentId)));
  };
  const find = (req, res) => {
    const entry = procurementEmailImports.find((candidate) => candidate.id === req.params.id);
    if (!entry || !canSee(req, entry)) {
      res.status(404).json({ error: 'Angebots-E-Mail nicht gefunden.' }); return null;
    }
    return entry;
  };
  const money = (value) => {
    const normalized = typeof value === 'string' && value.includes(',')
      ? value.replace(/\./g, '').replace(',', '.') : value;
    return Math.round((Number(normalized) || 0) * 100) / 100;
  };

  app.get('/api/procurement-email-inbox', authMiddleware, requirePermission('procurement.read'), (req, res) => {
    res.json({ address, entries: procurementEmailImports.filter((entry) => canSee(req, entry))
      .slice().reverse().map((entry) => publicEntry(entry)) });
  });

  app.get('/api/procurement-email-inbox/:id/attachments/:attachmentId', authMiddleware, requirePermission('procurement.read'), (req, res) => {
    const entry = find(req, res); if (!entry) return;
    const attachment = entry.attachments.find((candidate) => candidate.id === req.params.attachmentId);
    if (!attachment) return res.status(404).json({ error: 'Anhang nicht gefunden.' });
    return res.json(attachment);
  });

  app.post('/api/procurement-email-inbox/:id/process', authMiddleware, requirePermission('procurement.request'), (req, res) => {
    const entry = find(req, res); if (!entry) return;
    if (entry.status === 'verarbeitet' || entry.status === 'verworfen') {
      return res.status(409).json({ error: 'Diese E-Mail wurde bereits abgeschlossen.' });
    }
    const request = procurementRequests.find((candidate) => candidate.id === req.body.requestId);
    if (!request) return res.status(400).json({ error: 'Ein Beschaffungsvorgang ist erforderlich.' });
    if (!['Beantragt', 'Genehmigt'].includes(request.status)) {
      return res.status(409).json({ error: 'In diesem Vorgangsstatus können keine Angebote erfasst werden.' });
    }
    const supplier = suppliers.find((candidate) => candidate.id === req.body.supplierId && candidate.active !== false);
    if (!supplier) return res.status(400).json({ error: 'Ein aktiver Lieferant ist erforderlich.' });
    const grossTotal = money(req.body.grossTotal);
    if (grossTotal <= 0) return res.status(400).json({ error: 'Die Angebotssumme muss größer als null sein.' });
    const offer = {
      id: nextId('offer', procurementOffers), requestId: request.id, supplierId: supplier.id,
      offerNumber: text(req.body.offerNumber, 255), offerDate: req.body.offerDate || null,
      validUntil: req.body.validUntil || null, deliveryDays: Number(req.body.deliveryDays) || null,
      grossTotal, shippingGross: money(req.body.shippingGross),
      notes: text(req.body.notes || entry.messageText, 5000), createdAt: new Date().toISOString(),
      sourceEmailImportId: entry.id,
    };
    procurementOffers.push(offer);
    const selectedAttachmentIds = new Set((req.body.attachmentIds || []).map(String));
    const selectedAttachments = entry.attachments.filter((attachment) =>
      selectedAttachmentIds.size === 0 || selectedAttachmentIds.has(attachment.id));
    for (const attachment of selectedAttachments) {
      procurementDocuments.push({
        id: nextId('proc-document', procurementDocuments), requestId: request.id,
        entityType: 'Angebot', entityId: offer.id, documentType: 'Angebot',
        fileName: attachment.fileName, mimeType: attachment.mimeType,
        fileBase64: attachment.fileBase64, createdBy: req.user.username,
        createdAt: new Date().toISOString(), sourceEmailImportId: entry.id,
      });
    }
    entry.requestId = request.id; entry.supplierId = supplier.id; entry.offerId = offer.id;
    entry.status = 'verarbeitet'; entry.problem = null; entry.processedAt = new Date().toISOString();
    entry.processedBy = req.user.username;
    request.history.push({
      id: `history-${request.history.length + 1}`, action: 'Angebot aus E-Mail übernommen',
      actor: req.user.username, details: { offerId: offer.id, emailImportId: entry.id },
      createdAt: new Date().toISOString(),
    });
    request.updatedAt = new Date().toISOString();
    logEvent('Angebot aus E-Mail übernommen', 'ProcurementRequest', {
      id: request.id, offerId: offer.id, emailImportId: entry.id,
    }, req.user.username);
    return res.json({ entry: publicEntry(entry), offer });
  });

  app.post('/api/procurement-email-inbox/:id/discard', authMiddleware, requirePermission('procurement.request'), (req, res) => {
    const entry = find(req, res); if (!entry) return;
    if (entry.status === 'verarbeitet') return res.status(409).json({ error: 'Das Angebot wurde bereits übernommen.' });
    entry.status = 'verworfen'; entry.problem = text(req.body.reason || 'Manuell verworfen', 1000);
    entry.processedAt = new Date().toISOString(); entry.processedBy = req.user.username;
    logEvent('discard', 'ProcurementEmailImport', { id: entry.id, reason: entry.problem }, req.user.username);
    return res.json(publicEntry(entry));
  });
}

module.exports = {
  createProcurementEmailService,
  registerProcurementEmailRoutes,
};
