const crypto = require('node:crypto');

const QR_LOGIN_TTL_MS = 10 * 60 * 1000;
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
      if (new Date(credentials[index].expiresAt).getTime() <= now) credentials.splice(index, 1);
    }
  }

  function issue(user, actor) {
    removeExpired();
    for (let index = credentials.length - 1; index >= 0; index -= 1) {
      if (credentials[index].userId === user.id) credentials.splice(index, 1);
    }
    const secret = crypto.randomBytes(32).toString('base64url');
    const qrValue = `${QR_PREFIX}${secret}`;
    const createdAt = new Date();
    const expiresAt = new Date(createdAt.getTime() + QR_LOGIN_TTL_MS);
    credentials.push({
      id: crypto.randomUUID(),
      userId: user.id,
      credentialHash: hashCredential(qrValue),
      createdAt: createdAt.toISOString(),
      expiresAt: expiresAt.toISOString(),
      createdBy: actor.id,
      securityVersion: securityVersion(user),
    });
    logEvent('qr_login_issued', 'User', { id: user.id, expiresAt: expiresAt.toISOString() }, actor.username);
    return { qrValue, expiresAt: expiresAt.toISOString(), oneTime: true };
  }

  app.post('/api/auth/qr-credentials/me', authMiddleware, (req, res) => {
    res.status(201).json(issue(req.user, req.user));
  });

  app.delete('/api/auth/qr-credentials/me', authMiddleware, (req, res) => {
    for (let index = credentials.length - 1; index >= 0; index -= 1) {
      if (credentials[index].userId === req.user.id) credentials.splice(index, 1);
    }
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
      return res.status(201).json(issue(user, req.user));
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

    // Consume before issuing a session, so concurrent scans cannot reuse it.
    const [credential] = credentials.splice(index, 1);
    const user = users.find((entry) => entry.id === credential.userId);
    if (!user || !user.active || !user.emailVerifiedAt
        || credential.securityVersion !== securityVersion(user)) {
      return res.status(401).json({ error: 'QR-Code ist ungültig oder abgelaufen.' });
    }
    user.lastLoginAt = new Date().toISOString();
    await saveUser(user);
    logEvent('qr_login', 'User', { id: user.id }, user.username);
    return res.json({ token: createToken(user), expiresIn: 3600, user: publicUser(user) });
  });
}

module.exports = { registerQrLoginRoutes, hashCredential, QR_PREFIX, QR_LOGIN_TTL_MS };
