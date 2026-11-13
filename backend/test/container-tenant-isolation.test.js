const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');
const { seedData } = require('../src/data/seed');

// Material-IDs werden pro Gliederung vergeben und wiederholen sich deshalb.
// Gepackte Mengen, Kistensperren und Kisten-Lookups dürfen nie das
// gleichnamige Material einer anderen Gliederung treffen.

async function request(baseUrl, path, { token, method = 'GET', body } = {}) {
  const response = await fetch(`${baseUrl}${path}`, {
    method,
    headers: {
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body ? { 'Content-Type': 'application/json' } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  return { status: response.status, data: text ? JSON.parse(text) : null };
}

function tenantData() {
  const data = structuredClone(seedData);
  data.organizations = [
    { id: 'org-a', name: 'Organisation A', shortName: 'A', edvNumber: '10000001', status: 'active', branding: {} },
    { id: 'org-b', name: 'Organisation B', shortName: 'B', edvNumber: '10000002', status: 'active', branding: {} },
  ];
  data.organizationUnits = [
    { id: 'unit-a', organizationId: 'org-a', parentId: null, name: 'A', type: 'Organisation', edvNumber: '10000001', status: 'active' },
    { id: 'unit-b', organizationId: 'org-b', parentId: null, name: 'B', type: 'Organisation', edvNumber: '10000002', status: 'active' },
  ];
  data.memberships = ['a', 'b'].map((suffix) => ({
    id: `membership-admin-${suffix}`, userId: 'user-admin', organizationId: `org-${suffix}`,
    status: 'active', defaultUnitId: `unit-${suffix}`,
    scopes: [{ unitId: `unit-${suffix}`, includeDescendants: true, roles: ['Admin'], departmentIds: [] }],
  }));
  for (const [name, values] of Object.entries(data)) {
    if (!Array.isArray(values) || ['users', 'roles', 'permissions', 'organizations', 'organizationUnits', 'memberships'].includes(name)) continue;
    values.forEach((entry) => {
      if (!entry || typeof entry !== 'object') return;
      entry.organizationId = 'org-a';
      entry.unitId = 'unit-a';
    });
  }
  data.locations.push({
    ...structuredClone(data.locations[0]), id: 'loc-b', code: 'B', name: 'Lager B',
    organizationId: 'org-b', unitId: 'unit-b',
  });

  const template = {
    ...structuredClone(data.materials[0]),
    issuedQuantity: 0, archived: false, stockStructureId: null, status: 'Lagernd',
    safetyCritical: false, nextInspectionDate: null, nextMaintenanceDate: null,
    isContainer: false,
  };
  const material = (owner, id, values) => ({
    ...structuredClone(template), id, ...values,
    organizationId: `org-${owner}`, unitId: `unit-${owner}`,
    locationId: owner === 'a' ? 'loc-1' : 'loc-b',
  });
  // Die Datensätze der Gliederung B stehen in der Rohreihenfolge vorne, damit
  // ein reiner ID-Abgleich garantiert den falschen Datensatz finden würde.
  data.materials.unshift(
    material('b', 'material-box', { inventoryNumber: 'B-BOX', name: 'Kiste B', itemType: 'individual', quantity: 1 }),
    material('b', 'material-bulk', { inventoryNumber: 'B-BULK', name: 'Decken B', itemType: 'bulk', quantity: 10 }),
    material('b', 'material-single', { inventoryNumber: 'B-SINGLE', name: 'Gerät B', itemType: 'individual', quantity: 1 }),
  );
  data.materials.push(
    material('a', 'material-box', { inventoryNumber: 'A-BOX', name: 'Kein Behälter A', itemType: 'individual', quantity: 1 }),
    material('a', 'material-bulk', { inventoryNumber: 'A-BULK', name: 'Decken A', itemType: 'bulk', quantity: 10 }),
    material('a', 'material-single', { inventoryNumber: 'A-SINGLE', name: 'Gerät A', itemType: 'individual', quantity: 1 }),
  );
  return data;
}

async function start(data) {
  const app = createApp({ data, skipEmailVerification: true });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  return { app, server, baseUrl: `http://127.0.0.1:${server.address().port}` };
}

test('packing material in one unit leaves same-ID material of another unit untouched', async () => {
  const { server, baseUrl } = await start(tenantData());
  try {
    const loginResult = await request(baseUrl, '/api/auth/login', {
      method: 'POST', body: { identifier: 'admin', password: 'MaterialKompass2026!' },
    });
    assert.equal(loginResult.status, 200);
    const tokenA = loginResult.data.token;
    const switched = await request(baseUrl, '/api/auth/context', {
      token: tokenA, method: 'POST', body: { organizationId: 'org-b', unitId: 'unit-b' },
    });
    assert.equal(switched.status, 200);
    const tokenB = switched.data.token;

    // Gliederung B packt ihr Material in ihre Kiste.
    const box = await request(baseUrl, '/api/containers', {
      token: tokenB, method: 'POST', body: { materialId: 'material-box' },
    });
    assert.equal(box.status, 201, JSON.stringify(box.data));
    assert.equal(box.data.inventoryNumber, 'B-BOX');
    for (const body of [
      { entityType: 'MaterialItem', entityId: 'material-bulk', quantity: 4 },
      { entityType: 'MaterialItem', entityId: 'material-single' },
    ]) {
      const packed = await request(baseUrl, '/api/containers/material-box/contents', {
        token: tokenB, method: 'POST', body,
      });
      assert.equal(packed.status, 201, JSON.stringify(packed.data));
    }
    const bulkB = (await request(baseUrl, '/api/material/material-bulk', { token: tokenB })).data;
    assert.equal(bulkB.inventoryNumber, 'B-BULK');
    assert.equal(bulkB.containerPackedQuantity, 4);
    assert.equal(bulkB.availableQuantity, 6);
    const singleB = (await request(baseUrl, '/api/material/material-single', { token: tokenB })).data;
    assert.equal(singleB.containerId, 'material-box');
    assert.equal(singleB.containerName, 'B-BOX Kiste B');
    const detailB = (await request(baseUrl, '/api/containers/material-box', { token: tokenB })).data;
    assert.equal(detailB.contentCount, 2);
    assert.deepEqual(detailB.contents.map((entry) => entry.inventoryNumber).sort(), ['B-BULK', 'B-SINGLE']);

    // Gliederung A sieht ihr gleichnamiges Material vollständig verfügbar.
    const bulkA = (await request(baseUrl, '/api/material/material-bulk', { token: tokenA })).data;
    assert.equal(bulkA.inventoryNumber, 'A-BULK');
    assert.equal(bulkA.containerPackedQuantity, 0);
    assert.equal(bulkA.availableQuantity, 10);
    const singleA = (await request(baseUrl, '/api/material/material-single', { token: tokenA })).data;
    assert.equal(singleA.inventoryNumber, 'A-SINGLE');
    assert.equal(singleA.containerId, null);
    assert.equal(singleA.containerName, null);
    const boxA = (await request(baseUrl, '/api/material/material-box', { token: tokenA })).data;
    assert.equal(boxA.isContainer, false);
    assert.equal((await request(baseUrl, '/api/containers/material-box', { token: tokenA })).status, 404);

    // ... und kann es ungesperrt umbuchen und auf ein Fahrzeug laden.
    const relocated = await request(baseUrl, '/api/material/relocate/bulk', {
      token: tokenA, method: 'POST', body: { materialIds: ['material-single'], locationId: 'loc-2' },
    });
    assert.equal(relocated.status, 201, JSON.stringify(relocated.data));
    const vehicle = await request(baseUrl, '/api/vehicles', {
      token: tokenA, method: 'POST', body: {
        registrationNumber: 'A MK 7', vin: 'CONTAINER-TENANT-1', radioCallName: 'Kiste 1',
        vehicleKind: 'Kraftfahrzeug', usage: 'Einsatzfahrt', type: 'Einsatzfahrzeug',
        status: 'Verfügbar', primaryResponseVehicle: false,
      },
    });
    assert.equal(vehicle.status, 201, JSON.stringify(vehicle.data));
    const candidates = await request(baseUrl, `/api/vehicles/${vehicle.data.id}/load-materials`, { token: tokenA });
    assert.equal(candidates.status, 200);
    assert.equal(candidates.data.find((entry) => entry.id === 'material-bulk').availableQuantity, 10);
    assert.equal(candidates.data.find((entry) => entry.id === 'material-single').availableQuantity, 1);
    const loadSingle = await request(baseUrl, `/api/vehicles/${vehicle.data.id}/load`, {
      token: tokenA, method: 'POST', body: { materialId: 'material-single', quantity: 1 },
    });
    assert.equal(loadSingle.status, 201, JSON.stringify(loadSingle.data));
    assert.equal(loadSingle.data.inventoryNumber, 'A-SINGLE');
    const loadBulk = await request(baseUrl, `/api/vehicles/${vehicle.data.id}/load`, {
      token: tokenA, method: 'POST', body: { materialId: 'material-bulk', quantity: 10 },
    });
    assert.equal(loadBulk.status, 201, JSON.stringify(loadBulk.data));

    // Die Fahrzeugbuchung von A schmälert umgekehrt nicht den Bestand von B.
    const bulkBAfter = (await request(baseUrl, '/api/material/material-bulk', { token: tokenB })).data;
    assert.equal(bulkBAfter.vehicleLoadedQuantity, 0);
    assert.equal(bulkBAfter.availableQuantity, 6);
    const moreB = await request(baseUrl, '/api/containers/material-box/contents', {
      token: tokenB, method: 'POST', body: { entityType: 'MaterialItem', entityId: 'material-bulk', quantity: 6 },
    });
    assert.equal(moreB.status, 201, JSON.stringify(moreB.data));
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
