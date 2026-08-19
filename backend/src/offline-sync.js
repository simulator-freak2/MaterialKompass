const {
  createCipheriv,
  createDecipheriv,
  createHash,
  randomBytes,
  randomUUID,
} = require('node:crypto');

const OFFLINE_LEASE_DAYS = 7;
const MAX_COMMAND_RESULTS = 10_000;

function registerOfflineSync({
  app,
  clients,
  commandResults,
  syncState,
  authMiddleware,
  requirePermission,
  hasPermission,
  publicUser,
  data,
  deviceSession,
  securityVersion,
  jwtSecret,
}) {
  const state = () => (syncState[0] ||= { revision: 0, updatedAt: null });
  const nowIso = () => new Date().toISOString();
  const resultsByKey = new Map(commandResults.map((entry) => [entry.key, entry]));
  const clientsById = new Map(clients.map((entry) => [entry.id, entry]));
  const resultEncryptionKey = createHash('sha256')
    .update(`offline-results:${jwtSecret}`)
    .digest();

  function encryptResult(body) {
    const iv = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', resultEncryptionKey, iv);
    const encrypted = Buffer.concat([
      cipher.update(JSON.stringify(body), 'utf8'),
      cipher.final(),
    ]);
    return [iv, cipher.getAuthTag(), encrypted]
      .map((part) => part.toString('base64url'))
      .join('.');
  }

  function decryptResult(entry) {
    if (!entry.bodyEncrypted) return structuredClone(entry.body);
    try {
      const [iv, tag, body] = entry.bodyEncrypted
        .split('.')
        .map((part) => Buffer.from(part, 'base64url'));
      const decipher = createDecipheriv('aes-256-gcm', resultEncryptionKey, iv);
      decipher.setAuthTag(tag);
      return JSON.parse(Buffer.concat([
        decipher.update(body),
        decipher.final(),
      ]).toString('utf8'));
    } catch (_) {
      return { error: 'Das gespeicherte Offline-Ergebnis ist nicht mehr lesbar.' };
    }
  }

  function bumpRevision() {
    const current = state();
    current.revision = Number(current.revision || 0) + 1;
    current.updatedAt = nowIso();
  }

  // Replayed mutations use their original endpoint, keeping all established
  // domain validation in one place. The cached response makes retries exactly
  // once from the client's perspective.
  app.use((req, res, next) => {
    if (!['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method)) return next();
    const commandId = String(req.get('X-Offline-Command-Id') || '');
    if (!commandId) return next();
    if (!/^[A-Za-z0-9._:-]{16,128}$/.test(commandId)) {
      return res.status(400).json({ error: 'Die Offline-Befehls-ID ist ungültig.' });
    }
    // Authenticate before looking up a previous result. This prevents a
    // guessed command id from becoming an authentication bypass and keeps
    // deduplication stable when the same user receives a refreshed JWT.
    return authMiddleware(req, res, () => {
      const identity = `${req.user.id}:${req.device?.id || 'personal'}`;
      const key = `${createHash('sha256').update(identity).digest('base64url')}:${commandId}`;
      const stored = resultsByKey.get(key);
      if (stored) {
        res.set('X-Offline-Replayed', 'true');
        return res.status(stored.statusCode).json(decryptResult(stored));
      }
      const originalJson = res.json.bind(res);
      res.json = function storeIdempotentResponse(body) {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          const result = {
            key,
            commandId,
            statusCode: res.statusCode,
            bodyEncrypted: encryptResult(body),
            createdAt: nowIso(),
          };
          commandResults.push(result);
          resultsByKey.set(key, result);
          if (commandResults.length > MAX_COMMAND_RESULTS) {
            const removed = commandResults.splice(
              0,
              commandResults.length - MAX_COMMAND_RESULTS,
            );
            removed.forEach((entry) => resultsByKey.delete(entry.key));
          }
        }
        return originalJson(body);
      };
      return next();
    });
  });

  app.use((req, res, next) => {
    if (!['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method)
        || req.path.startsWith('/api/offline/')) return next();
    let bumped = false;
    const bumpOnce = () => {
      if (!bumped && res.statusCode >= 200 && res.statusCode < 300) {
        bumped = true;
        bumpRevision();
      }
    };
    const originalJson = res.json.bind(res);
    res.json = function revisionedJson(body) { bumpOnce(); return originalJson(body); };
    const originalEnd = res.end.bind(res);
    res.end = function revisionedEnd(...args) { bumpOnce(); return originalEnd(...args); };
    return next();
  });

  function offlineAllowed(req) {
    if (req.sessionType === deviceSession) return req.device?.offlineEnabled === true;
    if (!hasPermission(req.user, 'offline.access')) return false;
    if (!req.device) return true;
    return req.device.offlineEnabled === true
      && (req.device.allowedOfflineUserIds || []).includes(req.user.id);
  }

  function allowedLocationIds(req, requested) {
    const existing = new Set((data.locations || []).map((entry) => entry.id));
    const result = Array.from(new Set((Array.isArray(requested) ? requested : [])
      .map(String).filter((id) => existing.has(id))));
    if (req.device?.locationId && !result.includes(req.device.locationId)) {
      result.unshift(req.device.locationId);
    }
    return result;
  }

  function safeDefect(entry) {
    const copy = structuredClone(entry);
    delete copy.deviceAccessCodeHash;
    if (Array.isArray(copy.images)) {
      copy.images = copy.images.map(({ fileBase64, ...metadata }) => metadata);
    }
    if (Array.isArray(copy.documents)) {
      copy.documents = copy.documents.map(({ fileBase64, ...metadata }) => metadata);
    }
    return copy;
  }

  function snapshot(req, locationIds) {
    const selected = new Set(locationIds);
    const include = (entry) => selected.size === 0 || selected.has(entry.locationId);
    const materials = hasPermission(req.user, 'inventory.read') || req.sessionType === deviceSession
      ? (data.materials || []).filter((entry) => !entry.archived && include(entry)).map((entry) => ({
        ...entry,
        availableQuantity: Number(entry.quantity || 0) - Number(entry.issuedQuantity || 0),
      })) : [];
    const clothingItems = hasPermission(req.user, 'clothing.read') || req.sessionType === deviceSession
      ? (data.clothingItems || []).filter(include) : [];
    const entityIds = new Set([...materials, ...clothingItems].map((entry) => entry.id));
    const defectReports = hasPermission(req.user, 'defects.read') || req.sessionType === deviceSession
      ? (data.defectReports || []).filter((entry) => !entry.archivedAt && entityIds.has(entry.entityId)).map(safeDefect)
      : [];
    const shelves = selected.size === 0
      ? (data.shelves || []) : (data.shelves || []).filter((entry) => selected.has(entry.locationId));
    const shelfIds = new Set(shelves.map((entry) => entry.id));
    const storageLevels = selected.size === 0
      ? (data.storageLevels || []) : (data.storageLevels || []).filter((entry) => shelfIds.has(entry.shelfId));
    const levelIds = new Set(storageLevels.map((entry) => entry.id));
    const stockStructures = selected.size === 0
      ? (data.stockStructures || [])
      : (data.stockStructures || []).filter((entry) => selected.has(entry.locationId));
    return {
      materials,
      clothingItems,
      materialMovements: (data.materialMovements || [])
        .filter((entry) => entityIds.has(entry.materialId)),
      issueTransactions: (data.issueTransactions || [])
        .filter((entry) => entityIds.has(entry.clothingId)),
      defectReports,
      categories: data.categories || [],
      locations: selected.size === 0
        ? (data.locations || []) : (data.locations || []).filter((entry) => selected.has(entry.id)),
      stockStructures,
      shelves,
      storageLevels,
      storagePositions: selected.size === 0
        ? (data.storagePositions || []) : (data.storagePositions || []).filter((entry) => levelIds.has(entry.levelId)),
    };
  }

  function activeClient(req) {
    const id = String(req.get('X-Offline-Client-Id') || '');
    const client = clientsById.get(id);
    return client?.active
      && client.userId === req.user.id
      && Date.parse(client.leaseExpiresAt) > Date.now()
      ? client
      : null;
  }

  app.post('/api/offline/enroll', authMiddleware, (req, res) => {
    if (!offlineAllowed(req)) return res.status(403).json({ error: 'Offlinezugriff ist nicht freigegeben.' });
    const id = String(req.body.clientId || randomUUID());
    if (!/^[A-Za-z0-9._:-]{8,128}$/.test(id)) {
      return res.status(400).json({ error: 'Die Client-ID ist ungültig.' });
    }
    let client = clientsById.get(id);
    if (client && client.userId !== req.user.id) {
      return res.status(409).json({ error: 'Die Client-ID wird bereits verwendet.' });
    }
    const expiresAt = new Date(Date.now() + OFFLINE_LEASE_DAYS * 86_400_000).toISOString();
    const values = {
      userId: req.user.id,
      serviceDeviceId: req.device?.id || null,
      name: String(req.body.name || 'MaterialKompass').trim().slice(0, 120),
      platform: String(req.body.platform || '').trim().slice(0, 40),
      locationIds: allowedLocationIds(req, req.body.locationIds),
      active: true,
      securityVersion: req.device?.securityVersion || securityVersion(req.user),
      leaseExpiresAt: expiresAt,
      lastSeenAt: nowIso(),
    };
    if (client) Object.assign(client, values);
    else {
      client = { id, createdAt: nowIso(), ...values };
      clients.push(client);
      clientsById.set(id, client);
    }
    return res.json({
      clientId: id,
      expiresAt,
      revision: Number(state().revision || 0),
      user: publicUser(req.user),
      locationIds: client.locationIds,
    });
  });

  app.get('/api/offline/bootstrap', authMiddleware, (req, res) => {
    if (!offlineAllowed(req)) return res.status(403).json({ error: 'Offlinezugriff ist nicht freigegeben.' });
    const client = activeClient(req);
    if (!client) return res.status(403).json({ error: 'Die Offlinefreigabe ist ungültig oder abgelaufen.' });
    client.lastSeenAt = nowIso();
    return res.json({
      revision: Number(state().revision || 0),
      generatedAt: nowIso(),
      data: snapshot(req, client.locationIds || []),
    });
  });

  app.get('/api/offline/changes', authMiddleware, (req, res) => {
    if (!offlineAllowed(req)) return res.status(403).json({ error: 'Offlinezugriff ist nicht freigegeben.' });
    const client = activeClient(req);
    if (!client) return res.status(403).json({ error: 'Die Offlinefreigabe ist ungültig oder abgelaufen.' });
    const revision = Number(state().revision || 0);
    const changed = Number(req.query.cursor || 0) !== revision;
    client.lastSeenAt = nowIso();
    return res.json({
      revision,
      changed,
      data: changed ? snapshot(req, client.locationIds || []) : null,
    });
  });

  app.get('/api/offline/clients', authMiddleware, requirePermission('users.write'), (_req, res) => {
    res.json(clients);
  });

  app.post('/api/offline/clients/:id/revoke', authMiddleware, requirePermission('users.write'), (req, res) => {
    const client = clientsById.get(req.params.id);
    if (!client) return res.status(404).json({ error: 'Offlinegerät nicht gefunden.' });
    client.active = false;
    client.revokedAt = nowIso();
    return res.json(client);
  });
}

module.exports = { registerOfflineSync, OFFLINE_LEASE_DAYS };
