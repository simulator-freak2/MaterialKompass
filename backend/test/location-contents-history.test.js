const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');
const { seedData } = require('../src/data/seed');

async function fixture(status = 'Abgeschlossen') {
  const data = structuredClone(seedData);
  data.locations.push({ id: 'loc-historic', name: 'Altes Lager', code: 'ALT', type: 'Lager' });
  data.stockStructures.push({ id: 'pos-historic', name: 'Alter Platz', section: 'A', locationId: 'loc-historic' });
  data.materials.push({ ...data.materials[0], id: 'material-historic', inventoryNumber: 'HIST-123', locationId: 'loc-historic', stockStructureId: 'pos-historic', archived: true, inventoryNumberReleasedAt: null });
  data.deletedClothingItems ||= [];
  data.deletedClothingItems.push({ id: 'clothing-historic', name: 'Alte Jacke', inventoryNumber: 'HIST-456', locationId: 'loc-historic', stockStructureId: 'pos-historic' });
  data.stocktakes.push({ id: 'take-historic', status, scope: { locationIds: ['loc-historic'], stockStructureIds: ['pos-historic'] }, entries: [] });
  const app = createApp({ data });
  const server = await new Promise(resolve => { const instance = app.listen(0, '127.0.0.1', () => resolve(instance)); });
  const base = `http://127.0.0.1:${server.address().port}`;
  const login = await fetch(`${base}/api/auth/login`, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ email: 'admin@materialkompass.org', password: 'MaterialKompass2026!' }) });
  const token = (await login.json()).token;
  const request = (path, method = 'GET', body) => fetch(base + path, { method, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, ...(body ? { body: JSON.stringify(body) } : {}) });
  return { request, close: () => new Promise(resolve => server.close(resolve)) };
}

test('historical contents are opt-in and do not block deletion; restore needs a valid new location', async () => {
  const { request, close } = await fixture();
  try {
    let response = await request('/api/storage-contents/locations/loc-historic');
    assert.equal(response.status, 200);
    assert.deepEqual((await response.json()).items, []);
    response = await request('/api/storage-contents/locations/loc-historic?history=true');
    const contents = await response.json();
    assert.equal(contents.items.length, 2);
    assert.deepEqual(new Set(contents.items.map(item => item.type)), new Set(['Inventar', 'Kleidung']));
    for (const kind of ['shelves', 'levels', 'positions']) {
      const hierarchy = await (await request('/api/storage-hierarchy')).json();
      const entry = (kind === 'positions' ? hierarchy.stockStructures : kind === 'levels' ? hierarchy.storageLevels : hierarchy.shelves).find(item => item.locationId === 'loc-historic' || item.id === hierarchy.stockStructures.find(item => item.id === 'pos-historic')[kind === 'levels' ? 'levelId' : 'shelfId']);
      const result = await (await request(`/api/storage-contents/${kind}/${entry.id}?history=true`)).json();
      assert.equal(result.items.length, 2);
    }
    assert.equal((await request('/api/locations/loc-historic', 'DELETE')).status, 204);
    response = await request('/api/material/material-historic/restore', 'POST');
    assert.equal(response.status, 409);
    assert.equal((await response.json()).code, 'RESTORE_LOCATION_REQUIRED');
    response = await request('/api/material?archived=true');
    const archived = (await response.json()).find(item => item.id === 'material-historic');
    assert.equal(archived.locationName, 'Altes Lager');
    assert.match(archived.stockStructureName, /Altes Lager/);
    assert.equal((await request('/api/material/material-historic/restore', 'POST', { locationId: 'missing' })).status, 409);
    response = await request('/api/material/material-historic/restore', 'POST', { locationId: 'loc-3' });
    assert.equal(response.status, 200);
    const restored = await response.json();
    assert.equal(restored.locationId, 'loc-3');
    assert.equal(restored.stockStructureId, null);
    assert.equal(restored.archived, false);
  } finally { await close(); }
});

test('ongoing stocktakes continue to protect otherwise empty locations', async () => {
  const { request, close } = await fixture('In Arbeit');
  try { assert.equal((await request('/api/locations/loc-historic', 'DELETE')).status, 409); }
  finally { await close(); }
});

test('historical articles allow deletion at each storage level', async (t) => {
  for (const [collection, route, idField] of [['stockStructures', 'stock-structures', 'id'], ['storageLevels', 'storage-levels', 'levelId'], ['shelves', 'shelves', 'shelfId']]) {
    await t.test(route, async () => {
      const { request, close } = await fixture();
      try {
        const hierarchy = await (await request('/api/storage-hierarchy')).json();
        const position = hierarchy.stockStructures.find(item => item.id === 'pos-historic');
        assert.ok(hierarchy[collection].some(item => item.id === position[idField]));
        assert.equal((await request(`/api/${route}/${position[idField]}`, 'DELETE')).status, 204);
        assert.equal((await request('/api/material/material-historic/restore', 'POST')).status, 409);
        const restored = await request('/api/material/material-historic/restore', 'POST', { locationId: 'loc-historic' });
        assert.equal(restored.status, 200);
        assert.equal((await restored.json()).stockStructureId, null);
      } finally { await close(); }
    });
  }
});

test('current articles appear in contents and block deletion', async () => {
  const { request, close } = await fixture();
  try {
    assert.equal((await request('/api/material/material-historic/restore', 'POST')).status, 200);
    const contents = await (await request('/api/storage-contents/locations/loc-historic')).json();
    assert.equal(contents.items.length, 1);
    assert.equal(contents.items[0].historical, false);
    assert.equal((await request('/api/locations/loc-historic', 'DELETE')).status, 409);
    assert.equal((await request('/api/stock-structures/pos-historic', 'DELETE')).status, 409);
    assert.equal((await request('/api/storage-contents/unknown/loc-historic')).status, 400);
    assert.equal((await request('/api/storage-contents/locations/missing')).status, 404);
  } finally { await close(); }
});
