const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');

async function startApp(options = {}) {
  const app = createApp(options);
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  async function request(path, { method = 'GET', token, body } = {}) {
    const response = await fetch(`${baseUrl}${path}`, {
      method,
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return {
      response,
      data: response.status === 204 ? null : await response.json(),
    };
  }
  async function login(identifier, password) {
    const result = await request('/api/auth/login', {
      method: 'POST', body: { identifier, password },
    });
    assert.equal(result.response.status, 200);
    return result.data.token;
  }
  return { server, request, login };
}

test('admins manage scanner email addresses and changes are persisted', async () => {
  const snapshots = [];
  const { server, request, login } = await startApp({
    dataStore: {
      async saveCollections(snapshot) { snapshots.push(snapshot); },
    },
  });
  try {
    const token = await login('admin', 'MaterialKompass2026!');
    snapshots.length = 0;
    const created = await request('/api/scanner-email-addresses', {
      method: 'POST',
      token,
      body: { localPart: 'maengel', name: 'Mängelscanner', destination: 'Mängel' },
    });
    assert.equal(created.response.status, 201);
    assert.equal(created.data.email, 'maengel@materialkompass.org');
    assert.equal(snapshots.at(-1).scannerEmailAddresses[0].id, created.data.id);

    const duplicate = await request('/api/scanner-email-addresses', {
      method: 'POST',
      token,
      body: { localPart: 'MAENGEL', name: 'Duplikat', destination: 'Mängel' },
    });
    assert.equal(duplicate.response.status, 409);

    const updated = await request(`/api/scanner-email-addresses/${created.data.id}`, {
      method: 'PUT',
      token,
      body: { name: 'Scanner Gerätehaus', destination: 'Dokumente', active: false },
    });
    assert.equal(updated.response.status, 200);
    assert.equal(updated.data.active, false);
    assert.equal(updated.data.destination, 'Dokumente');

    const listed = await request('/api/scanner-email-addresses', { token });
    assert.equal(listed.response.status, 200);
    assert.equal(listed.data.addresses.length, 1);
    assert.deepEqual(listed.data.destinations, [
      'Mängel', 'Dokumente', 'Inventar', 'Kleiderkammer', 'Beschaffung',
    ]);

    const removed = await request(`/api/scanner-email-addresses/${created.data.id}`, {
      method: 'DELETE', token,
    });
    assert.equal(removed.response.status, 204);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('scanner email address management is restricted to admins', async () => {
  const { server, request, login } = await startApp();
  try {
    const token = await login('materialwart', 'Material123!');
    const listed = await request('/api/scanner-email-addresses', { token });
    assert.equal(listed.response.status, 403);
    assert.match(listed.data.error, /Nur Administratoren/);
    const created = await request('/api/scanner-email-addresses', {
      method: 'POST',
      token,
      body: { localPart: 'scan', name: 'Scanner', destination: 'Dokumente' },
    });
    assert.equal(created.response.status, 403);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('scanner email addresses validate local parts and user address collisions', async () => {
  const { server, request, login } = await startApp();
  try {
    const token = await login('admin', 'MaterialKompass2026!');
    const invalid = await request('/api/scanner-email-addresses', {
      method: 'POST',
      token,
      body: { localPart: 'Mängel Scan', name: 'Scanner', destination: 'Mängel' },
    });
    assert.equal(invalid.response.status, 400);

    const userCollision = await request('/api/scanner-email-addresses', {
      method: 'POST',
      token,
      body: { localPart: 'admin', name: 'Scanner', destination: 'Mängel' },
    });
    assert.equal(userCollision.response.status, 409);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
