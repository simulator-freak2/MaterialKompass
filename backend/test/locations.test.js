const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');

async function fixture() {
  const app = createApp();
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  const login = await fetch(`${baseUrl}/api/auth/login`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: 'admin@materialkompass.org', password: 'MaterialKompass2026!' }),
  });
  const token = (await login.json()).token;
  return { server, baseUrl, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' } };
}

test('storage hierarchy manages buildings, shelves, levels and positions safely', async () => {
  const { server, baseUrl, headers } = await fixture();
  try {
    let response = await fetch(`${baseUrl}/api/locations`, {
      method: 'POST', headers, body: JSON.stringify({
        name: 'Außenlager', code: 'AL', street: 'Hafenstraße', houseNumber: '7',
        postalCode: '20457', city: 'Hamburg', country: 'Deutschland',
      }),
    });
    assert.equal(response.status, 201);
    const location = await response.json();
    assert.equal(location.city, 'Hamburg');

    response = await fetch(`${baseUrl}/api/shelves`, {
      method: 'POST', headers, body: JSON.stringify({
        name: 'Regal B', code: 'RB', locationId: location.id,
      }),
    });
    assert.equal(response.status, 201);
    const shelf = await response.json();

    response = await fetch(`${baseUrl}/api/storage-levels`, {
      method: 'POST', headers, body: JSON.stringify({
        name: 'Ebene 1', code: 'E1', shelfId: shelf.id,
      }),
    });
    assert.equal(response.status, 201);
    const level = await response.json();

    response = await fetch(`${baseUrl}/api/stock-structures`, {
      method: 'POST', headers, body: JSON.stringify({
        name: 'Lagerplatz 1', code: 'P01', levelId: level.id,
      }),
    });
    assert.equal(response.status, 201);
    const stock = await response.json();
    assert.equal(stock.path, 'Außenlager / Regal B / Ebene 1 / Lagerplatz 1');

    response = await fetch(`${baseUrl}/api/clothing`, {
      method: 'POST', headers, body: JSON.stringify({ name: 'Testjacke', categoryId: '04-01', size: 'M', locationId: location.id, stockStructureId: stock.id }),
    });
    assert.equal(response.status, 201);
    assert.equal((await response.json()).stockStructureId, stock.id);

    assert.equal((await fetch(`${baseUrl}/api/stock-structures/${stock.id}`, { method: 'DELETE', headers })).status, 409);
    assert.equal((await fetch(`${baseUrl}/api/locations/${location.id}`, { method: 'DELETE', headers })).status, 409);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('bulk creation is bounded and generates complete paths', async () => {
  const { server, baseUrl, headers } = await fixture();
  try {
    let response = await fetch(`${baseUrl}/api/storage-hierarchy/bulk`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        locationId: 'loc-3', shelfCount: 2, levelsPerShelf: 2,
        positionsPerLevel: 3, startNumber: 1,
        shelfPrefix: 'R', levelPrefix: 'E', positionPrefix: 'P',
      }),
    });
    assert.equal(response.status, 201);
    const created = await response.json();
    assert.equal(created.shelves.length, 2);
    assert.equal(created.storageLevels.length, 4);
    assert.equal(created.stockStructures.length, 12);
    assert.equal(
      created.stockStructures[0].path,
      'Nebenlager / Regal 1 / Ebene 1 / Lagerplatz 01',
    );

    response = await fetch(`${baseUrl}/api/storage-hierarchy/bulk`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        locationId: 'loc-3', shelfCount: 20, levelsPerShelf: 50,
        positionsPerLevel: 200, startNumber: 50,
      }),
    });
    assert.equal(response.status, 400);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('legacy storage places are migrated without changing their IDs', async () => {
  const { server, baseUrl, headers } = await fixture();
  try {
    const response = await fetch(`${baseUrl}/api/storage-hierarchy`, { headers });
    assert.equal(response.status, 200);
    const hierarchy = await response.json();
    const migrated = hierarchy.stockStructures.find((entry) => entry.id === 'stock-1');
    assert.ok(migrated.shelfId);
    assert.ok(migrated.levelId);
    assert.equal(migrated.path, 'Hauptlager / Regal A / Ebene 1 / Lagerplatz A1');
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('moving a shelf keeps position IDs and updates assigned inventory', async () => {
  const { server, baseUrl, headers } = await fixture();
  try {
    let response = await fetch(`${baseUrl}/api/storage-hierarchy`, { headers });
    const before = await response.json();
    const position = before.stockStructures.find((entry) => entry.id === 'stock-1');
    const shelf = before.shelves.find((entry) => entry.id === position.shelfId);

    response = await fetch(`${baseUrl}/api/shelves/${shelf.id}`, {
      method: 'PUT',
      headers,
      body: JSON.stringify({ locationId: 'loc-3' }),
    });
    assert.equal(response.status, 200);

    response = await fetch(`${baseUrl}/api/storage-hierarchy`, { headers });
    const after = await response.json();
    const movedPosition = after.stockStructures.find((entry) => entry.id === 'stock-1');
    assert.equal(movedPosition.locationId, 'loc-3');
    assert.match(movedPosition.path, /^Nebenlager \/ Regal A \/ Ebene 1 \/ /);

    response = await fetch(`${baseUrl}/api/material`, { headers });
    const material = (await response.json()).find((entry) => entry.id === 'material-1');
    assert.equal(material.locationId, 'loc-3');
    assert.equal(material.stockStructureId, 'stock-1');
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
