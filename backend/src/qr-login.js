const crypto = require('node:crypto');

const QR_LOGIN_TTL_MS = 10 * 60 * 1000;
const DEFAULT_REUSABLE_QR_LOGIN_DAYS = 365;
const MAX_REUSABLE_QR_LOGIN_DAYS = 3650;
const MAX_QR_CREDENTIALS_PER_USER = 20;
const QR_PREFIX = 'mkqr:v1:';

function hashCredential(value) {
  return crypto.createHash('sha256').update(value).digest('hex');
}

function safeEqual(left, right) {
  const a = Buffer.from(left || '', 'hex');
  const b = Buffer.from(right || '', 'hex');
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function registerQrLoginRoutes({
  app, users, credentials, authMiddleware, requirePermission, authRateLimit,
  createToken, securityVersion, publicUser, logEvent, saveUser = async () => {},
}) {
  function removeExpired() {
    const now = Date.now();
    for (let index = credentials.length - 1; index >= 0; index -= 1) {
      const expiresAt = credentials[index].expiresAt;
      if (expiresAt && new Date(expiresAt).getTime() <= now) credentials.splice(index, 1);
    }
  }

  function issueSettings(body) {
    const oneTime = body.oneTime !== false;
    if (oneTime) return { oneTime: true, validForDays: null };
    if (!Object.hasOwn(body, 'validForDays')) {
      return { oneTime: false, validForDays: DEFAULT_REUSABLE_QR_LOGIN_DAYS };
    }
    if (body.validForDays === null) return { oneTime: false, validForDays: null };
    if (!Number.isInteger(body.validForDays)
        || body.validForDays < 1
        || body.validForDays > MAX_REUSABLE_QR_LOGIN_DAYS) {
      return {
        error: `Die Gültigkeit muss zwischen 1 und ${MAX_REUSABLE_QR_LOGIN_DAYS} Tagen liegen.`,
      };
    }
    return { oneTime: false, validForDays: body.validForDays };
  }

  function revokeForUser(userId) {
    for (let index = credentials.length - 1; index >= 0; index -= 1) {
      if (credentials[index].userId === userId) credentials.splice(index, 1);
    }
  }

  function publicCredential(credential) {
    return {
      id: credential.id,
      oneTime: credential.oneTime !== false && credential.reusable !== true,
      createdAt: credential.createdAt,
      expiresAt: credential.expiresAt || null,
      lastUsedAt: credential.lastUsedAt || null,
    };
  }

  function listForUser(userId) {
    removeExpired();
    return credentials
      .filter((credential) => credential.userId === userId)
      .map(publicCredential)
      .sort((left, right) => right.createdAt.localeCompare(left.createdAt));
  }

  function revokeCredential(userId, credentialId) {
    const index = credentials.findIndex((credential) =>
      credential.userId === userId && credential.id === credentialId);
    if (index < 0) return false;
    credentials.splice(index, 1);
    return true;
  }

  function issue(user, actor, { oneTime, validForDays }) {
    removeExpired();
    if (credentials.filter((credential) => credential.userId === user.id).length
        >= MAX_QR_CREDENTIALS_PER_USER) {
      return { error: `Es können höchstens ${MAX_QR_CREDENTIALS_PER_USER} aktive QR-Codes bestehen.` };
    }
    const secret = crypto.randomBytes(32).toString('base64url');
    const qrValue = `${QR_PREFIX}${secret}`;
    const createdAt = new Date();
    const expiresAt = oneTime
      ? new Date(createdAt.getTime() + QR_LOGIN_TTL_MS)
      : validForDays === null
        ? null
        : new Date(createdAt.getTime() + validForDays * 24 * 60 * 60 * 1000);
    const credentialId = crypto.randomUUID();
    credentials.push({
      id: credentialId,
      userId: user.id,
      credentialHash: hashCredential(qrValue),
      createdAt: createdAt.toISOString(),
      expiresAt: expiresAt?.toISOString() || null,
      createdBy: actor.id,
      securityVersion: securityVersion(user),
      oneTime,
      reusable: !oneTime,
    });
    logEvent('qr_login_issued', 'User', {
      id: user.id, expiresAt: expiresAt?.toISOString() || null, oneTime, validForDays,
    }, actor.username);
    return {
      qrValue,
      expiresAt: expiresAt?.toISOString() || null,
      oneTime,
      validForDays,
      credentialId,
    };
  }

  app.get('/api/auth/qr-credentials/me', authMiddleware, (req, res) => {
    res.json(listForUser(req.user.id));
  });

  app.post('/api/auth/qr-credentials/me', authMiddleware, (req, res) => {
    const settings = issueSettings(req.body);
    if (settings.error) return res.status(400).json({ error: settings.error });
    const issued = issue(req.user, req.user, settings);
    if (issued.error) return res.status(409).json({ error: issued.error });
    return res.status(201).json(issued);
  });

  app.delete('/api/auth/qr-credentials/me/:credentialId', authMiddleware, (req, res) => {
    if (!revokeCredential(req.user.id, req.params.credentialId)) {
      return res.status(404).json({ error: 'QR-Code nicht gefunden.' });
    }
    logEvent('qr_login_revoked', 'User', {
      id: req.user.id, credentialId: req.params.credentialId,
    }, req.user.username);
    return res.status(204).end();
  });

  app.delete('/api/auth/qr-credentials/me', authMiddleware, (req, res) => {
    revokeForUser(req.user.id);
    logEvent('qr_login_revoked', 'User', { id: req.user.id }, req.user.username);
    res.status(204).end();
  });

  app.post(
    '/api/users/:id/qr-credential',
    authMiddleware,
    requirePermission('users.write'),
    (req, res) => {
      const user = users.find((entry) => entry.id === req.params.id);
      if (!user) return res.status(404).json({ error: 'Nutzer nicht gefunden.' });
      if (!user.active || !user.emailVerifiedAt) {
        return res.status(409).json({ error: 'QR-Anmeldung ist nur für aktive, bestätigte Konten möglich.' });
      }
      const settings = issueSettings(req.body);
      if (settings.error) return res.status(400).json({ error: settings.error });
      const issued = issue(user, req.user, settings);
      if (issued.error) return res.status(409).json({ error: issued.error });
      return res.status(201).json(issued);
    },
  );

  app.get(
    '/api/users/:id/qr-credentials',
    authMiddleware,
    requirePermission('users.write'),
    (req, res) => {
      const user = users.find((entry) => entry.id === req.params.id);
      if (!user) return res.status(404).json({ error: 'Nutzer nicht gefunden.' });
      return res.json(listForUser(user.id));
    },
  );

  app.delete(
    '/api/users/:id/qr-credentials/:credentialId',
    authMiddleware,
    requirePermission('users.write'),
    (req, res) => {
      const user = users.find((entry) => entry.id === req.params.id);
      if (!user) return res.status(404).json({ error: 'Nutzer nicht gefunden.' });
      if (!revokeCredential(user.id, req.params.credentialId)) {
        return res.status(404).json({ error: 'QR-Code nicht gefunden.' });
      }
      logEvent('qr_login_revoked', 'User', {
        id: user.id, credentialId: req.params.credentialId,
      }, req.user.username);
      return res.status(204).end();
    },
  );

  app.delete(
    '/api/users/:id/qr-credential',
    authMiddleware,
    requirePermission('users.write'),
    (req, res) => {
      const user = users.find((entry) => entry.id === req.params.id);
      if (!user) return res.status(404).json({ error: 'Nutzer nicht gefunden.' });
      revokeForUser(user.id);
      logEvent('qr_login_revoked', 'User', { id: user.id }, req.user.username);
      return res.status(204).end();
    },
  );

  app.post('/api/auth/qr-login', authRateLimit, async (req, res) => {
    const qrValue = String(req.body.credential || '');
    if (!qrValue.startsWith(QR_PREFIX) || qrValue.length > 128) {
      return res.status(401).json({ error: 'QR-Code ist ungültig oder abgelaufen.' });
    }
    removeExpired();
    const suppliedHash = hashCredential(qrValue);
    const index = credentials.findIndex((entry) => safeEqual(entry.credentialHash, suppliedHash));
    if (index < 0) return res.status(401).json({ error: 'QR-Code ist ungültig oder abgelaufen.' });

    const credential = credentials[index];
    const user = users.find((entry) => entry.id === credential.userId);
    if (!user || !user.active || !user.emailVerifiedAt
        || credential.securityVersion !== securityVersion(user)) {
      credentials.splice(index, 1);
      return res.status(401).json({ error: 'QR-Code ist ungültig oder abgelaufen.' });
    }
    const reusable = credential.reusable === true || credential.oneTime === false;
    if (!reusable) {
      // Consume before issuing a session, so concurrent scans cannot reuse it.
      credentials.splice(index, 1);
    } else {
      credential.lastUsedAt = new Date().toISOString();
    }
    user.lastLoginAt = new Date().toISOString();
    await saveUser(user);
    logEvent('qr_login', 'User', { id: user.id }, user.username);
    return res.json({ token: createToken(user), expiresIn: 3600, user: publicUser(user) });
  });
}

module.exports = {
  registerQrLoginRoutes,
  hashCredential,
  QR_PREFIX,
  QR_LOGIN_TTL_MS,
  DEFAULT_REUSABLE_QR_LOGIN_DAYS,
  MAX_REUSABLE_QR_LOGIN_DAYS,
  MAX_QR_CREDENTIALS_PER_USER,
};
