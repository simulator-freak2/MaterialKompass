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
  assert.equal(queryValues[19], '2026-01-01 00:00:00');
  assert.equal(queryValues[9], null);
  assert.equal(queryValues[10], null);
  await store.close();
});
