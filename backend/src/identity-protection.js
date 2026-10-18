const crypto = require('node:crypto');
const fs = require('node:fs/promises');
const path = require('node:path');

const KEYRING_FORMAT = 'MaterialKompass identity keyring';
const KEYRING_VERSION = 1;
const TOKEN_PREFIX = 'mkid:v1:';
const MULTI_TOKEN_PREFIX = 'mkid:v2:';
const KEYRING_AAD = Buffer.from(`${KEYRING_FORMAT}:v${KEYRING_VERSION}`, 'utf8');
const IDENTITY_FIELDS = Object.freeze(['name', 'username', 'email']);
const IDENTITY_REFERENCE_KEYS = new Set([
  'username', 'userdisplayname', 'email', 'name', 'actor', 'actorname',
  'author', 'assignee', 'inspector', 'inspectoremail', 'label', 'by',
  'approvedby', 'archivedby', 'cancelledby', 'completedby', 'countedby',
  'countedbyname', 'createdby', 'deletedby', 'doneby', 'issuedby',
  'inventorynumberreleasedby', 'returnedby',
  'operationalapprovedby', 'processedby', 'reportedby', 'reportedbyname',
  'requestedby', 'requestedbyemail', 'requestername', 'responsiblename',
  'updatedby', 'vehicleapprovedby', 'contactname', 'contactemail', 'sendername',
]);

function parseMasterKey(value) {
  const text = String(value || '').trim();
  if (!/^[a-f0-9]{64}$/i.test(text)) {
    throw new Error('IDENTITY_KEYRING_MASTER_KEY muss ein zufälliger 64-stelliger Hex-Wert sein.');
  }
  return Buffer.from(text, 'hex');
}

function normalize(value) {
  return String(value || '').trim().toLocaleLowerCase('de');
}

function pseudonym(userId) {
  return `deleted-${crypto.createHash('sha256').update(String(userId)).digest('hex').slice(0, 12)}`;
}

function erasedIdentity(userId) {
  const value = pseudonym(userId);
  return {
    name: 'Gelöschte Person',
    username: value,
    email: `${value}@example.invalid`,
  };
}

function encryptAead(key, plaintext, aad) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  cipher.setAAD(Buffer.from(aad, 'utf8'));
  const ciphertext = Buffer.concat([
    cipher.update(String(plaintext), 'utf8'),
    cipher.final(),
  ]);
  return [iv, cipher.getAuthTag(), ciphertext]
    .map((part) => part.toString('base64url'));
}

function decryptAead(key, parts, aad) {
  if (!Array.isArray(parts) || parts.length !== 3) throw new Error('Ungültiges Chiffrat.');
  const [iv, tag, ciphertext] = parts.map((part) => Buffer.from(part, 'base64url'));
  if (iv.length !== 12 || tag.length !== 16 || ciphertext.length === 0) {
    throw new Error('Ungültiges Chiffrat.');
  }
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv);
  decipher.setAAD(Buffer.from(aad, 'utf8'));
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(ciphertext), decipher.final()]).toString('utf8');
}

function keyFingerprint(key) {
  return crypto.createHash('sha256').update(key).digest('base64url').slice(0, 22);
}

function tombstoneUser(user) {
  const identity = erasedIdentity(user.id);
  return {
    ...user,
    ...identity,
    active: false,
    platformAdmin: false,
    roles: [],
    permissions: [],
    departmentIds: [],
    passwordHash: `!identity-erased:${crypto.randomBytes(32).toString('base64url')}`,
    verificationTokenHash: null,
    verificationExpiresAt: null,
    passwordResetTokenHash: null,
    passwordResetExpiresAt: null,
    mfaRequired: false,
    mfaSecretEncrypted: null,
    mfaPendingSecretEncrypted: null,
    mfaPendingSecretExpiresAt: null,
    mfaRecoveryCodeHashes: [],
    mfaEnabledAt: null,
    mfaLastVerifiedAt: null,
    mfaGraceEndsAt: null,
    identityErased: true,
    deactivatedAt: user.deactivatedAt || new Date().toISOString(),
    deactivationReason: 'identity-key-erased',
  };
}

function createIdentityProtection({
  masterKey = process.env.IDENTITY_KEYRING_MASTER_KEY,
  keyringPath = process.env.IDENTITY_KEYRING_PATH,
  memoryOnly = false,
} = {}) {
  const master = parseMasterKey(masterKey);
  const resolvedPath = keyringPath ? path.resolve(keyringPath) : null;
  if (!memoryOnly && !resolvedPath) {
    throw new Error('IDENTITY_KEYRING_PATH muss auf eine separate Keyring-Datei zeigen.');
  }

  const keys = new Map();
  const identities = new Map();
  const identityAliases = new Map();
  let initialized = memoryOnly;
  let existedAtInitialization = memoryOnly;
  let writeQueue = Promise.resolve();

  function keyringDocument() {
    return {
      format: KEYRING_FORMAT,
      version: KEYRING_VERSION,
      updatedAt: new Date().toISOString(),
      keys: Object.fromEntries([...keys.entries()].map(([id, key]) => [
        id,
        key.toString('base64url'),
      ])),
    };
  }

  function encodeKeyring() {
    const plaintext = JSON.stringify(keyringDocument());
    const [iv, tag, ciphertext] = encryptAead(master, plaintext, KEYRING_AAD.toString('utf8'));
    return JSON.stringify({
      format: KEYRING_FORMAT,
      version: KEYRING_VERSION,
      iv,
      tag,
      ciphertext,
    });
  }

  function decodeKeyring(contents) {
    const envelope = JSON.parse(contents);
    if (envelope.format !== KEYRING_FORMAT || envelope.version !== KEYRING_VERSION) {
      throw new Error('Der Identity-Keyring hat ein unbekanntes Format.');
    }
    const plaintext = decryptAead(
      master,
      [envelope.iv, envelope.tag, envelope.ciphertext],
      KEYRING_AAD.toString('utf8'),
    );
    const document = JSON.parse(plaintext);
    if (document.format !== KEYRING_FORMAT || document.version !== KEYRING_VERSION
      || !document.keys || typeof document.keys !== 'object' || Array.isArray(document.keys)) {
      throw new Error('Der Identity-Keyring ist ungültig.');
    }
    for (const [userId, encoded] of Object.entries(document.keys)) {
      const key = Buffer.from(String(encoded), 'base64url');
      if (!userId || key.length !== 32) throw new Error('Der Identity-Keyring ist ungültig.');
      keys.set(userId, key);
    }
  }

  async function persistNow() {
    if (memoryOnly) return;
    const directory = path.dirname(resolvedPath);
    await fs.mkdir(directory, { recursive: true, mode: 0o700 });
    const temporary = `${resolvedPath}.${process.pid}.${crypto.randomBytes(8).toString('hex')}.tmp`;
    let handle;
    try {
      handle = await fs.open(temporary, 'wx', 0o600);
      await handle.writeFile(encodeKeyring(), { encoding: 'utf8' });
      await handle.sync();
      await handle.close();
      handle = null;
      await fs.rename(temporary, resolvedPath);
      await fs.chmod(resolvedPath, 0o600);
      // Windows does not support fsync on directory handles (EPERM). The file
      // itself is synced above; Linux additionally gets a durable rename.
      if (process.platform !== 'win32') {
        const directoryHandle = await fs.open(directory, 'r');
        try { await directoryHandle.sync(); } finally { await directoryHandle.close(); }
      }
    } catch (error) {
      if (handle) await handle.close().catch(() => {});
      await fs.unlink(temporary).catch(() => {});
      throw error;
    }
  }

  function persist() {
    const operation = writeQueue.then(persistNow);
    writeQueue = operation.catch(() => {});
    return operation;
  }

  async function initialize() {
    if (initialized) return { existed: existedAtInitialization };
    try {
      decodeKeyring(await fs.readFile(resolvedPath, 'utf8'));
      existedAtInitialization = true;
    } catch (error) {
      if (error.code !== 'ENOENT') {
        throw new Error(`Identity-Keyring konnte nicht geladen werden: ${error.message}`);
      }
      existedAtInitialization = false;
      await persist();
    }
    initialized = true;
    return { existed: existedAtInitialization };
  }

  function assertInitialized() {
    if (!initialized) throw new Error('Identity-Keyring wurde noch nicht initialisiert.');
  }

  function registerIdentity(user) {
    if (!user?.id || user.identityErased) return;
    identities.set(String(user.id), Object.fromEntries(
      IDENTITY_FIELDS.map((field) => [field, String(user[field] || '')]),
    ));
  }

  function identityChanged(user) {
    if (!user?.id || user.identityErased) return false;
    const previous = identities.get(String(user.id));
    return Boolean(previous) && IDENTITY_FIELDS.some(
      (field) => String(previous[field] || '') !== String(user[field] || ''),
    );
  }

  function addIdentityAlias(userId, identity) {
    if (!identity) return;
    const aliases = identityAliases.get(userId) || [];
    if (!aliases.some((entry) => IDENTITY_FIELDS.every(
      (field) => String(entry[field] || '') === String(identity[field] || ''),
    ))) {
      aliases.push(Object.fromEntries(
        IDENTITY_FIELDS.map((field) => [field, String(identity[field] || '')]),
      ));
      identityAliases.set(userId, aliases);
    }
  }

  function identityValues(userId) {
    const id = String(userId || '');
    return [identities.get(id), ...(identityAliases.get(id) || [])]
      .filter(Boolean)
      .flatMap((identity) => IDENTITY_FIELDS.map((field) => ({
        field,
        value: String(identity[field] || ''),
      })))
      .filter((entry) => entry.value);
  }

  async function ensureUsers(users) {
    assertInitialized();
    const added = [];
    const previousIdentities = new Map();
    for (const user of users) {
      if (!user?.id || user.identityErased) continue;
      const id = String(user.id);
      if (!previousIdentities.has(id)) {
        previousIdentities.set(id, identities.has(id) ? { ...identities.get(id) } : null);
      }
      if (!keys.has(id)) {
        const key = crypto.randomBytes(32);
        keys.set(id, key);
        added.push({ id, key });
      }
      registerIdentity(user);
    }
    if (added.length > 0) {
      try {
        await persist();
      } catch (error) {
        added.forEach(({ id, key }) => {
          keys.delete(id);
          key.fill(0);
        });
        previousIdentities.forEach((identity, id) => {
          if (identity) identities.set(id, identity);
          else identities.delete(id);
        });
        throw error;
      }
    }
    return added.length;
  }

  async function ensureUser(user) {
    return (await ensureUsers([user])) > 0;
  }

  async function rotateUser(user) {
    assertInitialized();
    if (!user?.id || user.identityErased) return;
    const id = String(user.id);
    const previous = keys.get(id);
    const previousIdentity = identities.get(id);
    const previousAliases = (identityAliases.get(id) || []).map((entry) => ({ ...entry }));
    const next = crypto.randomBytes(32);
    addIdentityAlias(id, previousIdentity);
    keys.set(id, next);
    registerIdentity(user);
    try {
      await persist();
      previous?.fill(0);
    } catch (error) {
      if (previous) keys.set(id, previous);
      else keys.delete(id);
      next.fill(0);
      if (previousIdentity) identities.set(id, previousIdentity);
      else identities.delete(id);
      if (previousAliases.length > 0) identityAliases.set(id, previousAliases);
      else identityAliases.delete(id);
      throw error;
    }
  }

  async function destroyUser(userId) {
    assertInitialized();
    const id = String(userId || '');
    const key = keys.get(id);
    const previousIdentity = identities.get(id);
    const previousAliases = identityAliases.get(id);
    const existed = keys.delete(id);
    identities.delete(id);
    identityAliases.delete(id);
    if (existed) {
      try {
        await persist();
        key.fill(0);
      } catch (error) {
        keys.set(id, key);
        if (previousIdentity) identities.set(id, previousIdentity);
        if (previousAliases) identityAliases.set(id, previousAliases);
        throw error;
      }
    }
    return existed;
  }

  async function pruneUsers(userIds) {
    assertInitialized();
    const allowed = new Set([...userIds].map(String));
    const removed = [];
    for (const [id, key] of keys) {
      if (allowed.has(id)) continue;
      removed.push({
        id,
        key,
        identity: identities.get(id),
        aliases: identityAliases.get(id),
      });
      keys.delete(id);
      identities.delete(id);
      identityAliases.delete(id);
    }
    if (removed.length === 0) return 0;
    try {
      await persist();
      removed.forEach(({ key }) => key.fill(0));
      return removed.length;
    } catch (error) {
      removed.forEach(({ id, key, identity, aliases }) => {
        keys.set(id, key);
        if (identity) identities.set(id, identity);
        if (aliases) identityAliases.set(id, aliases);
      });
      throw error;
    }
  }

  function hasUserKey(userId) {
    return keys.has(String(userId || ''));
  }

  function encryptForUser(userId, field, value) {
    const id = String(userId);
    const key = keys.get(id);
    if (!key) throw new Error(`Für ${id} ist kein Identity-Schlüssel vorhanden.`);
    const encodedId = Buffer.from(id, 'utf8').toString('base64url');
    const aad = `MaterialKompass identity:v1:${id}:${field}`;
    return `${TOKEN_PREFIX}${encodedId}:${field}:${keyFingerprint(key)}:${encryptAead(key, value, aad).join(':')}`;
  }

  function encryptForRecipients(recipients, value) {
    const field = recipients[0].field;
    const dataKey = crypto.randomBytes(32);
    try {
      const ciphertext = encryptAead(dataKey, value, `MaterialKompass identity:v2:${field}`);
      const wrappedKeys = recipients.map(({ userId }) => {
        const key = keys.get(userId);
        if (!key) throw new Error(`Für ${userId} ist kein Identity-Schlüssel vorhanden.`);
        return {
          userId,
          keyId: keyFingerprint(key),
          wrappedKey: encryptAead(
            key,
            dataKey.toString('base64url'),
            `MaterialKompass identity-wrap:v2:${userId}:${field}`,
          ),
        };
      });
      const envelope = { field, ciphertext, recipients: wrappedKeys };
      return `${MULTI_TOKEN_PREFIX}${Buffer.from(JSON.stringify(envelope), 'utf8').toString('base64url')}`;
    } finally {
      dataKey.fill(0);
    }
  }

  function decryptToken(token) {
    if (typeof token !== 'string'
      || (!token.startsWith(TOKEN_PREFIX) && !token.startsWith(MULTI_TOKEN_PREFIX))) {
      return { protected: false, value: token };
    }
    if (token.startsWith(MULTI_TOKEN_PREFIX)) {
      let envelope;
      try {
        envelope = JSON.parse(Buffer.from(
          token.slice(MULTI_TOKEN_PREFIX.length),
          'base64url',
        ).toString('utf8'));
      } catch (_) {
        throw new Error('Ungültiges Identity-Chiffrat.');
      }
      if (!IDENTITY_FIELDS.includes(envelope.field)
        || !Array.isArray(envelope.ciphertext) || envelope.ciphertext.length !== 3
        || !Array.isArray(envelope.recipients) || envelope.recipients.length < 2) {
        throw new Error('Ungültiges Identity-Chiffrat.');
      }
      const userIds = envelope.recipients.map((recipient) => String(recipient?.userId || ''));
      if (new Set(userIds).size !== userIds.length) {
        throw new Error('Ungültiges Identity-Chiffrat.');
      }
      for (let index = 0; index < envelope.recipients.length; index += 1) {
        const recipient = envelope.recipients[index];
        const userId = userIds[index];
        if (!userId || typeof recipient.keyId !== 'string'
          || !Array.isArray(recipient.wrappedKey)) {
          throw new Error('Ungültiges Identity-Chiffrat.');
        }
        const key = keys.get(userId);
        if (!key || recipient.keyId !== keyFingerprint(key)) continue;
        const encodedDataKey = decryptAead(
          key,
          recipient.wrappedKey,
          `MaterialKompass identity-wrap:v2:${userId}:${envelope.field}`,
        );
        const dataKey = Buffer.from(encodedDataKey, 'base64url');
        if (dataKey.length !== 32) throw new Error('Ungültiges Identity-Chiffrat.');
        try {
          return {
            protected: true,
            erased: false,
            userId,
            userIds,
            field: envelope.field,
            value: decryptAead(
              dataKey,
              envelope.ciphertext,
              `MaterialKompass identity:v2:${envelope.field}`,
            ),
          };
        } finally {
          dataKey.fill(0);
        }
      }
      const fallbackUserId = userIds[0];
      return {
        protected: true,
        erased: true,
        userId: fallbackUserId,
        userIds,
        field: envelope.field,
        value: erasedIdentity(fallbackUserId)[envelope.field],
      };
    }
    const parts = token.slice(TOKEN_PREFIX.length).split(':');
    if (parts.length !== 6) throw new Error('Ungültiges Identity-Chiffrat.');
    const [encodedId, field, keyId, iv, tag, ciphertext] = parts;
    if (!IDENTITY_FIELDS.includes(field) && field !== 'collection') {
      throw new Error('Ungültiges Identity-Feld.');
    }
    const userId = Buffer.from(encodedId, 'base64url').toString('utf8');
    const key = keys.get(userId);
    if (!key || keyId !== keyFingerprint(key)) {
      const fallback = erasedIdentity(userId);
      return {
        protected: true,
        erased: true,
        userId,
        field,
        value: field === 'collection' ? fallback.username : fallback[field],
      };
    }
    const aad = `MaterialKompass identity:v1:${userId}:${field}`;
    return {
      protected: true,
      erased: false,
      userId,
      field,
      value: decryptAead(key, [iv, tag, ciphertext], aad),
    };
  }

  function protectUserRecord(user) {
    if (user.identityErased) return { identityCiphertext: null, identityErased: true };
    const id = String(user.id);
    const value = JSON.stringify(Object.fromEntries(
      IDENTITY_FIELDS.map((field) => [field, String(user[field] || '')]),
    ));
    return {
      identityCiphertext: encryptForUser(id, 'collection', value),
      identityErased: false,
    };
  }

  function unprotectUserRecord(user, identityCiphertext, identityErased = false) {
    if (identityErased) return tombstoneUser(user);
    if (!identityCiphertext) {
      registerIdentity(user);
      return user;
    }
    const result = decryptToken(identityCiphertext);
    if (result.erased) return tombstoneUser(user);
    let identity;
    try { identity = JSON.parse(result.value); } catch (_) {
      throw new Error(`Identity-Chiffrat für ${user.id} enthält ungültige Daten.`);
    }
    if (result.userId !== String(user.id)
      || IDENTITY_FIELDS.some((field) => typeof identity[field] !== 'string')) {
      throw new Error(`Identity-Chiffrat für ${user.id} ist nicht an das Konto gebunden.`);
    }
    const restored = { ...user, ...identity, identityErased: false };
    registerIdentity(restored);
    return restored;
  }

  function identityRecipients(value, keyName, allowGenericIdentityFields) {
    const normalized = normalize(value);
    const lowerKey = String(keyName).toLowerCase();
    if (!normalized || !IDENTITY_REFERENCE_KEYS.has(lowerKey)) return [];
    if (['name', 'email', 'label'].includes(lowerKey) && !allowGenericIdentityFields) {
      return [];
    }
    const fields = lowerKey.includes('email') ? ['email']
      : lowerKey === 'username'
        ? ['username']
        : lowerKey.includes('name') || ['author', 'assignee', 'inspector', 'label'].includes(lowerKey)
          ? ['name', 'username', 'email']
          : ['username', 'name'];
    const matches = [];
    for (const [userId, identity] of identities) {
      const candidates = [identity, ...(identityAliases.get(userId) || [])];
      const field = fields.find((candidate) => candidates.some(
        (entry) => normalize(entry[candidate]) === normalized,
      ));
      if (field) {
        matches.push({ userId, field });
      }
    }
    return matches.sort((left, right) => left.userId.localeCompare(right.userId));
  }

  function protectValue(value, keyName = '', options = {}) {
    if (Array.isArray(value)) {
      return value.map((entry) => protectValue(entry, keyName, options));
    }
    if (value && typeof value === 'object') {
      return Object.fromEntries(Object.entries(value)
        .map(([key, entry]) => [key, protectValue(entry, key, options)]));
    }
    if (typeof value !== 'string'
      || value.startsWith(TOKEN_PREFIX) || value.startsWith(MULTI_TOKEN_PREFIX)) return value;
    const recipients = identityRecipients(
      value,
      keyName,
      options.allowGenericIdentityFields === true,
    );
    if (recipients.length === 0) return value;
    if (recipients.length > 1) return encryptForRecipients(recipients, value);
    return encryptForUser(recipients[0].userId, recipients[0].field, value);
  }

  function unprotectValue(value, erasedUserIds = new Set()) {
    if (Array.isArray(value)) return value.map((entry) => unprotectValue(entry, erasedUserIds));
    if (value && typeof value === 'object') {
      return Object.fromEntries(Object.entries(value)
        .map(([key, entry]) => [key, unprotectValue(entry, erasedUserIds)]));
    }
    if (typeof value !== 'string'
      || (!value.startsWith(TOKEN_PREFIX) && !value.startsWith(MULTI_TOKEN_PREFIX))) return value;
    const result = decryptToken(value);
    if (result.erased) (result.userIds || [result.userId])
      .forEach((userId) => erasedUserIds.add(userId));
    else if (IDENTITY_FIELDS.includes(result.field)) {
      (result.userIds || [result.userId]).forEach((userId) => {
        addIdentityAlias(userId, { [result.field]: result.value });
      });
    }
    return result.value;
  }

  async function protectBackupData(data) {
    const copy = structuredClone(data);
    await ensureUsers(copy.users || []);
    for (const user of copy.users || []) {
      if (user.identityErased) continue;
      for (const field of IDENTITY_FIELDS) {
        user[field] = encryptForUser(user.id, field, user[field] || '');
      }
    }
    const genericIdentityCollections = new Set([
      'procurementRequests', 'serviceDevices', 'qrLoginCredentials',
    ]);
    for (const [name, entries] of Object.entries(copy)) {
      if (name !== 'users') copy[name] = protectValue(entries, '', {
        allowGenericIdentityFields: genericIdentityCollections.has(name),
      });
    }
    return copy;
  }

  function unprotectBackupData(data) {
    const copy = structuredClone(data);
    const erasedUserIds = new Set();
    copy.users = (copy.users || []).map((user) => {
      if (user.identityErased) {
        erasedUserIds.add(String(user.id));
        return tombstoneUser(user);
      }
      const identity = {};
      let erased = false;
      for (const field of IDENTITY_FIELDS) {
        const result = decryptToken(user[field]);
        if (!result.protected || result.userId !== String(user.id) || result.field !== field) {
          throw new Error(`Die Identität von ${user.id} ist nicht geschützt oder falsch gebunden.`);
        }
        identity[field] = result.value;
        erased ||= result.erased;
      }
      if (erased) {
        erasedUserIds.add(String(user.id));
        return tombstoneUser(user);
      }
      const restored = { ...user, ...identity, identityErased: false };
      registerIdentity(restored);
      return restored;
    });
    for (const [name, entries] of Object.entries(copy)) {
      if (name !== 'users') copy[name] = unprotectValue(entries, erasedUserIds);
    }
    copy.passkeys = (copy.passkeys || [])
      .filter((entry) => !erasedUserIds.has(String(entry.userId)));
    copy.memberships = (copy.memberships || []).map((entry) => (
      erasedUserIds.has(String(entry.userId))
        ? { ...entry, status: 'archived', scopes: [] }
        : entry
    ));
    return { data: copy, erasedUserIds };
  }

  return {
    destroyUser,
    ensureUser,
    ensureUsers,
    erasedIdentity,
    hasUserKey,
    identityChanged,
    identityValues,
    initialize,
    protectBackupData,
    protectUserRecord,
    protectValue,
    pruneUsers,
    registerIdentity,
    rotateUser,
    tombstoneUser,
    unprotectBackupData,
    unprotectUserRecord,
    unprotectValue,
    get existedAtInitialization() { return existedAtInitialization; },
  };
}

function createMemoryIdentityProtection(masterKey = '1'.repeat(64)) {
  return createIdentityProtection({ masterKey, memoryOnly: true });
}

module.exports = {
  IDENTITY_FIELDS,
  TOKEN_PREFIX,
  createIdentityProtection,
  createMemoryIdentityProtection,
  erasedIdentity,
  pseudonym,
  tombstoneUser,
};
