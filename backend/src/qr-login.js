const crypto = require('node:crypto');

const QR_LOGIN_TTL_MS = 10 * 60 * 1000;
const QR_PREFIX = 'mkqr:v1:';
const QR_VALIDITY_MS = Object.freeze({
  '10m': 10 * 60 * 1000,
  '30m': 30 * 60 * 1000,
  '60m': 60 * 60 * 1000,
  '12h': 12 * 60 * 60 * 1000,
  '1d': 24 * 60 * 60 * 1000,
  '7d': 7 * 24 * 60 * 60 * 1000,
  '14d': 14 * 24 * 60 * 60 * 1000,
  '30d': 30 * 24 * 60 * 60 * 1000,
  '1y': 365 * 24 * 60 * 60 * 1000,
  '3y': 3 * 365 * 24 * 60 * 60 * 1000,
});
const MAX_CUSTOM_DAYS = 100 * 365;

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
  createToken, securityVersion, publicUser, logEvent, saveUser = async () => {}, userMfa,
}) {
  function removeExpired() {
    const now = Date.now();
    for (let index = credentials.length - 1; index >= 0; index -= 1) {
      const expiresAt = credentials[index].expiresAt;
      if (expiresAt && new Date(expiresAt).getTime() <= now) credentials.splice(index, 1);
    }
  }

  function validityFrom(body) {
    const validity = String(body.validity || '10m');
    if (validity === 'unlimited') return { validity, ttlMs: null };
    if (validity === 'custom') {
      const days = Number(body.customDays);
      if (!Number.isInteger(days) || days < 1 || days > MAX_CUSTOM_DAYS) {
        return { error: `Benutzerdefinierte Gültigkeit muss zwischen 1 und ${MAX_CUSTOM_DAYS} Tagen liegen.` };
      }
      return { validity, customDays: days, ttlMs: days * 24 * 60 * 60 * 1000 };
    }
    if (!Object.hasOwn(QR_VALIDITY_MS, validity)) {
      return { error: 'Ungültige Gültigkeitsdauer.' };
    }
    return { validity, ttlMs: QR_VALIDITY_MS[validity] };
  }

  function titleFrom(body) {
    const title = String(body.title || 'Anmeldecode').trim();
    if (title.length > 120) return { error: 'Der Titel darf höchstens 120 Zeichen lang sein.' };
    return { title };
  }

  function publicCredential(credential) {
    const oneTime = credential.validity !== 'unlimited' && credential.expiresAt !== null;
    return {
      id: credential.id,
      userId: credential.userId,
      title: credential.title || 'Anmeldecode',
      createdAt: credential.createdAt,
      expiresAt: credential.expiresAt || null,
      createdBy: credential.createdBy,
      validity: credential.validity || null,
      customDays: credential.customDays || null,
      oneTime,
    };
  }

  function listFor(userId) {
    removeExpired();
    return credentials
      .filter((entry) => entry.userId === userId)
      .map(publicCredential)
      .sort((left, right) => right.createdAt.localeCompare(left.createdAt));
  }

  function issue(user, actor, requestedValidity, title) {
    removeExpired();
    const secret = crypto.randomBytes(32).toString('base64url');
    const qrValue = `${QR_PREFIX}${secret}`;
    const createdAt = new Date();
    const expiresAt = requestedValidity.ttlMs === null
      ? null
      : new Date(createdAt.getTime() + requestedValidity.ttlMs);
    credentials.push({
      id: crypto.randomUUID(),
      userId: user.id,
      title,
      credentialHash: hashCredential(qrValue),
      createdAt: createdAt.toISOString(),
      expiresAt: expiresAt?.toISOString() || null,
      createdBy: actor.id,
      securityVersion: securityVersion(user),
      validity: requestedValidity.validity,
      customDays: requestedValidity.customDays || null,
    });
    const result = {
      qrValue,
      title,
      expiresAt: expiresAt?.toISOString() || null,
      oneTime: requestedValidity.validity !== 'unlimited',
      validity: requestedValidity.validity,
    };
    if (requestedValidity.customDays) result.customDays = requestedValidity.customDays;
    logEvent(
      'qr_login_issued',
      'User',
      {
        id: user.id,
        credentialId: credentials.at(-1).id,
        title,
        expiresAt: result.expiresAt,
        validity: result.validity,
      },
      actor.username,
    );
    return { ...result, id: credentials.at(-1).id };
  }

  function revoke(userId, credentialId, actor) {
    const index = credentials.findIndex(
      (entry) => entry.id === credentialId && entry.userId === userId,
    );
    if (index < 0) return false;
    const [credential] = credentials.splice(index, 1);
    logEvent(
      'qr_login_revoked',
      'User',
      { id: userId, credentialId, title: credential.title || 'Anmeldecode' },
      actor.username,
    );
    return true;
  }

  app.get('/api/auth/qr-credentials/me', authMiddleware, (req, res) => {
    res.json(listFor(req.user.id));
  });

  app.post('/api/auth/qr-credentials/me', authMiddleware, (req, res) => {
    const requestedValidity = validityFrom(req.body);
    if (requestedValidity.error) return res.status(400).json({ error: requestedValidity.error });
    const requestedTitle = titleFrom(req.body);
    if (requestedTitle.error) return res.status(400).json({ error: requestedTitle.error });
    return res.status(201).json(
      issue(req.user, req.user, requestedValidity, requestedTitle.title),
    );
  });

  app.delete('/api/auth/qr-credentials/me/:credentialId', authMiddleware, (req, res) => {
    if (!revoke(req.user.id, req.params.credentialId, req.user)) {
      return res.status(404).json({ error: 'Anmeldecode nicht gefunden.' });
    }
    return res.status(204).end();
  });

  app.delete('/api/auth/qr-credentials/me', authMiddleware, (req, res) => {
    for (let index = credentials.length - 1; index >= 0; index -= 1) {
      if (credentials[index].userId === req.user.id) credentials.splice(index, 1);
    }
    logEvent('qr_login_revoked', 'User', { id: req.user.id }, req.user.username);
    res.status(204).end();
  });

  app.get(
    '/api/users/:id/qr-credentials',
    authMiddleware,
    requirePermission('users.write'),
    (req, res) => {
      const user = users.find((entry) => entry.id === req.params.id);
      if (!user) return res.status(404).json({ error: 'Nutzer nicht gefunden.' });
      return res.json(listFor(user.id));
    },
  );

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
      const requestedValidity = validityFrom(req.body);
      if (requestedValidity.error) return res.status(400).json({ error: requestedValidity.error });
      const requestedTitle = titleFrom(req.body);
      if (requestedTitle.error) return res.status(400).json({ error: requestedTitle.error });
      return res.status(201).json(
        issue(user, req.user, requestedValidity, requestedTitle.title),
      );
    },
  );

  app.delete(
    '/api/users/:id/qr-credentials/:credentialId',
    authMiddleware,
    requirePermission('users.write'),
    (req, res) => {
      const user = users.find((entry) => entry.id === req.params.id);
      if (!user) return res.status(404).json({ error: 'Nutzer nicht gefunden.' });
      if (!revoke(user.id, req.params.credentialId, req.user)) {
        return res.status(404).json({ error: 'Anmeldecode nicht gefunden.' });
      }
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
    const oneTime = credential.validity !== 'unlimited' && credential.expiresAt !== null;
    // Zeitlich begrenzte Einmalcodes werden vor dem Erstellen der Sitzung
    // verbraucht, damit parallele Anmeldungen sie nicht mehrfach nutzen können.
    if (oneTime) credentials.splice(index, 1);
    const user = users.find((entry) => entry.id === credential.userId);
    if (!user || !user.active || !user.emailVerifiedAt
        || credential.securityVersion !== securityVersion(user)) {
      if (!oneTime) credentials.splice(index, 1);
      return res.status(401).json({ error: 'QR-Code ist ungültig oder abgelaufen.' });
    }
    const finishLogin = async (verifiedUser, response) => {
      verifiedUser.lastLoginAt = new Date().toISOString();
      await saveUser(verifiedUser);
      logEvent('qr_login', 'User', { id: verifiedUser.id }, verifiedUser.username);
      req.persistenceRequired = true;
      return response.json({
        token: createToken(verifiedUser), expiresIn: 3600, user: publicUser(verifiedUser),
      });
    };
    if (userMfa?.mfaEnabled(user)) {
      return res.status(202).json(userMfa.issueChallenge(
        user,
        (verifiedUser, response) => finishLogin(verifiedUser, response),
      ));
    }
    if (userMfa?.passkeyRequired(user)) {
      return res.status(403).json({
        error: 'Für dieses Konto ist eine starke Anmeldung erforderlich. Verwenden Sie auf der normalen Anmeldeseite einen Passkey.',
        passkeyRequired: true,
      });
    }
    if (userMfa?.enrollmentRequired(user)) {
      return res.json({
        token: createToken(user, { mfaSetupRequired: true }),
        expiresIn: 3600,
        user: publicUser(user),
        mfaSetupRequired: true,
      });
    }
    return finishLogin(user, res);
  });
}

module.exports = {
  registerQrLoginRoutes,
  hashCredential,
  QR_PREFIX,
  QR_LOGIN_TTL_MS,
  QR_VALIDITY_MS,
  MAX_CUSTOM_DAYS,
};
