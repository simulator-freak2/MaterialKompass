const mariadb = require('mariadb');

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
        name VARCHAR(64) PRIMARY KEY,
        data_json LONGTEXT NOT NULL,
        updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
          ON UPDATE CURRENT_TIMESTAMP(3),
        CHECK (JSON_VALID(data_json))
      )`);
      await pool.query(`CREATE TABLE IF NOT EXISTS mailbox_processing_state (
        mailbox VARCHAR(255) PRIMARY KEY,
        uid_validity VARCHAR(64) NOT NULL,
        last_uid BIGINT UNSIGNED NOT NULL,
        initialized_at DATETIME NOT NULL,
        updated_at DATETIME NOT NULL
      )`);
    },

    async load() {
      const [userRows, roleRows] = await Promise.all([
        pool.query('SELECT * FROM users'),
        pool.query('SELECT * FROM roles'),
      ]);
      return {
        users: userRows.map((row) => ({
          id: row.id, name: row.name, username: row.username, email: row.email,
          passwordHash: row.password_hash, roles: parseJson(row.roles),
          departmentIds: parseJson(row.department_ids),
          permissions: parseJson(row.permissions), active: Boolean(row.active),
          failedLoginAttempts: Number(row.failed_login_attempts || 0), lockedUntil: iso(row.locked_until),
          lastLoginAt: iso(row.last_login_at), emailVerifiedAt: iso(row.email_verified_at),
          verificationTokenHash: row.verification_token_hash, verificationExpiresAt: iso(row.verification_expires_at),
          passwordResetTokenHash: row.password_reset_token_hash, passwordResetExpiresAt: iso(row.password_reset_expires_at),
          deactivatedAt: iso(row.deactivated_at), deactivationReason: row.deactivation_reason,
          scheduledDeletionAt: iso(row.scheduled_deletion_at), createdAt: iso(row.created_at),
        })),
        roles: roleRows.map((row) => ({ id: row.id, name: row.name, permissions: parseJson(row.permissions) })),
      };
    },

    async saveUser(user) {
      await pool.query(`INSERT INTO users (
        id, name, username, email, password_hash, roles, permissions, active,
        failed_login_attempts, locked_until, last_login_at, email_verified_at,
        verification_token_hash, verification_expires_at, password_reset_token_hash,
        password_reset_expires_at, deactivated_at, deactivation_reason,
        scheduled_deletion_at, created_at, department_ids
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON DUPLICATE KEY UPDATE name=VALUES(name), username=VALUES(username), email=VALUES(email),
        password_hash=VALUES(password_hash), roles=VALUES(roles), department_ids=VALUES(department_ids),
        permissions=VALUES(permissions),
        active=VALUES(active), failed_login_attempts=VALUES(failed_login_attempts),
        locked_until=VALUES(locked_until), last_login_at=VALUES(last_login_at),
        email_verified_at=VALUES(email_verified_at), verification_token_hash=VALUES(verification_token_hash),
        verification_expires_at=VALUES(verification_expires_at), password_reset_token_hash=VALUES(password_reset_token_hash),
        password_reset_expires_at=VALUES(password_reset_expires_at), deactivated_at=VALUES(deactivated_at),
        deactivation_reason=VALUES(deactivation_reason), scheduled_deletion_at=VALUES(scheduled_deletion_at)`, [
        user.id, user.name, user.username, user.email, user.passwordHash,
        JSON.stringify(user.roles || []), JSON.stringify(user.permissions || []), user.active ? 1 : 0,
        user.failedLoginAttempts || 0, sqlDateTime(user.lockedUntil), sqlDateTime(user.lastLoginAt),
        sqlDateTime(user.emailVerifiedAt), user.verificationTokenHash || null, sqlDateTime(user.verificationExpiresAt),
        user.passwordResetTokenHash || null, sqlDateTime(user.passwordResetExpiresAt), sqlDateTime(user.deactivatedAt),
        user.deactivationReason || null, sqlDateTime(user.scheduledDeletionAt), sqlDateTime(user.createdAt),
        JSON.stringify(user.departmentIds || []),
      ]);
    },

    async deleteUser(id) { await pool.query('DELETE FROM users WHERE id = ?', [id]); },
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
      await pool.query(`INSERT INTO roles (id, name, permissions) VALUES (?, ?, ?)
        ON DUPLICATE KEY UPDATE name=VALUES(name), permissions=VALUES(permissions)`,
      [role.id, role.name, JSON.stringify(role.permissions || [])]);
    },
    async deleteRole(id) { await pool.query('DELETE FROM roles WHERE id = ?', [id]); },
    async loadCollections() {
      const rows = await pool.query('SELECT name, data_json FROM application_collections');
      return Object.fromEntries(rows.map((row) => {
        const data = parseJson(row.data_json);
        serializedCollections.set(row.name, JSON.stringify(data));
        return [row.name, data];
      }));
    },
    async saveCollections(collections) {
      // Most requests touch one domain collection plus the audit log. Avoid
      // rewriting every JSON collection on every mutation while retaining the
      // existing atomic snapshot semantics for the collections that changed.
      const entries = Object.entries(collections)
        .map(([name, data]) => [name, JSON.stringify(data)])
        .filter(([name, serialized]) => serializedCollections.get(name) !== serialized);
      if (entries.length === 0) return;
      let connection;
      try {
        connection = await pool.getConnection();
        await connection.beginTransaction();
        for (const [name, serialized] of entries) {
          await connection.query(`INSERT INTO application_collections (name, data_json)
            VALUES (?, ?) ON DUPLICATE KEY UPDATE data_json=VALUES(data_json)`,
          [name, serialized]);
        }
        await connection.commit();
        entries.forEach(([name, serialized]) => {
          serializedCollections.set(name, serialized);
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
