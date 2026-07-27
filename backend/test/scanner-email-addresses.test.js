const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');

async function startApp(options = {}) {
  const provisioned = [];
  const app = createApp({
    mailboxProvisioner: {
      async createMailbox(mailbox) { provisioned.push(mailbox); },
    },
    ...options,
  });
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
  return { server, request, login, provisioned };
}

test('admins manage scanner email addresses and changes are persisted', async () => {
  const snapshots = [];
  const { server, request, login, provisioned } = await startApp({
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
    assert.equal(created.data.initialPassword.length, 32);
    assert.equal(created.data.passwordCiphertext, undefined);
    assert.equal(created.data.passwordIv, undefined);
    assert.equal(created.data.passwordTag, undefined);
    assert.equal(provisioned[0].email, created.data.email);
    assert.equal(provisioned[0].password, created.data.initialPassword);
    assert.equal(snapshots.at(-1).scannerEmailAddresses[0].id, created.data.id);
    assert.equal(
      snapshots.at(-1).scannerEmailAddresses[0].initialPassword,
      undefined,
    );
    assert.ok(snapshots.at(-1).scannerEmailAddresses[0].passwordCiphertext);

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
    assert.equal(updated.data.passwordCiphertext, undefined);

    const listed = await request('/api/scanner-email-addresses', { token });
    assert.equal(listed.response.status, 200);
    assert.equal(listed.data.addresses.length, 1);
    assert.equal(listed.data.addresses[0].passwordCiphertext, undefined);
    assert.deepEqual(listed.data.destinations, [
      'Mängel', 'Dokumente', 'Inventar', 'Kleiderkammer', 'Beschaffung',
    ]);

    const wrongPassword = await request(
      `/api/scanner-email-addresses/${created.data.id}/credentials`,
      {
        method: 'POST',
        token,
        body: { password: 'FalschesPasswort!' },
      },
    );
    assert.equal(wrongPassword.response.status, 403);

    const credentials = await request(
      `/api/scanner-email-addresses/${created.data.id}/credentials`,
      {
        method: 'POST',
        token,
        body: { password: 'MaterialKompass2026!' },
      },
    );
    assert.equal(credentials.response.status, 200);
    assert.equal(credentials.data.initialPassword, created.data.initialPassword);

    const removed = await request(`/api/scanner-email-addresses/${created.data.id}`, {
      method: 'DELETE', token,
    });
    assert.equal(removed.response.status, 204);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('failed mailbox provisioning does not create an internal address', async () => {
  const { server, request, login } = await startApp({
    mailboxProvisioner: {
      async createMailbox() {
        const error = new Error('Das Postfach existiert bereits.');
        error.status = 409;
        throw error;
      },
    },
  });
  try {
    const token = await login('admin', 'MaterialKompass2026!');
    const created = await request('/api/scanner-email-addresses', {
      method: 'POST',
      token,
      body: { localPart: 'scanner01', name: 'Scanner', destination: 'Mängel' },
    });
    assert.equal(created.response.status, 409);
    const listed = await request('/api/scanner-email-addresses', { token });
    assert.deepEqual(listed.data.addresses, []);
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
