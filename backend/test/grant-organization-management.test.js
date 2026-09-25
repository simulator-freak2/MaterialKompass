const assert = require('node:assert/strict');
const test = require('node:test');
const {
  grantOrganizationManagement,
} = require('../src/scripts/grant-organization-management');

function fixture() {
  return {
    users: [
      { id: 'user-nils', username: 'nils.wiedenhaus', roles: [], permissions: [] },
      { id: 'user-admin', username: 'admin', roles: ['Admin'], permissions: [] },
    ],
    roles: [{ id: 'role-admin', name: 'Admin', permissions: ['users.write'] }],
    permissions: ['users.write'],
    memberships: [
      {
        id: 'membership-nils', userId: 'user-nils', organizationId: 'org-1',
        status: 'active', defaultUnitId: 'unit-1',
        scopes: [{ unitId: 'unit-1', roles: ['Nutzer'], departmentIds: [] }],
      },
      {
        id: 'membership-admin', userId: 'user-admin', organizationId: 'org-1',
        status: 'active', defaultUnitId: 'unit-1', scopes: [],
      },
    ],
    units: [
      {
        id: 'unit-1', organizationId: 'org-1', parentId: null,
        status: 'active',
      },
    ],
  };
}

test('grants organization administration to the configured users idempotently', () => {
  const data = fixture();

  const first = grantOrganizationManagement(data);
  const second = grantOrganizationManagement(data);

  assert.deepEqual(first.usernames, ['nils.wiedenhaus', 'admin']);
  assert.deepEqual(second.usernames, first.usernames);
  data.users.forEach((user) => {
    assert.equal(user.platformAdmin, true);
    assert.equal(user.roles.filter((role) => role === 'Admin').length, 1);
    assert.equal(
      user.permissions.filter((permission) => permission === 'organizations.write').length,
      1,
    );
  });
  data.memberships.forEach((membership) => {
    assert.ok(membership.scopes.length > 0);
    membership.scopes.forEach((scope) => {
      assert.equal(scope.roles.filter((role) => role === 'Admin').length, 1);
    });
  });
  assert.equal(
    data.roles[0].permissions.filter((permission) =>
      permission === 'organizations.write').length,
    1,
  );
  assert.equal(
    data.permissions.filter((permission) => permission === 'organizations.write').length,
    1,
  );
});

test('refuses partial changes when a requested user is missing', () => {
  const data = fixture();
  const before = structuredClone(data);

  assert.throws(
    () => grantOrganizationManagement(data, ['nils.wiedenhaus', 'unbekannt']),
    /Nutzer nicht gefunden: unbekannt/,
  );
  assert.deepEqual(data, before);
});
