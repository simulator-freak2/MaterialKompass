const test = require('node:test');
const assert = require('node:assert/strict');
const jwt = require('jsonwebtoken');
const crypto = require('node:crypto');
const { createApp } = require('../src/app');
const { ipAllowed } = require('../src/service-devices');
const { totp } = require('../src/totp');

test('device network rules support exact IPv4 and IPv6 CIDR ranges', () => {
  assert.equal(ipAllowed('192.168.10.25', ['192.168.10.0/24']), true);
  assert.equal(ipAllowed('192.168.11.25', ['192.168.10.0/24']), false);
  assert.equal(ipAllowed('2001:db8::42', ['2001:db8::/32']), true);
  assert.equal(ipAllowed('2001:db9::42', ['2001:db8::/32']), false);
});

async function setup(options = {}) {
  const app = createApp(options);
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  const request = async (path, { method = 'GET', token, body } = {}) => {
    const response = await fetch(`${baseUrl}${path}`, {
      method,
      headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return { response, data: response.status === 204 ? null : await response.json() };
  };
  const login = await request('/api/auth/login', {
    method: 'POST', body: { identifier: 'admin', password: 'MaterialKompass2026!' },
  });
  return { server, request, adminToken: login.data.token };
}

test('admin activates a service device and system sessions remain narrowly scoped', async () => {
  const { server, request, adminToken } = await setup();
  try {
    const created = await request('/api/service-devices', {
      method: 'POST', token: adminToken, body: {
        name: 'Fahrzeughalle', locationId: 'loc-1', room: 'Halle 1',
        inventoryNumber: 'DEVICE-001', macAddress: '02:00:00:00:00:01',
        description: 'Touchterminal', allowedDepartmentIds: [], allowedNetworks: [],
        systemPassword: 'GeraetePasswort1!', systemMfa: 'off', personalMfa: 'off',
      },
    });
    assert.equal(created.response.status, 201);
    assert.equal(created.data.systemPasswordHash, undefined);

    const browserActivation = await request('/api/service-devices/activate', {
      method: 'POST', body: {
        identifier: 'admin', password: 'MaterialKompass2026!', deviceId: created.data.id,
        clientPlatform: 'web',
      },
    });
    assert.equal(browserActivation.response.status, 400);

    const activation = await request('/api/service-devices/activate', {
      method: 'POST', body: {
        identifier: 'admin', password: 'MaterialKompass2026!', deviceId: created.data.id,
        clientPlatform: 'windows',
      },
    });
    assert.equal(activation.response.status, 200);
    assert.ok(activation.data.deviceCredential.length >= 48);

    const systemLogin = await request('/api/service-devices/login/system', {
      method: 'POST', body: {
        deviceCredential: activation.data.deviceCredential,
        password: 'GeraetePasswort1!',
      },
    });
    assert.equal(systemLogin.response.status, 200);
    const systemPayload = jwt.decode(systemLogin.data.token);
    assert.equal(systemPayload.st, 'service_device_system');
    assert.equal(systemPayload.did, created.data.id);
    assert.equal(systemPayload.exp - systemPayload.iat, 300);

    assert.equal((await request('/api/material', { token: systemLogin.data.token })).response.status, 403);
    assert.equal((await request('/api/users', { token: systemLogin.data.token })).response.status, 403);

    const search = await request('/api/device/search?q=Helm', { token: systemLogin.data.token });
    assert.equal(search.response.status, 200);
    assert.ok(Array.isArray(search.data));
    assert.equal(JSON.stringify(search.data).includes('recipient'), false);

    const report = await request('/api/device/defects', {
      method: 'POST', token: systemLogin.data.token, body: {
        entityType: 'MaterialItem', entityId: 'material-1', title: 'Beschädigte Halterung',
        description: 'Die Halterung ist sichtbar gerissen.', riskLevel: 'Verletzungsgefahr',
        measuresTaken: 'Artikel abgesperrt', location: 'Fahrzeughalle',
        contactName: 'Max Meldender', contactPhone: '+49 123 456',
      },
    });
    assert.equal(report.response.status, 201);
    assert.match(report.data.accessCode, /^[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$/);

    const accessed = await request('/api/device/defects/access', {
      method: 'POST', token: systemLogin.data.token,
      body: { defectNumber: report.data.report.defectNumber, code: report.data.accessCode },
    });
    assert.equal(accessed.response.status, 200);
    assert.equal(accessed.data.title, 'Beschädigte Halterung');
    assert.equal(accessed.data.history, undefined);
  } finally { server.close(); }
});

test('personal device login keeps user permissions and revocation invalidates both session types', async () => {
  const { server, request, adminToken } = await setup();
  try {
    const created = await request('/api/service-devices', {
      method: 'POST', token: adminToken, body: {
        name: 'Halle Personal', locationId: 'loc-1', inventoryNumber: 'DEVICE-002',
        systemPassword: 'GeraetePasswort2!', allowedDepartmentIds: [], allowedNetworks: [],
      },
    });
    const activation = await request('/api/service-devices/activate', {
      method: 'POST', body: {
        identifier: 'admin', password: 'MaterialKompass2026!', deviceId: created.data.id,
        clientPlatform: 'windows',
      },
    });
    const personal = await request('/api/service-devices/login/personal', {
      method: 'POST', body: {
        deviceCredential: activation.data.deviceCredential,
        identifier: 'admin', password: 'MaterialKompass2026!',
      },
    });
    assert.equal(personal.response.status, 200);
    assert.equal((await request('/api/users', { token: personal.data.token })).response.status, 200);

    assert.equal((await request(`/api/service-devices/${created.data.id}/revoke`, {
      method: 'POST', token: adminToken,
    })).response.status, 200);
    assert.equal((await request('/api/dashboard', { token: personal.data.token })).response.status, 401);
  } finally { server.close(); }
});

test('system MFA is enforced and administrative changes invalidate active sessions', async () => {
  const { server, request, adminToken } = await setup();
  try {
    const created = await request('/api/service-devices', {
      method: 'POST', token: adminToken, body: {
        name: 'MFA Terminal', locationId: 'loc-1', inventoryNumber: 'DEVICE-MFA-1',
        systemPassword: 'MfaGeraetPasswort1!', allowedDepartmentIds: [], allowedNetworks: [],
      },
    });
    const factor = await request(`/api/service-devices/${created.data.id}/nfc-factors`, {
      method: 'POST', token: adminToken,
      body: { label: 'Dienstausweis', credential: 'nfc-factor-credential-001' },
    });
    assert.equal(factor.response.status, 201);
    const configured = await request(`/api/service-devices/${created.data.id}`, {
      method: 'PUT', token: adminToken, body: { systemMfa: 'nfc' },
    });
    assert.equal(configured.response.status, 200);

    const activation = await request('/api/service-devices/activate', {
      method: 'POST', body: {
        identifier: 'admin', password: 'MaterialKompass2026!', deviceId: created.data.id,
        clientPlatform: 'linux',
      },
    });
    const withoutFactor = await request('/api/service-devices/login/system', {
      method: 'POST', body: {
        deviceCredential: activation.data.deviceCredential,
        password: 'MfaGeraetPasswort1!',
      },
    });
    assert.equal(withoutFactor.response.status, 401);
    const withFactor = await request('/api/service-devices/login/system', {
      method: 'POST', body: {
        deviceCredential: activation.data.deviceCredential,
        password: 'MfaGeraetPasswort1!',
        nfcCredential: 'nfc-factor-credential-001',
      },
    });
    assert.equal(withFactor.response.status, 200);

    const changed = await request(`/api/service-devices/${created.data.id}`, {
      method: 'PUT', token: adminToken, body: { description: 'Neue Sicherheitskonfiguration' },
    });
    assert.equal(changed.response.status, 200);
    const invalidated = await request('/api/device/search?q=Helm', {
      token: withFactor.data.token,
    });
    assert.equal(invalidated.response.status, 401);
  } finally { server.close(); }
});

test('offline QR login returns only a verifier and queued commands are idempotent', async () => {
  const snapshots = [];
  const { server, request, adminToken: initialAdminToken } = await setup({
    dataStore: {
      async saveCollections(snapshot) { snapshots.push(snapshot); },
    },
  });
  try {
    const setupResponse = await request('/api/users/me/mfa/setup', {
      method: 'POST', token: initialAdminToken,
      body: { currentPassword: 'MaterialKompass2026!' },
    });
    const confirmed = await request('/api/users/me/mfa/confirm', {
      method: 'POST', token: initialAdminToken,
      body: { code: totp(setupResponse.data.secret) },
    });
    const adminToken = confirmed.data.token;
    const created = await request('/api/service-devices', {
      method: 'POST', token: adminToken, body: {
        name: 'Offline Halle', locationId: 'loc-1', inventoryNumber: 'DEVICE-OFFLINE-1',
        systemPassword: 'OfflinePasswort1!', allowedDepartmentIds: [], allowedNetworks: [],
        offlineEnabled: true, allowedOfflineUserIds: ['user-admin'],
      },
    });
    assert.equal(created.response.status, 201);
    assert.equal(created.data.offlineEnabled, true);

    const activation = await request('/api/service-devices/activate', {
      method: 'POST', body: {
        identifier: 'admin', password: 'MaterialKompass2026!', deviceId: created.data.id,
        clientPlatform: 'windows',
      },
    });
    const issued = await request(`/api/service-devices/${created.data.id}/offline-qr`, {
      method: 'POST', token: adminToken, body: { userId: 'user-admin', label: 'Admin Offline' },
    });
    assert.equal(issued.response.status, 201);
    assert.match(issued.data.credential, /^mkoffline:v1:/);

    const personalChallenge = await request('/api/service-devices/login/personal', {
      method: 'POST', body: {
        deviceCredential: activation.data.deviceCredential,
        qrCredential: issued.data.credential,
      },
    });
    assert.equal(personalChallenge.response.status, 202);
    const personal = await request('/api/auth/mfa/verify', {
      method: 'POST', body: {
        challenge: personalChallenge.data.challenge,
        code: totp(setupResponse.data.secret),
      },
    });
    assert.equal(personal.response.status, 200);
    assert.equal(personal.data.offlineLease.verifierHash,
      crypto.createHash('sha256').update(issued.data.credential).digest('hex'));
    assert.equal(JSON.stringify(personal.data).includes(issued.data.credential), false);

    const enrolled = await request('/api/offline/enroll', {
      method: 'POST', token: personal.data.token,
      body: { clientId: 'offline-client-0001', name: 'Testgerät', platform: 'windows' },
    });
    assert.equal(enrolled.response.status, 200);
    const bootstrapResponse = await fetch(`${new URL('/api/offline/bootstrap', personal.response.url).origin}/api/offline/bootstrap`, {
      headers: {
        Authorization: `Bearer ${personal.data.token}`,
        'X-Offline-Client-Id': enrolled.data.clientId,
      },
    });
    assert.equal(bootstrapResponse.status, 200);
    const bootstrap = await bootstrapResponse.json();
    assert.ok(Array.isArray(bootstrap.data.materials));
    assert.ok(Array.isArray(bootstrap.data.stockStructures));

    const changesUrl = new URL('/api/offline/changes', personal.response.url);
    changesUrl.searchParams.set('cursor', String(bootstrap.revision));
    const unchangedResponse = await fetch(changesUrl, {
      headers: {
        Authorization: `Bearer ${personal.data.token}`,
        'X-Offline-Client-Id': enrolled.data.clientId,
      },
    });
    assert.equal(unchangedResponse.status, 200);
    const unchanged = await unchangedResponse.json();
    assert.equal(unchanged.changed, false);
    assert.equal(unchanged.data, null);

    const commandId = 'offline-command-idempotency-0001';
    const commandBody = { action: 'issue', recipient: 'Übung', items: [{ materialId: 'material-1', quantity: 1 }] };
    const command = async () => {
      const response = await fetch(`${new URL('/api/material/transactions/bulk', personal.response.url).origin}/api/material/transactions/bulk`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json', Authorization: `Bearer ${personal.data.token}`,
          'X-Offline-Command-Id': commandId,
        },
        body: JSON.stringify(commandBody),
      });
      return { response, data: await response.json() };
    };
    const first = await command();
    const replay = await command();
    assert.equal(first.response.status, 201);
    assert.equal(replay.response.status, 201);
    assert.equal(replay.response.headers.get('x-offline-replayed'), 'true');
    assert.deepEqual(replay.data, first.data);
    const storedResult = snapshots.at(-1).offlineCommandResults.at(-1);
    assert.match(storedResult.bodyEncrypted, /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
    assert.equal(storedResult.body, undefined);

    const changedResponse = await fetch(changesUrl, {
      headers: {
        Authorization: `Bearer ${personal.data.token}`,
        'X-Offline-Client-Id': enrolled.data.clientId,
      },
    });
    assert.equal(changedResponse.status, 200);
    const changed = await changedResponse.json();
    assert.equal(changed.changed, true);
    assert.ok(Array.isArray(changed.data.materials));

    const unauthenticatedReplay = await fetch(
      `${new URL('/api/material/transactions/bulk', personal.response.url).origin}/api/material/transactions/bulk`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-Offline-Command-Id': commandId },
        body: JSON.stringify(commandBody),
      },
    );
    assert.equal(unauthenticatedReplay.status, 401);

    const refreshedChallenge = await request('/api/service-devices/login/personal', {
      method: 'POST', body: {
        deviceCredential: activation.data.deviceCredential,
        qrCredential: issued.data.credential,
      },
    });
    const refreshedLogin = await request('/api/auth/mfa/verify', {
      method: 'POST', body: {
        challenge: refreshedChallenge.data.challenge,
        code: totp(setupResponse.data.secret),
      },
    });
    const refreshedReplay = await fetch(
      `${new URL('/api/material/transactions/bulk', personal.response.url).origin}/api/material/transactions/bulk`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json', Authorization: `Bearer ${refreshedLogin.data.token}`,
          'X-Offline-Command-Id': commandId,
        },
        body: JSON.stringify(commandBody),
      },
    );
    assert.equal(refreshedReplay.status, 201);
    assert.equal(refreshedReplay.headers.get('x-offline-replayed'), 'true');
  } finally { server.close(); }
});
