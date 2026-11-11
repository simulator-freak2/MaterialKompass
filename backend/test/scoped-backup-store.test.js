const test = require('node:test');
const assert = require('node:assert/strict');
const { createUserStore } = require('../src/db/user-store');

function setup({ failWrite = false } = {}) {
  const calls = [];
  const foreign = { id: 'foreign', organizationId: 'org', unitId: 'sibling', name: 'latest foreign data' };
  const connection = {
    async beginTransaction() { calls.push(['begin']); },
    async query(sql, values) {
      calls.push([sql, values]);
      if (sql.startsWith('SELECT')) return [{ data_json: JSON.stringify([
        foreign, { id: 'old', organizationId: 'org', unitId: 'local' },
      ]) }];
      if (failWrite) throw new Error('dummy storage failure');
      return [];
    },
    async commit() { calls.push(['commit']); },
    async rollback() { calls.push(['rollback']); },
    release() { calls.push(['release']); },
  };
  const store = createUserStore({ createPool: () => ({
    async getConnection() { return connection; }, async end() {},
  }) }, { identityProtection: { protectValue: (value) => value, unprotectValue: (value) => value } });
  const scope = { type: 'units', organizationId: 'org', unitIds: ['local'] };
  const collections = { materials: [{ id: 'restored', organizationId: 'org', unitId: 'local' }] };
  return { store, calls, foreign, scope, collections };
}

test('scoped restore locks and merges one organization partition without touching accounts', async () => {
  const { store, calls, foreign, scope, collections } = setup();
  await store.replaceScopedBackupData({ scope, collections });
  const select = calls.find(([sql]) => sql.startsWith('SELECT'));
  assert.match(select[0], /FOR UPDATE$/);
  assert.deepEqual(select[1], ['org', 'materials']);
  const write = calls.find(([sql]) => sql.startsWith('INSERT'));
  assert.deepEqual(JSON.parse(write[1][2]), [foreign, ...collections.materials]);
  assert.ok(calls.some(([sql]) => sql === 'commit'));
  assert.ok(calls.every(([sql]) => !/DELETE|\busers\b|\broles\b|user_passkeys/.test(sql)));
  await store.close();
});

test('failed scoped restore rolls back and rejects protected collections before storage', async () => {
  const { store, calls, scope, collections } = setup({ failWrite: true });
  await assert.rejects(store.replaceScopedBackupData({ scope, collections }), /dummy storage failure/);
  assert.ok(calls.some(([sql]) => sql === 'rollback'));
  assert.ok(!calls.some(([sql]) => sql === 'commit'));
  const previousCalls = calls.length;
  await assert.rejects(store.replaceScopedBackupData({ scope, collections: { users: [] } }), /Unzulässige/);
  assert.equal(calls.length, previousCalls);
  await store.close();
});
