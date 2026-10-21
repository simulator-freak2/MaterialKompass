'use strict';

const crypto = require('node:crypto');
const bcrypt = require('bcryptjs');

const APPROVAL_TTL_MS = 2 * 60 * 1000;
const PAIRING_TTL_MS = 5 * 60 * 1000;
const POLL_WAIT_MS = 25 * 1000;
const USER_PUSH_WINDOW_MS = 15 * 60 * 1000;
const USER_PUSH_MAX_REQUESTS = 5;
const MAX_APPROVALS = 10_000;
const MAX_PAIRINGS = 10_000;
const MAX_DEVICES_PER_USER = 5;
const MAX_DEVICE_NAME_LENGTH = 100;

function hashSecret(value) {
  return crypto.createHash('sha256').update(String(value || '')).digest();
}

function hashKey(value) {
  return hashSecret(value).toString('base64url');
}

function safeSecretEqual(value, expectedHash) {
  const actual = hashSecret(value);
  const expected = Buffer.isBuffer(expectedHash)
    ? expectedHash
    : Buffer.from(String(expectedHash || ''), 'base64url');
  return actual.length === expected.length && crypto.timingSafeEqual(actual, expected);
}

function publicDevice(device) {
  return {
    id: device.id,
    name: device.name,
    platform: device.platform,
    transport: 'self_hosted',
    createdAt: device.createdAt,
    lastUsedAt: device.lastUsedAt || null,
  };
}

function normalizeBaseUrl(value) {
  try {
    const parsed = new URL(String(value || ''));
    const localDevelopment = parsed.protocol === 'http:'
      && ['127.0.0.1', 'localhost', '::1'].includes(parsed.hostname);
    if (!(parsed.protocol === 'https:' || localDevelopment)
        || parsed.username || parsed.password || parsed.search || parsed.hash) return '';
    parsed.pathname = parsed.pathname.replace(/\/+$/, '');
    return parsed.toString().replace(/\/$/, '');
  } catch (_) {
    return '';
  }
}

function createMfaPush({
  app,
  users,
  devices,
  userMfa,
  authMiddleware,
  authRateLimit,
  statusRateLimit = authRateLimit,
  createToken,
  pushSender,
  appBaseUrl = process.env.APP_BASE_URL,
  saveUser = async () => {},
  saveDevice = async () => {},
  deleteDevice = async () => {},
  logEvent = () => {},
  now = Date.now,
}) {
  const approvals = new Map();
  const approvalByMfaChallenge = new Map();
  const pairings = new Map();
  const pairingByTokenHash = new Map();
  const waitersByDevice = new Map();
  const pushRequestsByUser = new Map();
  const delivery = pushSender || {
    configured: true,
    async sendApproval(targetDevices) {
      return { sent: targetDevices.length, invalidDeviceIds: [] };
    },
  };
  const pairingServerUrl = normalizeBaseUrl(appBaseUrl);

  function devicesFor(userId) {
    return devices.filter((entry) => entry.userId === userId);
  }

  function refreshUserCounts() {
    for (const user of users) user.pushMfaDeviceCount = devicesFor(user.id).length;
  }
  refreshUserCounts();

  function removePairing(pairing) {
    pairings.delete(pairing.id);
    pairingByTokenHash.delete(pairing.pairTokenHash);
  }

  function cleanState() {
    const timestamp = now();
    for (const [id, approval] of approvals) {
      if (approval.expiresAtMs <= timestamp) {
        approvals.delete(id);
        approvalByMfaChallenge.delete(approval.mfaChallengeId);
      }
    }
    for (const pairing of pairings.values()) {
      if (pairing.expiresAtMs <= timestamp) removePairing(pairing);
    }
    for (const [userId, entry] of pushRequestsByUser) {
      if (entry.resetAt <= timestamp) pushRequestsByUser.delete(userId);
    }
  }

  function reserveUserPush(userId) {
    const timestamp = now();
    let entry = pushRequestsByUser.get(userId);
    if (!entry || entry.resetAt <= timestamp) {
      entry = { count: 0, resetAt: timestamp + USER_PUSH_WINDOW_MS };
    }
    if (entry.count >= USER_PUSH_MAX_REQUESTS) return false;
    entry.count += 1;
    pushRequestsByUser.set(userId, entry);
    return true;
  }

  async function removeInvalidDevices(ids) {
    for (const id of ids) {
      const index = devices.findIndex((entry) => entry.id === id);
      if (index < 0) continue;
      const [device] = devices.splice(index, 1);
      const waiter = waitersByDevice.get(device.id);
      if (waiter) waiter.finish(null);
      await deleteDevice(device.id);
      const user = users.find((entry) => entry.id === device.userId);
      if (user) user.pushMfaDeviceCount = devicesFor(user.id).length;
    }
  }

  function authenticateDevice(body) {
    const device = devices.find((entry) => entry.id === body?.deviceId);
    if (!device || !safeSecretEqual(body?.deviceSecret, device.secretHash)) return null;
    return device;
  }

  function pendingApprovalFor(userId) {
    return [...approvals.values()]
      .filter((entry) => entry.userId === userId && entry.status === 'pending'
        && entry.expiresAtMs > now())
      .sort((left, right) => right.requestedAtMs - left.requestedAtMs)[0] || null;
  }

  function approvalPayload(approval) {
    return {
      approvalId: approval.id,
      expiresAt: approval.expiresAt,
      requestedAt: approval.requestedAt,
      matchingCode: approval.matchingCode,
      client: approval.client,
      sourceIp: approval.sourceIp,
    };
  }

  function notifyWaiters(userId) {
    const approval = pendingApprovalFor(userId);
    if (!approval) return;
    for (const device of devicesFor(userId)) {
      const waiter = waitersByDevice.get(device.id);
      if (waiter) waiter.finish(approval);
    }
  }

  async function requireFreshAccountProof(req, res) {
    if (!await bcrypt.compare(String(req.body.currentPassword || ''), req.user.passwordHash)) {
      res.status(403).json({ error: 'Die erneute Authentifizierung ist fehlgeschlagen.' });
      return false;
    }
    if (userMfa.mfaEnabled(req.user)) {
      const verification = await userMfa.verifyUserCode(req.user, req.body.code);
      if (!verification.valid) {
        res.status(403).json({ error: 'Die erneute Authentifizierung ist fehlgeschlagen.' });
        return false;
      }
    }
    return true;
  }

  async function registerDevice(user, { name, platform }) {
    if (devicesFor(user.id).length >= MAX_DEVICES_PER_USER) {
      const error = new Error('Die maximale Anzahl von Push-Geräten ist erreicht.');
      error.status = 409;
      throw error;
    }
    const normalizedName = String(name || '').trim();
    const normalizedPlatform = String(platform || '').toLowerCase();
    if (!normalizedName || normalizedName.length > MAX_DEVICE_NAME_LENGTH) {
      const error = new Error('Der Gerätename ist ungültig.');
      error.status = 400;
      throw error;
    }
    if (!['android', 'web'].includes(normalizedPlatform)) {
      const error = new Error('Diese Plattform unterstützt Push-2-FA nicht.');
      error.status = 400;
      throw error;
    }
    const secret = crypto.randomBytes(32).toString('base64url');
    const device = {
      id: crypto.randomUUID(),
      userId: user.id,
      name: normalizedName,
      platform: normalizedPlatform,
      pushToken: 'self-hosted-long-poll',
      secretHash: hashKey(secret),
      createdAt: new Date(now()).toISOString(),
      lastUsedAt: null,
    };
    devices.push(device);
    user.pushMfaDeviceCount = devicesFor(user.id).length;
    user.mfaVersion = Number(user.mfaVersion || 0) + 1;
    await saveDevice(device);
    await saveUser(user);
    logEvent('mfa_push_device_registered', 'User', {
      id: user.id, deviceId: device.id, transport: 'self_hosted',
    }, user.username);
    return { device, secret };
  }

  app.get('/api/users/me/mfa/push-devices', authMiddleware, (req, res) => {
    res.json(devicesFor(req.user.id).map(publicDevice));
  });

  // Compatibility route for older clients. New clients use the one-time QR pairing below.
  app.post('/api/users/me/mfa/push-devices', authMiddleware, authRateLimit, async (req, res) => {
    if (!await requireFreshAccountProof(req, res)) return undefined;
    try {
      const registered = await registerDevice(req.user, req.body);
      return res.status(201).json({
        device: publicDevice(registered.device),
        deviceSecret: registered.secret,
        token: createToken(req.user),
        expiresIn: 3600,
      });
    } catch (error) {
      return res.status(error.status || 500).json({ error: error.message });
    }
  });

  app.post('/api/users/me/mfa/push-pairings', authMiddleware, authRateLimit, async (req, res) => {
    if (!pairingServerUrl) {
      return res.status(503).json({ error: 'APP_BASE_URL ist für die Geräte-Kopplung nicht konfiguriert.' });
    }
    if (!await requireFreshAccountProof(req, res)) return undefined;
    cleanState();
    while (pairings.size >= MAX_PAIRINGS) removePairing(pairings.values().next().value);
    const pairToken = crypto.randomBytes(32).toString('base64url');
    const statusToken = crypto.randomBytes(32).toString('base64url');
    const id = crypto.randomUUID();
    const expiresAtMs = now() + PAIRING_TTL_MS;
    const pairing = {
      id,
      userId: req.user.id,
      pairTokenHash: hashKey(pairToken),
      statusTokenHash: hashKey(statusToken),
      status: 'pending',
      expiresAtMs,
      expiresAt: new Date(expiresAtMs).toISOString(),
    };
    pairings.set(id, pairing);
    pairingByTokenHash.set(pairing.pairTokenHash, pairing);
    const qrValue = new URL('materialkompass-auth://pair');
    qrValue.searchParams.set('server', pairingServerUrl);
    qrValue.searchParams.set('token', pairToken);
    return res.status(201).json({
      pairingId: id,
      statusToken,
      qrValue: qrValue.toString(),
      expiresAt: pairing.expiresAt,
    });
  });

  app.post('/api/auth/mfa/push/pair', authRateLimit, async (req, res) => {
    cleanState();
    const pairing = pairingByTokenHash.get(hashKey(req.body.pairToken));
    if (!pairing || pairing.status !== 'pending' || pairing.expiresAtMs <= now()) {
      return res.status(401).json({ error: 'Der Kopplungscode ist ungültig oder abgelaufen.' });
    }
    const user = users.find((entry) => entry.id === pairing.userId && entry.active);
    if (!user) {
      removePairing(pairing);
      return res.status(401).json({ error: 'Das zugehörige Konto ist nicht verfügbar.' });
    }
    try {
      const registered = await registerDevice(user, req.body);
      pairing.status = 'completed';
      pairing.deviceId = registered.device.id;
      pairingByTokenHash.delete(pairing.pairTokenHash);
      return res.status(201).json({
        serverUrl: pairingServerUrl,
        account: user.username,
        device: publicDevice(registered.device),
        deviceSecret: registered.secret,
      });
    } catch (error) {
      return res.status(error.status || 500).json({ error: error.message });
    }
  });

  app.post('/api/auth/mfa/push/pairing-status', statusRateLimit, (req, res) => {
    cleanState();
    const pairing = pairings.get(String(req.body.pairingId || ''));
    if (!pairing || !safeSecretEqual(req.body.statusToken, pairing.statusTokenHash)) {
      return res.status(401).json({ error: 'Die Kopplungsabfrage ist ungültig oder abgelaufen.' });
    }
    if (pairing.status === 'pending') return res.status(202).json({ status: 'pending' });
    const user = users.find((entry) => entry.id === pairing.userId && entry.active);
    const device = devices.find((entry) => entry.id === pairing.deviceId);
    removePairing(pairing);
    if (!user || !device) {
      return res.status(410).json({ error: 'Die Gerätekopplung ist nicht mehr verfügbar.' });
    }
    return res.json({
      status: 'completed',
      token: createToken(user),
      expiresIn: 3600,
      device: publicDevice(device),
    });
  });

  app.delete('/api/users/me/mfa/push-devices/:id', authMiddleware, authRateLimit, async (req, res) => {
    const index = devices.findIndex((entry) => entry.id === req.params.id
      && entry.userId === req.user.id);
    if (index < 0) return res.status(404).json({ error: 'Push-Gerät nicht gefunden.' });
    if (!await requireFreshAccountProof(req, res)) return undefined;
    const remaining = devicesFor(req.user.id).length - 1;
    if (req.user.mfaRequired && remaining === 0 && !userMfa.mfaEnabled(req.user)
        && Number(req.user.passkeyCount || 0) === 0) {
      return res.status(409).json({
        error: 'Für dieses Konto ist eine starke Anmeldung verpflichtend. Richten Sie zuerst einen anderen Faktor ein.',
      });
    }
    const [device] = devices.splice(index, 1);
    const waiter = waitersByDevice.get(device.id);
    if (waiter) waiter.finish(null);
    await deleteDevice(device.id);
    req.user.pushMfaDeviceCount = remaining;
    req.user.mfaVersion = Number(req.user.mfaVersion || 0) + 1;
    await saveUser(req.user);
    logEvent('mfa_push_device_revoked', 'User', {
      id: req.user.id, deviceId: device.id,
    }, req.user.username);
    return res.status(204).end();
  });

  app.put('/api/auth/mfa/push-device-token', authRateLimit, (req, res) => {
    if (!authenticateDevice(req.body)) {
      return res.status(401).json({ error: 'Das Push-Gerät ist ungültig.' });
    }
    return res.status(204).end();
  });

  app.post('/api/auth/mfa/push/pending', statusRateLimit, async (req, res) => {
    cleanState();
    const device = authenticateDevice(req.body);
    if (!device) return res.status(401).json({ error: 'Das Push-Gerät ist ungültig.' });
    const current = pendingApprovalFor(device.userId);
    if (current) return res.json(approvalPayload(current));

    const previous = waitersByDevice.get(device.id);
    if (previous) previous.finish(null);
    const approval = await new Promise((resolve) => {
      let completed = false;
      const finish = (value) => {
        if (completed) return;
        completed = true;
        clearTimeout(timer);
        if (waitersByDevice.get(device.id)?.finish === finish) waitersByDevice.delete(device.id);
        resolve(value);
      };
      const timer = setTimeout(() => finish(null), POLL_WAIT_MS);
      waitersByDevice.set(device.id, { finish });
      req.on('aborted', () => finish(null));
      res.on('close', () => finish(null));
    });
    if (res.headersSent || res.destroyed) return undefined;
    return approval ? res.json(approvalPayload(approval)) : res.status(204).end();
  });

  app.post('/api/auth/mfa/push/start', authRateLimit, async (req, res) => {
    const pending = userMfa.pendingChallenge(req.body.challenge);
    if (!pending) return res.status(401).json({ error: 'Die 2-FA-Anfrage ist ungültig oder abgelaufen.' });
    const userDevices = devicesFor(pending.user.id);
    if (!delivery?.configured || userDevices.length === 0) {
      return res.status(409).json({ error: 'Für dieses Konto ist kein Push-Gerät verfügbar.' });
    }
    cleanState();
    const existingId = approvalByMfaChallenge.get(pending.id);
    if (existingId && approvals.has(existingId)) {
      const existing = approvals.get(existingId);
      return res.json({
        approvalId: existing.id,
        expiresAt: existing.expiresAt,
        matchingCode: existing.matchingCode,
      });
    }
    if (!reserveUserPush(pending.user.id)) {
      return res.status(429).json({
        error: 'Zu viele Push-Anfragen für dieses Konto. Bitte später erneut versuchen.',
      });
    }
    while (approvals.size >= MAX_APPROVALS) {
      const oldestId = approvals.keys().next().value;
      const oldest = approvals.get(oldestId);
      approvals.delete(oldestId);
      if (oldest) approvalByMfaChallenge.delete(oldest.mfaChallengeId);
    }
    const id = crypto.randomUUID();
    const requestedAtMs = now();
    const expiresAtMs = Math.min(pending.challenge.expiresAt, requestedAtMs + APPROVAL_TTL_MS);
    const approval = {
      id,
      userId: pending.user.id,
      mfaChallengeId: pending.id,
      status: 'pending',
      requestedAtMs,
      requestedAt: new Date(requestedAtMs).toISOString(),
      expiresAtMs,
      expiresAt: new Date(expiresAtMs).toISOString(),
      matchingCode: String(crypto.randomInt(0, 100)).padStart(2, '0'),
      client: String(req.get('user-agent') || 'Unbekannter Client').slice(0, 120),
      sourceIp: String(req.ip || '').slice(0, 64),
    };
    approvals.set(id, approval);
    approvalByMfaChallenge.set(pending.id, id);
    let transportResult;
    try {
      transportResult = await delivery.sendApproval(userDevices, approval);
    } catch (error) {
      approvals.delete(id);
      approvalByMfaChallenge.delete(pending.id);
      logEvent('mfa_push_delivery_failed', 'User', {
        id: pending.user.id, error: error.message,
      }, pending.user.username);
      return res.status(503).json({ error: 'Die Push-Benachrichtigung konnte nicht zugestellt werden.' });
    }
    const invalidDeviceIds = transportResult.invalidDeviceIds || [];
    await removeInvalidDevices(invalidDeviceIds);
    if (invalidDeviceIds.length > 0) userMfa.refreshChallengeSecurityVersion(pending.id, pending.user);
    if (!transportResult.sent) {
      approvals.delete(id);
      approvalByMfaChallenge.delete(pending.id);
      return res.status(503).json({ error: 'Die Push-Benachrichtigung konnte nicht zugestellt werden.' });
    }
    notifyWaiters(pending.user.id);
    logEvent('mfa_push_sent', 'User', { id: pending.user.id }, pending.user.username);
    return res.json({
      approvalId: id,
      expiresAt: approval.expiresAt,
      matchingCode: approval.matchingCode,
    });
  });

  app.post('/api/auth/mfa/push/respond', authRateLimit, async (req, res) => {
    cleanState();
    const approval = approvals.get(String(req.body.approvalId || ''));
    const device = authenticateDevice(req.body);
    const decision = req.body.decision;
    if (!approval || !device || device.userId !== approval.userId
        || !['approve', 'deny'].includes(decision)
        || (decision === 'approve' && String(req.body.matchingCode || '') !== approval.matchingCode)) {
      return res.status(401).json({ error: 'Die Push-Freigabe ist ungültig oder abgelaufen.' });
    }
    if (approval.status !== 'pending') {
      return res.status(409).json({ error: 'Die Push-Freigabe wurde bereits beantwortet.' });
    }
    approval.status = decision === 'approve' ? 'approved' : 'denied';
    approval.respondedBy = device.id;
    if (approval.status === 'denied') userMfa.cancelChallenge(approval.mfaChallengeId);
    device.lastUsedAt = new Date(now()).toISOString();
    await saveDevice(device);
    logEvent(`mfa_push_${approval.status}`, 'User', {
      id: approval.userId, deviceId: device.id,
    }, users.find((entry) => entry.id === approval.userId)?.username);
    return res.status(204).end();
  });

  app.post('/api/auth/mfa/push/status', statusRateLimit, async (req, res) => {
    cleanState();
    const approval = approvals.get(String(req.body.approvalId || ''));
    if (approval?.status === 'denied'
        && userMfa.idForChallengeToken(req.body.challenge) === approval.mfaChallengeId) {
      approvals.delete(approval.id);
      approvalByMfaChallenge.delete(approval.mfaChallengeId);
      return res.status(403).json({ error: 'Die Anmeldung wurde auf dem Push-Gerät abgelehnt.' });
    }
    const pending = userMfa.pendingChallenge(req.body.challenge);
    if (!pending || !approval || approval.userId !== pending.user.id
        || approval.mfaChallengeId !== pending.id) {
      return res.status(401).json({ error: 'Die Push-Freigabe ist ungültig oder abgelaufen.' });
    }
    if (approval.status === 'pending') return res.status(202).json({ status: 'pending' });
    approvals.delete(approval.id);
    approvalByMfaChallenge.delete(approval.mfaChallengeId);
    return userMfa.completeChallenge(pending.id, pending.user, res, {
      valid: true,
      recovery: false,
      method: 'push',
    }, req);
  });

  return {
    devicesFor,
    refreshUserCounts,
    async removeUser(userId) {
      const removedIds = [];
      for (let index = devices.length - 1; index >= 0; index -= 1) {
        if (devices[index].userId === userId) {
          removedIds.push(devices[index].id);
          const waiter = waitersByDevice.get(devices[index].id);
          if (waiter) waiter.finish(null);
          devices.splice(index, 1);
        }
      }
      await Promise.all(removedIds.map((id) => deleteDevice(id)));
      const user = users.find((entry) => entry.id === userId);
      if (user) user.pushMfaDeviceCount = 0;
    },
  };
}

module.exports = {
  APPROVAL_TTL_MS,
  MAX_DEVICES_PER_USER,
  PAIRING_TTL_MS,
  USER_PUSH_MAX_REQUESTS,
  createMfaPush,
};
