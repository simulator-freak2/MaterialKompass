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
    { id: 'org-a', name: 'Organisation A', shortName: 'A', status: 'active', branding: {} },
    { id: 'org-b', name: 'Organisation B', shortName: 'B', status: 'active', branding: {} },
  ];
  data.organizationUnits = [
    { id: 'unit-a', organizationId: 'org-a', parentId: null, name: 'A', type: 'Organisation', status: 'active' },
    { id: 'unit-a-child', organizationId: 'org-a', parentId: 'unit-a', name: 'A-Ortsgruppe', type: 'Ortsgruppe', status: 'active' },
    { id: 'unit-a-sibling', organizationId: 'org-a', parentId: 'unit-a', name: 'A-Kreis', type: 'Kreis', status: 'active' },
    { id: 'unit-b', organizationId: 'org-b', parentId: null, name: 'B', type: 'Organisation', status: 'active' },
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
  data.materials.push({
    ...structuredClone(data.materials[0]),
    id: 'material-a-child',
    inventoryNumber: 'A-CHILD-001',
    name: 'Nur A-Ortsgruppe',
    organizationId: 'org-a',
    unitId: 'unit-a-child',
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
    assert.ok(!listA.data.some((entry) => entry.id === 'material-b'));
    assert.equal((await request(baseUrl, '/api/material/material-b', { token: tokenA })).response.status, 404);

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
      body: { name: 'Organisation C', shortName: 'C' },
    });
    assert.equal(organization.response.status, 201);

    const unit = await request(authorized.baseUrl, '/api/organization-units', {
      token,
      method: 'POST',
      body: { name: 'A-Unterorganisation', type: 'Ortsgruppe', parentId: 'unit-a' },
    });
    assert.equal(unit.response.status, 201);
    assert.equal(unit.data.parentId, 'unit-a');
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
