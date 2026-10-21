const test = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');
const {
  LOGIN_ACCESS_MODES,
  loginAccessAllowed,
  loginAccessPolicy,
  validateLoginAccessPolicy,
} = require('../src/login-access-policy');

test('login access policy defaults safely and distinguishes all three modes', () => {
  assert.deepEqual(loginAccessPolicy({}), {
    mode: LOGIN_ACCESS_MODES.ALL_CLIENTS,
    allowedServiceDeviceIds: [],
  });
  assert.equal(loginAccessAllowed({ loginAccessMode: 'all_clients' }), true);
  assert.equal(loginAccessAllowed({ loginAccessMode: 'service_devices' }), false);
  assert.equal(loginAccessAllowed({ loginAccessMode: 'service_devices' }, 'device-1'), true);
  assert.equal(loginAccessAllowed({
    loginAccessMode: 'selected_service_devices',
    allowedServiceDeviceIds: ['device-1'],
  }, 'device-1'), true);
  assert.equal(loginAccessAllowed({
    loginAccessMode: 'selected_service_devices',
    allowedServiceDeviceIds: ['device-1'],
  }, 'device-2'), false);
});

test('selected device policies reject empty, unknown and cross-organization devices', () => {
  const devices = [
    { id: 'device-1', organizationId: 'org-1' },
    { id: 'device-2', organizationId: 'org-2' },
  ];
  assert.ok(validateLoginAccessPolicy({
    mode: 'selected_service_devices', allowedServiceDeviceIds: [],
  }, { devices, organizationId: 'org-1' }).error);
  assert.ok(validateLoginAccessPolicy({
    mode: 'selected_service_devices', allowedServiceDeviceIds: ['missing'],
  }, { devices, organizationId: 'org-1' }).error);
  assert.ok(validateLoginAccessPolicy({
    mode: 'selected_service_devices', allowedServiceDeviceIds: ['device-2'],
  }, { devices, organizationId: 'org-1' }).error);
  assert.deepEqual(validateLoginAccessPolicy({
    mode: 'selected_service_devices',
    allowedServiceDeviceIds: ['device-1', 'device-1'],
  }, { devices, organizationId: 'org-1' }), {
    mode: 'selected_service_devices', allowedServiceDeviceIds: ['device-1'],
  });
});

async function setup() {
  const notices = [];
  const app = createApp({
    skipEmailVerification: true,
    accountMailSender: async (message) => notices.push(message),
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
    return { response, data: response.status === 204 ? null : await response.json() };
  };
  const login = await request('/api/auth/login', {
    method: 'POST', body: { identifier: 'admin', password: 'MaterialKompass2026!' },
  });
  return { server, request, notices, adminToken: login.data.token };
}

test('account policy blocks normal login and permits only selected service devices', async () => {
  const { server, request, notices, adminToken } = await setup();
  try {
    async function createAndActivate(name, inventoryNumber) {
      const created = await request('/api/service-devices', {
        method: 'POST', token: adminToken, body: {
          name, locationId: 'loc-1', inventoryNumber,
          systemPassword: 'GeraetePasswort1!', allowedDepartmentIds: [], allowedNetworks: [],
        },
      });
      assert.equal(created.response.status, 201);
      const activated = await request('/api/service-devices/activate', {
        method: 'POST', body: {
          identifier: 'admin', password: 'MaterialKompass2026!',
          deviceId: created.data.id, clientPlatform: 'windows',
        },
      });
      assert.equal(activated.response.status, 200);
      return { id: created.data.id, credential: activated.data.deviceCredential };
    }

    const allowedDevice = await createAndActivate('Zulässiges Terminal', 'ACCESS-001');
    const deniedDevice = await createAndActivate('Fremdes Terminal', 'ACCESS-002');
    const created = await request('/api/users', {
      method: 'POST', token: adminToken, body: {
        name: 'Gerätegebundene Person', username: 'device-user',
        email: 'device-user@example.org', password: 'SehrSicher123!',
        roles: ['Nutzer'], active: true,
        loginAccess: {
          mode: 'selected_service_devices',
          allowedServiceDeviceIds: [allowedDevice.id],
        },
      },
    });
    assert.equal(created.response.status, 201);
    assert.deepEqual(created.data.loginAccess, {
      mode: 'selected_service_devices',
      allowedServiceDeviceIds: [allowedDevice.id],
    });

    const normalLogin = await request('/api/auth/login', {
      method: 'POST', body: { identifier: 'device-user', password: 'SehrSicher123!' },
    });
    assert.equal(normalLogin.response.status, 403);

    const qr = await request(`/api/users/${created.data.id}/qr-credential`, {
      method: 'POST', token: adminToken, body: {},
    });
    assert.equal(qr.response.status, 201);
    assert.equal((await request('/api/auth/qr-login', {
      method: 'POST', body: { credential: qr.data.qrValue },
    })).response.status, 401);

    const denied = await request('/api/service-devices/login/personal', {
      method: 'POST', body: {
        deviceCredential: deniedDevice.credential,
        identifier: 'device-user', password: 'SehrSicher123!',
      },
    });
    assert.equal(denied.response.status, 401);

    const allowed = await request('/api/service-devices/login/personal', {
      method: 'POST', body: {
        deviceCredential: allowedDevice.credential,
        identifier: 'device-user', password: 'SehrSicher123!',
      },
    });
    assert.equal(allowed.response.status, 200);
    assert.equal((await request('/api/dashboard', { token: allowed.data.token })).response.status, 200);

    const invalidUpdate = await request(`/api/users/${created.data.id}`, {
      method: 'PUT', token: adminToken, body: {
        loginAccess: {
          mode: 'selected_service_devices',
          allowedServiceDeviceIds: ['device-does-not-exist'],
        },
      },
    });
    assert.equal(invalidUpdate.response.status, 400);

    const opened = await request(`/api/users/${created.data.id}`, {
      method: 'PUT', token: adminToken, body: {
        loginAccess: { mode: 'all_clients', allowedServiceDeviceIds: [] },
      },
    });
    assert.equal(opened.response.status, 200);
    assert.equal((await request('/api/dashboard', { token: allowed.data.token })).response.status, 401);
    assert.equal((await request('/api/auth/login', {
      method: 'POST', body: { identifier: 'device-user', password: 'SehrSicher123!' },
    })).response.status, 200);
    assert.ok(notices.some((message) => message.subject === 'Anmelderichtlinie geändert'));
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
