const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');
const { seedData } = require('../src/data/seed');

test('locations referenced by stocktakes remain protected', async () => {
  const data = structuredClone(seedData);
  data.locations.push({ id: 'loc-history', name: 'Historisches Lager', code: 'HIST', type: 'Lager' });
  data.stockStructures.push({ id: 'stock-history', name: 'Altes Regal', section: 'A1', locationId: 'loc-history' });
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
