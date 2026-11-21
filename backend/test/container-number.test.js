const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');
const {
  createContainerNumbering, validateContainerNumberPrefix,
} = require('../src/container-number');

async function setup() {
  const app = createApp();
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  const login = await fetch(`${baseUrl}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: 'admin@materialkompass.org', password: 'MaterialKompass2026!' }),
  });
  const token = (await login.json()).token;
  const headers = { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` };
  const call = async (path, method = 'GET', body) => {
    const response = await fetch(`${baseUrl}${path}`, {
      method, headers, body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await response.text();
    let data = null;
    try { data = text ? JSON.parse(text) : null; } catch { data = text; }
    return { status: response.status, data };
  };
  return { app, server, call };
}

async function createMaterial(call, overrides = {}) {
  const created = await call('/api/material', 'POST', {
    name: 'Sanitätskiste', categoryCode: '02', subcategoryCode: '02-02',
    locationId: 'loc-1', status: 'Lagernd', itemType: 'individual', ...overrides,
  });
  assert.equal(created.status, 201, JSON.stringify(created.data));
  return created.data;
}

test('prefix templates inherit along the unit tree and fall back to EDV-K', () => {
  const units = [
    { id: 'root', organizationId: 'org', parentId: null, edvNumber: '100', name: 'Org' },
    { id: 'district', organizationId: 'org', parentId: 'root', edvNumber: '200', name: 'Bezirk' },
    { id: 'local', organizationId: 'org', parentId: 'district', edvNumber: '300', name: 'Ort' },
  ];
  const materials = [];
  const numbering = createContainerNumbering({ units, materials, clothingItems: [] });
  assert.equal(numbering.effectivePrefix('local').prefix, '300-K-');
  assert.equal(numbering.effectivePrefix('local').isDefault, true);

  units[0].containerNumberPrefix = 'KI-{EDV}-';
  assert.equal(numbering.effectivePrefix('local').prefix, 'KI-300-');
  assert.equal(numbering.effectivePrefix('local').sourceUnitId, 'root');
  assert.equal(numbering.effectivePrefix('local').inherited, true);

  units[1].containerNumberPrefix = 'BZ-';
  assert.equal(numbering.effectivePrefix('local').prefix, 'BZ-');
  assert.equal(numbering.effectivePrefix('root').prefix, 'KI-100-');

  materials.push(
    { id: 'm1', organizationId: 'org', unitId: 'local', isContainer: true, createdAt: '2026-01-01' },
    { id: 'm2', organizationId: 'org', unitId: 'local', isContainer: true, createdAt: '2026-01-02' },
    { id: 'm3', organizationId: 'org', unitId: 'local', inventoryNumber: 'BZ-0003' },
    { id: 'm4', organizationId: 'org', unitId: 'district', isContainer: true, containerNumber: 'BZ-0001' },
  );
  assert.equal(numbering.backfill(), 2);
  assert.equal(materials[0].containerNumber, 'BZ-0001');
  assert.equal(materials[1].containerNumber, 'BZ-0002');
  // BZ-0003 ist als Inventarnummer belegt und wird übersprungen.
  assert.equal(numbering.suggest({ organizationId: 'org', unitId: 'local' }), 'BZ-0004');
  assert.equal(numbering.validate('bz-0003', { organizationId: 'org', unitId: 'local' }).status, 409);
  assert.equal(numbering.validate('bz-0001', { organizationId: 'org', unitId: 'local' }).status, 409);
  assert.equal(numbering.validate('BZ-0002', { organizationId: 'org', unitId: 'local', excludeId: 'm2' }).value, 'BZ-0002');
  assert.equal(numbering.validate('BZ 1', { organizationId: 'org', unitId: 'local' }).status, 400);

  assert.equal(validateContainerNumberPrefix('').value, null);
  assert.equal(validateContainerNumberPrefix('{EDV}/K-').value, '{EDV}/K-');
  assert.ok(validateContainerNumberPrefix('K {x}').error);
  assert.ok(validateContainerNumberPrefix('X'.repeat(33)).error);
});

test('containers receive editable, unique container numbers', async () => {
  const { server, call } = await setup();
  try {
    const suggestion = await call('/api/containers/number-suggestion');
    assert.equal(suggestion.status, 200, JSON.stringify(suggestion.data));
    assert.match(suggestion.data.containerNumber, /-K-0001$/);
    assert.equal(suggestion.data.prefixIsDefault, true);

    const first = await createMaterial(call);
    const created = await call('/api/containers', 'POST', { materialId: first.id });
    assert.equal(created.status, 201, JSON.stringify(created.data));
    assert.equal(created.data.containerNumber, suggestion.data.containerNumber);

    const second = await createMaterial(call, { name: 'Wurfsackkiste' });
    const manual = await call('/api/containers', 'POST', { materialId: second.id, containerNumber: 'WS-01' });
    assert.equal(manual.status, 201);
    assert.equal(manual.data.containerNumber, 'WS-01');

    const third = await createMaterial(call, { name: 'Verbandmodul' });
    const duplicate = await call('/api/containers', 'POST', { materialId: third.id, containerNumber: 'ws-01' });
    assert.equal(duplicate.status, 409);
    const asInventory = await call('/api/containers', 'POST', {
      materialId: third.id, containerNumber: first.inventoryNumber,
    });
    assert.equal(asInventory.status, 409);
    const invalid = await call('/api/containers', 'POST', { materialId: third.id, containerNumber: 'K 1' });
    assert.equal(invalid.status, 400);

    const renamed = await call(`/api/containers/${second.id}`, 'PUT', { containerNumber: 'WS-02' });
    assert.equal(renamed.status, 200, JSON.stringify(renamed.data));
    assert.equal(renamed.data.containerNumber, 'WS-02');
    const conflicting = await call(`/api/containers/${second.id}`, 'PUT', {
      containerNumber: created.data.containerNumber,
    });
    assert.equal(conflicting.status, 409);
    const emptied = await call(`/api/containers/${second.id}`, 'PUT', { containerNumber: '' });
    assert.equal(emptied.status, 400);

    const lookup = await call('/api/containers/lookup?code=ws-02');
    assert.equal(lookup.status, 200);
    assert.equal(lookup.data.match, 'container');
    assert.equal(lookup.data.container.id, second.id);
    const search = await call('/api/containers?query=WS-02');
    assert.deepEqual(search.data.map((entry) => entry.id), [second.id]);

    const inventory = await call(`/api/material/${second.id}`);
    assert.equal(inventory.data.containerNumber, 'WS-02');
    const clash = await call('/api/material', 'POST', {
      name: 'Doppelt', categoryCode: '02', subcategoryCode: '02-02', locationId: 'loc-1',
      status: 'Lagernd', itemType: 'individual', inventoryNumber: 'WS-02',
    });
    assert.equal(clash.status, 409);

    const viaForm = await createMaterial(call, { name: 'Formularkiste', isContainer: true });
    assert.match(viaForm.containerNumber, /-K-0002$/);

    const print = await call(`/api/containers/${second.id}/pack-list/print`);
    assert.equal(print.status, 200);

    const dissolved = await call(`/api/containers/${second.id}`, 'DELETE');
    assert.equal(dissolved.status, 200);
    const reused = await call('/api/containers', 'POST', { materialId: third.id, containerNumber: 'WS-02' });
    assert.equal(reused.status, 201, JSON.stringify(reused.data));
  } finally {
    server.close();
  }
});

test('organization admins define the container number prefix per unit', async () => {
  const { server, call } = await setup();
  try {
    const units = await call('/api/organization-units');
    assert.equal(units.status, 200);
    const root = units.data.find((entry) => entry.parentId === null);
    assert.equal(root.effectiveContainerNumberPrefix, '{EDV}-K-');

    const invalid = await call(`/api/organization-units/${root.id}/container-number-prefix`, 'PUT', { prefix: 'K 1' });
    assert.equal(invalid.status, 400);
    const saved = await call(`/api/organization-units/${root.id}/container-number-prefix`, 'PUT', { prefix: 'SAN-' });
    assert.equal(saved.status, 200, JSON.stringify(saved.data));
    assert.equal(saved.data.containerNumberPrefix, 'SAN-');

    const suggestion = await call('/api/containers/number-suggestion');
    assert.equal(suggestion.data.containerNumber, 'SAN-0001');
    assert.equal(suggestion.data.prefixIsDefault, false);

    const reset = await call(`/api/organization-units/${root.id}/container-number-prefix`, 'PUT', { prefix: '' });
    assert.equal(reset.data.containerNumberPrefix, null);
    const fallback = await call('/api/containers/number-suggestion');
    assert.match(fallback.data.containerNumber, /-K-0001$/);
  } finally {
    server.close();
  }
});
