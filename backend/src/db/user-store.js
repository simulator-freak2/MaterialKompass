const mariadb = require('mariadb');
const crypto = require('node:crypto');
const { DEFAULT_ORGANIZATION_ID } = require('../tenancy');

const PLATFORM_COLLECTIONS = new Set([
  'organizations', 'organizationUnits', 'memberships', 'permissions',
]);
const PLATFORM_SCOPE = '__platform__';

function parseJson(value, fallback = []) {
  if (Array.isArray(value)) return value;
  try { return JSON.parse(value); } catch (_) { return fallback; }
}

function iso(value) {
  if (!value) return null;
  return value instanceof Date ? value.toISOString() : new Date(value).toISOString();
}

function sqlDateTime(value) {
  if (!value) return null;
  return new Date(value).toISOString().slice(0, 19).replace('T', ' ');
}

function createUserStore(database = mariadb) {
  const connectionLimit = Number(process.env.DB_CONNECTION_LIMIT || 5);
  if (!Number.isInteger(connectionLimit) || connectionLimit < 2) {
    throw new Error(
      'DB_CONNECTION_LIMIT muss wegen der exklusiven Instanzsperre mindestens 2 sein.',
    );
  }
  const pool = database.createPool({
    host: process.env.DB_HOST,
    port: Number(process.env.DB_PORT || 3306),
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    database: process.env.DB_NAME || 'materialkompass',
    connectionLimit,
    ssl: process.env.DB_SSL === 'true',
    timezone: 'Z',
  });
  let processLockConnection;
  let processLockName;
  const serializedCollections = new Map();

  return {
    async acquireProcessLock(
      name = `materialkompass-backend:${process.env.DB_NAME || 'materialkompass'}`,
    ) {
      const connection = await pool.getConnection();
      try {
        const rows = await connection.query('SELECT GET_LOCK(?, 0) AS acquired', [name]);
        if (Number(rows[0]?.acquired) !== 1) {
          throw new Error(
            'Eine andere Backend-Instanz verwendet bereits diese Datenbank. '
            + 'Der aktuelle Persistenzmodus unterstützt nur eine Instanz.',
          );
        }
        processLockConnection = connection;
        processLockName = name;
      } catch (error) {
        connection.release();
        throw error;
      }
    },

    async checkHealth() {
      await pool.query('SELECT 1');
    },

    async initialize() {
      await pool.query(`CREATE TABLE IF NOT EXISTS application_collections (
        organization_id VARCHAR(64) NOT NULL,
        name VARCHAR(64) NOT NULL,
        data_json LONGTEXT NOT NULL,
        updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
          ON UPDATE CURRENT_TIMESTAMP(3),
        PRIMARY KEY (organization_id, name),
        INDEX idx_application_collections_name (name),
        CHECK (JSON_VALID(data_json))
      )`);
      await pool.query(`CREATE TABLE IF NOT EXISTS mailbox_processing_state (
        mailbox VARCHAR(255) PRIMARY KEY,
        uid_validity VARCHAR(64) NOT NULL,
        last_uid BIGINT UNSIGNED NOT NULL,
        initialized_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL
      )`);
      await pool.query(`CREATE TABLE IF NOT EXISTS user_passkeys (
        id CHAR(36) PRIMARY KEY,
        user_id VARCHAR(64) NOT NULL,
        user_handle VARCHAR(86) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        credential_id TEXT CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
        credential_id_hash BINARY(32) NOT NULL,
        public_key BLOB NOT NULL,
        signature_counter BIGINT UNSIGNED NOT NULL DEFAULT 0,
        transports JSON NOT NULL,
        device_type VARCHAR(32) NOT NULL,
        backed_up TINYINT(1) NOT NULL DEFAULT 0,
        name VARCHAR(100) NOT NULL,
        created_at DATETIME(3) NOT NULL,
        last_used_at DATETIME(3) NULL,
        updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
          ON UPDATE CURRENT_TIMESTAMP(3),
        UNIQUE KEY uq_user_passkeys_credential_hash (credential_id_hash),
        INDEX idx_user_passkeys_user_id (user_id),
        CONSTRAINT fk_user_passkeys_user FOREIGN KEY (user_id)
          REFERENCES users(id) ON DELETE CASCADE,
        CHECK (JSON_VALID(transports))
      )`);
    },

    async load() {
      const [userRows, roleRows, passkeyRows] = await Promise.all([
        pool.query('SELECT * FROM users'),
        pool.query('SELECT * FROM roles'),
        pool.query('SELECT * FROM user_passkeys'),
      ]);
      return {
        users: userRows.map((row) => ({
          id: row.id, name: row.name, username: row.username, email: row.email,
          passwordHash: row.password_hash, roles: parseJson(row.roles),
          platformAdmin: Boolean(row.platform_admin),
          departmentIds: parseJson(row.department_ids),
          permissions: parseJson(row.permissions), active: Boolean(row.active),
          failedLoginAttempts: Number(row.failed_login_attempts || 0), lockedUntil: iso(row.locked_until),
          lastLoginAt: iso(row.last_login_at), emailVerifiedAt: iso(row.email_verified_at),
          verificationTokenHash: row.verification_token_hash, verificationExpiresAt: iso(row.verification_expires_at),
          passwordResetTokenHash: row.password_reset_token_hash, passwordResetExpiresAt: iso(row.password_reset_expires_at),
          mfaRequired: Boolean(row.mfa_required), mfaSecretEncrypted: row.mfa_secret_encrypted,
          mfaPendingSecretEncrypted: row.mfa_pending_secret_encrypted,
          mfaPendingSecretExpiresAt: iso(row.mfa_pending_secret_expires_at),
          mfaRecoveryCodeHashes: parseJson(row.mfa_recovery_code_hashes),
          mfaEnabledAt: iso(row.mfa_enabled_at), mfaLastVerifiedAt: iso(row.mfa_last_verified_at),
          mfaGraceEndsAt: iso(row.mfa_grace_ends_at), mfaVersion: Number(row.mfa_version || 0),
          deactivatedAt: iso(row.deactivated_at), deactivationReason: row.deactivation_reason,
          scheduledDeletionAt: iso(row.scheduled_deletion_at), createdAt: iso(row.created_at),
        })),
        roles: roleRows.map((row) => ({
          id: row.id,
          organizationId: row.organization_id || null,
          name: row.name,
          permissions: parseJson(row.permissions),
        })),
        passkeys: passkeyRows.map((row) => ({
          id: row.id,
          userId: row.user_id,
          userHandle: row.user_handle,
          credentialId: row.credential_id,
          publicKey: Buffer.from(row.public_key).toString('base64url'),
          counter: Number(row.signature_counter || 0),
          transports: parseJson(row.transports),
          deviceType: row.device_type,
          backedUp: Boolean(row.backed_up),
          name: row.name,
          createdAt: iso(row.created_at),
          lastUsedAt: iso(row.last_used_at),
        })),
      };
    },

    async saveUser(user) {
      user = user?.__identity || user;
      await pool.query(`INSERT INTO users (
        id, name, username, email, password_hash, roles, permissions, platform_admin, active,
        failed_login_attempts, locked_until, last_login_at, email_verified_at,
        verification_token_hash, verification_expires_at, password_reset_token_hash,
        password_reset_expires_at, mfa_required, mfa_secret_encrypted,
        mfa_pending_secret_encrypted, mfa_pending_secret_expires_at,
        mfa_recovery_code_hashes, mfa_enabled_at,
        mfa_last_verified_at, mfa_grace_ends_at, mfa_version,
        deactivated_at, deactivation_reason, scheduled_deletion_at, created_at, department_ids
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON DUPLICATE KEY UPDATE name=VALUES(name), username=VALUES(username), email=VALUES(email),
        password_hash=VALUES(password_hash), roles=VALUES(roles), department_ids=VALUES(department_ids),
        permissions=VALUES(permissions), platform_admin=VALUES(platform_admin),
        active=VALUES(active), failed_login_attempts=VALUES(failed_login_attempts),
        locked_until=VALUES(locked_until), last_login_at=VALUES(last_login_at),
        email_verified_at=VALUES(email_verified_at), verification_token_hash=VALUES(verification_token_hash),
        verification_expires_at=VALUES(verification_expires_at), password_reset_token_hash=VALUES(password_reset_token_hash),
        password_reset_expires_at=VALUES(password_reset_expires_at), mfa_required=VALUES(mfa_required),
        mfa_secret_encrypted=VALUES(mfa_secret_encrypted),
        mfa_pending_secret_encrypted=VALUES(mfa_pending_secret_encrypted),
        mfa_pending_secret_expires_at=VALUES(mfa_pending_secret_expires_at),
        mfa_recovery_code_hashes=VALUES(mfa_recovery_code_hashes),
        mfa_enabled_at=VALUES(mfa_enabled_at), mfa_last_verified_at=VALUES(mfa_last_verified_at),
        mfa_grace_ends_at=VALUES(mfa_grace_ends_at), mfa_version=VALUES(mfa_version),
        deactivated_at=VALUES(deactivated_at),
        deactivation_reason=VALUES(deactivation_reason), scheduled_deletion_at=VALUES(scheduled_deletion_at)`, [
        user.id, user.name, user.username, user.email, user.passwordHash,
        JSON.stringify(user.roles || []), JSON.stringify(user.permissions || []),
        user.platformAdmin ? 1 : 0, user.active ? 1 : 0,
        user.failedLoginAttempts || 0, sqlDateTime(user.lockedUntil), sqlDateTime(user.lastLoginAt),
        sqlDateTime(user.emailVerifiedAt), user.verificationTokenHash || null, sqlDateTime(user.verificationExpiresAt),
        user.passwordResetTokenHash || null, sqlDateTime(user.passwordResetExpiresAt),
        user.mfaRequired ? 1 : 0, user.mfaSecretEncrypted || null,
        user.mfaPendingSecretEncrypted || null, sqlDateTime(user.mfaPendingSecretExpiresAt),
        JSON.stringify(user.mfaRecoveryCodeHashes || []),
        sqlDateTime(user.mfaEnabledAt), sqlDateTime(user.mfaLastVerifiedAt),
        sqlDateTime(user.mfaGraceEndsAt), Number(user.mfaVersion || 0), sqlDateTime(user.deactivatedAt),
        user.deactivationReason || null, sqlDateTime(user.scheduledDeletionAt), sqlDateTime(user.createdAt),
        JSON.stringify(user.departmentIds || []),
      ]);
    },

    async deleteUser(id) { await pool.query('DELETE FROM users WHERE id = ?', [id]); },
    async savePasskey(passkey) {
      const credentialHash = crypto.createHash('sha256')
        .update(passkey.credentialId).digest();
      await pool.query(`INSERT INTO user_passkeys (
        id, user_id, user_handle, credential_id, credential_id_hash, public_key,
        signature_counter, transports, device_type, backed_up, name, created_at, last_used_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON DUPLICATE KEY UPDATE signature_counter=VALUES(signature_counter),
        transports=VALUES(transports), device_type=VALUES(device_type),
        backed_up=VALUES(backed_up), name=VALUES(name),
        last_used_at=VALUES(last_used_at)`, [
        passkey.id,
        passkey.userId,
        passkey.userHandle,
        passkey.credentialId,
        credentialHash,
        Buffer.from(passkey.publicKey, 'base64url'),
        Number(passkey.counter || 0),
        JSON.stringify(passkey.transports || []),
        passkey.deviceType,
        passkey.backedUp ? 1 : 0,
        passkey.name,
        sqlDateTime(passkey.createdAt),
        sqlDateTime(passkey.lastUsedAt),
      ]);
    },
    async deletePasskey(id) {
      await pool.query('DELETE FROM user_passkeys WHERE id = ?', [id]);
    },
    async deleteUserPasskeys(userId) {
      await pool.query('DELETE FROM user_passkeys WHERE user_id = ?', [userId]);
    },
    async getMailboxProcessingState(mailbox) {
      const rows = await pool.query(
        'SELECT * FROM mailbox_processing_state WHERE mailbox = ?',
        [mailbox],
      );
      const row = rows[0];
      return row ? {
        mailbox: row.mailbox,
        uidValidity: String(row.uid_validity),
        lastUid: Number(row.last_uid),
        initializedAt: iso(row.initialized_at),
      } : null;
    },
    async saveMailboxProcessingState({
      mailbox,
      uidValidity,
      lastUid,
      initializedAt = new Date(),
    }) {
      await pool.query(`INSERT INTO mailbox_processing_state
        (mailbox, uid_validity, last_uid, initialized_at, updated_at)
        VALUES (?, ?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE uid_validity=VALUES(uid_validity),
          last_uid=VALUES(last_uid), initialized_at=VALUES(initialized_at),
          updated_at=VALUES(updated_at)`, [
        mailbox,
        String(uidValidity),
        lastUid,
        sqlDateTime(initializedAt),
        sqlDateTime(new Date()),
      ]);
    },
    async saveRole(role) {
      await pool.query(`INSERT INTO roles (id, organization_id, name, permissions)
        VALUES (?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE organization_id=VALUES(organization_id),
          name=VALUES(name), permissions=VALUES(permissions)`,
      [role.id, role.organizationId || null, role.name, JSON.stringify(role.permissions || [])]);
    },
    async deleteRole(id) { await pool.query('DELETE FROM roles WHERE id = ?', [id]); },
    async loadCollections() {
      const rows = await pool.query(
        'SELECT name, organization_id, data_json FROM application_collections',
      );
      const collections = {};
      rows.forEach((row) => {
        const data = parseJson(row.data_json);
        const scope = row.organization_id || DEFAULT_ORGANIZATION_ID;
        serializedCollections.set(`${scope}:${row.name}`, JSON.stringify(data));
        collections[row.name] ||= [];
        collections[row.name].push(...data);
      });
      return collections;
    },
    async saveCollections(collections) {
      // Most requests touch one domain collection plus the audit log. Avoid
      // rewriting every JSON collection on every mutation while retaining the
      // existing atomic snapshot semantics for the collections that changed.
      const partitions = [];
      for (const [name, data] of Object.entries(collections)) {
        if (PLATFORM_COLLECTIONS.has(name)) {
          partitions.push([PLATFORM_SCOPE, name, JSON.stringify(data)]);
          continue;
        }
        const grouped = new Map();
        for (const entry of data) {
          const organizationId = entry?.organizationId || DEFAULT_ORGANIZATION_ID;
          if (!grouped.has(organizationId)) grouped.set(organizationId, []);
          grouped.get(organizationId).push(entry);
        }
        if (grouped.size === 0) grouped.set(DEFAULT_ORGANIZATION_ID, []);
        grouped.forEach((values, organizationId) => {
          partitions.push([organizationId, name, JSON.stringify(values)]);
        });
      }
      const entries = partitions.filter(([organizationId, name, serialized]) =>
        serializedCollections.get(`${organizationId}:${name}`) !== serialized
      );
      if (entries.length === 0) return;
      let connection;
      try {
        connection = await pool.getConnection();
        await connection.beginTransaction();
        for (const [organizationId, name, serialized] of entries) {
          await connection.query(`INSERT INTO application_collections
            (organization_id, name, data_json) VALUES (?, ?, ?)
            ON DUPLICATE KEY UPDATE data_json=VALUES(data_json)`,
          [organizationId, name, serialized]);
        }
        await connection.commit();
        entries.forEach(([organizationId, name, serialized]) => {
          serializedCollections.set(`${organizationId}:${name}`, serialized);
        });
      } catch (error) {
        if (connection) await connection.rollback();
        throw error;
      } finally {
        if (connection) connection.release();
      }
    },
    async replaceBackupData({ users, roles, passkeys, collections }) {
      let connection;
      const serialized = [];
      for (const [name, data] of Object.entries(collections)) {
        if (PLATFORM_COLLECTIONS.has(name)) {
          serialized.push([PLATFORM_SCOPE, name, JSON.stringify(data)]);
          continue;
        }
        const grouped = new Map();
        for (const entry of data) {
          const organizationId = entry?.organizationId || DEFAULT_ORGANIZATION_ID;
          if (!grouped.has(organizationId)) grouped.set(organizationId, []);
          grouped.get(organizationId).push(entry);
        }
        if (grouped.size === 0) grouped.set(DEFAULT_ORGANIZATION_ID, []);
        grouped.forEach((values, organizationId) => {
          serialized.push([organizationId, name, JSON.stringify(values)]);
        });
      }
      try {
        connection = await pool.getConnection();
        await connection.beginTransaction();
        await connection.query('DELETE FROM user_passkeys');
        await connection.query('DELETE FROM users');
        await connection.query('DELETE FROM roles');
        await connection.query('DELETE FROM application_collections');

        if (roles.length > 0) {
          await connection.batch(
            'INSERT INTO roles (id, organization_id, name, permissions) VALUES (?, ?, ?, ?)',
            roles.map((role) => [
              role.id, role.organizationId || null, role.name,
              JSON.stringify(role.permissions || []),
            ]),
          );
        }
        if (users.length > 0) {
          await connection.batch(`INSERT INTO users (
            id, name, username, email, password_hash, roles, permissions, active,
            failed_login_attempts, locked_until, last_login_at, email_verified_at,
            verification_token_hash, verification_expires_at, password_reset_token_hash,
            password_reset_expires_at, mfa_required, mfa_secret_encrypted,
            mfa_pending_secret_encrypted, mfa_pending_secret_expires_at,
            mfa_recovery_code_hashes, mfa_enabled_at, mfa_last_verified_at,
            mfa_grace_ends_at, mfa_version, deactivated_at, deactivation_reason,
            scheduled_deletion_at, created_at, department_ids
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          users.map((user) => [
            user.id, user.name || '', user.username, user.email, user.passwordHash,
            JSON.stringify(user.roles || []), JSON.stringify(user.permissions || []), user.active ? 1 : 0,
            user.failedLoginAttempts || 0, sqlDateTime(user.lockedUntil), sqlDateTime(user.lastLoginAt),
            sqlDateTime(user.emailVerifiedAt), user.verificationTokenHash || null,
            sqlDateTime(user.verificationExpiresAt), user.passwordResetTokenHash || null,
            sqlDateTime(user.passwordResetExpiresAt), user.mfaRequired ? 1 : 0,
            user.mfaSecretEncrypted || null, user.mfaPendingSecretEncrypted || null,
            sqlDateTime(user.mfaPendingSecretExpiresAt), JSON.stringify(user.mfaRecoveryCodeHashes || []),
            sqlDateTime(user.mfaEnabledAt), sqlDateTime(user.mfaLastVerifiedAt),
            sqlDateTime(user.mfaGraceEndsAt), Number(user.mfaVersion || 0),
            sqlDateTime(user.deactivatedAt), user.deactivationReason || null,
            sqlDateTime(user.scheduledDeletionAt), sqlDateTime(user.createdAt || new Date()),
            JSON.stringify(user.departmentIds || []),
          ]));
        }
        if (passkeys.length > 0) {
          await connection.batch(`INSERT INTO user_passkeys (
            id, user_id, user_handle, credential_id, credential_id_hash, public_key,
            signature_counter, transports, device_type, backed_up, name, created_at, last_used_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
          passkeys.map((passkey) => [
            passkey.id, passkey.userId, passkey.userHandle, passkey.credentialId,
            crypto.createHash('sha256').update(passkey.credentialId).digest(),
            Buffer.from(passkey.publicKey, 'base64url'), Number(passkey.counter || 0),
            JSON.stringify(passkey.transports || []), passkey.deviceType,
            passkey.backedUp ? 1 : 0, passkey.name, sqlDateTime(passkey.createdAt),
            sqlDateTime(passkey.lastUsedAt),
          ]));
        }
        if (serialized.length > 0) {
          await connection.batch(
            'INSERT INTO application_collections (organization_id, name, data_json) VALUES (?, ?, ?)',
            serialized,
          );
        }
        await connection.commit();
        serializedCollections.clear();
        serialized.forEach(([organizationId, name, data]) => {
          serializedCollections.set(`${organizationId}:${name}`, data);
        });
      } catch (error) {
        if (connection) await connection.rollback();
        throw error;
      } finally {
        if (connection) connection.release();
      }
    },
    async close() {
      if (processLockConnection) {
        try {
          await processLockConnection.query(
            'SELECT RELEASE_LOCK(?)',
            [processLockName],
          );
        } finally {
          processLockConnection.release();
          processLockConnection = null;
          processLockName = null;
        }
      }
      await pool.end();
    },
  };
}

module.exports = { createUserStore, sqlDateTime };
