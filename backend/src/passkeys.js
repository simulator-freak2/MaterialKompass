const bcrypt = require('bcryptjs');
const crypto = require('node:crypto');
const defaultWebAuthn = require('@simplewebauthn/server');

const CHALLENGE_TTL_MS = 5 * 60 * 1000;
const MAX_CHALLENGES = 5_000;
const MAX_PASSKEYS_PER_USER = 20;
const MAX_PASSKEY_NAME_LENGTH = 100;
const MAX_CREDENTIAL_ID_LENGTH = 4096;
const MAX_PUBLIC_KEY_BYTES = 4096;
const CEREMONY_TIMEOUT_MS = 120_000;
const GENERIC_AUTH_ERROR = 'Die Passkey-Anmeldung ist ungültig oder abgelaufen.';

function normalizeOrigins(value, fallback) {
  const origins = String(value || fallback || '')
    .split(',')
    .map((origin) => origin.trim().replace(/\/$/, ''))
    .filter(Boolean);
  return [...new Set(origins)];
}

function passkeyConfig(env = process.env) {
  const appUrl = new URL(env.APP_BASE_URL || 'https://materialkompass.org');
  const rpID = env.PASSKEY_RP_ID || appUrl.hostname;
  const expectedOrigins = normalizeOrigins(env.PASSKEY_ORIGINS, appUrl.origin);
  const androidOrigins = normalizeOrigins(env.PASSKEY_ANDROID_ORIGINS);
  return {
    rpID,
    rpName: env.PASSKEY_RP_NAME || 'MaterialKompass',
    expectedOrigins: [...new Set([...expectedOrigins, ...androidOrigins])],
  };
}

function publicPasskey(passkey) {
  return {
    id: passkey.id,
    name: passkey.name,
    transports: passkey.transports || [],
    deviceType: passkey.deviceType,
    backedUp: passkey.backedUp === true,
    createdAt: passkey.createdAt,
    lastUsedAt: passkey.lastUsedAt || null,
  };
}

function safeEqual(left, right) {
  const a = Buffer.from(String(left || ''));
  const b = Buffer.from(String(right || ''));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function createPasskeyAuth({
  app,
  users,
  passkeys,
  authMiddleware,
  requirePermission,
  authRateLimit,
  createToken,
  publicUser,
  userMfa,
  saveUser = async () => {},
  savePasskey = async () => {},
  deletePasskey = async () => {},
  deleteUserPasskeys = async () => {},
  logEvent = () => {},
  securityVersion = () => '',
  now = Date.now,
  config = passkeyConfig(),
  webauthn = defaultWebAuthn,
}) {
  const challenges = new Map();
  const passkeysByCredentialId = new Map();

  function refreshUserCounts() {
    const counts = new Map();
    for (const passkey of passkeys) {
      counts.set(passkey.userId, (counts.get(passkey.userId) || 0) + 1);
      passkeysByCredentialId.set(passkey.credentialId, passkey);
    }
    for (const user of users) user.passkeyCount = counts.get(user.id) || 0;
  }
  refreshUserCounts();

  function challengeHash(value) {
    return crypto.createHash('sha256').update(String(value || '')).digest('hex');
  }

  function cleanChallenges() {
    const timestamp = now();
    for (const [hash, challenge] of challenges) {
      if (challenge.expiresAt <= timestamp) challenges.delete(hash);
    }
  }

  function issueChallenge(record) {
    cleanChallenges();
    while (challenges.size >= MAX_CHALLENGES) {
      challenges.delete(challenges.keys().next().value);
    }
    const id = crypto.randomBytes(32).toString('base64url');
    challenges.set(challengeHash(id), {
      ...record,
      expiresAt: now() + CHALLENGE_TTL_MS,
    });
    return id;
  }

  function consumeChallenge(id, purpose) {
    if (typeof id !== 'string' || id.length > 256) return null;
    cleanChallenges();
    const hash = challengeHash(id);
    const challenge = challenges.get(hash);
    if (!challenge || challenge.purpose !== purpose) return null;
    challenges.delete(hash);
    return challenge;
  }

  async function requireStepUp(user, body, res) {
    if (!await bcrypt.compare(body.currentPassword || '', user.passwordHash)) {
      res.status(403).json({ error: 'Die erneute Authentifizierung ist fehlgeschlagen.' });
      return false;
    }
    if (userMfa.mfaEnabled(user)) {
      const verification = await userMfa.verifyUserCode(user, body.code);
      if (!verification.valid) {
        res.status(403).json({ error: 'Die erneute Authentifizierung ist fehlgeschlagen.' });
        return false;
      }
      user.mfaLastVerifiedAt = new Date(now()).toISOString();
      await saveUser(user);
    }
    return true;
  }

  function passkeysFor(userId) {
    return passkeys.filter((entry) => entry.userId === userId);
  }

  app.get('/.well-known/assetlinks.json', (_req, res) => {
    const fingerprints = String(process.env.PASSKEY_ANDROID_SHA256_FINGERPRINTS || '')
      .split(',').map((value) => value.trim()).filter(Boolean);
    res.set('Cache-Control', 'public, max-age=3600');
    if (fingerprints.length === 0) return res.json([]);
    return res.json([{
      relation: ['delegate_permission/common.get_login_creds'],
      target: {
        namespace: 'android_app',
        package_name: process.env.PASSKEY_ANDROID_PACKAGE || 'org.materialkompass.materialkompass',
        sha256_cert_fingerprints: fingerprints,
      },
    }]);
  });

  app.get('/.well-known/apple-app-site-association', (_req, res) => {
    const teamId = String(process.env.PASSKEY_APPLE_TEAM_ID || '').trim();
    if (!teamId) return res.status(404).json({ error: 'Apple-App-Zuordnung nicht konfiguriert.' });
    res.set('Cache-Control', 'public, max-age=3600');
    const bundleId = process.env.PASSKEY_APPLE_BUNDLE_ID
      || 'org.materialkompass.materialkompass';
    return res.json({ webcredentials: { apps: [`${teamId}.${bundleId}`] } });
  });

  app.get('/api/users/me/passkeys', authMiddleware, (req, res) => {
    res.json(passkeysFor(req.user.id).map(publicPasskey));
  });

  app.post('/api/users/me/passkeys/options', authMiddleware, authRateLimit, async (req, res) => {
    if (!await requireStepUp(req.user, req.body, res)) return;
    const userPasskeys = passkeysFor(req.user.id);
    if (userPasskeys.length >= MAX_PASSKEYS_PER_USER) {
      return res.status(409).json({ error: 'Die maximale Anzahl von Passkeys ist erreicht.' });
    }
    const name = String(req.body.name || '').trim();
    if (!name || name.length > MAX_PASSKEY_NAME_LENGTH) {
      return res.status(400).json({
        error: `Der Passkey-Name muss 1 bis ${MAX_PASSKEY_NAME_LENGTH} Zeichen enthalten.`,
      });
    }
    const userHandle = userPasskeys[0]?.userHandle
      || crypto.randomBytes(32).toString('base64url');
    const options = await webauthn.generateRegistrationOptions({
      rpName: config.rpName,
      rpID: config.rpID,
      userID: Buffer.from(userHandle, 'base64url'),
      userName: req.user.username,
      userDisplayName: req.user.name,
      timeout: CEREMONY_TIMEOUT_MS,
      attestationType: 'none',
      excludeCredentials: userPasskeys.map((entry) => ({
        id: entry.credentialId,
        transports: entry.transports || [],
      })),
      authenticatorSelection: {
        residentKey: 'required',
        requireResidentKey: true,
        userVerification: 'required',
      },
    });
    const challengeId = issueChallenge({
      purpose: 'registration',
      challenge: options.challenge,
      userId: req.user.id,
      userHandle,
      name,
      securityVersion: securityVersion(req.user),
    });
    logEvent('passkey_registration_started', 'User', { id: req.user.id }, req.user.username);
    return res.json({ challengeId, options, expiresIn: CHALLENGE_TTL_MS / 1000 });
  });

  app.post('/api/users/me/passkeys/verify', authMiddleware, authRateLimit, async (req, res) => {
    const challenge = consumeChallenge(req.body.challengeId, 'registration');
    if (!challenge || challenge.userId !== req.user.id
        || challenge.securityVersion !== securityVersion(req.user)) {
      return res.status(400).json({ error: 'Die Passkey-Registrierung ist ungültig oder abgelaufen.' });
    }
    let verification;
    try {
      verification = await webauthn.verifyRegistrationResponse({
        response: req.body.credential,
        expectedChallenge: challenge.challenge,
        expectedOrigin: config.expectedOrigins,
        expectedRPID: config.rpID,
        requireUserPresence: true,
        requireUserVerification: true,
      });
    } catch (_) {
      return res.status(400).json({ error: 'Die Passkey-Registrierung konnte nicht bestätigt werden.' });
    }
    if (!verification.verified || !verification.registrationInfo?.userVerified) {
      return res.status(400).json({ error: 'Die Passkey-Registrierung konnte nicht bestätigt werden.' });
    }
    const info = verification.registrationInfo;
    const credentialId = String(info.credential.id || '');
    const publicKey = Buffer.from(info.credential.publicKey || []);
    if (!credentialId || credentialId.length > MAX_CREDENTIAL_ID_LENGTH
        || publicKey.length === 0 || publicKey.length > MAX_PUBLIC_KEY_BYTES) {
      return res.status(400).json({ error: 'Der Passkey enthält ungültige Schlüsseldaten.' });
    }
    if (passkeysByCredentialId.has(credentialId)) {
      return res.status(409).json({ error: 'Dieser Passkey ist bereits registriert.' });
    }
    const timestamp = new Date(now()).toISOString();
    const passkey = {
      id: crypto.randomUUID(),
      userId: req.user.id,
      userHandle: challenge.userHandle,
      credentialId,
      publicKey: publicKey.toString('base64url'),
      counter: info.credential.counter,
      transports: info.credential.transports || [],
      deviceType: info.credentialDeviceType,
      backedUp: info.credentialBackedUp,
      name: challenge.name,
      createdAt: timestamp,
      lastUsedAt: null,
    };
    await savePasskey(passkey);
    passkeys.push(passkey);
    passkeysByCredentialId.set(passkey.credentialId, passkey);
    req.user.passkeyCount = passkeysFor(req.user.id).length;
    req.user.mfaGraceEndsAt = null;
    req.user.mfaLastVerifiedAt = timestamp;
    req.user.mfaVersion = Number(req.user.mfaVersion || 0) + 1;
    await saveUser(req.user);
    logEvent('passkey_registered', 'User', {
      id: req.user.id,
      passkeyId: passkey.id,
      deviceType: passkey.deviceType,
      backedUp: passkey.backedUp,
    }, req.user.username);
    return res.status(201).json({
      passkey: publicPasskey(passkey),
      token: createToken(req.user),
      expiresIn: 3600,
      user: publicUser(req.user),
    });
  });

  app.patch('/api/users/me/passkeys/:id', authMiddleware, async (req, res) => {
    const passkey = passkeys.find((entry) => entry.id === req.params.id
      && entry.userId === req.user.id);
    if (!passkey) return res.status(404).json({ error: 'Passkey nicht gefunden.' });
    const name = String(req.body.name || '').trim();
    if (!name || name.length > MAX_PASSKEY_NAME_LENGTH) {
      return res.status(400).json({
        error: `Der Passkey-Name muss 1 bis ${MAX_PASSKEY_NAME_LENGTH} Zeichen enthalten.`,
      });
    }
    passkey.name = name;
    await savePasskey(passkey);
    logEvent('passkey_renamed', 'User', { id: req.user.id, passkeyId: passkey.id }, req.user.username);
    return res.json(publicPasskey(passkey));
  });

  app.delete('/api/users/me/passkeys/:id', authMiddleware, authRateLimit, async (req, res) => {
    const index = passkeys.findIndex((entry) => entry.id === req.params.id
      && entry.userId === req.user.id);
    if (index < 0) return res.status(404).json({ error: 'Passkey nicht gefunden.' });
    if (!await requireStepUp(req.user, req.body, res)) return;
    const passkey = passkeys[index];
    await deletePasskey(passkey.id);
    passkeys.splice(index, 1);
    passkeysByCredentialId.delete(passkey.credentialId);
    req.user.passkeyCount = passkeysFor(req.user.id).length;
    req.user.mfaVersion = Number(req.user.mfaVersion || 0) + 1;
    if (req.user.mfaRequired && !userMfa.mfaEnabled(req.user) && req.user.passkeyCount === 0) {
      req.user.mfaGraceEndsAt = new Date(now() + 14 * 24 * 60 * 60 * 1000).toISOString();
    }
    await saveUser(req.user);
    logEvent('passkey_revoked', 'User', {
      id: req.user.id, passkeyId: passkey.id,
    }, req.user.username);
    return res.status(204).end();
  });

  app.post('/api/auth/passkey/options', authRateLimit, async (_req, res) => {
    const options = await webauthn.generateAuthenticationOptions({
      rpID: config.rpID,
      timeout: CEREMONY_TIMEOUT_MS,
      userVerification: 'required',
    });
    const challengeId = issueChallenge({
      purpose: 'authentication',
      challenge: options.challenge,
    });
    return res.json({ challengeId, options, expiresIn: CHALLENGE_TTL_MS / 1000 });
  });

  app.post('/api/auth/passkey/verify', authRateLimit, async (req, res) => {
    const challenge = consumeChallenge(req.body.challengeId, 'authentication');
    const credentialId = String(req.body.credential?.id || '');
    if (!credentialId || credentialId.length > MAX_CREDENTIAL_ID_LENGTH) {
      return res.status(401).json({ error: GENERIC_AUTH_ERROR });
    }
    const passkey = passkeysByCredentialId.get(credentialId);
    const user = passkey && users.find((entry) => entry.id === passkey.userId);
    if (!challenge || !passkey || !user?.active || !user.emailVerifiedAt) {
      return res.status(401).json({ error: GENERIC_AUTH_ERROR });
    }
    const returnedUserHandle = req.body.credential?.response?.userHandle;
    if (!returnedUserHandle || !safeEqual(returnedUserHandle, passkey.userHandle)) {
      return res.status(401).json({ error: GENERIC_AUTH_ERROR });
    }
    let verification;
    try {
      verification = await webauthn.verifyAuthenticationResponse({
        response: req.body.credential,
        expectedChallenge: challenge.challenge,
        expectedOrigin: config.expectedOrigins,
        expectedRPID: config.rpID,
        credential: {
          id: passkey.credentialId,
          publicKey: Buffer.from(passkey.publicKey, 'base64url'),
          counter: Number(passkey.counter || 0),
          transports: passkey.transports || [],
        },
        requireUserVerification: true,
        advancedFIDOConfig: { userVerification: 'required' },
      });
    } catch (_) {
      logEvent('passkey_login_failed', 'User', { id: user.id }, user.username);
      return res.status(401).json({ error: GENERIC_AUTH_ERROR });
    }
    if (!verification.verified || !verification.authenticationInfo.userVerified) {
      return res.status(401).json({ error: GENERIC_AUTH_ERROR });
    }
    const timestamp = new Date(now()).toISOString();
    passkey.counter = verification.authenticationInfo.newCounter;
    passkey.deviceType = verification.authenticationInfo.credentialDeviceType;
    passkey.backedUp = verification.authenticationInfo.credentialBackedUp;
    passkey.lastUsedAt = timestamp;
    user.failedLoginAttempts = 0;
    user.lockedUntil = null;
    user.lastLoginAt = timestamp;
    user.mfaLastVerifiedAt = timestamp;
    await savePasskey(passkey);
    await saveUser(user);
    logEvent('passkey_login', 'User', {
      id: user.id, passkeyId: passkey.id,
    }, user.username);
    return res.json({
      token: createToken(user),
      expiresIn: 3600,
      user: publicUser(user),
    });
  });

  app.delete('/api/users/:id/passkeys', authMiddleware, requirePermission('users.write'),
    authRateLimit, async (req, res) => {
      const target = users.find((entry) => entry.id === req.params.id);
      if (!target) return res.status(404).json({ error: 'Benutzer nicht gefunden.' });
      if (!await requireStepUp(req.user, req.body, res)) return;
      const removed = passkeysFor(target.id);
      await deleteUserPasskeys(target.id);
      for (let index = passkeys.length - 1; index >= 0; index -= 1) {
        if (passkeys[index].userId === target.id) passkeys.splice(index, 1);
      }
      for (const passkey of removed) passkeysByCredentialId.delete(passkey.credentialId);
      target.passkeyCount = 0;
      target.mfaVersion = Number(target.mfaVersion || 0) + 1;
      if (target.mfaRequired && !userMfa.mfaEnabled(target)) {
        target.mfaGraceEndsAt = new Date(now() + 14 * 24 * 60 * 60 * 1000).toISOString();
      }
      await saveUser(target);
      logEvent('passkeys_admin_reset', 'User', {
        id: target.id, count: removed.length,
      }, req.user.username);
      return res.json({ removed: removed.length });
    });

  return {
    hasPasskey: (user) => Number(user?.passkeyCount || 0) > 0,
    publicPasskey,
    removeUser(userId) {
      for (let index = passkeys.length - 1; index >= 0; index -= 1) {
        if (passkeys[index].userId !== userId) continue;
        passkeysByCredentialId.delete(passkeys[index].credentialId);
        passkeys.splice(index, 1);
      }
    },
  };
}

module.exports = {
  CEREMONY_TIMEOUT_MS,
  CHALLENGE_TTL_MS,
  MAX_CHALLENGES,
  MAX_PASSKEYS_PER_USER,
  createPasskeyAuth,
  passkeyConfig,
  publicPasskey,
};
