const test = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');

async function setup() {
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
  const request = async (path, { method = 'GET', token, body } = {}) => {
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
  };
  const login = await request('/api/auth/login', {
    method: 'POST',
    body: { identifier: 'admin', password: 'MaterialKompass2026!' },
  });
  assert.equal(login.response.status, 200);
  return { server, request, snapshots, adminToken: login.data.token };
}

test('self-issued QR login is opaque, hashed at rest and single-use', async () => {
  const { server, request, snapshots, adminToken } = await setup();
  try {
    const issued = await request('/api/auth/qr-credentials/me', {
      method: 'POST', token: adminToken, body: {},
    });
    assert.equal(issued.response.status, 201);
    assert.match(issued.data.qrValue, /^mkqr:v1:[A-Za-z0-9_-]{43}$/);
    assert.equal(issued.data.qrValue.includes('admin'), false);

    const persisted = snapshots.at(-1).qrLoginCredentials[0];
    assert.equal(persisted.qrValue, undefined);
    assert.match(persisted.credentialHash, /^[a-f0-9]{64}$/);

    const firstUse = await request('/api/auth/qr-login', {
      method: 'POST', body: { credential: issued.data.qrValue },
    });
    assert.equal(firstUse.response.status, 200);
    assert.ok(firstUse.data.token);

    const secondUse = await request('/api/auth/qr-login', {
      method: 'POST', body: { credential: issued.data.qrValue },
    });
    assert.equal(secondUse.response.status, 401);
  } finally {
    server.close();
  }
});

test('admin can issue a QR login for another active user', async () => {
  const { server, request, adminToken } = await setup();
  try {
    const issued = await request('/api/users/user-materialwart/qr-credential', {
      method: 'POST', token: adminToken, body: {},
    });
    assert.equal(issued.response.status, 201);

    const used = await request('/api/auth/qr-login', {
      method: 'POST', body: { credential: issued.data.qrValue },
    });
    assert.equal(used.response.status, 200);
    assert.equal(used.data.user.id, 'user-materialwart');
  } finally {
    server.close();
  }
});
