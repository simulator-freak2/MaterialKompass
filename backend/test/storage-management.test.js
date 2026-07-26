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
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      email: 'admin@materialkompass.org',
      password: 'MaterialKompass2026!',
    }),
  });
  const token = (await login.json()).token;
  const headers = {
    Authorization: `Bearer ${token}`,
    'Content-Type': 'application/json',
  };
  async function request(path, method = 'GET', body = undefined) {
    const response = await fetch(`${baseUrl}${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const data = response.status === 204 ? null : await response.json();
    return { response, data };
  }
  return { server, request };
}

test('storage hierarchy generates canonical place and box numbers', async () => {
  const { server, request } = await fixture();
  try {
    const location = await request('/api/storage/locations', 'POST', {
      name: 'Basis', code: 'B', type: 'Lager', street: 'Rheinweg',
      houseNumber: '1', postalCode: '55218', city: 'Ingelheim',
      country: 'Deutschland', contactName: 'Lagerteam', contactPhone: '06132 1',
    });
    assert.equal(location.response.status, 201);

    const bulk = await request('/api/storage/bulk-create', 'POST', {
      locationId: location.data.id, rackStart: 8, rackCount: 1,
      levelsPerRack: 5, placesPerLevel: 4,
    });
    assert.equal(bulk.response.status, 201);
    assert.deepEqual(bulk.data, { racks: 1, levels: 5, places: 20 });

    const hierarchy = await request('/api/storage/hierarchy');
    const createdLocation = hierarchy.data.find((entry) => entry.id === location.data.id);
    const place = createdLocation.racks[0].levels[4].places[3];
    assert.equal(place.code, 'B-R008-E05-P04');

    const firstBox = await request('/api/storage/boxes', 'POST', {
      name: 'Helmkiste', type: 'Transportkiste', storagePlaceId: place.id,
      dimensions: { length: 60, width: 40, height: 35 }, maxLoadKg: 25,
    });
    const secondBox = await request('/api/storage/boxes', 'POST', {
      name: 'Seilkiste', storagePlaceId: place.id,
    });
    assert.equal(firstBox.data.inventoryNumber, 'B-K00001');
    assert.equal(secondBox.data.inventoryNumber, 'B-K00002');
    assert.equal(firstBox.data.dimensionsCm.length, 60);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('boxes carry mixed article assignments and stocktakes reconcile quantities', async () => {
  const { server, request } = await fixture();
  try {
    const location = (await request('/api/storage/locations', 'POST', {
      name: 'Südlager', code: 'S', type: 'Lager', street: 'Testweg',
      houseNumber: '2', postalCode: '55218', city: 'Ingelheim', country: 'Deutschland',
    })).data;
    await request('/api/storage/bulk-create', 'POST', {
      locationId: location.id, rackStart: 10, rackCount: 1,
      levelsPerRack: 5, placesPerLevel: 1,
    });
    const hierarchy = (await request('/api/storage/hierarchy')).data;
    const place = hierarchy.find((entry) => entry.id === location.id)
      .racks[0].levels[4].places[0];
    assert.equal(place.code, 'S-R010-E05-P01');
    const box = (await request('/api/storage/boxes', 'POST', {
      name: 'Gemischte Kiste', storagePlaceId: place.id,
    })).data;
    const material = (await request('/api/material', 'POST', {
      name: 'Leinen', categoryCode: '02', subcategoryCode: '02-02',
      status: 'Lagernd', itemType: 'bulk', quantity: 12, unit: 'Stück',
    })).data;
    const clothing = (await request('/api/clothing', 'POST', {
      name: 'Testjacke', categoryId: '04-01', size: 'M',
    })).data;
    assert.equal((await request('/api/storage/assignments', 'POST', {
      entityType: 'material', entityId: material.id, boxId: box.id, quantity: 10,
    })).response.status, 201);
    assert.equal((await request('/api/storage/assignments', 'POST', {
      entityType: 'clothing', entityId: clothing.id, boxId: box.id,
    })).response.status, 201);

    const stocktake = (await request('/api/stocktakes', 'POST', {
      name: 'Kisteninventur', scopeType: 'box', scopeId: box.id,
    })).data;
    const running = (await request(`/api/stocktakes/${stocktake.id}/start`, 'POST')).data;
    assert.equal(running.status, 'Laufend');
    assert.equal(running.entries.length, 2);

    for (const entry of running.entries) {
      await request(`/api/stocktakes/${stocktake.id}/counts`, 'POST', {
        entryId: entry.id,
        ...(entry.itemType === 'bulk' ? { quantity: 8 } : { present: true }),
      });
    }
    const completed = await request(`/api/stocktakes/${stocktake.id}/complete`, 'POST');
    assert.equal(completed.response.status, 200);
    assert.equal(completed.data.status, 'Abgeschlossen');
    const updatedMaterial = await request(`/api/material/${material.id}`);
    assert.equal(updatedMaterial.data.quantity, 8);

    for (const format of ['xlsx', 'ods', 'csv', 'pdf']) {
      const exported = await request(`/api/stocktakes/${stocktake.id}/export?format=${format}`);
      assert.equal(exported.response.status, 200);
      assert.ok(exported.data.fileBase64.length > 20);
    }
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('clothing can be assigned on creation and relocated in bulk', async () => {
  const { server, request } = await fixture();
  try {
    const location = (await request('/api/storage/locations', 'POST', {
      name: 'Kleiderlager', code: 'KL', type: 'Kleidung', street: 'Testweg',
      houseNumber: '3', postalCode: '55218', city: 'Ingelheim', country: 'Deutschland',
    })).data;
    await request('/api/storage/bulk-create', 'POST', {
      locationId: location.id, rackStart: 1, rackCount: 1,
      levelsPerRack: 1, placesPerLevel: 2,
    });
    const hierarchy = (await request('/api/storage/hierarchy')).data;
    const places = hierarchy.find((entry) => entry.id === location.id)
      .racks[0].levels[0].places;
    const box = (await request('/api/storage/boxes', 'POST', {
      name: 'Einsatzkleidung', storagePlaceId: places[1].id,
    })).data;

    const created = await request('/api/clothing', 'POST', {
      name: 'Überjacke', categoryId: '04-01', size: 'M',
      storagePlaceId: places[0].id,
    });
    assert.equal(created.response.status, 201);
    assert.equal(created.data.storageAssignments.length, 1);
    assert.equal(created.data.storageAssignments[0].storagePlaceId, places[0].id);

    const relocated = await request('/api/clothing/relocate/bulk', 'POST', {
      clothingIds: [created.data.id],
      storagePlaceId: places[1].id,
      boxId: box.id,
    });
    assert.equal(relocated.response.status, 201);
    assert.equal(relocated.data.length, 1);
    assert.equal(relocated.data[0].storagePlaceId, places[1].id);
    assert.equal(relocated.data[0].boxId, box.id);

    const clothing = (await request('/api/clothing')).data
      .find((entry) => entry.id === created.data.id);
    assert.equal(clothing.storageAssignments.length, 1);
    assert.equal(clothing.storageAssignments[0].boxId, box.id);

    assert.equal((await request('/api/transactions', 'POST', {
      clothingIds: [created.data.id], personName: 'Max Mustermann', action: 'ausgegeben',
    })).response.status, 201);
    const issuedRelocation = await request('/api/clothing/relocate/bulk', 'POST', {
      clothingIds: [created.data.id],
      storagePlaceId: places[0].id,
    });
    assert.equal(issuedRelocation.response.status, 409);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
