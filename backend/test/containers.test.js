const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');
const { seedData } = require('../src/data/seed');

async function setup(options = {}) {
  const app = createApp(options);
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
    return { status: response.status, data: text ? JSON.parse(text) : null };
  };
  return { app, server, call };
}

async function createMaterial(call, overrides = {}) {
  const created = await call('/api/material', 'POST', {
    name: 'Pulsoximeter', categoryCode: '02', subcategoryCode: '02-02',
    locationId: 'loc-1', status: 'Lagernd', itemType: 'individual', ...overrides,
  });
  assert.equal(created.status, 201, JSON.stringify(created.data));
  return created.data;
}

async function createContainer(call, overrides = {}) {
  const container = await call('/api/containers', 'POST', {
    name: 'Sanitätskiste', containerType: 'Sanitätskiste', stockStructureId: 'stock-1',
    compartments: ['Deckel', 'Boden'], ...overrides,
  });
  assert.equal(container.status, 201, JSON.stringify(container.data));
  return container.data;
}

test('containers are independent storage places assigned to a storage position', async () => {
  const { server, call } = await setup();
  try {
    const missingStock = await call('/api/containers', 'POST', { name: 'Ohne Platz' });
    assert.equal(missingStock.status, 400);
    const container = await createContainer(call);
    assert.equal(container.code, 'K-001');
    assert.equal(container.locationId, 'loc-1');
    assert.equal(container.stockStructureId, 'stock-1');
    assert.equal(container.completenessStatus, 'Ungeprüft');
    assert.deepEqual(container.items, []);
    assert.deepEqual(container.contents, []);
    const second = await createContainer(call, { name: 'Wurfsackkiste' });
    assert.equal(second.code, 'K-002');
    const duplicate = await call('/api/containers', 'POST', {
      name: 'Doppelt', code: 'k-001', stockStructureId: 'stock-1',
    });
    assert.equal(duplicate.status, 409);

    // Kisten sind kein Inventar mehr.
    const inventory = (await call('/api/material')).data;
    assert.equal(inventory.some((entry) => entry.id === container.id), false);

    const listed = (await call('/api/containers?stockStructureId=stock-1')).data;
    assert.deepEqual(listed.map((entry) => entry.code), ['K-001', 'K-002']);

    // Belegte Lagerplätze können nicht gelöscht werden.
    const deleteStock = await call('/api/stock-structures/stock-1', 'DELETE');
    assert.equal(deleteStock.status, 409);

    const targets = (await call('/api/containers/storage-targets')).data;
    assert.ok(targets.stockStructures.some((entry) => entry.id === 'stock-1' && entry.locationId === 'loc-1'));
    assert.ok(targets.locations.some((entry) => entry.id === 'loc-1'));
    assert.deepEqual(targets.containers.map((entry) => entry.code), ['K-001', 'K-002']);

    const contents = (await call('/api/storage-contents/positions/stock-1')).data;
    assert.ok(contents.items.some((entry) => entry.type === 'Kiste' && entry.inventoryNumber === 'K-001'));
  } finally {
    server.close();
  }
});

test('items with inventory numbers are booked into and out of containers', async () => {
  const { server, call } = await setup();
  try {
    const container = await createContainer(call);
    const other = await createContainer(call, { name: 'Modul', stockStructureId: 'stock-2' });
    const item = await createMaterial(call, { locationId: 'loc-3' });
    const bulk = await createMaterial(call, { name: 'Kabelbinder', itemType: 'bulk', quantity: 50 });

    const packed = await call(`/api/containers/${container.id}/items`, 'POST', {
      entityType: 'MaterialItem', entityId: item.id,
    });
    assert.equal(packed.status, 201, JSON.stringify(packed.data));
    const packedBulk = await call(`/api/containers/${container.id}/items`, 'POST', {
      entityType: 'MaterialItem', entityId: bulk.id,
    });
    assert.equal(packedBulk.status, 201);
    const clothing = await call(`/api/containers/${container.id}/items`, 'POST', {
      entityType: 'ClothingItem', entityId: 'clothing-1',
    });
    assert.equal(clothing.status, 201);
    const twice = await call(`/api/containers/${container.id}/items`, 'POST', {
      entityType: 'MaterialItem', entityId: item.id,
    });
    assert.equal(twice.status, 409);

    const material = (await call(`/api/material/${item.id}`)).data;
    assert.equal(material.containerId, container.id);
    assert.equal(material.locationId, 'loc-1');
    assert.equal(material.stockStructureId, 'stock-1');
    assert.match(material.containerName, /K-001/);
    assert.ok(material.movements.some((entry) => entry.action === 'container-pack'
      && entry.toContainerId === container.id));
    assert.equal((await call('/api/clothing')).data.find((entry) => entry.id === 'clothing-1').containerId, container.id);

    const detail = (await call(`/api/containers/${container.id}`)).data;
    assert.equal(detail.itemCount, 3);
    assert.ok(detail.items.every((entry) => entry.relocatable === true));
    assert.equal(detail.items.find((entry) => entry.entityId === bulk.id).quantity, 50);

    const lookup = (await call(`/api/containers/lookup?code=${encodeURIComponent(item.inventoryNumber)}`)).data;
    assert.equal(lookup.match, 'content');
    assert.equal(lookup.container.id, container.id);
    assert.equal((await call('/api/containers/lookup?code=K-001')).data.match, 'container');

    // Moving the container to another storage position takes its items along.
    const moved = await call(`/api/containers/${container.id}`, 'PUT', { stockStructureId: 'stock-2' });
    assert.equal(moved.status, 200, JSON.stringify(moved.data));
    const followed = (await call(`/api/material/${item.id}`)).data;
    assert.equal(followed.locationId, 'loc-2');
    assert.equal(followed.stockStructureId, 'stock-2');
    assert.equal(followed.containerId, container.id);
    assert.ok(followed.movements.some((entry) => entry.action === 'container-follow'));

    // Items with an inventory number can be relocated to another container ...
    const toOther = await call(`/api/containers/${container.id}/items/MaterialItem/${item.id}/relocate`, 'POST', {
      containerId: other.id,
    });
    assert.equal(toOther.status, 200, JSON.stringify(toOther.data));
    assert.equal((await call(`/api/material/${item.id}`)).data.containerId, other.id);
    // ... or out of it with the regular bulk relocation.
    const relocate = await call('/api/material/relocate/bulk', 'POST', {
      materialIds: [item.id, bulk.id], locationId: 'loc-3',
    });
    assert.equal(relocate.status, 201, JSON.stringify(relocate.data));
    const freed = (await call(`/api/material/${item.id}`)).data;
    assert.equal(freed.containerId, null);
    assert.equal(freed.locationId, 'loc-3');
    assert.equal((await call(`/api/containers/${container.id}`)).data.itemCount, 1);

    // Bulk relocation and the inventory form accept a container as target.
    const intoContainer = await call('/api/material/relocate/bulk', 'POST', {
      materialIds: [item.id], containerId: container.id,
    });
    assert.equal(intoContainer.status, 201);
    assert.equal((await call(`/api/material/${item.id}`)).data.containerId, container.id);
    const viaForm = await call(`/api/material/${bulk.id}`, 'PUT', { containerId: other.id });
    assert.equal(viaForm.status, 200, JSON.stringify(viaForm.data));
    assert.equal(viaForm.data.containerId, other.id);
    assert.equal(viaForm.data.stockStructureId, 'stock-2');
    const editOut = await call(`/api/material/${bulk.id}`, 'PUT', { locationId: 'loc-1', stockStructureId: '' });
    assert.equal(editOut.data.containerId, null);

    // Items in a container can be issued like items at any other storage place.
    const issue = await call('/api/material/transactions/bulk', 'POST', {
      action: 'issue', recipient: 'Einsatz', items: [{ materialId: item.id, quantity: 1 }],
    });
    assert.equal(issue.status, 201, JSON.stringify(issue.data));
    const relocateIssued = await call(`/api/containers/${container.id}/items/MaterialItem/${item.id}/relocate`, 'POST', {
      locationId: 'loc-3',
    });
    assert.equal(relocateIssued.status, 409);

    const dissolveFull = await call(`/api/containers/${container.id}`, 'DELETE');
    assert.equal(dissolveFull.status, 409);
    const dissolveOther = await call(`/api/containers/${other.id}`, 'DELETE');
    assert.equal(dissolveOther.status, 200);
  } finally {
    server.close();
  }
});

test('contents without inventory number belong to the container and cannot be relocated', async () => {
  const { server, call } = await setup();
  try {
    const container = await createContainer(call);
    const badSlot = await call(`/api/containers/${container.id}/contents`, 'POST', {
      name: 'Pflaster', quantity: 2, position: 'Seitenfach',
    });
    assert.equal(badSlot.status, 400);
    const withInventory = await call(`/api/containers/${container.id}/contents`, 'POST', {
      entityId: 'material-1',
    });
    assert.equal(withInventory.status, 400);
    const created = await call(`/api/containers/${container.id}/contents`, 'POST', {
      name: 'Pflasterstrips', quantity: 20, unit: 'Stück', position: 'Deckel',
      expiresAt: '2030-12-31', batchNumber: 'L-42',
    });
    assert.equal(created.status, 201, JSON.stringify(created.data));
    assert.equal(created.data.relocatable, false);
    assert.equal(created.data.inventoryNumber, null);

    for (const suffix of ['unpack', 'relocate']) {
      const blocked = await call(`/api/containers/${container.id}/contents/${created.data.id}/${suffix}`, 'POST', {
        locationId: 'loc-3',
      });
      assert.equal(blocked.status, 409);
      assert.match(blocked.data.error, /nicht auf andere Lagerorte umgebucht/);
    }
    const otherContainer = await createContainer(call, { name: 'Andere' });
    const moveByEdit = await call(`/api/containers/${container.id}/contents/${created.data.id}`, 'PUT', {
      containerId: otherContainer.id,
    });
    assert.equal(moveByEdit.status, 409);
    const asItem = await call(`/api/containers/${container.id}/items/Content/${created.data.id}/relocate`, 'POST', {
      locationId: 'loc-3',
    });
    assert.equal(asItem.status, 409);

    const updated = await call(`/api/containers/${container.id}/contents/${created.data.id}`, 'PUT', {
      quantity: 15, notes: 'Teilweise verbraucht',
    });
    assert.equal(updated.status, 200);
    assert.equal(updated.data.quantity, 15);
    assert.equal(updated.data.position, 'Deckel');

    const removeCompartment = await call(`/api/containers/${container.id}`, 'PUT', { compartments: ['Boden'] });
    assert.equal(removeCompartment.status, 409);
    const notEmpty = await call(`/api/containers/${container.id}`, 'DELETE');
    assert.equal(notEmpty.status, 409);

    // Contents move with the container because they are part of it.
    await call(`/api/containers/${container.id}`, 'PUT', { stockStructureId: 'stock-2' });
    assert.equal((await call(`/api/containers/${container.id}`)).data.contents[0].quantity, 15);

    const removed = await call(`/api/containers/${container.id}/contents/${created.data.id}`, 'DELETE', {
      reason: 'Verbraucht',
    });
    assert.equal(removed.status, 200);
    assert.equal((await call(`/api/containers/${container.id}`)).data.contentCount, 0);
    assert.equal((await call(`/api/containers/${container.id}`, 'DELETE')).status, 200);
  } finally {
    server.close();
  }
});

test('pack lists, completeness checks, defects and print output', async () => {
  const { server, call } = await setup();
  try {
    const container = await createContainer(call);
    const item = await createMaterial(call, { name: 'Beatmungsbeutel' });
    await call(`/api/containers/${container.id}/items`, 'POST', { entityType: 'MaterialItem', entityId: item.id });
    await call(`/api/containers/${container.id}/contents`, 'POST', { name: 'Kompresse', quantity: 5 });

    const invalidList = await call(`/api/containers/${container.id}/pack-lists`, 'POST', {
      name: 'Ungültig', items: [{ entityType: 'MaterialItem', entityId: item.id, targetQuantity: 2 }],
    });
    assert.equal(invalidList.status, 400);
    const list = await call(`/api/containers/${container.id}/pack-lists`, 'POST', {
      name: 'Sanitätskiste DIN', items: [
        { entityType: 'MaterialItem', entityId: item.id, targetQuantity: 1, position: 'Deckel' },
        { entityType: 'Content', name: 'Kompresse', targetQuantity: 10, position: 'Boden' },
        { name: 'Rettungsdecke', targetQuantity: 2 },
      ],
    });
    assert.equal(list.status, 201, JSON.stringify(list.data));
    assert.equal(list.data.status, 'Aktiv');
    const draft = await call(`/api/containers/${container.id}/pack-lists`, 'POST', {
      name: 'Entwurf', fromContents: true, activate: false,
    });
    assert.equal(draft.status, 201);
    assert.equal(draft.data.items.length, 2);

    const detail = (await call(`/api/containers/${container.id}`)).data;
    assert.equal(detail.packListDeviation.missingCount, 2);
    assert.equal(detail.checkTemplate.items.length, 3);
    const keys = detail.checkTemplate.items.map((entry) => entry.key);
    assert.ok(keys.includes('Content:kompresse'));

    const missingResult = await call(`/api/containers/${container.id}/checks`, 'POST', {
      results: [{ key: keys[0], result: 'vorhanden' }],
    });
    assert.equal(missingResult.status, 400);
    const incomplete = await call(`/api/containers/${container.id}/checks`, 'POST', {
      results: [
        { key: `MaterialItem:${item.id}`, result: 'beschädigt', notes: 'Ventil undicht' },
        { key: 'Content:kompresse', result: 'vorhanden', actualQuantity: 5 },
        { key: 'Content:rettungsdecke', result: 'fehlt' },
      ],
      createDefect: { priority: 'Normal' },
    });
    assert.equal(incomplete.status, 201, JSON.stringify(incomplete.data));
    assert.equal(incomplete.data.complete, false);
    assert.equal(incomplete.data.deviationCount, 3);
    assert.equal(incomplete.data.defectIds.length, 1);
    assert.equal(incomplete.data.container.completenessStatus, 'Unvollständig');
    assert.ok((await call(`/api/material/${item.id}`)).data.defects.length >= 1);

    const activated = await call(`/api/containers/${container.id}/pack-lists/${draft.data.id}/activate`, 'POST', {});
    assert.equal(activated.status, 200);
    const complete = await call(`/api/containers/${container.id}/checks`, 'POST', {
      results: [
        { key: `MaterialItem:${item.id}`, result: 'vorhanden' },
        { key: 'Content:kompresse', result: 'vorhanden' },
      ],
    });
    assert.equal(complete.status, 201);
    assert.equal(complete.data.container.completenessStatus, 'Vollständig');

    const print = await call(`/api/containers/${container.id}/pack-list/print`);
    assert.equal(print.status, 200);
    assert.equal(print.data.mimeType, 'application/pdf');
    assert.ok(Buffer.from(print.data.fileBase64, 'base64').subarray(0, 4).toString() === '%PDF');
  } finally {
    server.close();
  }
});

test('expiry dates of contents are validated and reported', async () => {
  const { server, call } = await setup();
  try {
    const container = await createContainer(call, { expiryWarningDays: 30 });
    const invalid = await call(`/api/containers/${container.id}/contents`, 'POST', {
      name: 'Pflaster', expiresAt: '2026-02-31',
    });
    assert.equal(invalid.status, 400);
    await call(`/api/containers/${container.id}/contents`, 'POST', { name: 'Pflaster', expiresAt: '2020-01-01' });
    const soon = new Date(Date.now() + 5 * 86400000).toISOString().slice(0, 10);
    await call(`/api/containers/${container.id}/contents`, 'POST', { name: 'Kompresse', expiresAt: soon });
    const summary = (await call('/api/containers')).data.find((entry) => entry.id === container.id);
    assert.equal(summary.expiredCount, 1);
    assert.equal(summary.expiringSoonCount, 1);
    assert.equal(summary.safetyStatus.warnings.length, 2);
    const expiring = (await call('/api/containers/expiring?days=10')).data;
    assert.equal(expiring.length, 2);
    assert.equal(expiring[0].expiryState, 'abgelaufen');
    assert.equal(expiring[0].containerCode, container.code);
  } finally {
    server.close();
  }
});

test('stocktakes show container placement and confirm closed containers', async () => {
  const { server, call } = await setup();
  try {
    const container = await createContainer(call);
    const item = await createMaterial(call, { name: 'Beatmungsbeutel' });
    await call(`/api/containers/${container.id}/items`, 'POST', { entityType: 'MaterialItem', entityId: item.id });
    const stocktake = (await call('/api/stocktakes', 'POST', {
      name: 'Kisteninventur', responsibleUserId: 'user-admin', method: 'online',
      startDate: '2026-07-31', entityTypes: ['MaterialItem'], scope: { locationIds: ['loc-1'] },
    })).data;
    const packedEntry = stocktake.entries.find((entry) => entry.entityId === item.id);
    assert.equal(packedEntry.containerId, container.id);
    assert.equal(packedEntry.containerCode, container.code);
    const early = await call(`/api/stocktakes/${stocktake.id}/containers/${container.id}/confirm`, 'POST', {});
    assert.equal(early.status, 409);
    await call(`/api/stocktakes/${stocktake.id}/start`, 'POST', {});
    const confirmed = await call(`/api/stocktakes/${stocktake.id}/containers/${container.id}/confirm`, 'POST', {});
    assert.equal(confirmed.status, 200);
    const counted = confirmed.data.entries.find((entry) => entry.entityId === item.id);
    assert.equal(counted.result, 'vorhanden');
    assert.equal(confirmed.data.entries.find((entry) => entry.entityId === 'material-1').countedAt, null);
  } finally {
    server.close();
  }
});

test('vehicle loading takes an item out of its container and unloading returns it', async () => {
  const { server, call } = await setup();
  try {
    const container = await createContainer(call);
    const item = await createMaterial(call, { name: 'Handfunkgerät' });
    await call(`/api/containers/${container.id}/items`, 'POST', { entityType: 'MaterialItem', entityId: item.id });
    const vehicle = (await call('/api/vehicles', 'POST', {
      registrationNumber: 'DLRG 7', vin: 'WVWZZZ1JZXW000007', vehicleKind: 'Kraftfahrzeug',
      usage: 'Einsatzfahrt', type: 'Einsatzfahrzeug', status: 'Verfügbar',
    })).data;
    assert.ok(vehicle?.id, JSON.stringify(vehicle));
    const load = await call(`/api/vehicles/${vehicle.id}/load`, 'POST', { materialId: item.id, quantity: 1 });
    assert.equal(load.status, 201, JSON.stringify(load.data));
    assert.equal((await call(`/api/material/${item.id}`)).data.containerId, null);
    assert.equal((await call(`/api/containers/${container.id}`)).data.itemCount, 0);
    const unload = await call(`/api/vehicles/${vehicle.id}/load/${load.data.id}/unload`, 'POST', {});
    assert.equal(unload.status, 200, JSON.stringify(unload.data));
    assert.equal((await call(`/api/material/${item.id}`)).data.containerId, container.id);
  } finally {
    server.close();
  }
});

test('legacy containers are migrated to independent storage places', async () => {
  const data = structuredClone(seedData);
  data.materials.push(
    {
      ...structuredClone(data.materials[0]), id: 'material-box', inventoryNumber: 'SAN-01',
      name: 'Alte Sanitätskiste', isContainer: true, containerCompartments: ['Deckel'],
      completenessStatus: 'Vollständig',
    },
    {
      ...structuredClone(data.materials[0]), id: 'material-inside', inventoryNumber: 'INV-02',
      name: 'Pulsoximeter', locationId: 'loc-1', stockStructureId: 'stock-1',
    },
    {
      ...structuredClone(data.materials[0]), id: 'material-bulk', inventoryNumber: 'INV-03',
      name: 'Rettungsdecke', itemType: 'bulk', quantity: 20,
    },
  );
  data.containerContents = [
    {
      id: 'content-1', organizationId: data.materials[0].organizationId, unitId: data.materials[0].unitId,
      containerId: 'material-box', entityType: 'MaterialItem', entityId: 'material-inside',
      individual: true, quantity: 1, position: 'Deckel',
    },
    {
      id: 'content-2', organizationId: data.materials[0].organizationId, unitId: data.materials[0].unitId,
      containerId: 'material-box', entityType: 'MaterialItem', entityId: 'material-bulk',
      individual: false, quantity: 5, position: 'Deckel', expiresAt: '2030-01-01', nameSnapshot: 'Rettungsdecke',
    },
  ];
  const { server, call } = await setup({ data });
  try {
    const containers = (await call('/api/containers')).data;
    const migrated = containers.find((entry) => entry.code === 'SAN-01');
    assert.ok(migrated, JSON.stringify(containers));
    assert.equal(migrated.stockStructureId, 'stock-1');
    assert.equal(migrated.completenessStatus, 'Vollständig');
    const detail = (await call(`/api/containers/${migrated.id}`)).data;
    assert.deepEqual(detail.items.map((entry) => entry.entityId), ['material-inside']);
    assert.equal(detail.contents.length, 1);
    assert.equal(detail.contents[0].name, 'Rettungsdecke');
    assert.equal(detail.contents[0].quantity, 5);
    assert.equal(detail.contents[0].relocatable, false);
    assert.equal((await call('/api/material/material-bulk')).data.quantity, 15);
    assert.equal((await call('/api/material/material-box')).data.isContainer, false);
  } finally {
    server.close();
  }
});

test('container permissions are granted per role', async () => {
  const { app, server } = await setup();
  try {
    const roles = app.locals.appData.roles;
    const role = (name) => roles.find((entry) => entry.name === name);
    assert.ok(role('Admin').permissions.includes('containers.manage'));
    assert.ok(role('Materialwart').permissions.includes('containers.packlists'));
    assert.ok(role('Fahrzeugwart').permissions.includes('containers.pack'));
    assert.equal(role('Fahrzeugwart').permissions.includes('containers.manage'), false);
    assert.equal(role('Nutzer').permissions.includes('containers.read'), false);
    const materialwart = app.locals.appData.users.find((entry) => entry.username === 'materialwart');
    assert.ok(materialwart.permissions.includes('containers.check'));
  } finally {
    server.close();
  }
});
