const crypto = require('node:crypto');
const { sendAccountMail } = require('./mailer');

const PURPOSES = new Set(['general', 'user-create', 'password-reset']);
const DEFAULT_TARGETS = new Set(['user-create', 'password-reset']);
const FORMATS = new Set(['markdown', 'html']);
const PLACEMENTS = new Set(['before-content', 'before-action', 'after-action']);

function normalizeTemplateInput(body, existing = {}) {
  const name = String(body.name ?? existing.name ?? '').trim();
  const subject = String(body.subject ?? existing.subject ?? '').trim();
  const content = String(body.content ?? existing.content ?? '').trim();
  const format = String(body.format ?? existing.format ?? 'markdown');
  const purpose = String(body.purpose ?? existing.purpose ?? 'general');
  const placement = String(body.placement ?? existing.placement ?? 'before-action');
  const defaultForValue = body.defaultFor === undefined
    ? existing.defaultFor
    : body.defaultFor;
  const defaultFor = defaultForValue == null || defaultForValue === ''
    ? null
    : String(defaultForValue);

  if (!name || name.length > 120) return { error: 'Ein Vorlagenname mit höchstens 120 Zeichen ist erforderlich.' };
  if (subject.length > 200) return { error: 'Der Betreff darf höchstens 200 Zeichen enthalten.' };
  if (!content || content.length > 20000) return { error: 'Eine Nachricht mit höchstens 20.000 Zeichen ist erforderlich.' };
  if (!FORMATS.has(format)) return { error: 'Das Nachrichtenformat ist ungültig.' };
  if (!PURPOSES.has(purpose)) return { error: 'Der Verwendungszweck ist ungültig.' };
  if (!PLACEMENTS.has(placement)) return { error: 'Die Position der Nachricht ist ungültig.' };
  if (defaultFor && !DEFAULT_TARGETS.has(defaultFor)) return { error: 'Die Standardzuordnung ist ungültig.' };
  if (defaultFor && purpose !== 'general' && purpose !== defaultFor) {
    return { error: 'Die Standardzuordnung muss zum Verwendungszweck der Vorlage passen.' };
  }
  return { value: { name, subject, content, format, purpose, placement, defaultFor } };
}

function messageFromTemplate(template) {
  return template ? {
    content: template.content,
    format: template.format,
    placement: template.placement,
  } : null;
}

function registerMailManagementRoutes({
  app,
  mailTemplates,
  authMiddleware,
  requirePermission,
  logEvent,
  accountMailSender = sendAccountMail,
}) {
  const requireAdmin = (req, res, next) => req.user?.roles?.includes('Admin')
    ? next()
    : res.status(403).json({ error: 'Diese Aktion ist nur für Admins verfügbar.' });
  const adminOnly = [authMiddleware, requirePermission('users.write'), requireAdmin];

  function setDefault(template) {
    if (!template.defaultFor) return;
    mailTemplates.forEach((entry) => {
      if (entry.id !== template.id && entry.defaultFor === template.defaultFor) {
        entry.defaultFor = null;
        entry.updatedAt = template.updatedAt;
      }
    });
  }

  function defaultMessageFor(target) {
    return messageFromTemplate(mailTemplates.find((entry) => entry.defaultFor === target));
  }

  app.get('/api/mail/templates', ...adminOnly, (_req, res) => {
    const sorted = [...mailTemplates].sort((a, b) => a.name.localeCompare(b.name, 'de'));
    return res.json(sorted);
  });

  app.post('/api/mail/templates', ...adminOnly, (req, res) => {
    const normalized = normalizeTemplateInput(req.body);
    if (normalized.error) return res.status(400).json({ error: normalized.error });
    const timestamp = new Date().toISOString();
    const template = {
      id: `mail-template-${crypto.randomUUID()}`,
      ...normalized.value,
      createdAt: timestamp,
      updatedAt: timestamp,
    };
    mailTemplates.push(template);
    setDefault(template);
    logEvent('create', 'MailTemplate', { id: template.id }, req.user.username);
    return res.status(201).json(template);
  });

  app.put('/api/mail/templates/:id', ...adminOnly, (req, res) => {
    const template = mailTemplates.find((entry) => entry.id === req.params.id);
    if (!template) return res.status(404).json({ error: 'Mailvorlage nicht gefunden.' });
    const normalized = normalizeTemplateInput(req.body, template);
    if (normalized.error) return res.status(400).json({ error: normalized.error });
    Object.assign(template, normalized.value, { updatedAt: new Date().toISOString() });
    setDefault(template);
    logEvent('update', 'MailTemplate', { id: template.id }, req.user.username);
    return res.json(template);
  });

  app.delete('/api/mail/templates/:id', ...adminOnly, (req, res) => {
    const index = mailTemplates.findIndex((entry) => entry.id === req.params.id);
    if (index < 0) return res.status(404).json({ error: 'Mailvorlage nicht gefunden.' });
    const [template] = mailTemplates.splice(index, 1);
    logEvent('delete', 'MailTemplate', { id: template.id }, req.user.username);
    return res.status(204).end();
  });

  app.post('/api/mail/send', ...adminOnly, async (req, res) => {
    const template = req.body.templateId
      ? mailTemplates.find((entry) => entry.id === req.body.templateId)
      : null;
    if (req.body.templateId && !template) return res.status(404).json({ error: 'Mailvorlage nicht gefunden.' });
    const to = String(req.body.to || '').trim().toLowerCase();
    const subject = String(req.body.subject ?? template?.subject ?? '').trim();
    const content = String(req.body.content ?? template?.content ?? '').trim();
    const format = String(req.body.format ?? template?.format ?? 'markdown');
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(to)) return res.status(400).json({ error: 'Eine gültige Empfängeradresse ist erforderlich.' });
    if (!subject || subject.length > 200) return res.status(400).json({ error: 'Ein Betreff mit höchstens 200 Zeichen ist erforderlich.' });
    if (!content || content.length > 20000) return res.status(400).json({ error: 'Eine Nachricht mit höchstens 20.000 Zeichen ist erforderlich.' });
    if (!FORMATS.has(format)) return res.status(400).json({ error: 'Das Nachrichtenformat ist ungültig.' });
    try {
      await accountMailSender({
        to,
        subject,
        text: '',
        richContent: { content, format },
      });
    } catch (error) {
      console.error('Individuelle E-Mail fehlgeschlagen:', error.message);
      return res.status(502).json({ error: 'Die E-Mail konnte nicht an den Mailserver übergeben werden.' });
    }
    logEvent('send', 'IndividualMail', { to, subject, templateId: template?.id || null }, req.user.username);
    return res.status(202).json({ message: 'Die E-Mail wurde an den Mailserver übergeben.' });
  });

  return { defaultMessageFor, messageFromTemplate };
}

module.exports = {
  registerMailManagementRoutes,
  normalizeTemplateInput,
  messageFromTemplate,
};
