const assert = require('node:assert/strict');
const test = require('node:test');
const XLSX = require('xlsx');
const { createApp } = require('../src/app');

async function setup() {
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
  const headers = { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` };
  return { app, server, baseUrl, headers };
}

async function request(baseUrl, headers, path, method = 'GET', body) {
  const response = await fetch(`${baseUrl}${path}`, {
    method, headers, body: body === undefined ? undefined : JSON.stringify(body),
  });
  const data = await response.json();
  return { response, data };
}

test('stocktake snapshots material and clothing and preserves repeat counts', async () => {
  const { server, baseUrl, headers } = await setup();
  try {
    const created = await request(baseUrl, headers, '/api/stocktakes', 'POST', {
      name: 'Jahresinventur', responsibleUserId: 'user-admin', method: 'online',
      startDate: '2026-07-31', countMode: 'blind',
      entityTypes: ['MaterialItem', 'ClothingItem'], scope: {},
    });
    assert.equal(created.response.status, 201);
    assert.equal(created.data.status, 'Angelegt');
    assert.equal(created.data.entries.length, 2);

    const started = await request(baseUrl, headers, `/api/stocktakes/${created.data.id}/start`, 'POST', {});
    assert.equal(started.data.status, 'In Arbeit');
    const material = started.data.entries.find((entry) => entry.entityType === 'MaterialItem');
    const first = await request(baseUrl, headers,
      `/api/stocktakes/${created.data.id}/entries/${material.id}`, 'PUT', {
        result: 'nicht vorhanden', actualLocationId: 'loc-1', actualStockStructureId: 'stock-1',
      });
    assert.equal(first.data.entries.find((entry) => entry.id === material.id).attempts.length, 1);
    const second = await request(baseUrl, headers,
      `/api/stocktakes/${created.data.id}/entries/${material.id}`, 'PUT', {
        result: 'beschädigt', notes: 'Kette defekt', actualLocationId: 'loc-1', actualStockStructureId: 'stock-1',
      });
    const recounted = second.data.entries.find((entry) => entry.id === material.id);
    assert.equal(recounted.attempts.length, 2);
    assert.deepEqual(recounted.discrepancies, ['Mangel']);
  } finally { server.close(); }
});

test('evaluation creates discrepancy defects and completion applies corrections explicitly', async () => {
  const { app, server, baseUrl, headers } = await setup();
  try {
    const materialResponse = await request(baseUrl, headers, '/api/material', 'POST', {
      name: 'Leinen', categoryCode: '02', subcategoryCode: '02-02', locationId: 'loc-1',
      stockStructureId: 'stock-1', status: 'Lagernd', itemType: 'bulk', quantity: 10, unit: 'Stück',
    });
    const created = (await request(baseUrl, headers, '/api/stocktakes', 'POST', {
      name: 'Lagerzählung', responsibleUserId: 'user-admin', method: 'offline',
      startDate: '2026-07-31', entityTypes: ['MaterialItem'],
      scope: { locationIds: ['loc-1'] }, countMode: 'open',
    })).data;
    await request(baseUrl, headers, `/api/stocktakes/${created.id}/start`, 'POST', {});
    const detail = (await request(baseUrl, headers, `/api/stocktakes/${created.id}`)).data;
    const entry = detail.entries.find((item) => item.entityId === materialResponse.data.id);
    await request(baseUrl, headers, `/api/stocktakes/${created.id}/entries/${entry.id}`, 'PUT', {
      actualQuantity: 7, actualLocationId: 'loc-3', notes: 'Drei fehlen',
    });
    const evaluated = await request(baseUrl, headers, `/api/stocktakes/${created.id}/evaluate`, 'POST', {});
    assert.equal(evaluated.data.status, 'Auswertung');
    assert.ok(evaluated.data.entries.find((item) => item.id === entry.id).shortageDefectId);
    assert.equal(app.locals.defectReports.filter((report) => report.linkedStocktakeId === created.id).length, 1);
    const differences = await request(baseUrl, headers,
      `/api/stocktakes/${created.id}/export?format=xlsx&differences=true`);
    const differenceWorkbook = XLSX.read(Buffer.from(differences.data.fileBase64, 'base64'));
    const differenceRows = XLSX.utils.sheet_to_json(
      differenceWorkbook.Sheets[differenceWorkbook.SheetNames[0]],
    );
    assert.equal(differenceRows.length, 1);
    assert.match(differenceRows[0].Abweichung, /Mengenabweichung/);

    const before = await request(baseUrl, headers, `/api/material/${materialResponse.data.id}`);
    assert.equal(before.data.quantity, 10);
    const completed = await request(baseUrl, headers, `/api/stocktakes/${created.id}/complete`, 'POST', { applyCorrections: true });
    assert.equal(completed.data.status, 'Abgeschlossen');
    const after = await request(baseUrl, headers, `/api/material/${materialResponse.data.id}`);
    assert.equal(after.data.quantity, 7);
    assert.equal(after.data.locationId, 'loc-3');
    const editAfterCompletion = await request(baseUrl, headers, `/api/stocktakes/${created.id}/entries/${entry.id}`, 'PUT', { actualQuantity: 8 });
    assert.equal(editAfterCompletion.response.status, 409);
  } finally { server.close(); }
});

test('offline exports and spreadsheet import are available', async () => {
  const { server, baseUrl, headers } = await setup();
  try {
    const created = (await request(baseUrl, headers, '/api/stocktakes', 'POST', {
      name: 'Papierinventur', responsibleUserId: 'user-admin', method: 'offline',
      startDate: '2026-07-31', entityTypes: ['MaterialItem'], scope: {}, countMode: 'blind',
    })).data;
    await request(baseUrl, headers, `/api/stocktakes/${created.id}/start`, 'POST', {});
    const pdf = await request(baseUrl, headers, `/api/stocktakes/${created.id}/export?format=pdf&blank=true`);
    assert.equal(pdf.response.status, 200);
    assert.equal(Buffer.from(pdf.data.fileBase64, 'base64').subarray(0, 4).toString(), '%PDF');

    const workbook = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(workbook, XLSX.utils.json_to_sheet([{
      Inventarnummer: created.entries[0].inventoryNumber, Ergebnis: 'vorhanden', Notizen: 'Papierliste',
    }]), 'Zählung');
    const imported = await request(baseUrl, headers, `/api/stocktakes/${created.id}/import`, 'POST', {
      fileName: 'zaehlung.xlsx', fileBase64: XLSX.write(workbook, { type: 'buffer', bookType: 'xlsx' }).toString('base64'),
    });
    assert.equal(imported.response.status, 200);
    assert.equal(imported.data.imported, 1);
  } finally { server.close(); }
});

test('material wardens can create material stocktakes but not wardrobe stocktakes', async () => {
  const app = createApp();
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  try {
    const login = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: 'materialwart@materialkompass.local', password: 'Material123!' }),
    });
    const headers = { 'Content-Type': 'application/json', Authorization: `Bearer ${(await login.json()).token}` };
    const common = {
      name: 'Bereichsinventur', responsibleUserId: 'user-materialwart', method: 'online',
      startDate: '2026-07-31', scope: {}, countMode: 'blind',
    };
    const material = await request(baseUrl, headers, '/api/stocktakes', 'POST', {
      ...common, entityTypes: ['MaterialItem'],
    });
    assert.equal(material.response.status, 201);
    const clothing = await request(baseUrl, headers, '/api/stocktakes', 'POST', {
      ...common, entityTypes: ['ClothingItem'],
    });
    assert.equal(clothing.response.status, 400);
    assert.match(clothing.data.error, /Berechtigung/);
  } finally { server.close(); }
});
