const { randomUUID } = require('node:crypto');

const LEVELS = new Set(['info', 'warning', 'critical']);

function registerAdminNoticeRoutes({
  app, authMiddleware, notices, logEvent,
}) {
  const isAdmin = (req, res, next) => {
    if (!req.user?.roles?.includes('Admin')) {
      return res.status(403).json({ error: 'Diese Funktion ist ausschließlich für Admins verfügbar.' });
    }
    return next();
  };

  function parseDate(value, field, { required = false } = {}) {
    if (value === null || value === undefined || value === '') {
      if (required) throw Object.assign(new Error(`${field} ist erforderlich.`), { status: 400 });
      return null;
    }
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) {
      throw Object.assign(new Error(`${field} enthält kein gültiges Datum.`), { status: 400 });
    }
    return date.toISOString();
  }

  function noticeInput(body) {
    const title = String(body.title || '').trim();
    const message = String(body.message || '').trim();
    const level = String(body.level || 'info');
    const startsAt = parseDate(body.startsAt, 'Anzeigen ab');
    const endsAt = parseDate(body.endsAt, 'Anzeigen bis');
    if (title.length > 120) {
      throw Object.assign(new Error('Der Titel darf höchstens 120 Zeichen lang sein.'), { status: 400 });
    }
    if (!message) {
      throw Object.assign(new Error('Der Hinweistext ist erforderlich.'), { status: 400 });
    }
    if (message.length > 2000) {
      throw Object.assign(new Error('Der Hinweistext darf höchstens 2.000 Zeichen lang sein.'), { status: 400 });
    }
    if (!LEVELS.has(level)) {
      throw Object.assign(new Error('Die Priorität ist ungültig.'), { status: 400 });
    }
    if (startsAt && endsAt && new Date(endsAt) <= new Date(startsAt)) {
      throw Object.assign(new Error('Das Ende muss nach dem Beginn liegen.'), { status: 400 });
    }
    return {
      title,
      message,
      level,
      startsAt,
      endsAt,
      active: body.active !== false,
    };
  }

  app.get('/api/admin/notices', authMiddleware, isAdmin, (req, res) => {
    res.json([...notices].sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt)));
  });

  app.post('/api/admin/notices', authMiddleware, isAdmin, (req, res, next) => {
    try {
      const now = new Date().toISOString();
      const notice = {
        id: randomUUID(),
        ...noticeInput(req.body),
        createdAt: now,
        updatedAt: now,
        createdBy: req.user.username,
      };
      notices.push(notice);
      logEvent('created', 'AdminNotice', { id: notice.id, title: notice.title }, req.user.username);
      return res.status(201).json(notice);
    } catch (error) {
      return next(error);
    }
  });

  app.put('/api/admin/notices/:id', authMiddleware, isAdmin, (req, res, next) => {
    const notice = notices.find((entry) => entry.id === req.params.id);
    if (!notice) return res.status(404).json({ error: 'Hinweis nicht gefunden.' });
    try {
      Object.assign(notice, noticeInput(req.body), {
        updatedAt: new Date().toISOString(),
      });
      logEvent('updated', 'AdminNotice', { id: notice.id, title: notice.title }, req.user.username);
      return res.json(notice);
    } catch (error) {
      return next(error);
    }
  });

  app.delete('/api/admin/notices/:id', authMiddleware, isAdmin, (req, res) => {
    const index = notices.findIndex((entry) => entry.id === req.params.id);
    if (index < 0) return res.status(404).json({ error: 'Hinweis nicht gefunden.' });
    const [notice] = notices.splice(index, 1);
    logEvent('deleted', 'AdminNotice', { id: notice.id, title: notice.title }, req.user.username);
    return res.status(204).end();
  });
}

module.exports = { registerAdminNoticeRoutes };
