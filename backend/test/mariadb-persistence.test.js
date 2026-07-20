const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');

test('a write is persisted before its API response completes', async () => {
  const snapshots = [];
  const app = createApp({
    dataStore: {
      async saveCollections(snapshot) { snapshots.push(snapshot); },
    },
  });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  try {
    const login = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: 'admin@materialkompass.org', password: 'MaterialKompass2026!' }),
    });
    const token = (await login.json()).token;
    snapshots.length = 0;

    const response = await fetch(`${baseUrl}/api/locations`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: 'DB-Lager', code: 'DB', type: 'Lager' }),
    });
    assert.equal(response.status, 201);
    const location = await response.json();
    assert.equal(snapshots.length, 1);
    assert.equal(snapshots[0].locations.find((entry) => entry.id === location.id).name, 'DB-Lager');
    assert.ok(snapshots[0].auditLogs.some((entry) => entry.details?.id === location.id));
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
