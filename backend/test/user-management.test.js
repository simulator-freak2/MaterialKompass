const test = require('node:test');
const assert = require('node:assert/strict');
const jwt = require('jsonwebtoken');
const { createApp } = require('../src/app');

async function setup(options = {}) {
  const tokens = [];
  const app = createApp({
    onAccountToken: (entry) => tokens.push(entry),
    accountMailSender: options.accountMailSender,
    now: options.now,
  });
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
  const login = await request('/api/auth/login', { method: 'POST', body: { identifier: 'admin', password: 'MaterialKompass2026!' } });
  assert.equal(login.response.status, 200);
  return { server, request, tokens, adminToken: login.data.token };
}

test('admin creates, verifies, searches, edits and deletes users', async () => {
  const { server, request, tokens, adminToken } = await setup();
  try {
    const created = await request('/api/users', { method: 'POST', token: adminToken, body: {
      name: 'Nora Nutzerin', username: 'nora', email: 'nora@example.org',
      password: 'SehrSicher123!', roles: ['Nutzer'], active: true,
    } });
    assert.equal(created.response.status, 201);
    assert.equal(created.data.passwordHash, undefined);

    const beforeVerification = await request('/api/auth/login', { method: 'POST', body: { identifier: 'nora', password: 'SehrSicher123!' } });
    assert.equal(beforeVerification.response.status, 403);

    const verification = tokens.find((entry) => entry.type === 'verification' && entry.userId === created.data.id);
    assert.ok(verification);
    const verified = await request(`/api/auth/verify-email?token=${verification.token}`);
    assert.equal(verified.response.status, 200);

    const login = await request('/api/auth/login', { method: 'POST', body: { identifier: 'nora', password: 'SehrSicher123!' } });
    assert.equal(login.response.status, 200);
    const payload = jwt.decode(login.data.token);
    assert.equal(payload.exp - payload.iat, 3600);

    const search = await request('/api/users?search=nora', { token: adminToken });
    assert.equal(search.data.length, 1);
    assert.equal(search.data[0].lastLoginAt !== null, true);

    const changed = await request(`/api/users/${created.data.id}`, { method: 'PUT', token: adminToken, body: { ...created.data, active: false } });
    assert.equal(changed.response.status, 200);
    assert.equal(changed.data.active, false);
    assert.equal((await request('/api/auth/login', { method: 'POST', body: { identifier: 'nora', password: 'SehrSicher123!' } })).response.status, 403);

    assert.equal((await request(`/api/users/${created.data.id}`, { method: 'DELETE', token: adminToken })).response.status, 204);
  } finally { server.close(); }
});

test('admin creates a user with only username and email as required fields', async () => {
  const { server, request, tokens, adminToken } = await setup();
  try {
    const created = await request('/api/users', { method: 'POST', token: adminToken, body: {
      username: 'ohne-name', email: 'ohne-name@example.org',
    } });
    assert.equal(created.response.status, 201);
    assert.equal(created.data.name, '');
    assert.equal(created.data.passwordHash, undefined);

    const verification = tokens.find((entry) => entry.type === 'verification' && entry.userId === created.data.id);
    const passwordReset = tokens.find((entry) => entry.type === 'password-reset' && entry.userId === created.data.id);
    assert.ok(verification);
    assert.ok(passwordReset);

    assert.equal((await request(`/api/auth/verify-email?token=${verification.token}`)).response.status, 200);
    assert.equal((await request('/api/auth/password-reset/confirm', { method: 'POST', body: {
      token: passwordReset.token, password: 'ErstesPasswort123!',
    } })).response.status, 200);
    assert.equal((await request('/api/auth/login', { method: 'POST', body: {
      identifier: 'ohne-name', password: 'ErstesPasswort123!',
    } })).response.status, 200);
  } finally { server.close(); }
});

test('authenticated users can download a secret-free personal data copy', async () => {
  const { server, request, adminToken } = await setup();
  try {
    const exported = await request('/api/users/me/export', { token: adminToken });
    assert.equal(exported.response.status, 200);
    assert.equal(exported.data.format, 'MaterialKompass DSGVO-Datenkopie');
    assert.equal(exported.data.account.username, 'admin');
    assert.equal(exported.data.account.passwordHash, undefined);
    assert.doesNotMatch(JSON.stringify(exported.data), /MaterialKompass2026!/);
  } finally { server.close(); }
});

test('email verification can only be resent after 24 hours for new and changed addresses', async () => {
  let currentTime = Date.parse('2026-07-01T08:00:00.000Z');
  const { server, request, tokens, adminToken } = await setup({
    now: () => currentTime,
  });
  try {
    const created = await request('/api/users', {
      method: 'POST',
      token: adminToken,
      body: {
        name: 'Wartende Nutzerin',
        username: 'wartend',
        email: 'wartend@example.org',
        password: 'SehrSicher123!',
        roles: ['Nutzer'],
      },
    });
    assert.equal(created.response.status, 201);
    assert.equal(
      created.data.verificationResendAvailableAt,
      '2026-07-02T08:00:00.000Z',
    );
    assert.equal(tokens.filter((entry) => entry.type === 'verification').length, 1);

    const earlyPublicResend = await request('/api/auth/verification/resend', {
      method: 'POST',
      body: { identifier: 'wartend' },
    });
    assert.equal(earlyPublicResend.response.status, 202);
    assert.equal(tokens.filter((entry) => entry.type === 'verification').length, 1);

    const earlyAdminResend = await request(
      `/api/users/${created.data.id}/verification/resend`,
      { method: 'POST', token: adminToken },
    );
    assert.equal(earlyAdminResend.response.status, 409);
    assert.equal(earlyAdminResend.data.availableAt, '2026-07-02T08:00:00.000Z');

    currentTime += 24 * 60 * 60 * 1000;
    const resentForNewUser = await request('/api/auth/verification/resend', {
      method: 'POST',
      body: { email: 'wartend@example.org' },
    });
    assert.equal(resentForNewUser.response.status, 202);
    assert.equal(tokens.filter((entry) => entry.type === 'verification').length, 2);

    const latestVerification = tokens.findLast(
      (entry) => entry.type === 'verification' && entry.userId === created.data.id,
    );
    assert.equal(
      (await request(`/api/auth/verify-email?token=${latestVerification.token}`)).response.status,
      200,
    );

    const changed = await request(`/api/users/${created.data.id}`, {
      method: 'PUT',
      token: adminToken,
      body: { ...created.data, email: 'geändert@example.org' },
    });
    assert.equal(changed.response.status, 200);
    assert.equal(changed.data.emailVerifiedAt, null);
    assert.equal(
      changed.data.verificationResendAvailableAt,
      '2026-07-03T08:00:00.000Z',
    );
    assert.equal(tokens.filter((entry) => entry.type === 'verification').length, 3);

    assert.equal(
      (await request(`/api/users/${created.data.id}/verification/resend`, {
        method: 'POST',
        token: adminToken,
      })).response.status,
      409,
    );

    currentTime += 24 * 60 * 60 * 1000;
    assert.equal(
      (await request(`/api/users/${created.data.id}/verification/resend`, {
        method: 'POST',
        token: adminToken,
      })).response.status,
      202,
    );
    assert.equal(tokens.filter((entry) => entry.type === 'verification').length, 4);

    const pendingToken = tokens.findLast(
      (entry) => entry.type === 'verification' && entry.userId === created.data.id,
    ).token;
    const manuallyConfirmed = await request(
      `/api/users/${created.data.id}/verification/confirm`,
      { method: 'POST', token: adminToken },
    );
    assert.equal(manuallyConfirmed.response.status, 200);
    assert.equal(manuallyConfirmed.data.emailVerifiedAt, '2026-07-03T08:00:00.000Z');
    assert.equal(manuallyConfirmed.data.verificationResendAvailableAt, null);
    assert.equal(
      (await request(`/api/auth/verify-email?token=${pendingToken}`)).response.status,
      400,
    );
    assert.equal(
      (await request(`/api/users/${created.data.id}/verification/confirm`, {
        method: 'POST',
        token: adminToken,
      })).response.status,
      409,
    );
  } finally { server.close(); }
});

test('password reset token is single-use and roles can be created', async () => {
  const { server, request, tokens, adminToken } = await setup();
  try {
    const role = await request('/api/roles', { method: 'POST', token: adminToken, body: { name: 'Leser', permissions: ['dashboard.read'] } });
    assert.equal(role.response.status, 201);
    const changedRole = await request(`/api/roles/${role.data.id}`, { method: 'PUT', token: adminToken, body: { name: 'Berichte-Leser', permissions: ['dashboard.read', 'reports.read'] } });
    assert.equal(changedRole.response.status, 200);
    assert.equal(changedRole.data.name, 'Berichte-Leser');
    assert.deepEqual(changedRole.data.permissions, ['dashboard.read', 'reports.read']);
    assert.equal((await request(`/api/roles/${role.data.id}`, { method: 'DELETE', token: adminToken })).response.status, 204);

    const resetRequest = await request('/api/auth/password-reset', { method: 'POST', body: { identifier: 'admin' } });
    assert.equal(resetRequest.response.status, 202);
    const resetToken = tokens.findLast((entry) => entry.type === 'password-reset').token;
    const reset = await request('/api/auth/password-reset/confirm', { method: 'POST', body: { token: resetToken, password: 'NeuesPasswort123!' } });
    assert.equal(reset.response.status, 200);
    assert.equal((await request('/api/auth/me', { token: adminToken })).response.status, 401);
    assert.equal((await request('/api/auth/password-reset/confirm', { method: 'POST', body: { token: resetToken, password: 'NochEinPasswort123!' } })).response.status, 400);
    assert.equal((await request('/api/auth/login', { method: 'POST', body: { identifier: 'admin', password: 'NeuesPasswort123!' } })).response.status, 200);
  } finally { server.close(); }
});

test('departments are managed centrally and required for department heads', async () => {
  const { server, request, adminToken } = await setup();
  try {
    const department = await request('/api/departments', {
      method: 'POST',
      token: adminToken,
      body: { name: 'Ausbildung', code: 'AUSB', active: true },
    });
    assert.equal(department.response.status, 201);

    const missingAssignment = await request('/api/users', {
      method: 'POST',
      token: adminToken,
      body: {
        username: 'bereichsleitung',
        email: 'bereichsleitung@example.org',
        password: 'SehrSicher123!',
        roles: ['Fachbereichsleiter'],
      },
    });
    assert.equal(missingAssignment.response.status, 400);

    const created = await request('/api/users', {
      method: 'POST',
      token: adminToken,
      body: {
        username: 'bereichsleitung',
        email: 'bereichsleitung@example.org',
        password: 'SehrSicher123!',
        roles: ['Fachbereichsleiter'],
        departmentIds: [department.data.id],
      },
    });
    assert.equal(created.response.status, 201);
    assert.deepEqual(created.data.departmentIds, [department.data.id]);
    assert.equal((await request(`/api/departments/${department.data.id}`, {
      method: 'DELETE', token: adminToken,
    })).response.status, 409);

    const changed = await request(`/api/departments/${department.data.id}`, {
      method: 'PUT',
      token: adminToken,
      body: { name: 'Aus- und Fortbildung', code: 'AFB', active: true },
    });
    assert.equal(changed.response.status, 200);
    assert.equal(changed.data.code, 'AFB');
  } finally { server.close(); }
});

test('password reset waits until the account email has been handed to SMTP', async () => {
  let finishDelivery;
  const deliveryStarted = new Promise((resolve) => {
    finishDelivery = resolve;
  });
  let releaseDelivery;
  const deliveryBlocked = new Promise((resolve) => {
    releaseDelivery = resolve;
  });
  const { server, request } = await setup({
    accountMailSender: async () => {
      finishDelivery();
      await deliveryBlocked;
      return true;
    },
  });
  try {
    let responseFinished = false;
    const resetRequest = request('/api/auth/password-reset', {
      method: 'POST', body: { identifier: 'admin' },
    }).then((result) => {
      responseFinished = true;
      return result;
    });
    await deliveryStarted;
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(responseFinished, false);
    releaseDelivery();
    assert.equal((await resetRequest).response.status, 202);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
test('failed guesses do not let an attacker lock another user out', async () => {
  const { server, request } = await setup();
  try {
    for (let attempt = 0; attempt < 5; attempt += 1) {
      assert.equal((await request('/api/auth/login', { method: 'POST', body: { identifier: 'admin', password: 'wrong' } })).response.status, 401);
    }
    assert.equal((await request('/api/auth/login', { method: 'POST', body: { identifier: 'admin', password: 'MaterialKompass2026!' } })).response.status, 200);
  } finally { server.close(); }
});
