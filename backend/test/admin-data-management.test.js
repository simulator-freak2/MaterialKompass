const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');

async function withServer(run) {
  const snapshots = [];
  const app = createApp({
    dataStore: {
      async saveCollections(snapshot) { snapshots.push(snapshot); },
    },
  });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  try {
    await run(`http://127.0.0.1:${server.address().port}`, snapshots);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

async function login(baseUrl, identifier, password) {
  const response = await fetch(`${baseUrl}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ identifier, password }),
  });
  return (await response.json()).token;
}

test('only admins can inspect data deletion areas', async () => {
  await withServer(async (baseUrl) => {
    const token = await login(baseUrl, 'materialwart', 'Material123!');
    const response = await fetch(`${baseUrl}/api/admin/data-management`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    assert.equal(response.status, 403);
  });
});

test('admin can delete only inventory with password and confirmation phrase', async () => {
  await withServer(async (baseUrl, snapshots) => {
    const token = await login(baseUrl, 'admin', 'MaterialKompass2026!');
    const headers = {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    };

    const rejected = await fetch(`${baseUrl}/api/admin/data-management`, {
      method: 'DELETE',
      headers,
      body: JSON.stringify({
        scopes: ['inventory'],
        currentPassword: 'wrong',
        confirmation: 'DATEN LÖSCHEN',
      }),
    });
    assert.equal(rejected.status, 403);

    snapshots.length = 0;
    const deleted = await fetch(`${baseUrl}/api/admin/data-management`, {
      method: 'DELETE',
      headers,
      body: JSON.stringify({
        scopes: ['inventory'],
        currentPassword: 'MaterialKompass2026!',
        confirmation: 'DATEN LÖSCHEN',
      }),
    });
    assert.equal(deleted.status, 200);
    assert.equal(snapshots.at(-1).materials.length, 0);
    assert.equal(snapshots.at(-1).clothingItems.length, 1);
    assert.ok(snapshots.at(-1).auditLogs.some((entry) => entry.action === 'purge'));

    const inventory = await fetch(`${baseUrl}/api/material`, { headers });
    assert.deepEqual(await inventory.json(), []);
    const wardrobe = await fetch(`${baseUrl}/api/clothing`, { headers });
    assert.equal((await wardrobe.json()).length, 1);
  });
});

test('selecting every area clears application collections but preserves admin access', async () => {
  await withServer(async (baseUrl, snapshots) => {
    const token = await login(baseUrl, 'admin', 'MaterialKompass2026!');
    const headers = {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    };
    const overview = await fetch(`${baseUrl}/api/admin/data-management`, { headers });
    const scopes = (await overview.json()).areas.map((area) => area.id);

    const deleted = await fetch(`${baseUrl}/api/admin/data-management`, {
      method: 'DELETE',
      headers,
      body: JSON.stringify({
        scopes,
        currentPassword: 'MaterialKompass2026!',
        confirmation: 'DATEN LÖSCHEN',
      }),
    });
    assert.equal(deleted.status, 200);
    const last = snapshots.at(-1);
    assert.equal(last.materials.length, 0);
    assert.equal(last.clothingItems.length, 0);
    assert.equal(last.categories.length, 0);
    assert.equal(last.locations.length, 0);
    assert.equal(last.procurementRequests.length, 0);
    assert.equal(last.auditLogs.length, 1);

    const me = await fetch(`${baseUrl}/api/auth/me`, { headers });
    assert.equal(me.status, 200);
    assert.deepEqual((await me.json()).user.roles, ['Admin']);
    const users = await fetch(`${baseUrl}/api/users`, { headers });
    assert.equal((await users.json()).length, 1);
  });
});
