const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');

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
    return { status: response.status, data: text ? JSON.parse(text) : null };
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

async function createContainer(call, overrides = {}) {
  const material = await createMaterial(call, overrides);
  const container = await call('/api/containers', 'POST', {
    materialId: material.id, containerType: 'Sanitätskiste', compartments: ['Deckel', 'Boden'],
  });
  assert.equal(container.status, 201, JSON.stringify(container.data));
  return container.data;
}

test('containers are packed with individual, bulk, clothing and nested items', async () => {
  const { server, call } = await setup();
  try {
    const container = await createContainer(call);
    assert.equal(container.completenessStatus, 'Ungeprüft');
    assert.equal(container.contentCount, 0);

    const bulk = await createMaterial(call, {
      name: 'Rettungsdecke', itemType: 'bulk', quantity: 200, unit: 'Stück',
    });
    const individual = await createMaterial(call, { name: 'Pulsoximeter', locationId: 'loc-3' });
    const nested = await createContainer(call, { name: 'Verbandmodul' });

    const notIndividual = await call('/api/containers', 'POST', { materialId: bulk.id });
    assert.equal(notIndividual.status, 409);

    const badSlot = await call(`/api/containers/${container.id}/contents`, 'POST', {
      entityType: 'MaterialItem', entityId: individual.id, position: 'Seitenfach',
    });
    assert.equal(badSlot.status, 400);

    const packedIndividual = await call(`/api/containers/${container.id}/contents`, 'POST', {
      entityType: 'MaterialItem', entityId: individual.id, position: 'Deckel',
    });
    assert.equal(packedIndividual.status, 201, JSON.stringify(packedIndividual.data));
    const tooMuch = await call(`/api/containers/${container.id}/contents`, 'POST', {
      entityType: 'MaterialItem', entityId: bulk.id, quantity: 201,
    });
    assert.equal(tooMuch.status, 409);
    const packedBulk = await call(`/api/containers/${container.id}/contents`, 'POST', {
      entityType: 'MaterialItem', entityId: bulk.id, quantity: 10, expiresAt: '2030-12-31',
    });
    assert.equal(packedBulk.status, 201);
    const packedClothing = await call(`/api/containers/${container.id}/contents`, 'POST', {
      entityType: 'ClothingItem', entityId: 'clothing-1',
    });
    assert.equal(packedClothing.status, 201, JSON.stringify(packedClothing.data));
    const packedNested = await call(`/api/containers/${container.id}/contents`, 'POST', {
      entityType: 'MaterialItem', entityId: nested.id, position: 'Boden',
    });
    assert.equal(packedNested.status, 201);

    const cycle = await call(`/api/containers/${nested.id}/contents`, 'POST', {
      entityType: 'MaterialItem', entityId: container.id,
    });
    assert.equal(cycle.status, 409);
    const twice = await call(`/api/containers/${nested.id}/contents`, 'POST', {
      entityType: 'MaterialItem', entityId: individual.id,
    });
    assert.equal(twice.status, 409);

    const bulkAfter = (await call(`/api/material/${bulk.id}`)).data;
    assert.equal(bulkAfter.containerPackedQuantity, 10);
    assert.equal(bulkAfter.availableQuantity, 190);
    const individualAfter = (await call(`/api/material/${individual.id}`)).data;
    assert.equal(individualAfter.locationId, 'loc-1');
    assert.equal(individualAfter.containerId, container.id);
    assert.ok(individualAfter.movements.some((entry) => entry.action === 'container-pack'));

    const detail = (await call(`/api/containers/${container.id}`)).data;
    assert.equal(detail.contents.length, 4);
    assert.equal(detail.contents.find((entry) => entry.entityId === nested.id).isContainer, true);
    assert.equal((await call(`/api/containers/${nested.id}`)).data.parentContainerName.includes(container.inventoryNumber), true);

    const candidates = (await call(`/api/containers/${nested.id}/candidates`)).data;
    assert.equal(candidates.some((entry) => entry.entityId === container.id), false);
    assert.equal(candidates.some((entry) => entry.entityId === individual.id), false);
    assert.equal(candidates.find((entry) => entry.entityId === bulk.id).availableQuantity, 190);

    const lookup = (await call(`/api/containers/lookup?code=${encodeURIComponent(individual.inventoryNumber)}`)).data;
    assert.equal(lookup.match, 'content');
    assert.equal(lookup.container.id, container.id);

    const reduce = await call(`/api/containers/${container.id}/contents/${packedBulk.data.id}`, 'PUT', {
      quantity: 5, batchNumber: 'LOT-7',
    });
    assert.equal(reduce.status, 200);
    assert.equal((await call(`/api/material/${bulk.id}`)).data.availableQuantity, 195);

    const removeCompartment = await call(`/api/containers/${container.id}`, 'PUT', { compartments: ['Boden'] });
    assert.equal(removeCompartment.status, 409);
    const archiveFull = await call(`/api/material/${container.id}/archive`, 'POST', {});
    assert.equal(archiveFull.status, 409);
    const dissolveFull = await call(`/api/containers/${container.id}`, 'DELETE');
    assert.equal(dissolveFull.status, 409);
  } finally {
    server.close();
  }
});

test('packed contents are locked and follow the container', async () => {
  const { app, server, call } = await setup();
  try {
    const container = await createContainer(call);
    const nested = await createContainer(call, { name: 'Modul' });
    const item = await createMaterial(call, { name: 'Absaugpumpe' });
    const deepItem = await createMaterial(call, { name: 'Schere' });
    await call(`/api/containers/${container.id}/contents`, 'POST', { entityType: 'MaterialItem', entityId: item.id });
    await call(`/api/containers/${nested.id}/contents`, 'POST', { entityType: 'MaterialItem', entityId: deepItem.id });
    await call(`/api/containers/${container.id}/contents`, 'POST', { entityType: 'MaterialItem', entityId: nested.id });
    await call(`/api/containers/${container.id}/contents`, 'POST', { entityType: 'ClothingItem', entityId: 'clothing-1' });

    const relocateContent = await call('/api/material/relocate/bulk', 'POST', {
      materialIds: [item.id], locationId: 'loc-3',
    });
    assert.equal(relocateContent.status, 409);
    const issueContent = await call('/api/material/transactions/bulk', 'POST', {
      action: 'issue', recipient: 'Wachdienst', items: [{ materialId: item.id, quantity: 1 }],
    });
    assert.equal(issueContent.status, 409);
    assert.equal(issueContent.data.details[0].error, 'packed_in_container');
    const editContent = await call(`/api/material/${item.id}`, 'PUT', { locationId: 'loc-3' });
    assert.equal(editContent.status, 409);
    const issueClothing = await call('/api/transactions', 'POST', {
      action: 'ausgegeben', clothingIds: ['clothing-1'], personName: 'Erika Muster',
    });
    assert.equal(issueClothing.status, 409);
    const deleteClothing = await call('/api/clothing/clothing-1', 'DELETE');
    assert.equal(deleteClothing.status, 409);

    const relocate = await call('/api/material/relocate/bulk', 'POST', {
      materialIds: [container.id], locationId: 'loc-3',
    });
    assert.equal(relocate.status, 201);
    assert.equal((await call(`/api/material/${item.id}`)).data.locationId, 'loc-3');
    assert.equal((await call(`/api/material/${deepItem.id}`)).data.locationId, 'loc-3');
    const clothing = app.locals.appData.clothingItems.find((entry) => entry.id === 'clothing-1');
    assert.equal(clothing.locationId, 'loc-3');
    assert.ok((await call(`/api/material/${deepItem.id}`)).data.movements
      .some((entry) => entry.action === 'container-follow'));

    const vehicle = (await call('/api/vehicles', 'POST', {
      registrationNumber: 'DLRG 7', vin: 'WVWZZZ1JZXW000007', vehicleKind: 'Kraftfahrzeug',
      usage: 'Einsatzfahrt', type: 'Einsatzfahrzeug', status: 'Verfügbar',
    })).data;
    const loadContent = await call(`/api/vehicles/${vehicle.id}/load`, 'POST', { materialId: item.id, quantity: 1 });
    assert.equal(loadContent.status, 409);
    const load = await call(`/api/vehicles/${vehicle.id}/load`, 'POST', { materialId: container.id, quantity: 1 });
    assert.equal(load.status, 201, JSON.stringify(load.data));
    assert.equal((await call(`/api/material/${deepItem.id}`)).data.locationId, vehicle.loadLocationId);
    assert.equal((await call(`/api/containers/${container.id}`)).data.vehicleId, vehicle.id);

    const unpackToVehicle = await call(`/api/containers/${container.id}/contents/${
      (await call(`/api/containers/${container.id}`)).data.contents.find((entry) => entry.entityId === item.id).id
    }/unpack`, 'POST', { locationId: vehicle.loadLocationId });
    assert.equal(unpackToVehicle.status, 400);

    const unload = await call(`/api/vehicles/${vehicle.id}/load/${load.data.id}/unload`, 'POST', { locationId: 'loc-1' });
    assert.equal(unload.status, 200);
    assert.equal((await call(`/api/material/${deepItem.id}`)).data.locationId, 'loc-1');

    const issue = await call('/api/material/transactions/bulk', 'POST', {
      action: 'issue', recipient: 'Wasserrettungszug', items: [{ materialId: container.id, quantity: 1 }],
    });
    assert.equal(issue.status, 201);
    const contentId = (await call(`/api/containers/${container.id}`)).data.contents
      .find((entry) => entry.entityId === item.id).id;
    const unpackIssued = await call(`/api/containers/${container.id}/contents/${contentId}/unpack`, 'POST', {});
    assert.equal(unpackIssued.status, 409);
    await call('/api/material/transactions/bulk', 'POST', {
      action: 'return', items: [{ materialId: container.id, quantity: 1 }],
    });

    const unpack = await call(`/api/containers/${container.id}/contents/${contentId}/unpack`, 'POST', {
      locationId: 'loc-3',
    });
    assert.equal(unpack.status, 200);
    const freed = (await call(`/api/material/${item.id}`)).data;
    assert.equal(freed.locationId, 'loc-3');
    assert.equal(freed.containerId, null);
    assert.equal((await call('/api/material/relocate/bulk', 'POST', {
      materialIds: [item.id], locationId: 'loc-1',
    })).status, 201);
  } finally {
    server.close();
  }
});

test('pack lists, completeness checks, defects and print output', async () => {
  const { app, server, call } = await setup();
  try {
    const container = await createContainer(call);
    const bulk = await createMaterial(call, { name: 'Pflaster', itemType: 'bulk', quantity: 100 });
    const scissors = await createMaterial(call, { name: 'Kleiderschere' });
    await call(`/api/containers/${container.id}/contents`, 'POST', {
      entityType: 'MaterialItem', entityId: bulk.id, quantity: 20,
    });

    const invalidList = await call(`/api/containers/${container.id}/pack-lists`, 'POST', {
      items: [{ entityType: 'MaterialItem', entityId: scissors.id, targetQuantity: 2 }],
    });
    assert.equal(invalidList.status, 400);
    const list = await call(`/api/containers/${container.id}/pack-lists`, 'POST', {
      name: 'Sanitätskiste Standard',
      items: [
        { entityType: 'MaterialItem', entityId: bulk.id, targetQuantity: 25, position: 'Deckel' },
        { entityType: 'MaterialItem', entityId: scissors.id, targetQuantity: 1 },
      ],
    });
    assert.equal(list.status, 201);
    assert.equal(list.data.version, 1);
    const draft = await call(`/api/containers/${container.id}/pack-lists`, 'POST', {
      fromContents: true, activate: false,
    });
    assert.equal(draft.data.status, 'Entwurf');
    assert.equal(draft.data.version, 2);

    const detail = (await call(`/api/containers/${container.id}`)).data;
    assert.equal(detail.activePackListVersion, 1);
    assert.equal(detail.packListDeviation.missingCount, 2);
    assert.equal(detail.checkTemplate.items.length, 2);

    const missingResult = await call(`/api/containers/${container.id}/checks`, 'POST', {
      results: [{ key: `MaterialItem:${bulk.id}`, result: 'vorhanden', actualQuantity: 20 }],
    });
    assert.equal(missingResult.status, 400);

    const incomplete = await call(`/api/containers/${container.id}/checks`, 'POST', {
      results: [
        { key: `MaterialItem:${bulk.id}`, result: 'vorhanden', actualQuantity: 20 },
        { key: `MaterialItem:${scissors.id}`, result: 'fehlt' },
      ],
      notes: 'Nach Wachdienst geprüft',
      createDefect: { priority: 'Normal' },
    });
    assert.equal(incomplete.status, 201, JSON.stringify(incomplete.data));
    assert.equal(incomplete.data.complete, false);
    assert.equal(incomplete.data.deviationCount, 2);
    assert.ok(incomplete.data.defectId);
    assert.equal(incomplete.data.container.completenessStatus, 'Unvollständig');
    const defect = app.locals.appData.defectReports.find((entry) => entry.id === incomplete.data.defectId);
    assert.equal(defect.entityId, container.id);
    assert.match(defect.description, /Kleiderschere: fehlt/);
    assert.notEqual((await call(`/api/material/${container.id}`)).data.status, 'Defekt');

    await call(`/api/containers/${container.id}/contents`, 'POST', {
      entityType: 'MaterialItem', entityId: bulk.id, quantity: 5,
    });
    await call(`/api/containers/${container.id}/contents`, 'POST', {
      entityType: 'MaterialItem', entityId: scissors.id,
    });
    assert.equal((await call(`/api/containers/${container.id}`)).data.packListDeviation.missingCount, 0);
    const complete = await call(`/api/containers/${container.id}/checks`, 'POST', {
      results: [
        { key: `MaterialItem:${bulk.id}`, result: 'vorhanden', actualQuantity: 25 },
        { key: `MaterialItem:${scissors.id}`, result: 'vorhanden' },
      ],
    });
    assert.equal(complete.data.complete, true);
    assert.equal(complete.data.container.completenessStatus, 'Vollständig');
    assert.equal(complete.data.container.checks.length, 2);

    const activated = await call(`/api/containers/${container.id}/pack-lists/${draft.data.id}/activate`, 'POST', {});
    assert.equal(activated.data.status, 'Aktiv');
    const lists = (await call(`/api/containers/${container.id}`)).data.packLists;
    assert.equal(lists.find((entry) => entry.version === 1).status, 'Ersetzt');

    const print = await call(`/api/containers/${container.id}/pack-list/print`);
    assert.equal(print.status, 200);
    assert.equal(print.data.mimeType, 'application/pdf');
    assert.equal(Buffer.from(print.data.fileBase64, 'base64').subarray(0, 4).toString(), '%PDF');
  } finally {
    server.close();
  }
});

test('expiry dates are validated and reported', async () => {
  const { server, call } = await setup();
  try {
    const container = await createContainer(call);
    const bulk = await createMaterial(call, { name: 'Kochsalzlösung', itemType: 'bulk', quantity: 10 });
    const other = await createMaterial(call, { name: 'Wundauflage', itemType: 'bulk', quantity: 10 });
    const invalid = await call(`/api/containers/${container.id}/contents`, 'POST', {
      entityType: 'MaterialItem', entityId: bulk.id, quantity: 1, expiresAt: '31.12.2020',
    });
    assert.equal(invalid.status, 400);
    await call(`/api/containers/${container.id}/contents`, 'POST', {
      entityType: 'MaterialItem', entityId: bulk.id, quantity: 2, expiresAt: '2020-01-31',
    });
    const soon = new Date(Date.now() + 5 * 86_400_000).toISOString().slice(0, 10);
    await call(`/api/containers/${container.id}/contents`, 'POST', {
      entityType: 'MaterialItem', entityId: other.id, quantity: 2, expiresAt: soon,
    });
    const summary = (await call('/api/containers')).data.find((entry) => entry.id === container.id);
    assert.equal(summary.expiredCount, 1);
    assert.equal(summary.expiringSoonCount, 1);
    assert.equal(summary.safetyStatus.blocked, false);
    assert.equal(summary.safetyStatus.warnings.length, 2);
    const expiring = (await call('/api/containers/expiring?days=10')).data;
    assert.deepEqual(expiring.map((entry) => entry.expiryState), ['abgelaufen', 'läuft bald ab']);
    assert.equal(expiring[0].containerInventoryNumber, container.inventoryNumber);
  } finally {
    server.close();
  }
});

test('stocktakes show container placement and confirm closed containers', async () => {
  const { server, call } = await setup();
  try {
    const container = await createContainer(call);
    const item = await createMaterial(call, { name: 'Beatmungsbeutel' });
    await call(`/api/containers/${container.id}/contents`, 'POST', {
      entityType: 'MaterialItem', entityId: item.id,
    });
    const stocktake = (await call('/api/stocktakes', 'POST', {
      name: 'Kisteninventur', responsibleUserId: 'user-admin', method: 'online',
      startDate: '2026-07-31', entityTypes: ['MaterialItem'], scope: { locationIds: ['loc-1'] },
    })).data;
    const packedEntry = stocktake.entries.find((entry) => entry.entityId === item.id);
    assert.equal(packedEntry.containerId, container.id);
    assert.equal(packedEntry.containerInventoryNumber, container.inventoryNumber);
    assert.equal(stocktake.entries.find((entry) => entry.entityId === container.id).isContainer, true);
    const early = await call(`/api/stocktakes/${stocktake.id}/containers/${container.id}/confirm`, 'POST', {});
    assert.equal(early.status, 409);
    await call(`/api/stocktakes/${stocktake.id}/start`, 'POST', {});
    const confirmed = await call(`/api/stocktakes/${stocktake.id}/containers/${container.id}/confirm`, 'POST', {});
    assert.equal(confirmed.status, 200);
    const counted = confirmed.data.entries.filter((entry) =>
      [item.id, container.id].includes(entry.entityId));
    assert.equal(counted.length, 2);
    assert.ok(counted.every((entry) => entry.result === 'vorhanden' && entry.countedAt));
    assert.equal(confirmed.data.entries.find((entry) => entry.entityId === 'material-1').countedAt, null);
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
