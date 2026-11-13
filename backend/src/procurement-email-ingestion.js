const { simpleParser } = require('mailparser');
const { normalizeOfferInput } = require('./procurement-offers');

const MAX_MAIL_BYTES = 25 * 1024 * 1024;
// Der Postfacheingang ist von außen beschreibbar. Ohne Obergrenzen könnte
// ein Absender Arbeitsspeicher und Datenbank beliebig füllen.
const MAX_EMAIL_IMPORT_RECORDS = 10_000;
const MAX_IMPORT_STORAGE_BYTES = 256 * 1024 * 1024;
const MAX_ATTACHMENT_BYTES = 5 * 1024 * 1024;
const ALLOWED_EXTENSIONS = new Set(['pdf', 'png', 'jpg', 'jpeg', 'docx', 'xlsx', 'ods']);
const DOCUMENT_TYPES = new Set([
  'Angebot', 'Genehmigung', 'Bestellung', 'Auftragsbestätigung', 'Lieferschein',
  'Rechnung', 'Sonstiges',
]);
// Dokumente aus der Postbox dürfen jedem laufenden Vorgang zugewiesen werden.
// Abgeschlossene Vorgänge nehmen nur noch nachträglich eingehende Rechnungen an.
const ASSIGNABLE_STATUSES = new Set([
  'Beantragt', 'Genehmigt', 'Bestellt', 'Teilweise geliefert', 'Geliefert',
]);
const INVOICE_ONLY_STATUSES = new Set(['Abgeschlossen']);
const MAX_DOCUMENTS_PER_REQUEST = 20;
const MAX_DOCUMENTS_TOTAL = 5_000;
const MAX_DOCUMENT_STORAGE_BYTES = 256 * 1024 * 1024;
const DELETED_STATUS = 'gelöscht';
const CLOSED_STATUSES = new Set(['verarbeitet', 'verworfen', DELETED_STATUS]);

function storedAttachmentBytes(entries) {
  return entries.reduce((sum, entry) => sum + (entry.attachments || [])
    .reduce((inner, attachment) => inner
      + Buffer.byteLength(attachment.fileBase64 || '', 'base64'), 0), 0);
}

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

function isPendingProcurementEmail(entry) {
  return !CLOSED_STATUSES.has(entry?.status);
}

function hasMailboxReference(entry) {
  const source = entry?.emailSource || {};
  return Boolean(source.uid || source.messageId);
}

// Entfernt eine abgeschlossene E-Mail aus MaterialKompass. Liegt die Nachricht
// noch im IMAP-Postfach, bleibt bis zur dortigen Löschung nur ein inhaltsloser
// Platzhalter mit der Postfach-Referenz bestehen; der Monitor entfernt ihn.
function releaseProcurementEmail(entries, entry, { mailDeletionEnabled = false } = {}) {
  if (mailDeletionEnabled && hasMailboxReference(entry)) {
    for (const key of Object.keys(entry)) {
      if (!['id', 'emailSource', 'createdAt'].includes(key)) delete entry[key];
    }
    entry.status = DELETED_STATUS;
    entry.attachments = [];
    entry.emailSource = { ...entry.emailSource, deleteRequestedAt: new Date().toISOString() };
    return;
  }
  const index = entries.indexOf(entry);
  if (index >= 0) entries.splice(index, 1);
}

function canAccessProcurementEmail(user, entry, procurementRequests) {
  const userRoles = new Set(user?.roles || []);
  const elevated = ['Admin', 'Vorsitz', 'Schatzmeister', 'Materialwart', 'Kleiderwart'];
  if (elevated.some((role) => userRoles.has(role))) return true;
  const request = procurementRequests.find((candidate) => candidate.id === entry.requestId);
  return !!request && (request.requestedByEmail === user?.email
    || (request.departmentId && (user?.departmentIds || []).includes(request.departmentId)));
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
    if (procurementEmailImports.length >= MAX_EMAIL_IMPORT_RECORDS) {
      throw new Error('Die maximale Anzahl gespeicherter Angebots-E-Mails ist erreicht.');
    }
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
    const incomingBytes = attachments.reduce((sum, attachment) => sum + attachment.sizeBytes, 0);
    if (storedAttachmentBytes(procurementEmailImports) + incomingBytes > MAX_IMPORT_STORAGE_BYTES) {
      throw new Error('Das Speicherlimit für E-Mail-Anhänge ist erreicht.');
    }
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
    if (procurementEmailImports.length >= MAX_EMAIL_IMPORT_RECORDS) return entry;
    procurementEmailImports.push(entry);
    await persistData();
    return entry;
  }

  async function updateMoved(entry, moved) {
    entry.emailSource = { ...(entry.emailSource || {}), ...moved };
    await persistData();
  }

  function pendingMailDeletions() {
    return procurementEmailImports.filter((entry) => entry.status === DELETED_STATUS
      && entry.emailSource?.deleteRequestedAt);
  }

  async function completeMailDeletion(entry) {
    const index = procurementEmailImports.indexOf(entry);
    if (index >= 0) procurementEmailImports.splice(index, 1);
    await persistData();
  }

  return {
    ingestSource, recordFailure, updateMoved, pendingMailDeletions, completeMailDeletion,
    stop: async () => {},
  };
}

function registerProcurementEmailRoutes({
  app, authMiddleware, requirePermission, procurementEmailImports,
  procurementRequests, procurementOffers, procurementDocuments, suppliers,
  nextId, logEvent, mailDeletionEnabled = Boolean(process.env.PROCUREMENT_IMAP_HOST),
}) {
  const address = process.env.PROCUREMENT_EMAIL_ADDRESS
    || process.env.PROCUREMENT_IMAP_USER
    || `angebote@${process.env.SCANNER_EMAIL_DOMAIN || 'materialkompass.org'}`;
  const canSee = (req, entry) => entry.status !== DELETED_STATUS
    && canAccessProcurementEmail(req.user, entry, procurementRequests);
  const release = (entry) => releaseProcurementEmail(procurementEmailImports, entry, {
    mailDeletionEnabled,
  });
  const emailHistoryDetails = (entry) => ({
    emailImportId: entry.id, sender: entry.sender, senderName: entry.senderName,
    subject: entry.subject, messageText: entry.messageText,
  });
  const find = (req, res) => {
    const entry = procurementEmailImports.find((candidate) => candidate.id === req.params.id);
    if (!entry || !canSee(req, entry)) {
      res.status(404).json({ error: 'Angebots-E-Mail nicht gefunden.' }); return null;
    }
    return entry;
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
    const normalized = normalizeOfferInput(req.body, request);
    if (normalized.error) return res.status(400).json({ error: normalized.error });
    const timestamp = new Date().toISOString();
    const offer = {
      id: nextId('offer', procurementOffers), requestId: request.id, supplierId: supplier.id,
      ...normalized.value,
      notes: text(req.body.notes || entry.messageText, 5000),
      createdAt: timestamp, updatedAt: timestamp,
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
      actor: req.user.username, details: { offerId: offer.id, ...emailHistoryDetails(entry) },
      createdAt: new Date().toISOString(),
    });
    request.updatedAt = new Date().toISOString();
    logEvent('Angebot aus E-Mail übernommen', 'ProcurementRequest', {
      id: request.id, offerId: offer.id, emailImportId: entry.id,
    }, req.user.username);
    const result = publicEntry(entry);
    release(entry);
    return res.json({ entry: result, offer });
  });

  app.post('/api/procurement-email-inbox/:id/discard', authMiddleware, requirePermission('procurement.request'), (req, res) => {
    const entry = find(req, res); if (!entry) return;
    if (entry.status === 'verarbeitet') return res.status(409).json({ error: 'Das Angebot wurde bereits übernommen.' });
    entry.status = 'verworfen'; entry.problem = text(req.body.reason || 'Manuell verworfen', 1000);
    entry.processedAt = new Date().toISOString(); entry.processedBy = req.user.username;
    logEvent('discard', 'ProcurementEmailImport', {
      id: entry.id, reason: entry.problem, sender: entry.sender, subject: entry.subject,
    }, req.user.username);
    const result = publicEntry(entry);
    release(entry);
    return res.json(result);
  });

  app.post('/api/procurement-email-inbox/:id/assign', authMiddleware, requirePermission('procurement.request'), (req, res) => {
    const entry = find(req, res); if (!entry) return;
    if (!isPendingProcurementEmail(entry)) {
      return res.status(409).json({ error: 'Diese E-Mail wurde bereits abgeschlossen.' });
    }
    const input = Array.isArray(req.body.assignments) ? req.body.assignments : [];
    if (!input.length) return res.status(400).json({ error: 'Mindestens ein Beschaffungsvorgang ist erforderlich.' });
    if (input.length > 50) return res.status(400).json({ error: 'Es können höchstens 50 Vorgänge gleichzeitig zugewiesen werden.' });
    const attachmentsById = new Map(entry.attachments.map((attachment) => [attachment.id, attachment]));
    const seenRequests = new Set();
    const plan = [];
    // Erst alles prüfen, dann schreiben: Eine ungültige Zuweisung darf keine
    // Teilübernahme hinterlassen, weil die E-Mail anschließend gelöscht wird.
    for (const assignment of input) {
      const requestId = String(assignment?.requestId || '');
      const request = procurementRequests.find((candidate) => candidate.id === requestId);
      if (!request || !canAccessProcurementEmail(req.user, { requestId }, procurementRequests)) {
        return res.status(400).json({ error: 'Ein ausgewählter Beschaffungsvorgang wurde nicht gefunden.' });
      }
      if (seenRequests.has(request.id)) {
        return res.status(400).json({ error: `Der Vorgang ${request.number} wurde mehrfach ausgewählt.` });
      }
      seenRequests.add(request.id);
      const documentType = String(assignment.documentType || '');
      if (!DOCUMENT_TYPES.has(documentType)) {
        return res.status(400).json({ error: `Für ${request.number} ist kein gültiger Dokumenttyp gewählt.` });
      }
      if (INVOICE_ONLY_STATUSES.has(request.status)) {
        if (documentType !== 'Rechnung') {
          return res.status(409).json({ error: `Dem abgeschlossenen Vorgang ${request.number} können nur Rechnungen zugewiesen werden.` });
        }
      } else if (!ASSIGNABLE_STATUSES.has(request.status)) {
        return res.status(409).json({ error: `Dem Vorgang ${request.number} können im Status „${request.status}“ keine Dokumente zugewiesen werden.` });
      }
      const ids = [...new Set((Array.isArray(assignment.attachmentIds) ? assignment.attachmentIds : []).map(String))];
      const attachments = ids.map((id) => attachmentsById.get(id));
      if (attachments.some((attachment) => !attachment)) {
        return res.status(400).json({ error: 'Ein ausgewählter Anhang wurde nicht gefunden.' });
      }
      if (!attachments.length && entry.attachments.length) {
        return res.status(400).json({ error: `Für ${request.number} ist kein Anhang ausgewählt.` });
      }
      const existing = procurementDocuments.filter((document) => document.requestId === request.id).length;
      if (existing + attachments.length > MAX_DOCUMENTS_PER_REQUEST) {
        return res.status(409).json({ error: `Pro Vorgang sind maximal ${MAX_DOCUMENTS_PER_REQUEST} Dokumente erlaubt (${request.number}).` });
      }
      plan.push({ request, documentType, attachments });
    }
    const newDocuments = plan.flatMap((item) => item.attachments);
    if (procurementDocuments.length + newDocuments.length > MAX_DOCUMENTS_TOTAL) {
      return res.status(507).json({ error: 'Die maximale Gesamtzahl an Beschaffungsdokumenten ist erreicht.' });
    }
    const storedBytes = procurementDocuments.reduce((sum, document) =>
      sum + Buffer.byteLength(document.fileBase64 || '', 'base64'), 0);
    const incomingBytes = newDocuments.reduce((sum, attachment) => sum + attachment.sizeBytes, 0);
    if (storedBytes + incomingBytes > MAX_DOCUMENT_STORAGE_BYTES) {
      return res.status(507).json({ error: 'Das Speicherlimit für Beschaffungsdokumente ist erreicht.' });
    }

    const timestamp = new Date().toISOString();
    const results = [];
    for (const { request, documentType, attachments } of plan) {
      const documentIds = [];
      for (const attachment of attachments) {
        const document = {
          id: nextId('proc-document', procurementDocuments), requestId: request.id,
          entityType: 'Antrag', entityId: request.id, documentType,
          fileName: attachment.fileName, mimeType: attachment.mimeType,
          fileBase64: attachment.fileBase64, createdBy: req.user.username,
          createdAt: timestamp, sourceEmailImportId: entry.id,
        };
        procurementDocuments.push(document);
        documentIds.push(document.id);
      }
      request.history.push({
        id: `history-${request.history.length + 1}`, action: 'Dokumente aus Postbox zugewiesen',
        actor: req.user.username,
        details: {
          documentType, documentIds,
          fileNames: attachments.map((attachment) => attachment.fileName),
          ...emailHistoryDetails(entry),
        },
        createdAt: timestamp,
      });
      request.updatedAt = timestamp;
      logEvent('Dokumente aus Postbox zugewiesen', 'ProcurementRequest', {
        id: request.id, documentIds, emailImportId: entry.id,
      }, req.user.username);
      results.push({ requestId: request.id, number: request.number, documentIds });
    }
    release(entry);
    return res.json({ assignments: results });
  });
}

module.exports = {
  DOCUMENT_TYPES,
  canAccessProcurementEmail,
  isPendingProcurementEmail,
  releaseProcurementEmail,
  createProcurementEmailService,
  registerProcurementEmailRoutes,
};
