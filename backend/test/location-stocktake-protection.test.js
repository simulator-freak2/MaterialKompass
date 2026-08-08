const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');
const { seedData } = require('../src/data/seed');

test('locations referenced by stocktakes remain protected', async () => {
  const data = structuredClone(seedData);
  data.locations.push({ id: 'loc-history', name: 'Historisches Lager', street: 'Altweg', houseNumber: '1', postalCode: '12345', city: 'Musterstadt', code: 'HIST', type: 'Lager' });
  data.shelves.push({ id: 'shelf-history', name: 'Altes Regal', code: 'A', locationId: 'loc-history' });
  data.storageLevels.push({ id: 'level-history', name: 'Ebene 1', code: '01', shelfId: 'shelf-history' });
  data.storagePositions.push({ id: 'stock-history', name: 'Platz 1', code: '01', levelId: 'level-history' });
  data.stocktakes.push({
    id: 'stocktake-history',
    scope: { locationIds: ['loc-history'], stockStructureIds: ['stock-history'] },
    entries: [{
      expectedLocationId: 'loc-history',
      expectedStockStructureId: 'stock-history',
      actualLocationId: null,
      actualStockStructureId: null,
      attempts: [],
    }],
  });
  const app = createApp({ data });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;

  try {
    const login = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: 'admin@materialkompass.org', password: 'MaterialKompass2026!' }),
    });
    const token = (await login.json()).token;
    const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };

    let response = await fetch(`${baseUrl}/api/stock-structures/stock-history`, { method: 'DELETE', headers });
    assert.equal(response.status, 409);
    assert.match((await response.json()).error, /Inventuren/);

    response = await fetch(`${baseUrl}/api/locations/loc-history`, { method: 'DELETE', headers });
    assert.equal(response.status, 409);
    assert.match((await response.json()).error, /Inventuren/);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
