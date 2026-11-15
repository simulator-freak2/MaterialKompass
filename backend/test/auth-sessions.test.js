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
  const request = async (path, { method = 'GET', token, body, headers = {} } = {}) => {
    const response = await fetch(`${baseUrl}${path}`, {
      method,
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...headers,
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

test('sessions end after 60 minutes without user activity', () => {
  const user = { id: 'user-1', active: true, emailVerifiedAt: '2026-01-01T00:00:00.000Z' };
  const sessions = [];
  const contexts = [];
  let clock = Date.parse('2026-11-15T08:00:00.000Z');
  const minutes = (value) => value * 60 * 1000;
  const authSessions = createAuthSessions({
    sessions,
    users: [user],
    createToken: (_user, context) => {
      contexts.push(context);
      return `token-${contexts.length}`;
    },
    securityVersion: () => 'security-v1',
    loginAccessAllowed: () => true,
    now: () => clock,
  });

  const initial = authSessions.issue(user);
  const sessionId = contexts[0].sessionId;
  assert.equal(sessionId, sessions[0].id, 'access tokens carry their session id');

  // User activity keeps the session open.
  clock += minutes(50);
  assert.deepEqual(authSessions.touch(sessionId, { userId: 'user-1' }), { active: true, persist: true });
  clock += minutes(50);
  assert.equal(authSessions.touch(sessionId, { userId: 'user-1' }).active, true);

  // Background polling and token refreshes do not count as activity.
  clock += minutes(30);
  assert.equal(authSessions.touch(sessionId, { userId: 'user-1', background: true }).active, true);
  const refreshed = authSessions.rotate(initial.refreshToken);
  assert.ok(refreshed);
  assert.equal(contexts.at(-1).sessionId, sessionId);
  clock += minutes(30);
  assert.equal(authSessions.touch(sessionId, { userId: 'user-1' }).active, false);
  assert.equal(sessions.length, 0, 'the inactive session is discarded');
  assert.equal(authSessions.rotate(refreshed.refreshToken), null);
});

test('an idle refresh token cannot be rotated', () => {
  const user = { id: 'user-1', active: true, emailVerifiedAt: '2026-01-01T00:00:00.000Z' };
  let clock = Date.parse('2026-11-15T08:00:00.000Z');
  const authSessions = createAuthSessions({
    sessions: [],
    users: [user],
    createToken: () => 'token',
    securityVersion: () => 'security-v1',
    loginAccessAllowed: () => true,
    now: () => clock,
  });
  const initial = authSessions.issue(user);
  clock += 59 * 60 * 1000;
  const refreshed = authSessions.rotate(initial.refreshToken);
  assert.ok(refreshed, 'still within the inactivity window');
  clock += 2 * 60 * 1000;
  assert.equal(authSessions.rotate(refreshed.refreshToken), null);
});

test('touch rejects unknown sessions and foreign users', () => {
  const user = { id: 'user-1', active: true, emailVerifiedAt: '2026-01-01T00:00:00.000Z' };
  const sessions = [];
  const contexts = [];
  const authSessions = createAuthSessions({
    sessions,
    users: [user],
    createToken: (_user, context) => { contexts.push(context); return 'token'; },
    securityVersion: () => 'security-v1',
    loginAccessAllowed: () => true,
  });
  authSessions.issue(user);
  assert.equal(authSessions.touch('missing', { userId: 'user-1' }).active, false);
  assert.equal(authSessions.touch(contexts[0].sessionId, { userId: 'user-2' }).active, false);
  assert.equal(authSessions.touch(contexts[0].sessionId, { userId: 'user-1' }).active, true);
});

test('the API rejects tokens of a session idle for 60 minutes', async (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: Date.parse('2026-11-15T08:00:00.000Z') });
  const { server, request } = await start();
  const background = { 'X-MaterialKompass-Activity': 'background' };
  try {
    const login = await request('/api/auth/login', {
      method: 'POST',
      body: { identifier: 'admin', password: 'MaterialKompass2026!' },
    });
    assert.equal(login.response.status, 200);

    // Active use: a request after 50 minutes keeps the session open.
    t.mock.timers.tick(50 * 60 * 1000);
    assert.equal((await request('/api/auth/me', { token: login.data.token })).response.status, 200);
    t.mock.timers.tick(5 * 60 * 1000);
    const refreshed = await request('/api/auth/refresh', {
      method: 'POST', body: { refreshToken: login.data.refreshToken },
    });
    assert.equal(refreshed.response.status, 200);

    // Only background polling for the next 60 minutes.
    t.mock.timers.tick(40 * 60 * 1000);
    assert.equal((await request('/api/auth/me', {
      token: refreshed.data.token, headers: background,
    })).response.status, 200);
    t.mock.timers.tick(15 * 60 * 1000);
    const expired = await request('/api/auth/me', { token: refreshed.data.token });
    assert.equal(expired.response.status, 401);
    assert.equal(expired.data.sessionExpired, true);
    assert.equal((await request('/api/auth/refresh', {
      method: 'POST', body: { refreshToken: refreshed.data.refreshToken },
    })).response.status, 401);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('tokens reissued during a request stay bound to the session', async (t) => {
  t.mock.timers.enable({ apis: ['Date'], now: Date.parse('2026-11-15T08:00:00.000Z') });
  const { server, request } = await start();
  try {
    const login = await request('/api/auth/login', {
      method: 'POST',
      body: { identifier: 'admin', password: 'MaterialKompass2026!' },
    });
    const me = await request('/api/auth/me', { token: login.data.token });
    const context = me.data.context;
    const switched = await request('/api/auth/context', {
      method: 'POST',
      token: login.data.token,
      body: { organizationId: context.organization.id, unitId: context.unit.id },
    });
    assert.equal(switched.response.status, 200);
    const sid = (token) => JSON.parse(Buffer.from(token.split('.')[1], 'base64url')).sid;
    assert.ok(sid(login.data.token));
    assert.equal(sid(switched.data.token), sid(login.data.token));

    t.mock.timers.tick(61 * 60 * 1000);
    assert.equal((await request('/api/auth/me', { token: switched.data.token })).response.status, 401);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
