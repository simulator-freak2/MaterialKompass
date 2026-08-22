const test = require('node:test');
const assert = require('node:assert/strict');

const { createUserStore, sqlDateTime } = require('../src/db/user-store');

test('sqlDateTime converts ISO timestamps to MariaDB DATETIME values', () => {
  assert.equal(sqlDateTime('2026-01-01T00:00:00.000Z'), '2026-01-01 00:00:00');
  assert.equal(sqlDateTime(null), null);
});

test('saveUser converts every timestamp before sending it to MariaDB', async () => {
  let poolOptions;
  let queryValues;
  const database = {
    createPool(options) {
      poolOptions = options;
      return {
        async query(_sql, values) { queryValues = values; },
        async end() {},
      };
    },
  };
  const store = createUserStore(database);

  await store.saveUser({
    id: 'admin-1',
    name: 'Admin',
    username: 'admin',
    email: 'admin@materialkompass.org',
    passwordHash: 'hash',
    roles: ['Admin'],
    permissions: [],
    active: true,
    emailVerifiedAt: '2026-01-01T00:00:00.000Z',
    createdAt: '2026-01-01T00:00:00.000Z',
  });

  assert.equal(poolOptions.timezone, 'Z');
  assert.equal(queryValues[11], '2026-01-01 00:00:00');
  assert.equal(queryValues[28], '2026-01-01 00:00:00');
  assert.equal(queryValues[9], null);
  assert.equal(queryValues[10], null);
  await store.close();
});

test('application collections save only changed values in one transaction', async () => {
  const calls = [];
  const connection = {
    async beginTransaction() { calls.push('begin'); },
    async query(sql, values) { calls.push({ sql, values }); },
    async commit() { calls.push('commit'); },
    async rollback() { calls.push('rollback'); },
    release() { calls.push('release'); },
  };
  const database = {
    createPool() {
      return {
        async query(sql) {
          if (sql.startsWith('SELECT name')) {
            return [{ name: 'locations', data_json: '[{"id":"loc-db"}]' }];
          }
          return [];
        },
        async getConnection() { return connection; },
        async end() {},
      };
    },
  };
  const store = createUserStore(database);

  assert.deepEqual(await store.loadCollections(), { locations: [{ id: 'loc-db' }] });
  await store.saveCollections({ locations: [{ id: 'loc-new' }], auditLogs: [] });

  assert.equal(calls[0], 'begin');
  assert.equal(calls.filter((entry) => entry?.sql?.includes('INSERT INTO application_collections')).length, 2);
  assert.deepEqual(calls.slice(-2), ['commit', 'release']);

  const callCount = calls.length;
  await store.saveCollections({ locations: [{ id: 'loc-new' }], auditLogs: [] });
  assert.equal(calls.length, callCount, 'an unchanged snapshot must not reach MariaDB');

  await store.saveCollections({ locations: [{ id: 'loc-newer' }], auditLogs: [] });
  assert.equal(
    calls.slice(callCount).filter((entry) => entry?.sql?.includes('INSERT INTO application_collections')).length,
    1,
  );
});

test('process lock prevents concurrent snapshot-based backend instances', async () => {
  const calls = [];
  const connection = {
    async query(sql, values) {
      calls.push({ sql, values });
      if (sql.startsWith('SELECT GET_LOCK')) return [{ acquired: 1 }];
      return [{ released: 1 }];
    },
    release() { calls.push('release'); },
  };
  const database = {
    createPool() {
      return {
        async getConnection() { return connection; },
        async end() { calls.push('end'); },
      };
    },
  };
  const store = createUserStore(database);

  await store.acquireProcessLock();
  await store.close();

  assert.match(calls[0].sql, /GET_LOCK/);
  assert.match(calls[1].sql, /RELEASE_LOCK/);
  assert.deepEqual(calls.slice(-2), ['release', 'end']);
});

test('process lock fails fast when another backend owns the database', async () => {
  let released = false;
  const database = {
    createPool() {
      return {
        async getConnection() {
          return {
            async query() { return [{ acquired: 0 }]; },
            release() { released = true; },
          };
        },
        async end() {},
      };
    },
  };
  const store = createUserStore(database);

  await assert.rejects(
    store.acquireProcessLock(),
    /nur eine Instanz/,
  );
  assert.equal(released, true);
  await store.close();
});
