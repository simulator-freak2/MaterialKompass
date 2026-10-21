const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');
const { seedData } = require('../src/data/seed');

async function start() {
  const data = structuredClone(seedData);
  const deliveries = [];
  const savedDevices = [];
  const deletedDevices = [];
  const app = createApp({
    data,
    mfaPushSender: {
      configured: true,
      async sendApproval(devices, approval) {
        deliveries.push({ devices: structuredClone(devices), approval: structuredClone(approval) });
        return { sent: devices.length, invalidDeviceIds: [] };
      },
    },
    userStore: {
      saveUser: async () => {},
      saveMfaPushDevice: async (device) => savedDevices.push(structuredClone(device)),
      deleteMfaPushDevice: async (id) => deletedDevices.push(id),
    },
  });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  async function request(path, { method = 'GET', token, body } = {}) {
    const response = await fetch(`${baseUrl}${path}`, {
      method,
      headers: {
        ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return {
      response,
      data: response.status === 204 ? null : await response.json(),
    };
  }
  return { server, request, deliveries, savedDevices, deletedDevices };
}

test('a registered app device approves a login push without TOTP or passkey', async () => {
  const { server, request, deliveries, savedDevices } = await start();
  try {
    const firstLogin = await request('/api/auth/login', {
      method: 'POST',
      body: { identifier: 'admin', password: 'MaterialKompass2026!' },
    });
    assert.equal(firstLogin.response.status, 200);

    const registered = await request('/api/users/me/mfa/push-devices', {
      method: 'POST', token: firstLogin.data.token,
      body: {
        name: 'Telefon',
        platform: 'android',
        currentPassword: 'MaterialKompass2026!',
      },
    });
    assert.equal(registered.response.status, 201);
    assert.ok(registered.data.deviceSecret);
    assert.equal(savedDevices.length, 1);
    assert.notEqual(savedDevices[0].secretHash, registered.data.deviceSecret);

    const login = await request('/api/auth/login', {
      method: 'POST',
      body: { identifier: 'admin', password: 'MaterialKompass2026!' },
    });
    assert.equal(login.response.status, 202);
    assert.deepEqual(login.data.methods, ['push']);
    assert.equal(login.data.token, undefined);

    const started = await request('/api/auth/mfa/push/start', {
      method: 'POST', body: { challenge: login.data.challenge },
    });
    assert.equal(started.response.status, 200);
    assert.equal(deliveries.length, 1);
    assert.equal(deliveries[0].devices[0].pushToken, 'self-hosted-long-poll');
    assert.equal(deliveries[0].approval.id, started.data.approvalId);
    assert.match(started.data.matchingCode, /^\d{2}$/);

    const pending = await request('/api/auth/mfa/push/pending', {
      method: 'POST',
      body: {
        deviceId: registered.data.device.id,
        deviceSecret: registered.data.deviceSecret,
      },
    });
    assert.equal(pending.response.status, 200);
    assert.equal(pending.data.matchingCode, started.data.matchingCode);

    const rejectedSecret = await request('/api/auth/mfa/push/respond', {
      method: 'POST',
      body: {
        approvalId: started.data.approvalId,
        deviceId: registered.data.device.id,
        deviceSecret: 'wrong-secret',
        decision: 'approve',
      },
    });
    assert.equal(rejectedSecret.response.status, 401);

    const approved = await request('/api/auth/mfa/push/respond', {
      method: 'POST',
      body: {
        approvalId: started.data.approvalId,
        deviceId: registered.data.device.id,
        deviceSecret: registered.data.deviceSecret,
        matchingCode: started.data.matchingCode,
        decision: 'approve',
      },
    });
    assert.equal(approved.response.status, 204);

    const completed = await request('/api/auth/mfa/push/status', {
      method: 'POST',
      body: {
        challenge: login.data.challenge,
        approvalId: started.data.approvalId,
      },
    });
    assert.equal(completed.response.status, 200);
    assert.ok(completed.data.token);
    assert.equal(completed.data.user.mfa.pushEnabled, true);
    assert.equal(completed.data.user.mfa.strongAuthenticationConfigured, true);

    const reused = await request('/api/auth/mfa/push/status', {
      method: 'POST',
      body: {
        challenge: login.data.challenge,
        approvalId: started.data.approvalId,
      },
    });
    assert.equal(reused.response.status, 401);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('a push approval can be denied and is not converted into a session', async () => {
  const { server, request } = await start();
  try {
    const firstLogin = await request('/api/auth/login', {
      method: 'POST',
      body: { identifier: 'admin', password: 'MaterialKompass2026!' },
    });
    const registered = await request('/api/users/me/mfa/push-devices', {
      method: 'POST', token: firstLogin.data.token,
      body: {
        name: 'Tablet', platform: 'android',
        currentPassword: 'MaterialKompass2026!',
      },
    });
    const login = await request('/api/auth/login', {
      method: 'POST',
      body: { identifier: 'admin', password: 'MaterialKompass2026!' },
    });
    const started = await request('/api/auth/mfa/push/start', {
      method: 'POST', body: { challenge: login.data.challenge },
    });
    assert.equal((await request('/api/auth/mfa/push/respond', {
      method: 'POST',
      body: {
        approvalId: started.data.approvalId,
        deviceId: registered.data.device.id,
        deviceSecret: registered.data.deviceSecret,
        decision: 'deny',
      },
    })).response.status, 204);
    const restartBeforeStatus = await request('/api/auth/mfa/push/start', {
      method: 'POST', body: { challenge: login.data.challenge },
    });
    assert.equal(restartBeforeStatus.response.status, 401);
    const status = await request('/api/auth/mfa/push/status', {
      method: 'POST',
      body: { challenge: login.data.challenge, approvalId: started.data.approvalId },
    });
    assert.equal(status.response.status, 403);
    assert.equal(status.data.token, undefined);
    const restarted = await request('/api/auth/mfa/push/start', {
      method: 'POST', body: { challenge: login.data.challenge },
    });
    assert.equal(restarted.response.status, 401);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('a one-time QR pairing enrolls the separate authenticator and returns a refreshed session', async () => {
  const { server, request } = await start();
  try {
    const login = await request('/api/auth/login', {
      method: 'POST',
      body: { identifier: 'admin', password: 'MaterialKompass2026!' },
    });
    const pairing = await request('/api/users/me/mfa/push-pairings', {
      method: 'POST',
      token: login.data.token,
      body: { currentPassword: 'MaterialKompass2026!' },
    });
    assert.equal(pairing.response.status, 201);
    const pairUri = new URL(pairing.data.qrValue);
    assert.equal(pairUri.protocol, 'materialkompass-auth:');
    assert.equal(pairUri.hostname, 'pair');

    const paired = await request('/api/auth/mfa/push/pair', {
      method: 'POST',
      body: {
        pairToken: pairUri.searchParams.get('token'),
        name: 'Separater Authenticator',
        platform: 'android',
      },
    });
    assert.equal(paired.response.status, 201);
    assert.ok(paired.data.deviceSecret);
    assert.equal(paired.data.device.transport, 'self_hosted');

    const replay = await request('/api/auth/mfa/push/pair', {
      method: 'POST',
      body: {
        pairToken: pairUri.searchParams.get('token'),
        name: 'Replay',
        platform: 'android',
      },
    });
    assert.equal(replay.response.status, 401);

    const status = await request('/api/auth/mfa/push/pairing-status', {
      method: 'POST',
      body: {
        pairingId: pairing.data.pairingId,
        statusToken: pairing.data.statusToken,
      },
    });
    assert.equal(status.response.status, 200);
    assert.ok(status.data.token);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
