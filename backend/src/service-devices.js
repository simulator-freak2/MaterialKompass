const crypto = require('node:crypto');
const bcrypt = require('bcryptjs');
const {
  base32Encode,
  hash,
  ipAllowed,
  normalize,
  passwordIsValid,
  safeHashEqual,
  validNetworkRule,
  verifyTotp,
} = require('./service-device-security');

const DEVICE_SESSION = 'service_device_system';
const PERSONAL_DEVICE_SESSION = 'service_device_personal';
const SYSTEM_TOKEN_TTL_SECONDS = 5 * 60;
const LOGIN_MAX_ATTEMPTS = 5;
const LOCK_MS = 15 * 60 * 1000;
const QR_PREFIX = 'mkdevice:v1:';
const OFFLINE_QR_PREFIX = 'mkoffline:v1:';
const OFFLINE_LEASE_MS = 7 * 24 * 60 * 60 * 1000;
const DUMMY_PASSWORD_HASH = '$2a$12$tEwsha9iOj5Uyyv0aMD6Xu.E4qatRuDZsHCHJPpisY/SuIk8qs52.';
const NATIVE_CLIENT_PLATFORMS = new Set([
  'android', 'ios', 'windows', 'linux', 'macos',
]);

function publicDevice(device) {
  const {
    credentialHash, systemPasswordHash, activationBypassHash,
    loginCredentials, secondFactors, personalNfcCredentials, offlineQrCredentials, ...safe
  } = device;
  return {
    ...safe,
    activated: Boolean(credentialHash),
    systemPasswordConfigured: Boolean(systemPasswordHash),
    qrCredentials: (loginCredentials || []).filter((entry) => entry.type === 'qr').map(({ credentialHash: _, ...entry }) => entry),
    nfcFactors: (secondFactors || []).filter((entry) => entry.type === 'nfc').map(({ credentialHash: _, ...entry }) => entry),
    totpFactors: (secondFactors || []).filter((entry) => entry.type === 'totp').map(({ secretEncrypted: _, ...entry }) => entry),
    personalNfcCredentials: (personalNfcCredentials || []).map(({ credentialHash: _, ...entry }) => entry),
    offlineQrCredentials: (offlineQrCredentials || []).map(({ credentialHash: _, ...entry }) => entry),
  };
}

function registerServiceDeviceRoutes({
  app, devices, users, departments, locations, stockStructures, categories,
  materials, clothingItems, materialDocuments, authMiddleware, requirePermission,
  authRateLimit, createToken, findUser, publicUser, logEvent, defectManagement,
  jwtSecret, qrLoginCredentials = [], securityVersion,
  saveUser = async () => {},
  userMfa,
}) {
  const encryptionKey = crypto.createHash('sha256').update(jwtSecret).digest();
  const nextId = (prefix) => `${prefix}-${crypto.randomUUID()}`;
  const nowIso = () => new Date().toISOString();

  devices.forEach((device) => {
    device.securityVersion ||= 1;
    device.loginCredentials ||= [];
    device.secondFactors ||= [];
    device.personalNfcCredentials ||= [];
    device.offlineQrCredentials ||= [];
    device.allowedDepartmentIds ||= [];
    device.allowedNetworks ||= [];
    device.allowedOfflineUserIds ||= [];
    device.offlineEnabled ??= false;
    device.systemMfa ||= 'off';
    device.personalMfa ||= 'off';
  });
  const devicesById = new Map(devices.map((device) => [device.id, device]));
  const devicesByCredentialHash = new Map(
    devices
      .filter((device) => device.credentialHash)
      .map((device) => [device.credentialHash, device]),
  );

  function encrypt(value) {
    const iv = crypto.randomBytes(12);
    const cipher = crypto.createCipheriv('aes-256-gcm', encryptionKey, iv);
    const body = Buffer.concat([cipher.update(String(value), 'utf8'), cipher.final()]);
    return `${iv.toString('base64url')}.${cipher.getAuthTag().toString('base64url')}.${body.toString('base64url')}`;
  }

  function decrypt(value) {
    try {
      const [iv, tag, body] = String(value).split('.').map((part) => Buffer.from(part, 'base64url'));
      const decipher = crypto.createDecipheriv('aes-256-gcm', encryptionKey, iv);
      decipher.setAuthTag(tag);
      return Buffer.concat([decipher.update(body), decipher.final()]).toString('utf8');
    } catch (_) { return ''; }
  }

  function findDevice(id) {
    return devicesById.get(String(id || ''));
  }

  function findActivatedDevice(credential) {
    const value = String(credential || '');
    if (!value) return null;
    return devicesByCredentialHash.get(hash(value)) || null;
  }

  function replaceDeviceCredential(device, credential = null) {
    if (device.credentialHash) {
      devicesByCredentialHash.delete(device.credentialHash);
    }
    device.credentialHash = credential ? hash(credential) : null;
    if (device.credentialHash) {
      devicesByCredentialHash.set(device.credentialHash, device);
    }
  }
  function isAdmin(user) {
    return user?.active && user.emailVerifiedAt && user.roles?.includes('Admin');
  }

  async function authenticateAdmin(identifier, password) {
    const user = findUser(identifier);
    const supplied = typeof password === 'string' ? password : '';
    const withinBcryptLimit = Buffer.byteLength(supplied, 'utf8') <= 72;
    const passwordMatches = await bcrypt.compare(
      withinBcryptLimit ? supplied : '',
      withinBcryptLimit && user?.passwordHash
        ? user.passwordHash
        : DUMMY_PASSWORD_HASH,
    );
    return withinBcryptLimit && passwordMatches && isAdmin(user) ? user : null;
  }
  function clientIp(req) { return String(req.ip || req.socket?.remoteAddress || '').replace(/^::ffff:/, ''); }
  function updateClientInfo(device, req) {
    device.lastSeenAt = nowIso();
    device.lastClientPlatform = String(req.body?.clientPlatform || req.get('X-Client-Platform') || device.lastClientPlatform || '').slice(0, 80);
    device.lastClientVersion = String(req.body?.clientVersion || req.get('X-Client-Version') || device.lastClientVersion || '').slice(0, 80);
  }

  function validateDeviceBody(body, existing = {}) {
    const name = String(body.name ?? existing.name ?? '').trim();
    const locationId = String(body.locationId ?? existing.locationId ?? '').trim();
    const location = locations.find((entry) => entry.id === locationId);
    const inventoryNumber = String(body.inventoryNumber ?? existing.inventoryNumber ?? '').trim();
    const macAddress = String(body.macAddress ?? existing.macAddress ?? '').trim().toUpperCase();
    const room = String(body.room ?? existing.room ?? '').trim();
    const responsibleUserId = String(
      body.responsibleUserId ?? existing.responsibleUserId ?? '',
    ).trim();
    const allowedDepartmentIds = Array.isArray(body.allowedDepartmentIds)
      ? [...new Set(body.allowedDepartmentIds.map(String))] : (existing.allowedDepartmentIds || []);
    const allowedNetworks = Array.isArray(body.allowedNetworks)
      ? [...new Set(body.allowedNetworks.map((entry) => String(entry).trim()).filter(Boolean))]
      : (existing.allowedNetworks || []);
    const allowedOfflineUserIds = Array.isArray(body.allowedOfflineUserIds)
      ? [...new Set(body.allowedOfflineUserIds.map(String))]
      : (existing.allowedOfflineUserIds || []);
    const validMfaModes = ['off', 'totp', 'nfc'];
    if (!name || !location || !inventoryNumber) return { error: 'Name, Standort und Inventarnummer sind erforderlich.' };
    if (name.length > 255 || inventoryNumber.length > 128 || room.length > 255) {
      return { error: 'Name, Inventarnummer oder Raum ist zu lang.' };
    }
    if (macAddress && !/^([0-9A-F]{2}[:-]){5}[0-9A-F]{2}$/.test(macAddress)) return { error: 'Die MAC-Adresse ist ungültig.' };
    if (devices.some((entry) => entry.id !== existing.id && entry.inventoryNumber === inventoryNumber)) return { error: 'Die Geräte-Inventarnummer ist bereits vergeben.' };
    if (allowedDepartmentIds.some((id) => !departments.some((entry) => entry.id === id))) return { error: 'Ein Fachbereich ist ungültig.' };
    if (allowedNetworks.some((entry) => !validNetworkRule(entry))) return { error: 'Eine IP-Adresse oder ein CIDR-Netz ist ungültig.' };
    if (allowedOfflineUserIds.some((id) => !users.some((entry) => entry.id === id && entry.active))) return { error: 'Eine Offline-Benutzerfreigabe ist ungültig.' };
    if (responsibleUserId
        && !users.some((entry) => entry.id === responsibleUserId && entry.active)) {
      return { error: 'Die verantwortliche Person ist ungültig.' };
    }
    if (body.systemMfa !== undefined && !validMfaModes.includes(body.systemMfa)) {
      return { error: 'Die MFA-Einstellung für den Systemzugang ist ungültig.' };
    }
    if (body.personalMfa !== undefined && !validMfaModes.includes(body.personalMfa)) {
      return { error: 'Die MFA-Einstellung für persönliche Konten ist ungültig.' };
    }
    return {
      name, locationId, locationName: location.name,
      room, inventoryNumber, macAddress,
      description: String(body.description ?? existing.description ?? '').trim().slice(0, 5000),
      responsibleUserId: responsibleUserId || null,
      allowedDepartmentIds, allowedNetworks, allowedOfflineUserIds,
      offlineEnabled: body.offlineEnabled === undefined
        ? existing.offlineEnabled ?? false
        : body.offlineEnabled === true,
      systemMfa: body.systemMfa ?? existing.systemMfa ?? 'off',
      personalMfa: body.personalMfa ?? existing.personalMfa ?? 'off',
      active: body.active === undefined ? existing.active ?? true : body.active === true,
    };
  }

  function ensureDeviceRequest(req, res, next) {
    if (!req.device || ![DEVICE_SESSION, PERSONAL_DEVICE_SESSION].includes(req.sessionType)) {
      return res.status(403).json({ error: 'Diese Funktion ist nur auf einem aktivierten Dienstgerät verfügbar.' });
    }
    updateClientInfo(req.device, req);
    return next();
  }

  function ensureSystem(req, res, next) {
    if (req.sessionType !== DEVICE_SESSION) return res.status(403).json({ error: 'Systemzugang erforderlich.' });
    return next();
  }

  async function verifySecondFactor(device, mode, body) {
    if (mode === 'off') return true;
    const factors = (device.secondFactors || []).filter((entry) => entry.active !== false && entry.type === mode);
    if (mode === 'totp') return factors.some((entry) => verifyTotp(decrypt(entry.secretEncrypted), body.totp));
    return factors.some((entry) => safeHashEqual(entry.credentialHash, String(body.nfcCredential || '')));
  }

  function successfulLogin(device, label, method) {
    device.failedLoginAttempts = 0; device.lockedUntil = null;
    device.lastLoginAt = nowIso(); device.lastLoginLabel = label; device.lastLoginMethod = method;
  }

  function offlineLease(device, user, qrCredential, sessionType) {
    if (!device.offlineEnabled || !qrCredential) return null;
    if (sessionType !== DEVICE_SESSION
        && !(device.allowedOfflineUserIds || []).includes(user.id)) return null;
    if (sessionType !== DEVICE_SESSION
        && !user.permissions?.includes('offline.access')
        && !user.roles?.includes('Admin')) return null;
    if (sessionType !== DEVICE_SESSION && !userMfa?.offlineMfaEligible(user)) return null;
    return {
      expiresAt: new Date(Date.now() + OFFLINE_LEASE_MS).toISOString(),
      verifierHash: hash(qrCredential),
      subjectId: user.id,
      sessionType,
      deviceId: device.id,
      deviceSecurityVersion: device.securityVersion,
      locationIds: [device.locationId].filter(Boolean),
      user: sessionType === DEVICE_SESSION ? null : publicUser(user),
    };
  }

  function failedLogin(device) {
    device.failedLoginAttempts = Number(device.failedLoginAttempts || 0) + 1;
    if (device.failedLoginAttempts >= LOGIN_MAX_ATTEMPTS) device.lockedUntil = new Date(Date.now() + LOCK_MS).toISOString();
  }

  app.get('/api/service-devices', authMiddleware, requirePermission('users.write'), (_req, res) => {
    res.json(devices.map(publicDevice));
  });

  app.post('/api/service-devices', authMiddleware, requirePermission('users.write'), async (req, res) => {
    const values = validateDeviceBody(req.body);
    if (values.error) return res.status(400).json({ error: values.error });
    if (!passwordIsValid(req.body.systemPassword)) return res.status(400).json({ error: 'Das Gerätepasswort muss mindestens 12 Zeichen sowie Groß-/Kleinbuchstaben, Zahl und Sonderzeichen enthalten.' });
    const device = {
      id: nextId('device'), ...values, systemPasswordHash: await bcrypt.hash(req.body.systemPassword, 12),
      credentialHash: null, securityVersion: 1, loginCredentials: [], secondFactors: [], personalNfcCredentials: [], offlineQrCredentials: [],
      failedLoginAttempts: 0, lockedUntil: null, createdAt: nowIso(), createdBy: req.user.id,
      activatedAt: null, activatedBy: null, lastSeenAt: null,
    };
    devices.push(device);
    devicesById.set(device.id, device);
    logEvent('create', 'ServiceDevice', { id: device.id, name: device.name }, req.user.username);
    return res.status(201).json(publicDevice(device));
  });

  app.put('/api/service-devices/:id', authMiddleware, requirePermission('users.write'), async (req, res) => {
    const device = findDevice(req.params.id); if (!device) return res.status(404).json({ error: 'Gerät nicht gefunden.' });
    const values = validateDeviceBody(req.body, device); if (values.error) return res.status(400).json({ error: values.error });
    Object.assign(device, values);
    if (req.body.systemPassword) {
      if (!passwordIsValid(req.body.systemPassword)) return res.status(400).json({ error: 'Das Gerätepasswort erfüllt die Mindestanforderungen nicht.' });
      device.systemPasswordHash = await bcrypt.hash(req.body.systemPassword, 12);
    }
    if (!device.active) replaceDeviceCredential(device);
    device.securityVersion += 1;
    logEvent('update', 'ServiceDevice', { id: device.id }, req.user.username);
    return res.json(publicDevice(device));
  });

  app.post('/api/service-devices/:id/revoke', authMiddleware, requirePermission('users.write'), (req, res) => {
    const device = findDevice(req.params.id); if (!device) return res.status(404).json({ error: 'Gerät nicht gefunden.' });
    device.active = false;
    replaceDeviceCredential(device);
    device.securityVersion += 1;
    logEvent('revoke', 'ServiceDevice', { id: device.id }, req.user.username);
    return res.json(publicDevice(device));
  });

  app.post('/api/service-devices/:id/reset-activation', authMiddleware, requirePermission('users.write'), (req, res) => {
    const device = findDevice(req.params.id); if (!device) return res.status(404).json({ error: 'Gerät nicht gefunden.' });
    replaceDeviceCredential(device);
    device.activatedAt = null; device.activatedBy = null; device.securityVersion += 1;
    logEvent('reset_activation', 'ServiceDevice', { id: device.id }, req.user.username);
    return res.json(publicDevice(device));
  });

  app.post('/api/service-devices/:id/qr-credentials', authMiddleware, requirePermission('users.write'), (req, res) => {
    const device = findDevice(req.params.id); if (!device) return res.status(404).json({ error: 'Gerät nicht gefunden.' });
    const secret = `${QR_PREFIX}${crypto.randomBytes(32).toString('base64url')}`;
    const entry = { id: nextId('device-qr'), type: 'qr', label: String(req.body.label || 'System-QR-Code').trim().slice(0, 120), credentialHash: hash(secret), active: true, createdAt: nowIso(), createdBy: req.user.id };
    device.loginCredentials.push(entry);
    logEvent('qr_issued', 'ServiceDevice', { id: device.id, credentialId: entry.id }, req.user.username);
    return res.status(201).json({ id: entry.id, label: entry.label, credential: secret });
  });

  app.delete('/api/service-devices/:id/qr-credentials/:credentialId', authMiddleware, requirePermission('users.write'), (req, res) => {
    const device = findDevice(req.params.id); if (!device) return res.status(404).json({ error: 'Gerät nicht gefunden.' });
    const index = device.loginCredentials.findIndex((entry) => entry.id === req.params.credentialId);
    if (index < 0) return res.status(404).json({ error: 'QR-Zugang nicht gefunden.' });
    device.loginCredentials.splice(index, 1); return res.status(204).end();
  });

  app.post('/api/service-devices/:id/nfc-factors', authMiddleware, requirePermission('users.write'), (req, res) => {
    const device = findDevice(req.params.id); if (!device) return res.status(404).json({ error: 'Gerät nicht gefunden.' });
    const credential = String(req.body.credential || '').trim(); if (credential.length < 8) return res.status(400).json({ error: 'Das NFC-Credential ist zu kurz.' });
    const entry = { id: nextId('device-nfc'), type: 'nfc', label: String(req.body.label || 'NFC-Karte').trim().slice(0, 120), credentialHash: hash(credential), active: true, createdAt: nowIso(), createdBy: req.user.id };
    device.secondFactors.push(entry); return res.status(201).json({ id: entry.id, label: entry.label, type: entry.type });
  });

  app.post('/api/service-devices/:id/totp-factors', authMiddleware, requirePermission('users.write'), (req, res) => {
    const device = findDevice(req.params.id); if (!device) return res.status(404).json({ error: 'Gerät nicht gefunden.' });
    const secret = base32Encode(crypto.randomBytes(20));
    const label = String(req.body.label || 'TOTP-Berechtigung').trim().slice(0, 120);
    const entry = { id: nextId('device-totp'), type: 'totp', label, secretEncrypted: encrypt(secret), active: true, createdAt: nowIso(), createdBy: req.user.id };
    device.secondFactors.push(entry);
    const issuer = encodeURIComponent('MaterialKompass'); const account = encodeURIComponent(`${device.name}:${label}`);
    return res.status(201).json({ id: entry.id, label, secret, provisioningUri: `otpauth://totp/${issuer}:${account}?secret=${secret}&issuer=${issuer}` });
  });

  app.delete('/api/service-devices/:id/second-factors/:factorId', authMiddleware, requirePermission('users.write'), (req, res) => {
    const device = findDevice(req.params.id); if (!device) return res.status(404).json({ error: 'Gerät nicht gefunden.' });
    const index = device.secondFactors.findIndex((entry) => entry.id === req.params.factorId);
    if (index < 0) return res.status(404).json({ error: 'Zweiter Faktor nicht gefunden.' });
    device.secondFactors.splice(index, 1); return res.status(204).end();
  });

  app.post('/api/service-devices/:id/personal-nfc', authMiddleware, requirePermission('users.write'), (req, res) => {
    const device = findDevice(req.params.id); if (!device) return res.status(404).json({ error: 'Gerät nicht gefunden.' });
    const user = users.find((entry) => entry.id === req.body.userId && entry.active);
    const credential = String(req.body.credential || '').trim();
    if (!user || credential.length < 8) return res.status(400).json({ error: 'Aktiver Benutzer und gültiges NFC-Credential sind erforderlich.' });
    device.personalNfcCredentials ||= [];
    const entry = { id: nextId('personal-nfc'), userId: user.id, label: String(req.body.label || user.name || user.username).trim().slice(0, 120), credentialHash: hash(credential), active: true, createdAt: nowIso(), createdBy: req.user.id };
    device.personalNfcCredentials.push(entry);
    return res.status(201).json({ id: entry.id, userId: entry.userId, label: entry.label });
  });

  app.delete('/api/service-devices/:id/personal-nfc/:credentialId', authMiddleware, requirePermission('users.write'), (req, res) => {
    const device = findDevice(req.params.id); if (!device) return res.status(404).json({ error: 'Gerät nicht gefunden.' });
    const index = (device.personalNfcCredentials || []).findIndex((entry) => entry.id === req.params.credentialId);
    if (index < 0) return res.status(404).json({ error: 'NFC-Zugang nicht gefunden.' });
    device.personalNfcCredentials.splice(index, 1); return res.status(204).end();
  });

  app.post('/api/service-devices/:id/offline-qr', authMiddleware, requirePermission('users.write'), (req, res) => {
    const device = findDevice(req.params.id); if (!device) return res.status(404).json({ error: 'Gerät nicht gefunden.' });
    const user = users.find((entry) => entry.id === req.body.userId && entry.active);
    if (!user || !(device.allowedOfflineUserIds || []).includes(user.id)) {
      return res.status(400).json({ error: 'Der Benutzer ist für dieses Gerät nicht offline freigegeben.' });
    }
    const credential = `${OFFLINE_QR_PREFIX}${crypto.randomBytes(32).toString('base64url')}`;
    const entry = {
      id: nextId('offline-qr'), userId: user.id,
      label: String(req.body.label || user.name || user.username).trim().slice(0, 120),
      credentialHash: hash(credential), active: true, createdAt: nowIso(), createdBy: req.user.id,
    };
    device.offlineQrCredentials ||= [];
    device.offlineQrCredentials.push(entry);
    logEvent('offline_qr_issued', 'ServiceDevice', { id: device.id, credentialId: entry.id, userId: user.id }, req.user.username);
    return res.status(201).json({ id: entry.id, userId: entry.userId, label: entry.label, credential });
  });

  app.delete('/api/service-devices/:id/offline-qr/:credentialId', authMiddleware, requirePermission('users.write'), (req, res) => {
    const device = findDevice(req.params.id); if (!device) return res.status(404).json({ error: 'Gerät nicht gefunden.' });
    const index = (device.offlineQrCredentials || []).findIndex((entry) => entry.id === req.params.credentialId);
    if (index < 0) return res.status(404).json({ error: 'Offline-QR-Code nicht gefunden.' });
    device.offlineQrCredentials.splice(index, 1);
    device.securityVersion += 1;
    return res.status(204).end();
  });

  app.post('/api/service-devices/activation/options', authRateLimit, async (req, res) => {
    const user = await authenticateAdmin(req.body.identifier, req.body.password);
    if (!user) return res.status(401).json({ error: 'Administrativer Login fehlgeschlagen.' });
    return res.json(devices.filter((entry) => entry.active).map(publicDevice));
  });

  app.post('/api/service-devices/activate', authRateLimit, async (req, res) => {
    const user = await authenticateAdmin(req.body.identifier, req.body.password);
    if (!user) return res.status(401).json({ error: 'Administrativer Login fehlgeschlagen.' });
    if (!NATIVE_CLIENT_PLATFORMS.has(String(req.body.clientPlatform || '').toLowerCase())) {
      return res.status(400).json({
        error: 'Dienstgeräte können nur in einer installierten App aktiviert werden.',
      });
    }
    const device = findDevice(req.body.deviceId); if (!device?.active) return res.status(404).json({ error: 'Aktives Gerät nicht gefunden.' });
    const credential = crypto.randomBytes(48).toString('base64url');
    replaceDeviceCredential(device, credential);
    device.securityVersion += 1;
    device.activatedAt = nowIso(); device.activatedBy = user.id; updateClientInfo(device, req);
    logEvent('activate', 'ServiceDevice', { id: device.id }, user.username);
    return res.json({ device: publicDevice(device), deviceCredential: credential });
  });

  app.post('/api/service-devices/status', authRateLimit, (req, res) => {
    const device = findActivatedDevice(req.body.deviceCredential);
    if (!device?.active || !ipAllowed(clientIp(req), device.allowedNetworks)) return res.status(401).json({ error: 'Geräteaktivierung ist ungültig.' });
    updateClientInfo(device, req); return res.json({ device: publicDevice(device) });
  });

  app.post('/api/service-devices/deactivate-client', authRateLimit, async (req, res) => {
    const user = await authenticateAdmin(req.body.identifier, req.body.password);
    const device = findActivatedDevice(req.body.deviceCredential);
    if (!user || !device) return res.status(401).json({ error: 'Administrative Bestätigung fehlgeschlagen.' });
    replaceDeviceCredential(device);
    device.activatedAt = null; device.activatedBy = null; device.securityVersion += 1;
    logEvent('deactivate_client', 'ServiceDevice', { id: device.id }, user.username);
    return res.json({ success: true });
  });

  app.post('/api/service-devices/login/system', authRateLimit, async (req, res) => {
    const device = findActivatedDevice(req.body.deviceCredential);
    if (!device?.active || !ipAllowed(clientIp(req), device.allowedNetworks)) return res.status(401).json({ error: 'Gerät oder Anmeldung ist ungültig.' });
    if (device.lockedUntil && Date.parse(device.lockedUntil) > Date.now()) return res.status(423).json({ error: 'Systemzugang vorübergehend gesperrt.' });
    const systemPassword = typeof req.body.password === 'string' ? req.body.password : '';
    const passwordValid = device.systemPasswordHash
      && Buffer.byteLength(systemPassword, 'utf8') <= 72
      ? await bcrypt.compare(systemPassword, device.systemPasswordHash)
      : false;
    const qrValid = String(req.body.qrCredential || '').startsWith(QR_PREFIX)
      && (device.loginCredentials || []).some((entry) => entry.active !== false && safeHashEqual(entry.credentialHash, req.body.qrCredential));
    const method = qrValid ? 'qr' : 'password';
    if ((!passwordValid && !qrValid) || !await verifySecondFactor(device, device.systemMfa, req.body)) {
      failedLogin(device); logEvent('login_failed', 'ServiceDevice', { id: device.id }, 'system-device');
      return res.status(401).json({ error: 'Gerät oder Anmeldung ist ungültig.' });
    }
    successfulLogin(device, 'Systemzugang', method); updateClientInfo(device, req);
    const systemUser = { id: `device-system:${device.id}`, username: `Gerät ${device.name}`, name: 'Systemzugang', email: '', roles: [], permissions: [], active: true, emailVerifiedAt: nowIso() };
    const token = createToken(systemUser, { deviceId: device.id, sessionType: DEVICE_SESSION, expiresIn: SYSTEM_TOKEN_TTL_SECONDS });
    logEvent('login', 'ServiceDevice', { id: device.id, method }, systemUser.username);
    return res.json({
      token, expiresIn: SYSTEM_TOKEN_TTL_SECONDS, device: publicDevice(device), sessionType: DEVICE_SESSION,
      offlineLease: qrValid ? offlineLease(device, systemUser, req.body.qrCredential, DEVICE_SESSION) : null,
    });
  });

  app.post('/api/service-devices/login/personal', authRateLimit, async (req, res) => {
    const device = findActivatedDevice(req.body.deviceCredential);
    if (!device?.active || !ipAllowed(clientIp(req), device.allowedNetworks)) return res.status(401).json({ error: 'Gerät oder Anmeldung ist ungültig.' });
    let user = findUser(req.body.identifier); let method = 'personal-password'; let qrIndexToConsume = -1;
    const personalPassword = typeof req.body.password === 'string' ? req.body.password : '';
    const passwordWithinLimit = Buffer.byteLength(personalPassword, 'utf8') <= 72;
    let valid = await bcrypt.compare(
      passwordWithinLimit ? personalPassword : '',
      passwordWithinLimit && user?.passwordHash
        ? user.passwordHash
        : DUMMY_PASSWORD_HASH,
    ) && passwordWithinLimit && Boolean(user);
    const qrValue = String(req.body.qrCredential || '');
    if (!valid && qrValue.startsWith('mkqr:v1:')) {
      const index = qrLoginCredentials.findIndex((entry) => safeHashEqual(entry.credentialHash, qrValue));
      const credential = qrLoginCredentials[index];
      const qrUser = credential && users.find((entry) => entry.id === credential.userId);
      const expired = credential?.expiresAt && Date.parse(credential.expiresAt) <= Date.now();
      if (credential && qrUser && !expired && credential.securityVersion === securityVersion(qrUser)) {
        user = qrUser; valid = true; method = 'personal-qr';
        if (credential.validity !== 'unlimited' && credential.expiresAt !== null) qrIndexToConsume = index;
      }
    }
    if (!valid && qrValue.startsWith(OFFLINE_QR_PREFIX)) {
      const credential = (device.offlineQrCredentials || [])
        .find((entry) => entry.active !== false && safeHashEqual(entry.credentialHash, qrValue));
      const qrUser = credential && users.find((entry) => entry.id === credential.userId);
      if (qrUser && (device.allowedOfflineUserIds || []).includes(qrUser.id)) {
        user = qrUser; valid = true; method = 'personal-offline-qr';
      }
    }
    const nfcValue = String(req.body.nfcLoginCredential || '');
    if (!valid && nfcValue) {
      const credential = (device.personalNfcCredentials || []).find((entry) => entry.active !== false && safeHashEqual(entry.credentialHash, nfcValue));
      const nfcUser = credential && users.find((entry) => entry.id === credential.userId);
      if (nfcUser) { user = nfcUser; valid = true; method = 'personal-nfc'; }
    }
    if (!valid || !user?.active || !user.emailVerifiedAt || !await verifySecondFactor(device, device.personalMfa, req.body)
        || (method === 'personal-nfc' && device.personalMfa === 'nfc'
          && String(req.body.nfcLoginCredential || '') === String(req.body.nfcCredential || ''))) {
      // The IP limiter throttles guesses without allowing an attacker to lock
      // a known personal account globally from a shared service device.
      return res.status(401).json({ error: 'Persönliche Anmeldung fehlgeschlagen.' });
    }
    if (qrIndexToConsume >= 0) qrLoginCredentials.splice(qrIndexToConsume, 1);
    const challengeDeviceSecurityVersion = device.securityVersion;
    const finishLogin = async (verifiedUser, response, verifyRequest = req) => {
      if (!device.active || device.securityVersion !== challengeDeviceSecurityVersion
          || !ipAllowed(clientIp(verifyRequest), device.allowedNetworks)) {
        return response.status(401).json({ error: 'Gerät oder Anmeldung ist ungültig.' });
      }
      successfulLogin(device, verifiedUser.username, method);
      updateClientInfo(device, verifyRequest);
      verifiedUser.failedLoginAttempts = 0;
      verifiedUser.lockedUntil = null;
      verifiedUser.lastLoginAt = nowIso();
      await saveUser(verifiedUser);
      const token = createToken(verifiedUser, {
        deviceId: device.id,
        sessionType: PERSONAL_DEVICE_SESSION,
      });
      logEvent('login', 'ServiceDevice', {
        id: device.id, userId: verifiedUser.id, method,
      }, verifiedUser.username);
      return response.json({
        token,
        expiresIn: 3600,
        user: publicUser(verifiedUser),
        device: publicDevice(device),
        sessionType: PERSONAL_DEVICE_SESSION,
        offlineLease: method === 'personal-offline-qr'
          ? offlineLease(device, verifiedUser, qrValue, PERSONAL_DEVICE_SESSION) : null,
      });
    };
    if (userMfa?.mfaEnabled(user)) {
      return res.status(202).json(userMfa.issueChallenge(
        user,
        (verifiedUser, response, _verification, verifyRequest) => finishLogin(
          verifiedUser, response, verifyRequest,
        ),
      ));
    }
    if (userMfa?.enrollmentRequired(user)) {
      return res.status(428).json({
        error: '2-FA muss zunächst über die normale Anmeldung eingerichtet werden.',
        mfaSetupRequired: true,
      });
    }
    return finishLogin(user, res);
  });

  function allowedDocument(entry) {
    const type = normalize(entry.documentType);
    return type.includes('vorlage') || type.includes('gebrauchsanweisung') || type === 'anleitung';
  }

  function searchLookups() {
    const documentsByMaterialId = new Map();
    for (const document of materialDocuments) {
      if (!allowedDocument(document)) continue;
      const entries = documentsByMaterialId.get(document.materialId) || [];
      const { fileBase64: _fileBase64, ...metadata } = document;
      entries.push(metadata);
      documentsByMaterialId.set(document.materialId, entries);
    }
    return {
      positionsById: new Map(stockStructures.map((entry) => [entry.id, entry])),
      locationsById: new Map(locations.map((entry) => [entry.id, entry])),
      documentsByMaterialId,
    };
  }

  function locationFacts(item, lookups) {
    const position = lookups.positionsById.get(item.storagePositionId || item.stockStructureId);
    const location = lookups.locationsById.get(position?.locationId || item.locationId);
    return { location: location?.name || '', storagePosition: position?.path || position?.fullCode || position?.name || '' };
  }

  function itemResult(item, entityType, lookups) {
    const facts = locationFacts(item, lookups);
    return {
      type: entityType, id: item.id, name: item.name,
      inventoryNumber: item.inventoryNumber || '', status: item.status,
      location: facts.location, storagePosition: facts.storagePosition,
      quantity: entityType === 'MaterialItem' ? Number(item.quantity || 0) : 1,
      availableQuantity: entityType === 'MaterialItem' ? Math.max(0, Number(item.quantity || 0) - Number(item.issuedQuantity || 0)) : (item.assignedPerson ? 0 : 1),
      nextInspectionDate: item.nextInspectionDate || null,
      image: item.image || item.imageBase64 || null,
      documents: entityType === 'MaterialItem'
        ? lookups.documentsByMaterialId.get(item.id) || []
        : [],
    };
  }

  app.get('/api/device/search', authMiddleware, ensureDeviceRequest, ensureSystem, (req, res) => {
    const query = normalize(req.query.q); if (!query) return res.json([]);
    const contains = (...values) => values.some((value) => normalize(value).includes(query));
    const lookups = searchLookups();
    const results = [];
    for (const item of materials) {
      if (results.length >= 100) break;
      if (!item.archived && Number(item.issuedQuantity || 0) === 0
          && item.status !== 'Ausgesondert'
          && contains(item.name, item.inventoryNumber, item.categoryCode, item.subcategoryCode)) {
        results.push(itemResult(item, 'MaterialItem', lookups));
      }
    }
    for (const item of clothingItems) {
      if (results.length >= 100) break;
      if (!item.archived && !item.assignedPerson && item.status !== 'Ausgesondert'
          && contains(item.name, item.inventoryNumber, item.categoryId, item.size)) {
        results.push(itemResult(item, 'ClothingItem', lookups));
      }
    }
    for (const entry of locations) {
      if (results.length >= 100) break;
      if (contains(entry.name, entry.code)) {
        results.push({ type: 'Location', id: entry.id, name: entry.name, code: entry.code });
      }
    }
    for (const entry of categories) {
      if (results.length >= 100) break;
      if (contains(entry.name, entry.id)) {
        results.push({ type: 'Category', id: entry.id, name: entry.name });
      }
    }
    return res.json(results);
  });

  app.get('/api/device/defect-target', authMiddleware, ensureDeviceRequest, ensureSystem, (req, res) => {
    const inventoryNumber = String(req.query.inventoryNumber || '').trim();
    const material = materials.find((entry) => !entry.archived && entry.status !== 'Ausgesondert' && entry.inventoryNumber === inventoryNumber);
    const clothing = clothingItems.find((entry) => !entry.archived && entry.status !== 'Ausgesondert' && entry.inventoryNumber === inventoryNumber);
    const item = material || clothing; if (!item) return res.status(404).json({ error: 'Artikel nicht gefunden.' });
    return res.json(itemResult(
      item,
      material ? 'MaterialItem' : 'ClothingItem',
      searchLookups(),
    ));
  });

  app.get('/api/device/documents/:id', authMiddleware, ensureDeviceRequest, ensureSystem, (req, res) => {
    const document = materialDocuments.find((entry) => entry.id === req.params.id && allowedDocument(entry));
    if (!document) return res.status(404).json({ error: 'Dokument nicht gefunden.' });
    return res.json(document);
  });

  app.post('/api/device/defects', authMiddleware, ensureDeviceRequest, ensureSystem, (req, res) => {
    const result = defectManagement.createFromDevice({ body: req.body, user: req.user, device: req.device });
    if (result.error) return res.status(400).json({ error: result.error });
    return res.status(201).json(result);
  });

  app.post('/api/device/defects/access', authRateLimit, authMiddleware, ensureDeviceRequest, ensureSystem, (req, res) => {
    const report = defectManagement.accessFromDevice(req.body);
    if (!report) {
      logEvent('device_code_failed', 'DefectReport', { deviceId: req.device.id }, req.user.username);
      return res.status(404).json({ error: 'Mängelnummer oder Zugriffscode ist ungültig.' });
    }
    logEvent('device_code_access', 'DefectReport', { id: report.id, deviceId: req.device.id }, req.user.username);
    return res.json(report);
  });

  app.put('/api/device/defects/access', authRateLimit, authMiddleware, ensureDeviceRequest, ensureSystem, (req, res) => {
    const result = defectManagement.updateFromDevice({ ...req.body, body: req.body, user: req.user });
    if (result.error) return res.status(result.status || 400).json({ error: result.error });
    logEvent('device_code_update', 'DefectReport', { id: result.report.id, deviceId: req.device.id }, req.user.username);
    return res.json(result);
  });

  return { publicDevice, ipAllowed, DEVICE_SESSION, PERSONAL_DEVICE_SESSION };
}

module.exports = {
  registerServiceDeviceRoutes, publicDevice, ipAllowed,
  DEVICE_SESSION, PERSONAL_DEVICE_SESSION, SYSTEM_TOKEN_TTL_SECONDS,
};
