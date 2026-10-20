const crypto = require('node:crypto');
const bcrypt = require('bcryptjs');
const {
  consumeRecoveryCode,
  createMfaVault,
  createRecoveryCodes,
  createTotpSecret,
  provisioningUri,
  verifyTotp,
} = require('./mfa-security');

const CHALLENGE_TTL_MS = 5 * 60 * 1000;
const CHALLENGE_MAX_ATTEMPTS = 5;
const ENROLLMENT_GRACE_DAYS = 14;
const OFFLINE_MFA_MAX_AGE_MS = 365 * 24 * 60 * 60 * 1000;
const SETUP_TTL_MS = 10 * 60 * 1000;

function publicMfa(user) {
  const enabled = Boolean(user.mfaSecretEncrypted && user.mfaEnabledAt);
  const pushDevices = Number(user.pushMfaDeviceCount || 0);
  const lastVerifiedAt = Date.parse(user.mfaLastVerifiedAt || '');
  return {
    enabled,
    pushEnabled: pushDevices > 0,
    pushDevices,
    required: user.mfaRequired === true,
    strongAuthenticationConfigured: strongAuthenticationEnabled(user),
    graceEndsAt: user.mfaGraceEndsAt || null,
    enabledAt: user.mfaEnabledAt || null,
    lastVerifiedAt: user.mfaLastVerifiedAt || null,
    recoveryCodesRemaining: enabled ? (user.mfaRecoveryCodeHashes || []).length : 0,
    offlineEligibleUntil: Number.isFinite(lastVerifiedAt)
      ? new Date(lastVerifiedAt + OFFLINE_MFA_MAX_AGE_MS).toISOString()
      : null,
  };
}

function mfaEnabled(user) {
  return Boolean(user?.mfaSecretEncrypted && user?.mfaEnabledAt);
}

function authenticationEnabled(user) {
  return mfaEnabled(user) || Number(user?.pushMfaDeviceCount || 0) > 0;
}

function strongAuthenticationEnabled(user) {
  return authenticationEnabled(user) || Number(user?.passkeyCount || 0) > 0;
}

function enrollmentRequired(user, now = Date.now()) {
  if (!user?.mfaRequired || strongAuthenticationEnabled(user)) return false;
  const graceEndsAt = Date.parse(user.mfaGraceEndsAt || '');
  return !Number.isFinite(graceEndsAt) || graceEndsAt <= now;
}

function offlineMfaEligible(user, now = Date.now()) {
  if (!strongAuthenticationEnabled(user)) return false;
  const lastVerifiedAt = Date.parse(user.mfaLastVerifiedAt || '');
  return Number.isFinite(lastVerifiedAt)
    && lastVerifiedAt + OFFLINE_MFA_MAX_AGE_MS > now;
}

function createUserMfa({
  app,
  users,
  authMiddleware,
  requirePermission,
  authRateLimit,
  createToken,
  saveUser = async () => {},
  logEvent = () => {},
  accountMailSender = async () => {},
  resetPushDevices = async () => {},
  encryptionKey,
  securityVersion = () => '',
  now = Date.now,
}) {
  const vault = createMfaVault(encryptionKey);
  // Challenges deliberately live only in this single-instance process: they
  // are one-time capabilities and become invalid after a restart instead of
  // turning into another persistent session type.
  const challenges = new Map();

  users.forEach((user) => {
    user.mfaRequired ??= false;
    user.mfaRecoveryCodeHashes ||= [];
    user.mfaVersion ||= 0;
  });

  function cleanChallenges() {
    const timestamp = now();
    for (const [hash, challenge] of challenges) {
      if (challenge.expiresAt <= timestamp) challenges.delete(hash);
    }
  }

  function challengeHash(value) {
    return crypto.createHash('sha256').update(String(value || '')).digest('hex');
  }

  function idForChallengeToken(token) {
    if (typeof token !== 'string' || token.length > 256) return null;
    return challengeHash(token);
  }

  function issueChallenge(user, complete) {
    cleanChallenges();
    if (challenges.size >= 10_000) {
      challenges.delete(challenges.keys().next().value);
    }
    const token = crypto.randomBytes(32).toString('base64url');
    challenges.set(challengeHash(token), {
      userId: user.id,
      expiresAt: now() + CHALLENGE_TTL_MS,
      attempts: 0,
      securityVersion: securityVersion(user),
      complete,
    });
    const pushAvailable = Number(user.pushMfaDeviceCount || 0) > 0;
    const codeAvailable = mfaEnabled(user);
    return {
      mfaRequired: true,
      error: pushAvailable
        ? 'Zwei-Faktor-Authentifizierung erforderlich. Bestätigen Sie die Push-Anfrage in der MaterialKompass-App.'
        : 'Zwei-Faktor-Authentifizierung erforderlich. Verwenden Sie einen aktuellen Code.',
      challenge: token,
      expiresIn: CHALLENGE_TTL_MS / 1000,
      methods: [
        ...(pushAvailable ? ['push'] : []),
        ...(codeAvailable ? ['totp', 'recovery_code'] : []),
      ],
    };
  }

  function pendingChallenge(token) {
    if (typeof token !== 'string' || token.length > 256) return null;
    cleanChallenges();
    const id = challengeHash(token);
    const challenge = challenges.get(id);
    if (!challenge) return null;
    const user = users.find((entry) => entry.id === challenge.userId);
    if (!user?.active || !user.emailVerifiedAt || !authenticationEnabled(user)
        || challenge.securityVersion !== securityVersion(user)) {
      challenges.delete(id);
      return null;
    }
    return { id, challenge, user };
  }

  function refreshChallengeSecurityVersion(id, user) {
    const challenge = challenges.get(id);
    if (!challenge || challenge.userId !== user?.id) return false;
    challenge.securityVersion = securityVersion(user);
    return true;
  }

  function cancelChallenge(id) {
    return challenges.delete(id);
  }

  async function completeChallenge(id, expectedUser, res, verification, req) {
    cleanChallenges();
    const challenge = challenges.get(id);
    if (!challenge || challenge.userId !== expectedUser?.id
        || challenge.securityVersion !== securityVersion(expectedUser)
        || verification?.valid !== true) {
      if (challenge) challenges.delete(id);
      return res.status(401).json({ error: 'Die 2-FA-Anfrage ist ungültig oder abgelaufen.' });
    }
    challenges.delete(id);
    expectedUser.mfaLastVerifiedAt = new Date(now()).toISOString();
    await saveUser(expectedUser);
    logEvent('mfa_verified', 'User', {
      id: expectedUser.id,
      method: verification.recovery ? 'recovery_code' : verification.method,
    }, expectedUser.username);
    return challenge.complete(expectedUser, res, verification, req);
  }

  async function verifyUserCode(user, code, { allowRecovery = true } = {}) {
    const secret = vault.decrypt(user.mfaSecretEncrypted);
    if (secret && verifyTotp(secret, code)) return { valid: true, recovery: false };
    if (allowRecovery && consumeRecoveryCode(user, code)) {
      await saveUser(user);
      return { valid: true, recovery: true };
    }
    return { valid: false, recovery: false };
  }

  async function securityNotice(user, subject, text) {
    try {
      await accountMailSender({ to: user.email, subject, text });
    } catch (error) {
      console.error('2-FA-Sicherheitsbenachrichtigung fehlgeschlagen:', error.message);
    }
  }

  app.post('/api/auth/mfa/verify', authRateLimit, async (req, res) => {
    const pending = pendingChallenge(req.body.challenge);
    if (!pending) {
      return res.status(401).json({ error: 'Die 2-FA-Anfrage ist ungültig oder abgelaufen.' });
    }
    const { id, challenge, user } = pending;
    challenge.attempts += 1;
    const verification = await verifyUserCode(user, req.body.code);
    if (!verification.valid) {
      if (challenge.attempts >= CHALLENGE_MAX_ATTEMPTS) challenges.delete(id);
      logEvent('mfa_failed', 'User', { id: user.id }, user.username);
      return res.status(401).json({ error: 'Der 2-FA-Code ist ungültig.' });
    }
    return completeChallenge(id, user, res, {
      ...verification,
      method: 'totp',
    }, req);
  });

  app.get('/api/users/me/mfa', authMiddleware, (req, res) => {
    res.json(publicMfa(req.user));
  });

  app.post('/api/users/me/mfa/setup', authMiddleware, async (req, res) => {
    if (!await bcrypt.compare(req.body.currentPassword || '', req.user.passwordHash)) {
      return res.status(403).json({ error: 'Das aktuelle Passwort ist nicht korrekt.' });
    }
    const secret = createTotpSecret();
    req.user.mfaPendingSecretEncrypted = vault.encrypt(secret);
    req.user.mfaPendingSecretExpiresAt = new Date(now() + SETUP_TTL_MS).toISOString();
    await saveUser(req.user);
    logEvent('mfa_setup_started', 'User', { id: req.user.id }, req.user.username);
    return res.json({
      secret,
      provisioningUri: provisioningUri(secret, req.user.email || req.user.username),
      issuer: 'MaterialKompass',
      account: req.user.email || req.user.username,
    });
  });

  app.post('/api/users/me/mfa/confirm', authMiddleware, async (req, res) => {
    const secret = vault.decrypt(req.user.mfaPendingSecretEncrypted);
    const pendingExpiresAt = Date.parse(req.user.mfaPendingSecretExpiresAt || '');
    if (!secret || !Number.isFinite(pendingExpiresAt) || pendingExpiresAt <= now()
        || !verifyTotp(secret, req.body.code)) {
      return res.status(400).json({ error: 'Der Bestätigungscode ist ungültig.' });
    }
    const recovery = createRecoveryCodes();
    // Plain recovery codes leave the backend only in this response. Persisted
    // user records contain their hashes and can therefore never reveal them.
    req.user.mfaSecretEncrypted = req.user.mfaPendingSecretEncrypted;
    req.user.mfaPendingSecretEncrypted = null;
    req.user.mfaPendingSecretExpiresAt = null;
    req.user.mfaRecoveryCodeHashes = recovery.hashes;
    req.user.mfaEnabledAt = new Date(now()).toISOString();
    req.user.mfaLastVerifiedAt = req.user.mfaEnabledAt;
    req.user.mfaGraceEndsAt = null;
    req.user.mfaVersion = Number(req.user.mfaVersion || 0) + 1;
    await saveUser(req.user);
    logEvent('mfa_enabled', 'User', { id: req.user.id }, req.user.username);
    await securityNotice(
      req.user,
      'Zwei-Faktor-Authentifizierung aktiviert',
      'Für Ihr MaterialKompass-Konto wurde die Zwei-Faktor-Authentifizierung aktiviert.',
    );
    return res.json({
      mfa: publicMfa(req.user),
      recoveryCodes: recovery.codes,
      token: createToken(req.user),
      expiresIn: 3600,
    });
  });

  app.post('/api/users/me/mfa/recovery-codes', authMiddleware, async (req, res) => {
    if (!await bcrypt.compare(req.body.currentPassword || '', req.user.passwordHash)) {
      return res.status(403).json({ error: 'Das aktuelle Passwort ist nicht korrekt.' });
    }
    const verification = await verifyUserCode(req.user, req.body.code);
    if (!verification.valid) return res.status(403).json({ error: 'Der 2-FA-Code ist ungültig.' });
    const recovery = createRecoveryCodes();
    req.user.mfaRecoveryCodeHashes = recovery.hashes;
    req.user.mfaVersion = Number(req.user.mfaVersion || 0) + 1;
    await saveUser(req.user);
    logEvent('mfa_recovery_codes_regenerated', 'User', { id: req.user.id }, req.user.username);
    await securityNotice(req.user, 'Neue Wiederherstellungscodes erstellt',
      'Für Ihr MaterialKompass-Konto wurden neue 2-FA-Wiederherstellungscodes erstellt.');
    return res.json({
      recoveryCodes: recovery.codes,
      mfa: publicMfa(req.user),
      token: createToken(req.user),
      expiresIn: 3600,
    });
  });

  app.post('/api/users/me/mfa/disable', authMiddleware, async (req, res) => {
    if (req.user.mfaRequired && Number(req.user.passkeyCount || 0) === 0
        && Number(req.user.pushMfaDeviceCount || 0) === 0) {
      return res.status(409).json({
        error: 'Für dieses Konto ist eine starke Anmeldung verpflichtend. Richten Sie vor dem Deaktivieren einen anderen Faktor ein.',
      });
    }
    if (!await bcrypt.compare(req.body.currentPassword || '', req.user.passwordHash)) {
      return res.status(403).json({ error: 'Das aktuelle Passwort ist nicht korrekt.' });
    }
    const verification = await verifyUserCode(req.user, req.body.code);
    if (!verification.valid) return res.status(403).json({ error: 'Der 2-FA-Code ist ungültig.' });
    req.user.mfaSecretEncrypted = null;
    req.user.mfaPendingSecretEncrypted = null;
    req.user.mfaPendingSecretExpiresAt = null;
    req.user.mfaRecoveryCodeHashes = [];
    req.user.mfaEnabledAt = null;
    req.user.mfaLastVerifiedAt = null;
    req.user.mfaVersion = Number(req.user.mfaVersion || 0) + 1;
    await saveUser(req.user);
    logEvent('mfa_disabled', 'User', { id: req.user.id }, req.user.username);
    await securityNotice(req.user, 'Zwei-Faktor-Authentifizierung deaktiviert',
      'Für Ihr MaterialKompass-Konto wurde die Zwei-Faktor-Authentifizierung deaktiviert.');
    return res.json({
      mfa: publicMfa(req.user),
      token: createToken(req.user),
      expiresIn: 3600,
    });
  });

  app.put('/api/users/:id/mfa-policy', authMiddleware, requirePermission('users.write'), async (req, res) => {
    const user = users.find((entry) => entry.id === req.params.id);
    if (!user) return res.status(404).json({ error: 'Nutzer nicht gefunden.' });
    if (typeof req.body.required !== 'boolean') {
      return res.status(400).json({ error: 'Die 2-FA-Richtlinie ist ungültig.' });
    }
    user.mfaRequired = req.body.required;
    user.mfaGraceEndsAt = req.body.required && !strongAuthenticationEnabled(user)
      ? new Date(now() + ENROLLMENT_GRACE_DAYS * 86_400_000).toISOString()
      : null;
    user.mfaVersion = Number(user.mfaVersion || 0) + 1;
    await saveUser(user);
    logEvent('mfa_policy_updated', 'User', { id: user.id, required: user.mfaRequired }, req.user.username);
    await securityNotice(
      user,
      user.mfaRequired ? 'Starke Anmeldung wird verpflichtend' : 'Richtlinie für starke Anmeldung geändert',
      user.mfaRequired
        ? `Ein Administrator hat eine starke Anmeldung für Ihr MaterialKompass-Konto verpflichtend gemacht. Richten Sie bis ${user.mfaGraceEndsAt || 'zum Ende der Einrichtungsfrist'} einen Passkey oder 2-FA ein.`
        : 'Ein Administrator hat die starke Anmeldung für Ihr MaterialKompass-Konto auf freiwillig gesetzt.',
    );
    return res.json(publicMfa(user));
  });

  app.delete('/api/users/:id/mfa', authMiddleware, requirePermission('users.write'), async (req, res) => {
    const user = users.find((entry) => entry.id === req.params.id);
    if (!user) return res.status(404).json({ error: 'Nutzer nicht gefunden.' });
    if (!await bcrypt.compare(req.body.currentPassword || '', req.user.passwordHash)) {
      return res.status(403).json({ error: 'Das Admin-Passwort ist nicht korrekt.' });
    }
    if (mfaEnabled(req.user)) {
      const verification = await verifyUserCode(req.user, req.body.code);
      if (!verification.valid) {
        return res.status(403).json({ error: 'Der 2-FA-Code des Administrators ist ungültig.' });
      }
    }
    user.mfaSecretEncrypted = null;
    user.mfaPendingSecretEncrypted = null;
    user.mfaPendingSecretExpiresAt = null;
    user.mfaRecoveryCodeHashes = [];
    user.mfaEnabledAt = null;
    user.mfaLastVerifiedAt = null;
    await resetPushDevices(user.id);
    user.pushMfaDeviceCount = 0;
    user.mfaGraceEndsAt = user.mfaRequired && !strongAuthenticationEnabled(user)
      ? new Date(now() + ENROLLMENT_GRACE_DAYS * 86_400_000).toISOString()
      : null;
    user.mfaVersion = Number(user.mfaVersion || 0) + 1;
    await saveUser(user);
    logEvent('mfa_admin_reset', 'User', { id: user.id }, req.user.username);
    await securityNotice(user, 'Zwei-Faktor-Authentifizierung zurückgesetzt',
      'Ein Administrator hat die Zwei-Faktor-Authentifizierung Ihres MaterialKompass-Kontos zurückgesetzt.');
    return res.json(publicMfa(user));
  });

  return {
    cancelChallenge,
    completeChallenge,
    authenticationEnabled,
    enrollmentRequired: (user) => enrollmentRequired(user, now()),
    issueChallenge,
    idForChallengeToken,
    mfaEnabled,
    offlineMfaEligible: (user) => offlineMfaEligible(user, now()),
    pendingChallenge,
    refreshChallengeSecurityVersion,
    passkeyRequired: (user) => user?.mfaRequired === true
      && !authenticationEnabled(user) && Number(user?.passkeyCount || 0) > 0,
    publicMfa,
    strongAuthenticationEnabled,
    verifyUserCode,
  };
}

module.exports = {
  CHALLENGE_MAX_ATTEMPTS,
  CHALLENGE_TTL_MS,
  ENROLLMENT_GRACE_DAYS,
  OFFLINE_MFA_MAX_AGE_MS,
  authenticationEnabled,
  createUserMfa,
  enrollmentRequired,
  mfaEnabled,
  offlineMfaEligible,
  publicMfa,
  strongAuthenticationEnabled,
};
