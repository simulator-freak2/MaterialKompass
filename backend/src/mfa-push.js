'use strict';

const crypto = require('node:crypto');
const bcrypt = require('bcryptjs');

const APPROVAL_TTL_MS = 2 * 60 * 1000;
const USER_PUSH_WINDOW_MS = 15 * 60 * 1000;
const USER_PUSH_MAX_REQUESTS = 5;
const MAX_APPROVALS = 10_000;
const MAX_DEVICES_PER_USER = 5;
const MAX_DEVICE_NAME_LENGTH = 100;
const MAX_PUSH_TOKEN_LENGTH = 4096;

function hashSecret(value) {
  return crypto.createHash('sha256').update(String(value || '')).digest();
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
    createdAt: device.createdAt,
    lastUsedAt: device.lastUsedAt || null,
  };
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
  saveUser = async () => {},
  saveDevice = async () => {},
  deleteDevice = async () => {},
  logEvent = () => {},
  now = Date.now,
}) {
  const approvals = new Map();
  const approvalByMfaChallenge = new Map();
  const pushRequestsByUser = new Map();

  function devicesFor(userId) {
    return devices.filter((entry) => entry.userId === userId);
  }

  function refreshUserCounts() {
    for (const user of users) user.pushMfaDeviceCount = devicesFor(user.id).length;
  }
  refreshUserCounts();

  function cleanApprovals() {
    const timestamp = now();
    for (const [id, approval] of approvals) {
      if (approval.expiresAtMs <= timestamp) {
        approvals.delete(id);
        approvalByMfaChallenge.delete(approval.mfaChallengeId);
      }
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
      await deleteDevice(device.id);
      const user = users.find((entry) => entry.id === device.userId);
      if (user) user.pushMfaDeviceCount = devicesFor(user.id).length;
    }
  }

  app.get('/api/users/me/mfa/push-devices', authMiddleware, (req, res) => {
    res.json(devicesFor(req.user.id).map(publicDevice));
  });

  app.post('/api/users/me/mfa/push-devices', authMiddleware, authRateLimit, async (req, res) => {
    if (!pushSender?.configured) {
      return res.status(503).json({ error: 'Push-2-FA ist auf dem Server noch nicht konfiguriert.' });
    }
    if (!await bcrypt.compare(String(req.body.currentPassword || ''), req.user.passwordHash)) {
      return res.status(403).json({ error: 'Die erneute Authentifizierung ist fehlgeschlagen.' });
    }
    if (userMfa.mfaEnabled(req.user)) {
      const verification = await userMfa.verifyUserCode(req.user, req.body.code);
      if (!verification.valid) {
        return res.status(403).json({ error: 'Die erneute Authentifizierung ist fehlgeschlagen.' });
      }
    }
    if (devicesFor(req.user.id).length >= MAX_DEVICES_PER_USER) {
      return res.status(409).json({ error: 'Die maximale Anzahl von Push-Geräten ist erreicht.' });
    }
    const name = String(req.body.name || '').trim();
    const platform = String(req.body.platform || '').toLowerCase();
    const pushToken = String(req.body.pushToken || '');
    if (!name || name.length > MAX_DEVICE_NAME_LENGTH) {
      return res.status(400).json({ error: 'Der Gerätename ist ungültig.' });
    }
    if (!['android', 'ios', 'macos'].includes(platform)) {
      return res.status(400).json({ error: 'Diese Plattform unterstützt Push-2-FA nicht.' });
    }
    if (!pushToken || pushToken.length > MAX_PUSH_TOKEN_LENGTH) {
      return res.status(400).json({ error: 'Das Push-Token ist ungültig.' });
    }
    const secret = crypto.randomBytes(32).toString('base64url');
    const device = {
      id: crypto.randomUUID(),
      userId: req.user.id,
      name,
      platform,
      pushToken,
      secretHash: hashSecret(secret).toString('base64url'),
      createdAt: new Date(now()).toISOString(),
      lastUsedAt: null,
    };
    devices.push(device);
    req.user.pushMfaDeviceCount = devicesFor(req.user.id).length;
    req.user.mfaVersion = Number(req.user.mfaVersion || 0) + 1;
    await saveDevice(device);
    await saveUser(req.user);
    logEvent('mfa_push_device_registered', 'User', {
      id: req.user.id, deviceId: device.id,
    }, req.user.username);
    return res.status(201).json({
      device: publicDevice(device),
      deviceSecret: secret,
      token: createToken(req.user),
      expiresIn: 3600,
    });
  });

  app.delete('/api/users/me/mfa/push-devices/:id', authMiddleware, authRateLimit, async (req, res) => {
    const index = devices.findIndex((entry) => entry.id === req.params.id
      && entry.userId === req.user.id);
    if (index < 0) return res.status(404).json({ error: 'Push-Gerät nicht gefunden.' });
    if (!await bcrypt.compare(String(req.body.currentPassword || ''), req.user.passwordHash)) {
      return res.status(403).json({ error: 'Die erneute Authentifizierung ist fehlgeschlagen.' });
    }
    if (userMfa.mfaEnabled(req.user)) {
      const verification = await userMfa.verifyUserCode(req.user, req.body.code);
      if (!verification.valid) {
        return res.status(403).json({ error: 'Die erneute Authentifizierung ist fehlgeschlagen.' });
      }
    }
    const remaining = devicesFor(req.user.id).length - 1;
    if (req.user.mfaRequired && remaining === 0 && !userMfa.mfaEnabled(req.user)
        && Number(req.user.passkeyCount || 0) === 0) {
      return res.status(409).json({
        error: 'Für dieses Konto ist eine starke Anmeldung verpflichtend. Richten Sie zuerst einen anderen Faktor ein.',
      });
    }
    const [device] = devices.splice(index, 1);
    await deleteDevice(device.id);
    req.user.pushMfaDeviceCount = remaining;
    req.user.mfaVersion = Number(req.user.mfaVersion || 0) + 1;
    await saveUser(req.user);
    logEvent('mfa_push_device_revoked', 'User', {
      id: req.user.id, deviceId: device.id,
    }, req.user.username);
    return res.status(204).end();
  });

  app.put('/api/auth/mfa/push-device-token', authRateLimit, async (req, res) => {
    const device = devices.find((entry) => entry.id === req.body.deviceId);
    const pushToken = String(req.body.pushToken || '');
    if (!device || !safeSecretEqual(req.body.deviceSecret, device.secretHash)
        || !pushToken || pushToken.length > MAX_PUSH_TOKEN_LENGTH) {
      return res.status(401).json({ error: 'Das Push-Gerät ist ungültig.' });
    }
    device.pushToken = pushToken;
    await saveDevice(device);
    return res.status(204).end();
  });

  app.post('/api/auth/mfa/push/start', authRateLimit, async (req, res) => {
    const pending = userMfa.pendingChallenge(req.body.challenge);
    if (!pending) return res.status(401).json({ error: 'Die 2-FA-Anfrage ist ungültig oder abgelaufen.' });
    const userDevices = devicesFor(pending.user.id);
    if (!pushSender?.configured || userDevices.length === 0) {
      return res.status(409).json({ error: 'Für dieses Konto ist kein Push-Gerät verfügbar.' });
    }
    cleanApprovals();
    const existingId = approvalByMfaChallenge.get(pending.id);
    if (existingId && approvals.has(existingId)) {
      const existing = approvals.get(existingId);
      return res.json({ approvalId: existing.id, expiresAt: existing.expiresAt });
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
    const expiresAtMs = Math.min(pending.challenge.expiresAt, now() + APPROVAL_TTL_MS);
    const approval = {
      id,
      userId: pending.user.id,
      mfaChallengeId: pending.id,
      status: 'pending',
      expiresAtMs,
      expiresAt: new Date(expiresAtMs).toISOString(),
    };
    approvals.set(id, approval);
    approvalByMfaChallenge.set(pending.id, id);
    let delivery;
    try {
      delivery = await pushSender.sendApproval(userDevices, approval);
    } catch (error) {
      approvals.delete(id);
      approvalByMfaChallenge.delete(pending.id);
      logEvent('mfa_push_delivery_failed', 'User', {
        id: pending.user.id, error: error.message,
      }, pending.user.username);
      return res.status(503).json({ error: 'Die Push-Benachrichtigung konnte nicht zugestellt werden.' });
    }
    const invalidDeviceIds = delivery.invalidDeviceIds || [];
    await removeInvalidDevices(invalidDeviceIds);
    if (invalidDeviceIds.length > 0) {
      userMfa.refreshChallengeSecurityVersion(pending.id, pending.user);
    }
    if (!delivery.sent) {
      approvals.delete(id);
      approvalByMfaChallenge.delete(pending.id);
      return res.status(503).json({ error: 'Die Push-Benachrichtigung konnte nicht zugestellt werden.' });
    }
    logEvent('mfa_push_sent', 'User', { id: pending.user.id }, pending.user.username);
    return res.json({ approvalId: id, expiresAt: approval.expiresAt });
  });

  app.post('/api/auth/mfa/push/respond', authRateLimit, async (req, res) => {
    cleanApprovals();
    const approval = approvals.get(String(req.body.approvalId || ''));
    const device = devices.find((entry) => entry.id === req.body.deviceId);
    const decision = req.body.decision;
    if (!approval || !device || device.userId !== approval.userId
        || !safeSecretEqual(req.body.deviceSecret, device.secretHash)
        || !['approve', 'deny'].includes(decision)) {
      return res.status(401).json({ error: 'Die Push-Freigabe ist ungültig oder abgelaufen.' });
    }
    if (approval.status !== 'pending') {
      return res.status(409).json({ error: 'Die Push-Freigabe wurde bereits beantwortet.' });
    }
    approval.status = decision === 'approve' ? 'approved' : 'denied';
    approval.respondedBy = device.id;
    if (approval.status === 'denied') {
      userMfa.cancelChallenge(approval.mfaChallengeId);
    }
    device.lastUsedAt = new Date(now()).toISOString();
    await saveDevice(device);
    logEvent(`mfa_push_${approval.status}`, 'User', {
      id: approval.userId, deviceId: device.id,
    }, users.find((entry) => entry.id === approval.userId)?.username);
    return res.status(204).end();
  });

  app.post('/api/auth/mfa/push/status', statusRateLimit, async (req, res) => {
    cleanApprovals();
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
  USER_PUSH_MAX_REQUESTS,
  createMfaPush,
};
