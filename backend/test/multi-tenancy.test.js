const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');
const { seedData } = require('../src/data/seed');

async function request(baseUrl, path, { token, method = 'GET', body } = {}) {
  const response = await fetch(`${baseUrl}${path}`, {
    method,
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const data = response.status === 204 ? null : await response.json();
  return { response, data };
}

function tenantData() {
  const data = structuredClone(seedData);
  data.organizations = [
    { id: 'org-a', name: 'Organisation A', shortName: 'A', edvNumber: '10000001', status: 'active', branding: {} },
    { id: 'org-b', name: 'Organisation B', shortName: 'B', edvNumber: '10000002', status: 'active', branding: {} },
  ];
  data.organizationUnits = [
    { id: 'unit-a', organizationId: 'org-a', parentId: null, name: 'A', type: 'Organisation', edvNumber: '10000001', status: 'active' },
    { id: 'unit-a-child', organizationId: 'org-a', parentId: 'unit-a', name: 'A-Ortsgruppe', type: 'Ortsgruppe', edvNumber: '10000101', status: 'active' },
    { id: 'unit-a-sibling', organizationId: 'org-a', parentId: 'unit-a', name: 'A-Kreis', type: 'Kreis', edvNumber: '10000102', status: 'active' },
    { id: 'unit-b', organizationId: 'org-b', parentId: null, name: 'B', type: 'Organisation', edvNumber: '10000002', status: 'active' },
  ];
  data.memberships = [
    {
      id: 'membership-admin-a', userId: 'user-admin', organizationId: 'org-a',
      status: 'active', defaultUnitId: 'unit-a',
      scopes: [{ unitId: 'unit-a', includeDescendants: true, roles: ['Admin'], departmentIds: [] }],
    },
    {
      id: 'membership-admin-b', userId: 'user-admin', organizationId: 'org-b',
      status: 'active', defaultUnitId: 'unit-b',
      scopes: [{ unitId: 'unit-b', includeDescendants: true, roles: ['Admin'], departmentIds: [] }],
    },
    {
      id: 'membership-warden-a', userId: 'user-materialwart', organizationId: 'org-a',
      status: 'active', defaultUnitId: 'unit-a-child',
      scopes: [{ unitId: 'unit-a-child', includeDescendants: false, roles: ['Materialwart'], departmentIds: [] }],
    },
  ];
  const unitScoped = new Set([
    'departments', 'locations', 'shelves', 'storageLevels', 'stockStructures',
    'materials', 'deletedMaterials', 'materialMovements', 'materialInspections',
    'materialDocuments', 'reservations', 'maintenanceEvents', 'clothingItems',
    'clothingInspections', 'deletedClothingItems', 'issueTransactions',
    'defectReports', 'notifications', 'defectEmailImports', 'procurementRequests',
    'procurementOffers', 'procurementOrders', 'procurementReceipts',
    'procurementDocuments', 'suppliers', 'documents', 'procurementEmailImports',
    'exportLogs', 'stocktakes', 'stocktakeEmailImports',
  ]);
  for (const [name, values] of Object.entries(data)) {
    if (!Array.isArray(values) || ['users', 'roles', 'permissions', 'organizations', 'organizationUnits', 'memberships'].includes(name)) continue;
    values.forEach((entry) => {
      if (!entry || typeof entry !== 'object') return;
      entry.organizationId = 'org-a';
      if (unitScoped.has(name)) entry.unitId = 'unit-a';
    });
  }
  data.materials.push({
    ...structuredClone(data.materials[0]),
    id: 'material-b',
    inventoryNumber: 'B-001',
    name: 'Nur Organisation B',
    organizationId: 'org-b',
    unitId: 'unit-b',
  });
  data.locations.push({
    ...structuredClone(data.locations[0]),
    id: 'loc-a-child',
    code: 'A-CHILD',
    name: 'Lager A-Ortsgruppe',
    organizationId: 'org-a',
    unitId: 'unit-a-child',
  });
  data.materials.push({
    ...structuredClone(data.materials[0]),
    id: 'material-a-child',
    inventoryNumber: 'A-CHILD-001',
    name: 'Nur A-Ortsgruppe',
    organizationId: 'org-a',
    unitId: 'unit-a-child',
    locationId: 'loc-a-child',
    stockStructureId: null,
  });
  data.categories.push(
    {
      id: 'A-CHILD-CATEGORY', name: 'Kategorie Ortsgruppe', parentId: null,
      organizationId: 'org-a', unitId: 'unit-a-child', scope: 'unit',
    },
    {
      id: 'A-SIBLING-CATEGORY', name: 'Kategorie Kreis', parentId: null,
      organizationId: 'org-a', unitId: 'unit-a-sibling', scope: 'unit',
    },
  );
  return data;
}

function youthTenantData() {
  const data = tenantData();
  data.organizationUnits.push({
    id: 'unit-a-youth', organizationId: 'org-a', parentId: 'unit-a',
    baseUnitId: 'unit-a', unitKind: 'youth', name: 'Jugend A',
    type: 'Jugendorganisation', edvNumber: '10000110', status: 'active',
  });
  const chair = {
    ...structuredClone(data.users.find((entry) => entry.id === 'user-materialwart')),
    id: 'user-youth-chair', name: 'Jugend Vorsitz', username: 'jugendvorsitz',
    email: 'jugendvorsitz@example.test', roles: ['Vorsitz'], permissions: [],
  };
  data.users.push(chair);
  data.memberships.push({
    id: 'membership-youth-chair', userId: chair.id, organizationId: 'org-a',
    status: 'active', defaultUnitId: 'unit-a-youth',
    scopes: [
      {
        unitId: 'unit-a-youth', includeDescendants: false,
        roles: ['Vorsitz'], departmentIds: [],
      },
      {
        unitId: 'unit-a', includeDescendants: false,
        roles: ['Nutzer'], departmentIds: [],
      },
    ],
  });
  data.locations.push({
    id: 'loc-a-youth', name: 'Jugendlager', code: 'JUG', type: 'Lager',
    street: 'Jugendweg', houseNumber: '1', postalCode: '12345', city: 'Musterstadt',
    country: 'Deutschland', organizationId: 'org-a', unitId: 'unit-a-youth',
  });
  data.materials.push({
    ...structuredClone(data.materials[0]), id: 'material-a-youth',
    inventoryNumber: 'A-YOUTH-001', name: 'Jugend-Zelt', locationId: 'loc-a-youth',
    stockStructureId: null, organizationId: 'org-a', unitId: 'unit-a-youth',
    safetyCritical: false, nextInspectionDate: null, nextMaintenanceDate: null,
  });
  data.materials.push({
    ...structuredClone(data.materials[0]), id: 'material-a-base-shared',
    inventoryNumber: 'A-BASE-001', name: 'Stamm-Zelt', locationId: 'loc-1',
    stockStructureId: null, organizationId: 'org-a', unitId: 'unit-a',
    safetyCritical: false, nextInspectionDate: null, nextMaintenanceDate: null,
    reservationApprovalRequired: false, reservationAllowedUnitIds: [],
  });
  data.vehicles.push({
    id: 'vehicle-a-base', organizationId: 'org-a', unitId: 'unit-a',
    registrationNumber: 'A JUG 1', vin: 'YOUTH-VEHICLE-1',
    radioCallName: 'Stammfahrzeug', vehicleKind: 'Kraftfahrzeug',
    usage: 'sonstige Verwendung', type: 'Vereinsfahrzeug', status: 'Verfügbar',
    primaryResponseVehicle: false, viewAllowedUnitIds: [],
    reservationAllowedUnitIds: [], createdAt: '2026-01-01T00:00:00.000Z',
  });
  data.vehicles.push({
    id: 'vehicle-a-youth', organizationId: 'org-a', unitId: 'unit-a-youth',
    registrationNumber: 'A JUG 2', vin: 'YOUTH-VEHICLE-2',
    radioCallName: 'Jugendfahrzeug', vehicleKind: 'Kraftfahrzeug',
    usage: 'sonstige Verwendung', type: 'Vereinsfahrzeug', status: 'Verfügbar',
    primaryResponseVehicle: false, viewAllowedUnitIds: [],
    reservationAllowedUnitIds: [], createdAt: '2026-01-01T00:00:00.000Z',
  });
  return data;
}

async function start(data = tenantData()) {
  const app = createApp({ data, skipEmailVerification: true });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  return { app, server, baseUrl: `http://127.0.0.1:${server.address().port}` };
}

async function login(baseUrl, identifier, password) {
  const result = await request(baseUrl, '/api/auth/login', {
    method: 'POST', body: { identifier, password },
  });
  assert.equal(result.response.status, 200);
  return result.data.token;
}

test('organization context prevents cross-tenant reads and guessed foreign IDs', async () => {
  const { server, baseUrl } = await start();
  try {
    const tokenA = await login(baseUrl, 'admin', 'MaterialKompass2026!');
    const listA = await request(baseUrl, '/api/material', { token: tokenA });
    assert.equal(listA.response.status, 200);
    assert.ok(listA.data.some((entry) => entry.id === 'material-1'));
    assert.ok(!listA.data.some((entry) => entry.id === 'material-a-child'));
    assert.ok(!listA.data.some((entry) => entry.id === 'material-b'));
    assert.equal((await request(baseUrl, '/api/material/material-b', { token: tokenA })).response.status, 404);

    const switchedChild = await request(baseUrl, '/api/auth/context', {
      token: tokenA,
      method: 'POST',
      body: { organizationId: 'org-a', unitId: 'unit-a-child' },
    });
    assert.equal(switchedChild.response.status, 200);
    const childMaterials = await request(baseUrl, '/api/material', {
      token: switchedChild.data.token,
    });
    assert.deepEqual(childMaterials.data.map((entry) => entry.id), ['material-a-child']);

    const switched = await request(baseUrl, '/api/auth/context', {
      token: tokenA,
      method: 'POST',
      body: { organizationId: 'org-b', unitId: 'unit-b' },
    });
    assert.equal(switched.response.status, 200);
    const tokenB = switched.data.token;
    const listB = await request(baseUrl, '/api/material', { token: tokenB });
    assert.deepEqual(listB.data.map((entry) => entry.id), ['material-b']);
    assert.equal((await request(baseUrl, '/api/material/material-1', { token: tokenB })).response.status, 404);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('unit-scoped memberships see central and own categories but not sibling data', async () => {
  const { server, baseUrl } = await start();
  try {
    const token = await login(baseUrl, 'materialwart', 'Material123!');
    const materials = await request(baseUrl, '/api/material', { token });
    assert.deepEqual(materials.data.map((entry) => entry.id), ['material-a-child']);
    const categories = await request(baseUrl, '/api/categories', { token });
    assert.ok(categories.data.some((entry) => entry.id === '02'));
    assert.ok(categories.data.some((entry) => entry.id === 'A-CHILD-CATEGORY'));
    assert.ok(!categories.data.some((entry) => entry.id === 'A-SIBLING-CATEGORY'));
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('only admins with organization permission create organizations and suborganizations', async () => {
  const authorized = await start();
  try {
    const token = await login(authorized.baseUrl, 'admin', 'MaterialKompass2026!');
    const organization = await request(authorized.baseUrl, '/api/organizations', {
      token,
      method: 'POST',
      body: { name: 'Organisation C', shortName: 'C', edvNumber: '10000003' },
    });
    assert.equal(organization.response.status, 201);
    assert.equal(organization.data.edvNumber, '10000003');

    const unit = await request(authorized.baseUrl, '/api/organization-units', {
      token,
      method: 'POST',
      body: {
        name: 'A-Unterorganisation', type: 'Ortsgruppe',
        parentId: 'unit-a', edvNumber: '10000103',
      },
    });
    assert.equal(unit.response.status, 201);
    assert.equal(unit.data.parentId, 'unit-a');
    assert.equal(unit.data.edvNumber, '10000103');
    assert.equal(unit.data.dataIsolation, 'strict');

    const creatorCanEnter = await request(authorized.baseUrl, '/api/auth/context', {
      token,
      method: 'POST',
      body: { organizationId: 'org-a', unitId: unit.data.id },
    });
    assert.equal(creatorCanEnter.response.status, 200);

    const nestedUnit = await request(authorized.baseUrl, '/api/organization-units', {
      token: creatorCanEnter.data.token,
      method: 'POST',
      body: {
        name: 'A-Unterebene', type: 'Gruppe',
        parentId: unit.data.id, edvNumber: '10000104',
      },
    });
    assert.equal(nestedUnit.response.status, 201);
    assert.equal(nestedUnit.data.parentId, unit.data.id);

    const materialwartToken = await login(
      authorized.baseUrl, 'materialwart', 'Material123!'
    );
    const otherUnitIsBlocked = await request(authorized.baseUrl, '/api/auth/context', {
      token: materialwartToken,
      method: 'POST',
      body: { organizationId: 'org-a', unitId: unit.data.id },
    });
    assert.equal(otherUnitIsBlocked.response.status, 403);

    const duplicateEdvNumber = await request(authorized.baseUrl, '/api/organization-units', {
      token,
      method: 'POST',
      body: {
        name: 'Doppelte EDV', type: 'Ortsgruppe',
        parentId: 'unit-a', edvNumber: '10000103',
      },
    });
    assert.equal(duplicateEdvNumber.response.status, 409);
  } finally {
    await new Promise((resolve) => authorized.server.close(resolve));
  }

  const nonAdminData = tenantData();
  nonAdminData.roles.push({
    id: 'role-organization-creator',
    name: 'Organisationsstruktur-Ersteller',
    permissions: ['organizations.write'],
  });
  nonAdminData.memberships.find((entry) =>
    entry.id === 'membership-warden-a'
  ).scopes[0].roles = ['Organisationsstruktur-Ersteller'];
  const nonAdmin = await start(nonAdminData);
  try {
    const token = await login(nonAdmin.baseUrl, 'materialwart', 'Material123!');
    const result = await request(nonAdmin.baseUrl, '/api/organization-units', {
      token,
      method: 'POST',
      body: { name: 'Nicht erlaubt', type: 'Ortsgruppe', parentId: 'unit-a-child' },
    });
    assert.equal(result.response.status, 403);
  } finally {
    await new Promise((resolve) => nonAdmin.server.close(resolve));
  }

  const missingPermissionData = tenantData();
  missingPermissionData.roles.find((role) => role.name === 'Admin').permissions =
    missingPermissionData.roles.find((role) => role.name === 'Admin').permissions
      .filter((permission) => permission !== 'organizations.write');
  const missingPermission = await start(missingPermissionData);
  try {
    const token = await login(missingPermission.baseUrl, 'admin', 'MaterialKompass2026!');
    const organization = await request(missingPermission.baseUrl, '/api/organizations', {
      token,
      method: 'POST',
      body: { name: 'Nicht erlaubt', shortName: 'NE' },
    });
    assert.equal(organization.response.status, 403);

    const unit = await request(missingPermission.baseUrl, '/api/organization-units', {
      token,
      method: 'POST',
      body: { name: 'Nicht erlaubt', type: 'Ortsgruppe', parentId: 'unit-a' },
    });
    assert.equal(unit.response.status, 403);
  } finally {
    await new Promise((resolve) => missingPermission.server.close(resolve));
  }
});

test('youth organizations are one-to-one linked units without child units', async () => {
  const { server, baseUrl } = await start();
  try {
    const token = await login(baseUrl, 'admin', 'MaterialKompass2026!');
    const youth = await request(baseUrl, '/api/organization-units', {
      token, method: 'POST', body: {
        name: 'Jugend A', type: 'Wird ignoriert', unitKind: 'youth',
        parentId: 'unit-a', edvNumber: '10000120',
      },
    });
    assert.equal(youth.response.status, 201);
    assert.equal(youth.data.unitKind, 'youth');
    assert.equal(youth.data.baseUnitId, 'unit-a');
    assert.equal(youth.data.type, 'Jugendorganisation');

    const duplicate = await request(baseUrl, '/api/organization-units', {
      token, method: 'POST', body: {
        name: 'Zweite Jugend', unitKind: 'youth',
        parentId: 'unit-a', edvNumber: '10000121',
      },
    });
    assert.equal(duplicate.response.status, 409);

    const child = await request(baseUrl, '/api/organization-units', {
      token, method: 'POST', body: {
        name: 'Unzulässige Untergruppe', type: 'Gruppe',
        parentId: youth.data.id, edvNumber: '10000122',
      },
    });
    assert.equal(child.response.status, 409);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('youth chair derives the restricted Jugendvorsitzender role in the base unit', async () => {
  const { server, baseUrl } = await start(youthTenantData());
  try {
    const youthToken = await login(baseUrl, 'jugendvorsitz', 'Material123!');
    const units = await request(baseUrl, '/api/organization-units', { token: youthToken });
    assert.deepEqual(new Set(units.data.map((entry) => entry.id)),
      new Set(['unit-a', 'unit-a-youth']));

    const baseContext = await request(baseUrl, '/api/auth/context', {
      token: youthToken, method: 'POST',
      body: { organizationId: 'org-a', unitId: 'unit-a' },
    });
    assert.equal(baseContext.response.status, 200);
    assert.deepEqual(new Set(baseContext.data.user.roles),
      new Set(['Nutzer', 'Jugendvorsitzender']));
    assert.ok(baseContext.data.user.permissions.includes('reservations.create'));
    assert.ok(baseContext.data.user.permissions.includes('defects.report'));
    assert.ok(!baseContext.data.user.permissions.includes('inventory.write'));
    assert.ok(!baseContext.data.user.permissions.includes('stocktakes.create'));

    const adminToken = await login(baseUrl, 'admin', 'MaterialKompass2026!');
    const invalidAssignment = await request(baseUrl, '/api/users/user-youth-chair', {
      token: adminToken, method: 'PUT', body: {
        name: 'Jugend Vorsitz', username: 'jugendvorsitz',
        email: 'jugendvorsitz@example.test', active: true,
        defaultUnitId: 'unit-a-youth', scopes: [{
          unitId: 'unit-a-youth', includeDescendants: false,
          roles: ['Jugendvorsitzender'], departmentIds: [],
        }],
      },
    });
    assert.equal(invalidAssignment.response.status, 400);
    const reservedRoleName = await request(baseUrl, '/api/roles', {
      token: adminToken, method: 'POST', body: {
        name: 'Jugendvorsitzender', permissions: ['inventory.write'],
      },
    });
    assert.equal(reservedRoleName.response.status, 409);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('youth and base units share only search, reservation and defect reporting capabilities', async () => {
  const { server, baseUrl } = await start(youthTenantData());
  try {
    const youthToken = await login(baseUrl, 'jugendvorsitz', 'Material123!');
    const inventory = await request(baseUrl, '/api/material', { token: youthToken });
    assert.ok(inventory.data.some((entry) => entry.id === 'material-a-base-shared'
      && entry.readOnly === true));
    assert.ok(!inventory.data.some((entry) => entry.id === 'material-a-child'));

    const forbiddenMaterialWrite = await request(baseUrl, '/api/material/material-a-base-shared', {
      token: youthToken, method: 'PUT', body: { name: 'Manipuliert' },
    });
    assert.equal(forbiddenMaterialWrite.response.status, 404);

    const locations = await request(baseUrl, '/api/locations', { token: youthToken });
    assert.ok(locations.data.some((entry) => entry.id === 'loc-1' && entry.readOnly === true));
    const forbiddenLocationWrite = await request(baseUrl, '/api/locations/loc-1', {
      token: youthToken, method: 'PUT', body: { name: 'Manipuliert' },
    });
    assert.equal(forbiddenLocationWrite.response.status, 404);

    const reservableMaterials = await request(baseUrl, '/api/calendar/materials', {
      token: youthToken,
    });
    assert.ok(reservableMaterials.data.some((entry) => entry.id === 'material-a-base-shared'));
    const reservation = await request(baseUrl, '/api/reservations', {
      token: youthToken, method: 'POST', body: {
        purpose: 'Jugendübung', startAt: '2028-06-01T08:00:00.000Z',
        endAt: '2028-06-01T12:00:00.000Z',
        items: [{ materialId: 'material-a-base-shared', quantity: 1 }],
      },
    });
    assert.equal(reservation.response.status, 201);
    assert.equal(reservation.data.status, 'Ausstehend');

    const vehicles = await request(baseUrl, '/api/vehicles', { token: youthToken });
    assert.ok(vehicles.data.some((entry) => entry.id === 'vehicle-a-base'));
    const vehicleReservation = await request(baseUrl, '/api/vehicle-reservations', {
      token: youthToken, method: 'POST', body: {
        vehicleId: 'vehicle-a-base', title: 'Jugendfahrt', purpose: 'Übung',
        destination: 'Musterstadt', contact: 'Jugend Vorsitz',
        startAt: '2028-06-02T08:00:00.000Z', endAt: '2028-06-02T12:00:00.000Z',
      },
    });
    assert.equal(vehicleReservation.response.status, 201);
    assert.equal(vehicleReservation.data.status, 'Ausstehend');

    const defect = await request(baseUrl, '/api/defects', {
      token: youthToken, method: 'POST', body: {
        entityType: 'MaterialItem', entityId: 'material-a-base-shared',
        title: 'Beschädigtes Zelt', description: 'Eine Stange ist gebrochen.',
        priority: 'Normal',
      },
    });
    assert.equal(defect.response.status, 201);
    assert.equal(defect.data.unitId, 'unit-a');
    const ownDefects = await request(baseUrl, '/api/defects', { token: youthToken });
    const ownDefect = ownDefects.data.find((entry) => entry.id === defect.data.id);
    assert.equal(ownDefect.readOnly, true);
    assert.ok(!Object.hasOwn(ownDefect, 'history'));

    const siblingDefect = await request(baseUrl, '/api/defects', {
      token: youthToken, method: 'POST', body: {
        entityType: 'MaterialItem', entityId: 'material-a-child',
        title: 'Nicht erlaubt', description: 'Nicht verknüpfte Einheit.',
      },
    });
    assert.equal(siblingDefect.response.status, 400);

    const baseToken = await login(baseUrl, 'admin', 'MaterialKompass2026!');
    const baseInventory = await request(baseUrl, '/api/material', { token: baseToken });
    assert.ok(baseInventory.data.some((entry) => entry.id === 'material-a-youth'
      && entry.readOnly === true));
    const baseLocations = await request(baseUrl, '/api/locations', { token: baseToken });
    assert.ok(baseLocations.data.some((entry) => entry.id === 'loc-a-youth'
      && entry.readOnly === true));
    const baseVehicles = await request(baseUrl, '/api/vehicles', { token: baseToken });
    assert.ok(baseVehicles.data.some((entry) => entry.id === 'vehicle-a-youth'));
    const reverseDefect = await request(baseUrl, '/api/defects', {
      token: baseToken, method: 'POST', body: {
        entityType: 'Vehicle', entityId: 'vehicle-a-youth',
        title: 'Reifen beschädigt', description: 'Der Reifen verliert Luft.',
        priority: 'Hoch',
      },
    });
    assert.equal(reverseDefect.response.status, 201);
    assert.equal(reverseDefect.data.unitId, 'unit-a-youth');
    assert.equal(reverseDefect.data.readOnly, true);
    const forbiddenDefectWrite = await request(
      baseUrl,
      `/api/defects/${reverseDefect.data.id}`,
      {
        token: baseToken, method: 'PUT',
        body: { title: 'Darf nicht geändert werden' },
      },
    );
    assert.equal(forbiddenDefectWrite.response.status, 403);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('admins selectively share inventory with parent and child units as read-only', async () => {
  const { server, baseUrl } = await start();
  try {
    const rootToken = await login(baseUrl, 'admin', 'MaterialKompass2026!');
    const sharedUp = await request(
      baseUrl,
      '/api/organization-units/unit-a-child/inventory-visibility',
      {
        token: rootToken,
        method: 'PUT',
        body: { visibleToUnitIds: ['unit-a'] },
      },
    );
    assert.equal(sharedUp.response.status, 200);
    assert.deepEqual(sharedUp.data.visibleToUnitIds, ['unit-a']);

    const rootInventory = await request(baseUrl, '/api/material', { token: rootToken });
    const sharedChildItem = rootInventory.data.find((entry) =>
      entry.id === 'material-a-child');
    assert.ok(sharedChildItem);
    assert.equal(sharedChildItem.readOnly, true);
    assert.equal(sharedChildItem.sourceUnitName, 'A-Ortsgruppe');

    const sharedWrite = await request(baseUrl, '/api/material/material-a-child', {
      token: rootToken,
      method: 'PUT',
      body: { name: 'Darf nicht geändert werden' },
    });
    assert.equal(sharedWrite.response.status, 404);

    const siblingShare = await request(
      baseUrl,
      '/api/organization-units/unit-a-child/inventory-visibility',
      {
        token: rootToken,
        method: 'PUT',
        body: { visibleToUnitIds: ['unit-a-sibling'] },
      },
    );
    assert.equal(siblingShare.response.status, 400);

    const sharedDown = await request(
      baseUrl,
      '/api/organization-units/unit-a/inventory-visibility',
      {
        token: rootToken,
        method: 'PUT',
        body: { visibleToUnitIds: ['unit-a-child'] },
      },
    );
    assert.equal(sharedDown.response.status, 200);

    const childContext = await request(baseUrl, '/api/auth/context', {
      token: rootToken,
      method: 'POST',
      body: { organizationId: 'org-a', unitId: 'unit-a-child' },
    });
    const childInventory = await request(baseUrl, '/api/material', {
      token: childContext.data.token,
    });
    assert.ok(childInventory.data.some((entry) =>
      entry.id === 'material-1' && entry.readOnly === true));
    assert.ok(childInventory.data.some((entry) =>
      entry.id === 'material-a-child' && entry.readOnly === false));

    const nonAdminToken = await login(baseUrl, 'materialwart', 'Material123!');
    const forbidden = await request(
      baseUrl,
      '/api/organization-units/unit-a-child/inventory-visibility',
      {
        token: nonAdminToken,
        method: 'PUT',
        body: { visibleToUnitIds: ['unit-a'] },
      },
    );
    assert.equal(forbidden.response.status, 403);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('cross-level reservations require an explicit item grant and conflict organization-wide', async () => {
  const { server, baseUrl } = await start();
  try {
    const rootToken = await login(baseUrl, 'admin', 'MaterialKompass2026!');
    const visibility = await request(
      baseUrl,
      '/api/organization-units/unit-a-child/inventory-visibility',
      { token: rootToken, method: 'PUT', body: { visibleToUnitIds: ['unit-a'] } },
    );
    assert.equal(visibility.response.status, 200);

    const beforeGrant = await request(baseUrl, '/api/calendar/materials', {
      token: rootToken,
    });
    assert.ok(!beforeGrant.data.some((entry) => entry.id === 'material-a-child'));

    const childContext = await request(baseUrl, '/api/auth/context', {
      token: rootToken,
      method: 'POST',
      body: { organizationId: 'org-a', unitId: 'unit-a-child' },
    });
    const childToken = childContext.data.token;
    const childMaterial = await request(baseUrl, '/api/material/material-a-child', {
      token: childToken,
    });
    const grant = await request(baseUrl, '/api/material/material-a-child', {
      token: childToken,
      method: 'PUT',
      body: { ...childMaterial.data, reservationAllowedUnitIds: ['unit-a'] },
    });
    assert.equal(grant.response.status, 200);
    assert.deepEqual(grant.data.reservationAllowedUnitIds, ['unit-a']);

    const afterGrant = await request(baseUrl, '/api/calendar/materials', {
      token: rootToken,
    });
    const shared = afterGrant.data.find((entry) => entry.id === 'material-a-child');
    assert.ok(shared);
    assert.equal(shared.externalReservation, true);

    const body = {
      purpose: 'Gemeinsame Übung',
      startAt: '2027-11-01T08:00:00.000Z',
      endAt: '2027-11-01T12:00:00.000Z',
      items: [{ materialId: 'material-a-child', quantity: 1 }],
    };
    const reservation = await request(baseUrl, '/api/reservations', {
      token: rootToken, method: 'POST', body,
    });
    assert.equal(reservation.response.status, 201);
    assert.equal(reservation.data.items[0].materialUnitId, 'unit-a-child');

    const sourceConflict = await request(baseUrl, '/api/reservations', {
      token: childToken, method: 'POST', body: { ...body, purpose: 'Lokaler Termin' },
    });
    assert.equal(sourceConflict.response.status, 409);

    const issued = await request(
      baseUrl,
      `/api/reservations/${reservation.data.id}/issue`,
      { token: rootToken, method: 'POST', body: {} },
    );
    assert.equal(issued.response.status, 200);
    const sourceAfterIssue = await request(baseUrl, '/api/material/material-a-child', {
      token: childToken,
    });
    assert.equal(sourceAfterIssue.data.issuedQuantity, 1);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('units require transfer before archive and receive a two-year purge deadline', async () => {
  const { server, baseUrl } = await start();
  try {
    const token = await login(baseUrl, 'admin', 'MaterialKompass2026!');
    const blocked = await request(baseUrl, '/api/organization-units/unit-a-child/archive', {
      token, method: 'POST', body: {},
    });
    assert.equal(blocked.response.status, 409);

    const transfer = await request(baseUrl, '/api/organization-units/unit-a-child/transfer', {
      token, method: 'POST', body: { targetUnitId: 'unit-a' },
    });
    assert.equal(transfer.response.status, 200);
    assert.ok(transfer.data.transferred > 0);

    const archived = await request(baseUrl, '/api/organization-units/unit-a-child/archive', {
      token, method: 'POST', body: {},
    });
    assert.equal(archived.response.status, 200);
    const retentionDays = (Date.parse(archived.data.purgeAfter) - Date.now()) / 86_400_000;
    assert.ok(retentionDays > 729 && retentionDays <= 730.1);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('users receive independent rights per organization and organization unit', async () => {
  const { server, baseUrl } = await start();
  try {
    const adminToken = await login(baseUrl, 'admin', 'MaterialKompass2026!');
    const users = await request(baseUrl, '/api/users?search=materialwart', {
      token: adminToken,
    });
    const materialwart = users.data[0];
    const changed = await request(baseUrl, `/api/users/${materialwart.id}`, {
      token: adminToken,
      method: 'PUT',
      body: {
        ...materialwart,
        defaultUnitId: 'unit-a-child',
        scopes: [
          {
            unitId: 'unit-a-child', includeDescendants: false,
            roles: ['Materialwart'], departmentIds: [],
          },
          {
            unitId: 'unit-a-sibling', includeDescendants: false,
            roles: ['Nutzer'], departmentIds: [],
          },
        ],
      },
    });
    assert.equal(changed.response.status, 200);
    assert.deepEqual(
      changed.data.organizationAccess.scopes.map((scope) => scope.roles),
      [['Materialwart'], ['Nutzer']],
    );

    const materialwartToken = await login(baseUrl, 'materialwart', 'Material123!');
    const siblingContext = await request(baseUrl, '/api/auth/context', {
      token: materialwartToken,
      method: 'POST',
      body: { organizationId: 'org-a', unitId: 'unit-a-sibling' },
    });
    assert.equal(siblingContext.response.status, 200);
    assert.deepEqual(siblingContext.data.user.roles, ['Nutzer']);

    const organizationB = await request(baseUrl, '/api/auth/context', {
      token: adminToken,
      method: 'POST',
      body: { organizationId: 'org-b', unitId: 'unit-b' },
    });
    assert.equal(organizationB.response.status, 200);
    const assigned = await request(baseUrl, '/api/users/memberships', {
      token: organizationB.data.token,
      method: 'POST',
      body: {
        identifier: 'materialwart',
        defaultUnitId: 'unit-b',
        scopes: [{
          unitId: 'unit-b', includeDescendants: false,
          roles: ['Nutzer'], departmentIds: [],
        }],
      },
    });
    assert.equal(assigned.response.status, 201);

    const switchedOrganization = await request(baseUrl, '/api/auth/context', {
      token: materialwartToken,
      method: 'POST',
      body: { organizationId: 'org-b', unitId: 'unit-b' },
    });
    assert.equal(switchedOrganization.response.status, 200);
    assert.deepEqual(switchedOrganization.data.user.roles, ['Nutzer']);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('unit administrators cannot read or overwrite access rights of sibling units', async () => {
  const { server, baseUrl } = await start();
  try {
    const rootAdminToken = await login(baseUrl, 'admin', 'MaterialKompass2026!');
    const users = await request(baseUrl, '/api/users?search=materialwart', {
      token: rootAdminToken,
    });
    const materialwart = users.data[0];
    const configured = await request(baseUrl, `/api/users/${materialwart.id}`, {
      token: rootAdminToken,
      method: 'PUT',
      body: {
        ...materialwart,
        defaultUnitId: 'unit-a-child',
        scopes: [
          {
            unitId: 'unit-a-child', includeDescendants: false,
            roles: ['Admin'], departmentIds: [],
          },
          {
            unitId: 'unit-a-sibling', includeDescendants: false,
            roles: ['Nutzer'], departmentIds: [],
          },
        ],
      },
    });
    assert.equal(configured.response.status, 200);

    const unitAdminToken = await login(baseUrl, 'materialwart', 'Material123!');
    const visibleUsers = await request(baseUrl, '/api/users', { token: unitAdminToken });
    assert.deepEqual(
      visibleUsers.data.map((entry) => entry.id),
      ['user-admin', materialwart.id],
    );
    assert.ok(visibleUsers.data.every((entry) =>
      entry.organizationAccess.scopes.every((scope) => scope.unitId === 'unit-a-child')));
    const visibleMaterialwart = visibleUsers.data.find((entry) =>
      entry.id === materialwart.id);
    assert.deepEqual(
      visibleMaterialwart.organizationAccess.scopes.map((scope) => scope.unitId),
      ['unit-a-child'],
    );

    const updated = await request(baseUrl, `/api/users/${materialwart.id}`, {
      token: unitAdminToken,
      method: 'PUT',
      body: {
        ...visibleMaterialwart,
        defaultUnitId: 'unit-a-child',
        scopes: [{
          unitId: 'unit-a-child', includeDescendants: false,
          roles: ['Admin'], departmentIds: [],
        }],
      },
    });
    assert.equal(updated.response.status, 200);

    const rootView = await request(baseUrl, '/api/users?search=materialwart', {
      token: rootAdminToken,
    });
    assert.deepEqual(
      rootView.data[0].organizationAccess.scopes.map((scope) => scope.unitId),
      ['unit-a-sibling', 'unit-a-child'],
    );
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
