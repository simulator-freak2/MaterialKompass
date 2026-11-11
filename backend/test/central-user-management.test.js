const test = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');
const { normalizeTenancyData } = require('../src/tenancy');
const { totp } = require('../src/totp');

async function fixture(t) {
  const tokens = [];
  let timestamp = Date.now();
  const app = createApp({ skipEmailVerification: true,
    accountMailSender: async () => {},
    onAccountToken: (token) => tokens.push(token), now: () => timestamp });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  t.after(() => new Promise((resolve) => { server.close(resolve); server.closeAllConnections(); }));
  const request = async (path, body, token, method = 'POST') => {
    const response = await fetch(`http://127.0.0.1:${server.address().port}${path}`, {
      method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return { status: response.status, data: response.status === 204 ? null : await response.json() };
  };
  const login = async (identifier, password = 'MaterialKompass2026!') => request('/api/auth/login', { identifier, password });
  const admin = await login('admin');
  assert.equal(admin.status, 200);
  const create = async (username, extra = {}) => {
    const result = await request('/api/users', { username, email: `${username}@example.org`,
      password: 'SehrSicher123!', ...extra }, admin.data.token);
    assert.equal(result.status, 201, JSON.stringify(result.data));
    return result.data;
  };
  return { app, request, login, create, admin: admin.data.token, tokens,
    advance: (milliseconds) => { timestamp += milliseconds; } };
}

test('concurrent normalized duplicate creation returns one account and one conflict', async (t) => {
  const f = await fixture(t);
  const results = await Promise.all([
    f.request('/api/users', { username: 'parallel-one', email: 'parallel@example.org' }, f.admin),
    f.request('/api/users', { username: 'parallel-two', email: ' PARALLEL@EXAMPLE.ORG ' }, f.admin),
  ]);
  assert.deepEqual(results.map((result) => result.status).sort(), [201, 409]);
  assert.equal(f.app.locals.appData.users.filter((user) => user.email === 'parallel@example.org').length, 1);
});

test('non-platform organization admin cannot modify account identity or authentication', async (t) => {
  const f = await fixture(t);
  const manager = await f.create('org-manager', { roles: ['Admin'] });
  const user = await f.create('central-person');
  const login = await f.login(manager.username, 'SehrSicher123!');
  assert.equal(login.status, 200);
  for (const change of [{ email: 'takeover@example.org' }, { username: 'takeover' },
    { name: 'Changed identity' }, { active: false }, { password: 'ChangedPass123!' }, { mfaRequired: true }]) {
    assert.equal((await f.request(`/api/users/${user.id}`, change, login.data.token, 'PUT')).status, 403);
  }
  for (const [method, suffix, body] of [
    ['PUT', 'mfa-policy', { required: false }], ['DELETE', 'mfa', {}],
    ['DELETE', 'passkeys', {}], ['POST', 'qr-credential', {}],
    ['POST', 'verification/confirm', {}], ['POST', 'password-reset', {}],
  ]) assert.equal((await f.request(`/api/users/${user.id}/${suffix}`, body, login.data.token, method)).status, 403);
});

test('revoking the final membership preserves the account and never recreates default access', async (t) => {
  const f = await fixture(t);
  const user = await f.create('retained-person');
  const login = await f.login(user.username, 'SehrSicher123!');
  assert.equal((await f.request(`/api/users/${user.id}`, {}, f.admin, 'DELETE')).status, 204);
  assert.ok(f.app.locals.appData.users.some((entry) => entry.id === user.id));
  const membership = f.app.locals.appData.memberships.find((entry) => entry.userId === user.id);
  assert.equal(membership.status, 'inactive');
  const normalized = normalizeTenancyData(structuredClone({ users: f.app.locals.appData.users,
    organizations: f.app.locals.appData.organizations,
    organizationUnits: f.app.locals.appData.organizationUnits,
    memberships: f.app.locals.appData.memberships }));
  assert.equal(normalized.memberships.filter((entry) => entry.userId === user.id && entry.status === 'active').length, 0);
  assert.equal((await f.request('/api/users/me/export', undefined, login.data.token, 'GET')).status, 200);
  assert.equal((await f.request('/api/material', undefined, login.data.token, 'GET')).status, 403);
  assert.equal((await f.request('/api/users/memberships', { identifier: user.email }, f.admin)).status, 201);
  assert.equal(f.app.locals.appData.memberships.filter((entry) => entry.userId === user.id).length, 1);
});

test('invitation requires explicit consent, rejects replay, and keeps one membership', async (t) => {
  const f = await fixture(t);
  const user = await f.create('invited-person');
  assert.equal((await f.request(`/api/users/${user.id}`, {}, f.admin, 'DELETE')).status, 204);
  const sent = await f.request('/api/users/memberships', { identifier: user.email, mode: 'invitation' }, f.admin);
  assert.equal(sent.status, 202);
  const token = f.tokens.find((entry) => entry.type === 'membership-invitation').token;
  assert.equal(f.app.locals.appData.memberships.find((entry) => entry.userId === user.id).status, 'inactive');
  const preview = await f.request(`/api/auth/membership-invitation?token=${token}`, undefined, undefined, 'GET');
  assert.equal(preview.status, 200);
  assert.ok(preview.data.organization);
  assert.equal((await f.request('/api/auth/membership-invitation/confirm', { token, accept: true })).status, 200);
  assert.equal((await f.request('/api/auth/membership-invitation/confirm', { token, accept: true })).status, 400);
  assert.equal(f.app.locals.appData.memberships.filter((entry) => entry.userId === user.id).length, 1);
});

test('expired or revoked invitations never activate access', async (t) => {
  const f = await fixture(t);
  const user = await f.create('expired-person');
  await f.request(`/api/users/${user.id}`, {}, f.admin, 'DELETE');
  await f.request('/api/users/memberships', { identifier: user.email, mode: 'invitation' }, f.admin);
  const token = f.tokens.find((entry) => entry.type === 'membership-invitation').token;
  const pending = await f.request('/api/users/invitations', undefined, f.admin, 'GET');
  assert.equal(pending.status, 200);
  assert.equal((await f.request(`/api/users/invitations/${pending.data[0].id}`, {}, f.admin, 'DELETE')).status, 204);
  assert.equal((await f.request('/api/auth/membership-invitation/confirm', { token, accept: true })).status, 400);
  await f.request('/api/users/memberships', { identifier: user.email, mode: 'invitation' }, f.admin);
  const expiredToken = f.tokens.filter((entry) => entry.type === 'membership-invitation').at(-1).token;
  f.advance(7 * 24 * 60 * 60 * 1000);
  assert.equal((await f.request('/api/auth/membership-invitation/confirm', { token: expiredToken, accept: true })).status, 400);
  assert.equal(f.app.locals.appData.memberships.find((entry) => entry.userId === user.id).status, 'inactive');
});

test('an organization role used in another non-managed unit cannot be edited', async (t) => {
  const f = await fixture(t);
  const manager = await f.create('role-manager', { roles: ['Admin'] });
  const target = await f.create('other-unit-person');
  const data = f.app.locals.appData;
  const base = data.organizationUnits[0];
  data.organizationUnits.push({ ...base, id: 'isolated-unit', parentId: base.id, name: 'Other unit' });
  data.roles.push({ id: 'shared-role', organizationId: base.organizationId, name: 'Shared role', permissions: ['dashboard.read'] });
  data.memberships.find((entry) => entry.userId === target.id).scopes = [{ unitId: 'isolated-unit', roles: ['Shared role'], departmentIds: [] }];
  const login = await f.login(manager.username, 'SehrSicher123!');
  assert.equal((await f.request('/api/roles/shared-role', { permissions: ['dashboard.read', 'inventory.write'] }, login.data.token, 'PUT')).status, 403);
  assert.deepEqual(data.roles.find((entry) => entry.id === 'shared-role').permissions, ['dashboard.read']);
});

test('an enabled TOTP factor cannot be replaced through the initial setup route', async (t) => {
  const f = await fixture(t);
  const user = await f.create('mfa-person');
  const login = await f.login(user.username, 'SehrSicher123!');
  const setup = await f.request('/api/users/me/mfa/setup', { currentPassword: 'SehrSicher123!' }, login.data.token);
  assert.equal(setup.status, 200);
  const enabled = await f.request('/api/users/me/mfa/confirm', { code: totp(setup.data.secret) }, login.data.token);
  assert.equal(enabled.status, 200);
  assert.equal((await f.request('/api/users/me/mfa/setup', { currentPassword: 'SehrSicher123!' }, enabled.data.token)).status, 409);
});

test('a reset token can complete only one of two concurrent password replacements', async (t) => {
  const f = await fixture(t);
  const user = await f.create('reset-person');
  await f.request('/api/auth/password-reset', { email: user.email });
  const token = f.tokens.filter((entry) => entry.type === 'password-reset' && entry.userId === user.id).at(-1).token;
  const results = await Promise.all([
    f.request('/api/auth/password-reset/confirm', { token, password: 'PasswordOne123!' }),
    f.request('/api/auth/password-reset/confirm', { token, password: 'PasswordTwo123!' }),
  ]);
  assert.deepEqual(results.map((entry) => entry.status).sort(), [200, 400]);
});

test('invitation acceptance rejects an inviter whose area authority was revoked', async (t) => {
  const f = await fixture(t);
  const manager = await f.create('inviting-manager', { roles: ['Admin'] });
  const user = await f.create('late-invite-person');
  await f.request(`/api/users/${user.id}`, {}, f.admin, 'DELETE');
  const login = await f.login(manager.username, 'SehrSicher123!');
  await f.request('/api/users/memberships', { identifier: user.email, mode: 'invitation' }, login.data.token);
  const token = f.tokens.find((entry) => entry.type === 'membership-invitation').token;
  const actorMembership = f.app.locals.appData.memberships.find((entry) => entry.userId === manager.id);
  actorMembership.status = 'inactive';
  actorMembership.scopes = [];
  assert.equal((await f.request('/api/auth/membership-invitation/confirm', { token, accept: true })).status, 409);
  assert.equal(f.app.locals.appData.memberships.find((entry) => entry.userId === user.id).status, 'inactive');
});

test('a durably marked central account never receives legacy rights after partial creation', () => {
  const normalized = normalizeTenancyData({ users: [{ id: 'new-central', membershipManaged: true,
    roles: ['Admin'], departmentIds: [] }], memberships: [] });
  assert.equal(normalized.memberships.length, 0);
  const legacy = normalizeTenancyData({ users: [{ id: 'legacy', roles: ['Nutzer'] }], memberships: [] });
  assert.equal(legacy.memberships.length, 1);
});

test('concurrent deletion cannot remove both remaining platform administrators', async (t) => {
  const f = await fixture(t);
  const second = await f.create('second-platform');
  await f.create('remaining-org-admin', { roles: ['Admin'] });
  const data = f.app.locals.appData;
  data.users.find((entry) => entry.id === second.id).platformAdmin = true;
  data.memberships.find((entry) => entry.userId === 'user-admin').scopes.forEach((scope) => { scope.roles = ['Nutzer']; });
  const secondLogin = await f.login(second.username, 'SehrSicher123!');
  const results = await Promise.all([
    f.request('/api/users/me', { password: 'MaterialKompass2026!' }, f.admin, 'DELETE'),
    f.request('/api/users/me', { password: 'SehrSicher123!' }, secondLogin.data.token, 'DELETE'),
  ]);
  assert.deepEqual(results.map((entry) => entry.status).sort(), [204, 409]);
  assert.equal(data.users.filter((entry) => entry.active && entry.platformAdmin).length, 1);
});

test('platform account administration survives loss of organizational membership', async (t) => {
  const f = await fixture(t);
  const user = await f.create('global-managed-person');
  const identity = f.app.locals.appData.users.find((entry) => entry.id === user.id);
  identity.loginAccessMode = 'selected_service_devices';
  identity.allowedServiceDeviceIds = ['other-organization-device'];
  const membership = f.app.locals.appData.memberships.find((entry) => entry.userId === 'user-admin');
  membership.status = 'inactive';
  membership.scopes = [];
  assert.equal((await f.request('/api/users/identity-conflicts', undefined, f.admin, 'GET')).status, 200);
  assert.equal((await f.request(`/api/users/${user.id}`, { name: 'Updated globally' }, f.admin, 'PUT')).status, 200);
  assert.equal((await f.request('/api/material', undefined, f.admin, 'GET')).status, 403);
});

test('disabled and unverified identities cannot bootstrap service-device administration', async (t) => {
  const f = await fixture(t);
  const manager = await f.create('device-manager', { roles: ['Admin'] });
  const user = f.app.locals.appData.users.find((entry) => entry.id === manager.id);
  const proof = { identifier: manager.username, password: 'SehrSicher123!' };
  user.active = false;
  assert.equal((await f.request('/api/service-devices/activation/options', proof)).status, 401);
  user.active = true;
  user.emailVerifiedAt = null;
  assert.equal((await f.request('/api/service-devices/activation/options', proof)).status, 401);
});

test('device listing and updates stay inside the selected authorized unit', async (t) => {
  const f = await fixture(t);
  const created = await f.request('/api/service-devices', {
    name: 'Dummy terminal', locationId: 'loc-1', inventoryNumber: 'CENTRAL-DEVICE-1',
    macAddress: '02:00:00:00:00:55', systemPassword: 'GeraetePasswort1!',
    systemMfa: 'off', personalMfa: 'off', allowedDepartmentIds: [], allowedNetworks: [],
  }, f.admin);
  assert.equal(created.status, 201);
  const manager = await f.create('other-device-manager', { roles: ['Admin'] });
  const data = f.app.locals.appData;
  const root = data.organizationUnits[0];
  data.organizationUnits.push({ ...root, id: 'other-device-unit', parentId: root.id, name: 'Other device unit' });
  const membership = data.memberships.find((entry) => entry.userId === manager.id);
  membership.defaultUnitId = 'other-device-unit';
  membership.scopes = [{ unitId: 'other-device-unit', roles: ['Admin'], departmentIds: [] }];
  const login = await f.login(manager.username, 'SehrSicher123!');
  const listed = await f.request('/api/service-devices', undefined, login.data.token, 'GET');
  assert.equal(listed.status, 200);
  assert.deepEqual(listed.data, []);
  assert.equal((await f.request(`/api/service-devices/${created.data.id}`, { name: 'Wrong unit' }, login.data.token, 'PUT')).status, 404);
  const activationOptions = await f.request('/api/service-devices/activation/options', { identifier: manager.username, password: 'SehrSicher123!' });
  assert.equal(activationOptions.status, 200);
  assert.deepEqual(activationOptions.data, []);
});
