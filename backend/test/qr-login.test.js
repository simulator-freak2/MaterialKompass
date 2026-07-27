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

test('QR login supports preset, custom and unlimited validity', async () => {
  const { server, request, adminToken } = await setup();
  try {
    const before = Date.now();
    const preset = await request('/api/auth/qr-credentials/me', {
      method: 'POST', token: adminToken, body: { validity: '12h' },
    });
    assert.equal(preset.response.status, 201);
    assert.equal(preset.data.validity, '12h');
    assert.ok(new Date(preset.data.expiresAt).getTime() >= before + (12 * 60 * 60 * 1000));

    const custom = await request('/api/auth/qr-credentials/me', {
      method: 'POST', token: adminToken, body: { validity: 'custom', customDays: 45 },
    });
    assert.equal(custom.response.status, 201);
    assert.equal(custom.data.customDays, 45);

    const unlimited = await request('/api/auth/qr-credentials/me', {
      method: 'POST', token: adminToken, body: { validity: 'unlimited' },
    });
    assert.equal(unlimited.response.status, 201);
    assert.equal(unlimited.data.expiresAt, null);
    const used = await request('/api/auth/qr-login', {
      method: 'POST', body: { credential: unlimited.data.qrValue },
    });
    assert.equal(used.response.status, 200);
    const reused = await request('/api/auth/qr-login', {
      method: 'POST', body: { credential: unlimited.data.qrValue },
    });
    assert.equal(reused.response.status, 200);
    const stillActive = await request('/api/auth/qr-credentials/me', {
      token: adminToken,
    });
    assert.equal(
      stillActive.data.some((entry) => entry.id === unlimited.data.id),
      true,
    );
    assert.equal(
      stillActive.data.find((entry) => entry.id === unlimited.data.id).oneTime,
      false,
    );

    const invalid = await request('/api/auth/qr-credentials/me', {
      method: 'POST', token: adminToken, body: { validity: 'custom', customDays: 0 },
    });
    assert.equal(invalid.response.status, 400);
  } finally {
    server.close();
  }
});

test('users can keep multiple titled QR codes and revoke one individually', async () => {
  const { server, request, adminToken } = await setup();
  try {
    const tablet = await request('/api/auth/qr-credentials/me', {
      method: 'POST',
      token: adminToken,
      body: { title: 'Tablet Gerätehaus', validity: '30d' },
    });
    const laptop = await request('/api/auth/qr-credentials/me', {
      method: 'POST',
      token: adminToken,
      body: { title: 'Laptop Vorstand', validity: '1y' },
    });
    assert.equal(tablet.response.status, 201);
    assert.equal(laptop.response.status, 201);

    const listed = await request('/api/auth/qr-credentials/me', {
      token: adminToken,
    });
    assert.equal(listed.response.status, 200);
    assert.deepEqual(
      new Set(listed.data.map((entry) => entry.title)),
      new Set(['Tablet Gerätehaus', 'Laptop Vorstand']),
    );
    assert.equal(listed.data.some((entry) => entry.qrValue), false);
    assert.equal(listed.data.some((entry) => entry.credentialHash), false);

    const revoked = await request(
      `/api/auth/qr-credentials/me/${tablet.data.id}`,
      { method: 'DELETE', token: adminToken },
    );
    assert.equal(revoked.response.status, 204);

    const rejected = await request('/api/auth/qr-login', {
      method: 'POST', body: { credential: tablet.data.qrValue },
    });
    assert.equal(rejected.response.status, 401);
    const accepted = await request('/api/auth/qr-login', {
      method: 'POST', body: { credential: laptop.data.qrValue },
    });
    assert.equal(accepted.response.status, 200);
  } finally {
    server.close();
  }
});
