const { createUserStore } = require('../db/user-store');

const ORGANIZATION_PERMISSION = 'organizations.write';
const ADMIN_ROLE = 'Admin';
const DEFAULT_TARGET_USERNAMES = ['nils.wiedenhaus', 'admin'];

function addUnique(values, value) {
  if (!values.includes(value)) values.push(value);
}

function grantOrganizationManagement(data, targetUsernames = DEFAULT_TARGET_USERNAMES) {
  const requested = [...new Set(targetUsernames.map((value) =>
    String(value).trim().toLocaleLowerCase('de')))].filter(Boolean);
  const usersByUsername = new Map((data.users || []).map((user) =>
    [String(user.username || '').toLocaleLowerCase('de'), user]));
  const targets = requested.map((username) => usersByUsername.get(username));
  const missingUsers = requested.filter((_username, index) => !targets[index]);
  if (missingUsers.length > 0) {
    throw new Error(`Nutzer nicht gefunden: ${missingUsers.join(', ')}`);
  }

  const membershipsByUser = new Map(targets.map((user) => [
    user.id,
    (data.memberships || []).filter((membership) =>
      membership.userId === user.id && membership.status === 'active'),
  ]));
  const usersWithoutMembership = targets
    .filter((user) => membershipsByUser.get(user.id).length === 0)
    .map((user) => user.username);
  if (usersWithoutMembership.length > 0) {
    throw new Error(
      `Keine aktive Organisationszuordnung für: ${usersWithoutMembership.join(', ')}`,
    );
  }

  const adminRoles = (data.roles || []).filter((role) => role.name === ADMIN_ROLE);
  if (adminRoles.length === 0) throw new Error('Die Rolle Admin wurde nicht gefunden.');

  data.permissions ||= [];
  addUnique(data.permissions, ORGANIZATION_PERMISSION);
  adminRoles.forEach((role) => {
    role.permissions ||= [];
    addUnique(role.permissions, ORGANIZATION_PERMISSION);
  });

  const changedMembershipIds = [];
  targets.forEach((user) => {
    user.roles ||= [];
    user.permissions ||= [];
    addUnique(user.roles, ADMIN_ROLE);
    addUnique(user.permissions, ORGANIZATION_PERMISSION);
    user.platformAdmin = true;

    membershipsByUser.get(user.id).forEach((membership) => {
      membership.scopes ||= [];
      if (membership.scopes.length === 0) {
        const defaultUnit = (data.units || []).find((unit) =>
          unit.id === membership.defaultUnitId
            && unit.organizationId === membership.organizationId
            && unit.status === 'active')
          || (data.units || []).find((unit) =>
            unit.organizationId === membership.organizationId
              && unit.parentId === null && unit.status === 'active');
        if (!defaultUnit) {
          throw new Error(
            `Keine aktive Organisationseinheit für ${user.username} gefunden.`,
          );
        }
        membership.defaultUnitId = defaultUnit.id;
        membership.scopes.push({
          unitId: defaultUnit.id,
          includeDescendants: true,
          roles: [ADMIN_ROLE],
          departmentIds: [],
        });
      } else {
        membership.scopes.forEach((scope) => {
          scope.roles ||= [];
          addUnique(scope.roles, ADMIN_ROLE);
        });
      }
      changedMembershipIds.push(membership.id);
    });
  });

  return {
    usernames: targets.map((user) => user.username),
    users: targets,
    roles: adminRoles,
    changedMembershipIds,
  };
}

async function main() {
  const store = createUserStore();
  try {
    await store.acquireProcessLock();
    await store.initialize();
    const userData = await store.load();
    const collections = await store.loadCollections();
    const data = {
      users: userData.users,
      roles: userData.roles,
      memberships: collections.memberships || [],
      units: collections.organizationUnits || [],
      permissions: collections.permissions || [],
    };
    const result = grantOrganizationManagement(data);

    await Promise.all(result.roles.map((role) => store.saveRole(role)));
    await Promise.all(result.users.map((user) => store.saveUser(user)));
    await store.saveCollections({
      memberships: data.memberships,
      permissions: data.permissions,
    });

    console.log(
      `Organisationsverwaltung freigeschaltet für: ${result.usernames.join(', ')}.`,
    );
    console.log(
      `${result.changedMembershipIds.length} aktive Organisationszuordnung(en) aktualisiert.`,
    );
  } finally {
    await store.close();
  }
}

if (require.main === module) {
  main().catch((error) => {
    console.error(`Freischaltung fehlgeschlagen: ${error.message}`);
    process.exitCode = 1;
  });
}

module.exports = {
  ADMIN_ROLE,
  ORGANIZATION_PERMISSION,
  DEFAULT_TARGET_USERNAMES,
  grantOrganizationManagement,
};
