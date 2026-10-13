const fs = require('node:fs');
const path = require('node:path');

const MAX_FILE_BYTES = 512 * 1024;
const MAX_MESSAGES = 100;
const MAX_ACKNOWLEDGEMENTS = 100_000;
const MESSAGE_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/;
const VERSION = /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/;

function dateOrNull(value) {
  if (value === null || value === undefined || value === '') return null;
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? null : parsed.toISOString();
}

function boundedText(value, maximum) {
  const normalized = String(value || '').trim();
  return normalized && normalized.length <= maximum ? normalized : null;
}

function normalizeMessage(value) {
  if (!value || typeof value !== 'object' || !MESSAGE_ID.test(String(value.id || ''))) {
    return null;
  }
  if (!['release', 'maintenance'].includes(value.type)) return null;
  const title = boundedText(value.title, 120);
  const message = boundedText(value.message, 4000);
  const publishedAt = dateOrNull(value.publishedAt);
  if (!title || !message || !publishedAt) return null;

  const normalized = {
    id: String(value.id),
    type: value.type,
    title,
    message,
    publishedAt,
  };
  if (value.type === 'release') {
    const version = boundedText(value.version, 64);
    if (!version || !VERSION.test(version)) return null;
    normalized.version = version;
  } else {
    const startsAt = dateOrNull(value.startsAt);
    const endsAt = dateOrNull(value.endsAt);
    if (!startsAt || !endsAt || startsAt >= endsAt) return null;
    normalized.startsAt = startsAt;
    normalized.endsAt = endsAt;
  }
  return normalized;
}

function readMessageFile(filePath) {
  if (!filePath) return [];
  let descriptor;
  try {
    const flags = fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0);
    descriptor = fs.openSync(filePath, flags);
    const stats = fs.fstatSync(descriptor);
    if (!stats.isFile() || stats.size > MAX_FILE_BYTES) {
      throw new Error('Die Systemnachrichtendatei ist ungültig oder zu groß.');
    }
    const document = JSON.parse(fs.readFileSync(descriptor, 'utf8'));
    if (document?.schemaVersion !== 1 || !Array.isArray(document.messages)
        || document.messages.length > MAX_MESSAGES) {
      throw new Error('Die Systemnachrichtendatei hat ein ungültiges Format.');
    }
    const messages = document.messages.map(normalizeMessage);
    if (messages.some((entry) => entry === null)) {
      throw new Error('Die Systemnachrichtendatei enthält ungültige Einträge.');
    }
    return messages.sort((left, right) => right.publishedAt.localeCompare(left.publishedAt));
  } catch (error) {
    if (error.code === 'ENOENT') return [];
    throw error;
  } finally {
    if (descriptor !== undefined) fs.closeSync(descriptor);
  }
}

function visibleMessages(messages, now = new Date()) {
  const instant = now.toISOString();
  return messages.filter((entry) => entry.publishedAt <= instant
    && (entry.type !== 'maintenance' || entry.endsAt > instant));
}

function createSystemMessageService({
  filePath = process.env.SYSTEM_MESSAGES_PATH
    || path.resolve(__dirname, '..', 'runtime', 'public-messages.json'),
  acknowledgements,
}) {
  function readVisible() {
    return visibleMessages(readMessageFile(filePath));
  }

  function forUser(userId) {
    const acknowledgedIds = new Set(acknowledgements
      .filter((entry) => entry.userId === userId)
      .map((entry) => entry.messageId));
    return readVisible().map((entry) => ({
      ...entry,
      acknowledged: entry.type === 'release' && acknowledgedIds.has(entry.id),
    }));
  }

  function acknowledge(userId, messageId) {
    const message = readVisible().find((entry) => entry.id === messageId);
    if (!message || message.type !== 'release') return false;
    if (!acknowledgements.some((entry) => entry.userId === userId
      && entry.messageId === messageId)) {
      acknowledgements.push({
        id: `message-ack:${userId}:${messageId}`,
        userId,
        messageId,
        acknowledgedAt: new Date().toISOString(),
      });
      if (acknowledgements.length > MAX_ACKNOWLEDGEMENTS) {
        acknowledgements.splice(0, acknowledgements.length - MAX_ACKNOWLEDGEMENTS);
      }
    }
    return true;
  }

  return { acknowledge, forUser, readVisible };
}

function registerSystemMessageRoutes({
  app,
  authMiddleware,
  publicRateLimit,
  acknowledgements,
  filePath,
}) {
  const service = createSystemMessageService({ acknowledgements, filePath });

  app.get('/api/system/messages', publicRateLimit, (_req, res) => {
    const messages = service.readVisible().filter((entry) => entry.type === 'maintenance');
    return res.json({ messages });
  });

  app.get('/api/system/messages/me', authMiddleware, (req, res) => res.json({
    messages: service.forUser(req.user.id),
  }));

  app.post('/api/system/messages/:id/acknowledge', authMiddleware, (req, res) => {
    if (!MESSAGE_ID.test(req.params.id) || !service.acknowledge(req.user.id, req.params.id)) {
      return res.status(404).json({ error: 'Releasehinweis nicht gefunden.' });
    }
    return res.status(204).end();
  });

  return service;
}

module.exports = {
  createSystemMessageService,
  normalizeMessage,
  readMessageFile,
  registerSystemMessageRoutes,
  visibleMessages,
};
