const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');
const { rawCollection } = require('../src/tenancy');

async function setup() {
  const app = createApp();
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  const request = async (path, { method = 'GET', token, body } = {}) => {
    const response = await fetch(`${baseUrl}${path}`, {
      method,
      headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return { response, data: response.status === 204 ? null : await response.json() };
  };
  const login = await request('/api/auth/login', {
    method: 'POST', body: { identifier: 'admin', password: 'MaterialKompass2026!' },
  });
  return { app, server, request, adminToken: login.data.token };
}

async function createKey(request, adminToken, scopes = ['material:lesen', 'fahrzeuge:lesen']) {
  const created = await request('/api/integration-keys', {
    method: 'POST', token: adminToken, body: { name: 'Übungsplaner', scopes },
  });
  assert.equal(created.response.status, 201, JSON.stringify(created.data));
  return created.data;
}

test('admins issue API keys that are shown once and stored only as digest', async () => {
  const { app, server, request, adminToken } = await setup();
  try {
    const created = await createKey(request, adminToken);
    assert.match(created.apiKey, /^mkapi_[A-Za-z0-9_-]{43}$/);
    assert.equal(created.keyHash, undefined);
    assert.deepEqual(created.scopes, ['material:lesen', 'fahrzeuge:lesen']);

    const stored = rawCollection(app.locals.appData.integrationApiKeys)[0];
    assert.notEqual(stored.keyHash, created.apiKey);
    assert.equal(JSON.stringify(stored).includes(created.apiKey), false);

    const listed = await request('/api/integration-keys', { token: adminToken });
    assert.equal(listed.response.status, 200);
    assert.equal(listed.data.keys.length, 1);
    assert.equal(listed.data.keys[0].apiKey, undefined);
    assert.equal(listed.data.keys[0].keyHash, undefined);

    const invalidScope = await request('/api/integration-keys', {
      method: 'POST', token: adminToken, body: { name: 'X', scopes: ['alles'] },
    });
    assert.equal(invalidScope.response.status, 400);

    const status = await request('/api/v1/status', { token: created.apiKey });
    assert.equal(status.response.status, 200);
    assert.equal(status.data.version, '1.0.0');
    assert.ok(status.data.organisation.id);
    assert.ok(status.data.organisation.name);
    assert.ok(listed.data.keys[0].lastUsedAt === null);
    const afterUse = await request('/api/integration-keys', { token: adminToken });
    assert.ok(afterUse.data.keys[0].lastUsedAt);
  } finally {
    server.close();
  }
});

test('revoked, regenerated and unknown keys are rejected', async () => {
  const { server, request, adminToken } = await setup();
  try {
    assert.equal((await request('/api/v1/status')).response.status, 401);
    assert.equal((await request('/api/v1/status', { token: 'mkapi_unbekannt' })).response.status, 401);
    // A normal user session must not unlock the partner interface.
    assert.equal((await request('/api/v1/material', { token: adminToken })).response.status, 401);

    const created = await createKey(request, adminToken);
    const regenerated = await request(`/api/integration-keys/${created.id}/regenerate`, {
      method: 'POST', token: adminToken,
    });
    assert.equal(regenerated.response.status, 200);
    assert.notEqual(regenerated.data.apiKey, created.apiKey);
    assert.equal((await request('/api/v1/status', { token: created.apiKey })).response.status, 401);
    assert.equal((await request('/api/v1/status', { token: regenerated.data.apiKey })).response.status, 200);

    const revoked = await request(`/api/integration-keys/${created.id}/revoke`, {
      method: 'POST', token: adminToken,
    });
    assert.equal(revoked.data.active, false);
    const rejected = await request('/api/v1/status', { token: regenerated.data.apiKey });
    assert.equal(rejected.response.status, 401);
    assert.match(rejected.response.headers.get('content-type'), /application\/problem\+json/);
    assert.ok(rejected.data.detail);

    const removed = await request(`/api/integration-keys/${created.id}`, { method: 'DELETE', token: adminToken });
    assert.equal(removed.response.status, 204);
    assert.equal((await request('/api/integration-keys', { token: adminToken })).data.keys.length, 0);
  } finally {
    server.close();
  }
});

test('material list maps inventory data, honours scopes, paging and change filter', async () => {
  const { app, server, request, adminToken } = await setup();
  try {
    const vehiclesOnly = await createKey(request, adminToken, ['fahrzeuge:lesen']);
    const forbidden = await request('/api/v1/material', { token: vehiclesOnly.apiKey });
    assert.equal(forbidden.response.status, 403);

    const { apiKey } = await createKey(request, adminToken, ['material:lesen']);
    const seeded = rawCollection(app.locals.appData.materials)[0];
    rawCollection(app.locals.appData.materials).push({
      ...structuredClone(seeded), id: 'material-2', name: 'Bindemittel', itemType: 'bulk',
      inventoryNumber: '10050035-02-02-002', quantity: 4, unit: 'Sack',
    });
    const listed = await request('/api/v1/material?limit=500', { token: apiKey });
    assert.equal(listed.response.status, 200, JSON.stringify(listed.data));
    assert.ok(listed.data.server_zeit);
    const chainsaw = listed.data.daten.find((entry) => entry.id === 'material-1');
    assert.equal(chainsaw.bezeichnung, 'Kettensäge');
    assert.equal(chainsaw.kategorie, 'Werkzeug');
    assert.equal(chainsaw.unterkategorie, 'Handwerk');
    assert.equal(chainsaw.inventarnummer, '10050035-02-02-001');
    assert.equal(chainsaw.menge, 1);
    assert.equal(chainsaw.einheit, 'Stück');
    assert.equal(chainsaw.standort_id, 'loc-1');
    assert.match(chainsaw.lagerort, /Hauptlager/);
    assert.equal(chainsaw.geloescht, false);
    assert.ok(['einsatzbereit', 'pruefung_faellig'].includes(chainsaw.status));
    assert.ok(chainsaw.aktualisiert_am);

    const total = listed.data.daten.length;
    assert.ok(total >= 2);
    const first = await request('/api/v1/material?limit=1', { token: apiKey });
    assert.equal(first.data.daten.length, 1);
    assert.ok(first.data.naechster_cursor);
    const second = await request(`/api/v1/material?limit=1&cursor=${first.data.naechster_cursor}`, { token: apiKey });
    assert.notEqual(second.data.daten[0].id, first.data.daten[0].id);
    assert.equal((await request('/api/v1/material?limit=501', { token: apiKey })).response.status, 400);
    assert.equal((await request('/api/v1/material?cursor=kaputt', { token: apiKey })).response.status, 400);

    const search = await request('/api/v1/material?suche=kettens', { token: apiKey });
    assert.deepEqual(search.data.daten.map((entry) => entry.id), ['material-1']);

    // Archived items stay visible as deleted so partners can remove them.
    const since = new Date(Date.now() - 1000).toISOString();
    rawCollection(app.locals.appData.materials).find((entry) => entry.id === 'material-1')
      .updatedAt = new Date().toISOString();
    const changed = await request(`/api/v1/material?geaendert_seit=${encodeURIComponent(since)}`, { token: apiKey });
    assert.deepEqual(changed.data.daten.map((entry) => entry.id), ['material-1']);
    const archived = await request('/api/material/material-1/archive', { method: 'POST', token: adminToken });
    assert.ok(archived.response.status < 300, JSON.stringify(archived.data));
    const afterArchive = await request('/api/v1/material?suche=kettens', { token: apiKey });
    assert.equal(afterArchive.data.daten[0].geloescht, true);
    assert.equal(afterArchive.data.daten[0].status, 'ausgesondert');
  } finally {
    server.close();
  }
});

test('vehicles are listed with status and availability', async () => {
  const { server, request, adminToken } = await setup();
  try {
    const created = await request('/api/vehicles', {
      method: 'POST', token: adminToken, body: {
        registrationNumber: 'DLRG 1', vin: 'WVWZZZ1JZXW000001',
        radioCallName: 'Pelikan Musterstadt 1/11-1', vehicleKind: 'Kraftfahrzeug',
        usage: 'Einsatzfahrt', type: 'Einsatzfahrzeug', year: 2024, status: 'Verfügbar',
      },
    });
    assert.equal(created.response.status, 201, JSON.stringify(created.data));
    const boat = await request('/api/vehicles', {
      method: 'POST', token: adminToken, body: {
        radioCallName: 'MZB 1', vehicleKind: 'Boot', usage: 'Einsatzfahrt',
        type: 'Einsatzfahrzeug', status: 'In Wartung',
      },
    });
    assert.equal(boat.response.status, 201, JSON.stringify(boat.data));

    const materialOnly = await createKey(request, adminToken, ['material:lesen']);
    assert.equal((await request('/api/v1/fahrzeuge', { token: materialOnly.apiKey })).response.status, 403);

    const { apiKey } = await createKey(request, adminToken, ['fahrzeuge:lesen']);
    const listed = await request('/api/v1/fahrzeuge', { token: apiKey });
    assert.equal(listed.response.status, 200);
    const car = listed.data.daten.find((entry) => entry.id === created.data.id);
    assert.equal(car.bezeichnung, 'Pelikan Musterstadt 1/11-1');
    assert.equal(car.funkrufname, 'Pelikan Musterstadt 1/11-1');
    assert.equal(car.kennzeichen, 'DLRG 1');
    assert.equal(car.art, 'fahrzeug');
    assert.equal(car.status, 'einsatzbereit');
    const mzb = listed.data.daten.find((entry) => entry.id === boat.data.id);
    assert.equal(mzb.art, 'boot');
    assert.equal(mzb.status, 'werkstatt');

    const single = await request(`/api/v1/fahrzeuge/${created.data.id}`, { token: apiKey });
    assert.equal(single.data.id, created.data.id);
    assert.equal((await request('/api/v1/fahrzeuge/unbekannt', { token: apiKey })).response.status, 404);

    const from = new Date(Date.now() + 24 * 3600 * 1000).toISOString();
    const to = new Date(Date.now() + 26 * 3600 * 1000).toISOString();
    const free = await request(`/api/v1/fahrzeuge/${created.data.id}/verfuegbarkeit?von=${from}&bis=${to}`, { token: apiKey });
    assert.equal(free.data.verfuegbar, true);
    const reservation = await request('/api/vehicle-reservations', {
      method: 'POST', token: adminToken, body: {
        vehicleId: created.data.id, startAt: from, endAt: to, title: 'Übung',
        purpose: 'Ausbildung', destination: 'See', contact: 'Leitung',
      },
    });
    assert.equal(reservation.response.status, 201, JSON.stringify(reservation.data));
    const busy = await request(`/api/v1/fahrzeuge/${created.data.id}/verfuegbarkeit?von=${from}&bis=${to}`, { token: apiKey });
    assert.equal(busy.data.verfuegbar, false);
    assert.equal(busy.data.belegungen[0].grund, 'Reservierung');
    assert.equal((await request(`/api/v1/fahrzeuge/${created.data.id}/verfuegbarkeit?von=x&bis=y`, { token: apiKey })).response.status, 400);
  } finally {
    server.close();
  }
});

test('API keys only see data of their own organization unit', async () => {
  const { app, server, request, adminToken } = await setup();
  try {
    const { apiKey } = await createKey(request, adminToken);
    const ownMaterial = rawCollection(app.locals.appData.materials)[0];
    rawCollection(app.locals.appData.materials).push({
      ...structuredClone(ownMaterial), id: 'foreign-material', name: 'Fremdes Material',
      organizationId: 'org-foreign', unitId: 'unit-foreign',
    });
    const listed = await request('/api/v1/material?limit=500', { token: apiKey });
    assert.equal(listed.data.daten.some((entry) => entry.id === 'foreign-material'), false);

    // Keys of a deactivated organization stop working immediately.
    const organization = app.locals.appData.organizations.find((entry) =>
      entry.id === ownMaterial.organizationId);
    organization.status = 'archived';
    assert.equal((await request('/api/v1/status', { token: apiKey })).response.status, 403);
  } finally {
    server.close();
  }
});
