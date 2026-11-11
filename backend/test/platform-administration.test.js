const test = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');
const { normalizeTenancyData } = require('../src/tenancy');
const { seedData } = require('../src/data/seed');
const { PLATFORM_ORGANIZATION_ID, PLATFORM_UNIT_ID, synchronizePlatformAdministration } = require('../src/platform-administration');

async function fixture(t) {
  const app = createApp({ skipEmailVerification: true, accountMailSender: async () => true });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  t.after(() => new Promise((resolve) => { server.close(resolve); server.closeAllConnections(); }));
  const request = async (path, { method = 'GET', token, body } = {}) => {
    const response = await fetch(`http://127.0.0.1:${server.address().port}${path}`, {
      method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return { status: response.status, data: response.status === 204 ? null : await response.json() };
  };
  const login = await request('/api/auth/login', { method: 'POST', body: { identifier: 'admin', password: 'MaterialKompass2026!' } });
  assert.equal(login.status, 200);
  const rootToken = login.data.token;
  const me = await request('/api/auth/me', { token: rootToken });
  const normalOrganizationId = me.data.context.organization.id;
  const normalUnitId = me.data.context.unit.id;
  const central = await request('/api/auth/context', { method: 'POST', token: rootToken,
    body: { organizationId: PLATFORM_ORGANIZATION_ID } });
  assert.equal(central.status, 200);
  const centralToken = central.data.token;
  const create = async (username) => {
    const created = await request('/api/users', { method: 'POST', token: centralToken,
      body: { username, email: `${username}@example.org`, password: 'SehrSicher123!' } });
    assert.equal(created.status, 201, JSON.stringify(created.data));
    return created.data;
  };
  return { app, request, create, rootToken, centralToken, normalOrganizationId, normalUnitId };
}

test('protected administration membership is idempotent and derived only from platform flags', () => {
  const data = structuredClone(seedData);
  normalizeTenancyData(data);
  const normal = data.users.find((user) => user.platformAdmin !== true);
  data.memberships.push({ id: 'forged-center', userId: normal.id, organizationId: PLATFORM_ORGANIZATION_ID,
    status: 'active', scopes: [{ unitId: PLATFORM_UNIT_ID, roles: ['Admin'] }] });
  synchronizePlatformAdministration(data);
  const first = JSON.stringify(data.memberships.filter((entry) => entry.organizationId === PLATFORM_ORGANIZATION_ID));
  synchronizePlatformAdministration(data);
  assert.equal(JSON.stringify(data.memberships.filter((entry) => entry.organizationId === PLATFORM_ORGANIZATION_ID)), first);
  assert.equal(data.organizations.filter((entry) => entry.id === PLATFORM_ORGANIZATION_ID).length, 1);
  assert.equal(data.organizationUnits.filter((entry) => entry.organizationId === PLATFORM_ORGANIZATION_ID).length, 1);
  assert.ok(data.memberships.filter((entry) => entry.organizationId === PLATFORM_ORGANIZATION_ID)
    .every((entry) => data.users.find((user) => user.id === entry.userId).platformAdmin === true));
  const copy = structuredClone(data);
  normalizeTenancyData(copy);
  assert.equal(copy.memberships.some((entry) => entry.organizationId === PLATFORM_ORGANIZATION_ID && entry.userId === normal.id), false);
});

test('only the protected center creates accounts and reviews global duplicates', async (t) => {
  const f = await fixture(t);
  const account = await f.create('central-only-person');
  assert.equal(f.app.locals.appData.memberships.some((entry) => entry.userId === account.id), false);
  assert.equal((await f.request('/api/users', { method: 'POST', token: f.rootToken,
    body: { username: 'wrong-place', email: 'wrong-place@example.org' } })).status, 403);
  assert.equal((await f.request('/api/users/identity-conflicts', { token: f.rootToken })).status, 403);
  assert.equal((await f.request('/api/users/identity-conflicts', { token: f.centralToken })).status, 200);
  assert.equal((await f.request('/api/users', { method: 'POST', token: f.centralToken,
    body: { username: 'duplicate-name', email: ' CENTRAL-ONLY-PERSON@EXAMPLE.ORG ' } })).status, 409);
  const listed = await f.request('/api/users', { token: f.centralToken });
  assert.ok(listed.data.some((user) => user.id === account.id));
  assert.equal((await f.request('/api/users/memberships', { method: 'POST', token: f.centralToken,
    body: { identifier: account.email, roles: ['Admin'] } })).status, 403);
  assert.equal((await f.request('/api/organization-units', { method: 'POST', token: f.centralToken,
    body: { name: 'Not a domain hierarchy' } })).status, 403);
});

test('ordinary organization admins cannot enter or become members of central administration', async (t) => {
  const f = await fixture(t);
  const manager = await f.create('local-only-admin');
  assert.equal((await f.request('/api/users/memberships', { method: 'POST', token: f.rootToken,
    body: { identifier: manager.email, roles: ['Admin'] } })).status, 201);
  const loggedIn = await f.request('/api/auth/login', { method: 'POST',
    body: { identifier: manager.username, password: 'SehrSicher123!' } });
  const localToken = loggedIn.data.token;
  const organizations = await f.request('/api/organizations', { token: localToken });
  assert.equal(organizations.data.some((entry) => entry.id === PLATFORM_ORGANIZATION_ID), false);
  assert.equal((await f.request('/api/auth/context', { method: 'POST', token: localToken,
    body: { organizationId: PLATFORM_ORGANIZATION_ID, unitId: PLATFORM_UNIT_ID } })).status, 403);
  assert.equal((await f.request('/api/users/memberships', { method: 'POST', token: localToken,
    body: { identifier: manager.email, scopes: [{ unitId: PLATFORM_UNIT_ID, roles: ['Admin'], departmentIds: [] }] } })).status, 400);
  assert.equal(f.app.locals.appData.memberships.some((entry) => entry.userId === manager.id
    && entry.organizationId === PLATFORM_ORGANIZATION_ID), false);
});

test('local account lists disclose only active-level grants, even to an actor managing both levels', async (t) => {
  const f = await fixture(t);
  const target = await f.create('two-level-person');
  const siblingOnly = await f.create('sibling-only-person');
  const data = f.app.locals.appData;
  data.organizationUnits.push({ id: 'other-level', organizationId: f.normalOrganizationId,
    parentId: f.normalUnitId, name: 'Other level', status: 'active', unitKind: 'standard' });
  const actorMembership = data.memberships.find((entry) => entry.userId === 'user-admin'
    && entry.organizationId === f.normalOrganizationId);
  actorMembership.scopes.push({ unitId: 'other-level', roles: ['Admin'], departmentIds: [] });
  data.memberships.push({ id: 'two-level-membership', userId: target.id, organizationId: f.normalOrganizationId,
    status: 'active', defaultUnitId: f.normalUnitId, scopes: [
      { unitId: f.normalUnitId, roles: ['Nutzer'], departmentIds: [] },
      { unitId: 'other-level', roles: ['Admin'], departmentIds: [] },
    ] });
  data.memberships.push({ id: 'sibling-only-membership', userId: siblingOnly.id, organizationId: f.normalOrganizationId,
    status: 'active', defaultUnitId: 'other-level', scopes: [{ unitId: 'other-level', roles: ['Nutzer'], departmentIds: [] }] });
  const identity = data.users.find((entry) => entry.id === target.id);
  identity.loginAccessMode = 'selected_service_devices';
  identity.allowedServiceDeviceIds = ['private-device-in-another-organization'];
  const rootList = await f.request('/api/users', { token: f.rootToken });
  assert.equal(rootList.status, 200);
  const local = rootList.data.find((entry) => entry.id === target.id);
  assert.deepEqual(local.roles, ['Nutzer']);
  assert.deepEqual(local.organizationAccess.scopes.map((scope) => scope.unitId), [f.normalUnitId]);
  assert.equal(local.loginAccess, undefined);
  assert.equal(local.mfa, undefined);
  assert.equal(rootList.data.some((entry) => entry.id === siblingOnly.id), false);
  assert.equal((await f.request(`/api/users/${target.id}`, { method: 'PUT', token: f.rootToken,
    body: { scopes: [{ unitId: 'other-level', roles: ['Nutzer'], departmentIds: [] }] } })).status, 400);
  const switched = await f.request('/api/auth/context', { method: 'POST', token: f.rootToken,
    body: { organizationId: f.normalOrganizationId, unitId: 'other-level' } });
  const otherList = await f.request('/api/users', { token: switched.data.token });
  assert.deepEqual(otherList.data.find((entry) => entry.id === target.id).roles, ['Admin']);
  const centralList = await f.request('/api/users', { token: f.centralToken });
  assert.ok(centralList.data.some((entry) => entry.id === siblingOnly.id));
  assert.deepEqual(centralList.data.find((entry) => entry.id === target.id).roles, []);
});

test('administrative EDV numbers do not collide with existing ordinary units', () => {
  const data = structuredClone(seedData);
  normalizeTenancyData(data);
  const ordinaryOrganization = data.organizations.find((entry) => entry.id !== PLATFORM_ORGANIZATION_ID);
  data.organizationUnits.push({ id: 'existing-number', organizationId: ordinaryOrganization.id,
    parentId: data.organizationUnits.find((unit) => unit.organizationId === ordinaryOrganization.id).id,
    name: 'Existing unit', status: 'active', edvNumber: 'MK-PLATFORM' });
  synchronizePlatformAdministration(data);
  assert.notEqual(data.organizations.find((entry) => entry.id === PLATFORM_ORGANIZATION_ID).edvNumber, 'MK-PLATFORM');
  assert.equal(data.organizationUnits.find((entry) => entry.id === 'existing-number').edvNumber, 'MK-PLATFORM');
});
