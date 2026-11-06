const test = require('node:test');
const assert = require('node:assert/strict');

const { createApp } = require('../src/app');
const { createAuthSessions } = require('../src/auth-sessions');

async function start() {
  const app = createApp();
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
  return { server, request };
}

test('password login issues a rotating refresh session', async () => {
  const { server, request } = await start();
  try {
    const login = await request('/api/auth/login', {
      method: 'POST',
      body: { identifier: 'admin', password: 'MaterialKompass2026!' },
    });
    assert.equal(login.response.status, 200);
    assert.ok(login.data.token);
    assert.match(login.data.refreshToken, /^[0-9a-f-]{36}\.[A-Za-z0-9_-]{43}$/);

    const refreshed = await request('/api/auth/refresh', {
      method: 'POST',
      body: { refreshToken: login.data.refreshToken },
    });
    assert.equal(refreshed.response.status, 200);
    assert.ok(refreshed.data.token);
    assert.notEqual(refreshed.data.refreshToken, login.data.refreshToken);

    const replay = await request('/api/auth/refresh', {
      method: 'POST',
      body: { refreshToken: login.data.refreshToken },
    });
    assert.equal(replay.response.status, 401);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('logout revokes access and refresh sessions on every device', async () => {
  const { server, request } = await start();
  try {
    const first = await request('/api/auth/login', {
      method: 'POST',
      body: { identifier: 'admin', password: 'MaterialKompass2026!' },
    });
    const second = await request('/api/auth/login', {
      method: 'POST',
      body: { identifier: 'admin', password: 'MaterialKompass2026!' },
    });

    const logout = await request('/api/auth/logout', {
      method: 'POST',
      token: first.data.token,
      body: { refreshToken: first.data.refreshToken },
    });
    assert.equal(logout.response.status, 204);
    assert.equal((await request('/api/auth/me', { token: first.data.token })).response.status, 401);
    assert.equal((await request('/api/auth/me', { token: second.data.token })).response.status, 401);
    assert.equal((await request('/api/auth/refresh', {
      method: 'POST', body: { refreshToken: second.data.refreshToken },
    })).response.status, 401);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('refresh preserves a restricted device context and rechecks the device gate', () => {
  const user = { id: 'user-1', active: true, emailVerifiedAt: '2026-01-01T00:00:00.000Z' };
  const sessions = [];
  const issuedContexts = [];
  let deviceAllowed = true;
  const authSessions = createAuthSessions({
    sessions,
    users: [user],
    createToken: (_user, context) => {
      issuedContexts.push(context);
      return `token-${issuedContexts.length}`;
    },
    securityVersion: () => 'security-v1',
    loginAccessAllowed: (_user, deviceId) => !deviceId || deviceId === 'device-1',
    sessionContextAllowed: (_user, context) =>
      deviceAllowed && context.sessionType === 'service_device_personal',
  });

  const initial = authSessions.issue(user, {
    deviceId: 'device-1',
    sessionType: 'service_device_personal',
    organizationId: 'organization-1',
    unitId: 'unit-1',
  });
  const refreshed = authSessions.rotate(initial.refreshToken);
  assert.ok(refreshed);
  assert.deepEqual(issuedContexts[1], issuedContexts[0]);

  deviceAllowed = false;
  assert.equal(authSessions.rotate(refreshed.refreshToken), null);
});
