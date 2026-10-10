const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');
const { seedData } = require('../src/data/seed');

async function start() {
  const data = structuredClone(seedData);
  data.defectEmailImports = [
    { id: 'defect-mail-1', status: 'pending', extractedData: {} },
    { id: 'defect-mail-2', status: 'pending', extractedData: {} },
    { id: 'defect-mail-3', status: 'processed', extractedData: {} },
  ];
  data.procurementEmailImports = [
    { id: 'proc-mail-1', status: 'offen', requestId: null },
    { id: 'proc-mail-2', status: 'fehlerhaft', requestId: null },
    { id: 'proc-mail-3', status: 'verarbeitet', requestId: null },
  ];
  data.stocktakeEmailImports = [
    { id: 'stock-mail-1', status: 'unzugeordnet', stocktakeId: null, attachments: [] },
    { id: 'stock-mail-2', status: 'fehlerhaft', stocktakeId: null, attachments: [] },
    { id: 'stock-mail-3', status: 'verarbeitet', stocktakeId: null, attachments: [] },
  ];
  const app = createApp({ data, skipEmailVerification: true });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  const login = await fetch(`${baseUrl}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ identifier: 'admin', password: 'MaterialKompass2026!' }),
  });
  return { app, server, baseUrl, token: (await login.json()).token };
}

test('dashboard counts every visible unfinished email including failed imports', async () => {
  const { app, server, baseUrl, token } = await start();
  const headers = {
    Authorization: `Bearer ${token}`,
    'Content-Type': 'application/json',
  };
  try {
    const response = await fetch(`${baseUrl}/api/dashboard`, { headers });
    assert.equal(response.status, 200);
    const dashboard = await response.json();
    assert.equal(dashboard.summary.pendingDefectEmailCount, 2);
    assert.equal(dashboard.summary.pendingProcurementEmailCount, 2);
    assert.equal(dashboard.summary.pendingStocktakeEmailCount, 2);

    const discarded = await fetch(
      `${baseUrl}/api/stocktake-email-imports/stock-mail-1/discard`,
      { method: 'POST', headers, body: JSON.stringify({ reason: 'Nicht relevant' }) },
    );
    assert.equal(discarded.status, 200);
    assert.equal((await discarded.json()).status, 'verworfen');

    const duplicateDiscard = await fetch(
      `${baseUrl}/api/stocktake-email-imports/stock-mail-1/discard`,
      { method: 'POST', headers, body: JSON.stringify({ reason: 'Erneut' }) },
    );
    assert.equal(duplicateDiscard.status, 409);

    const refreshed = await fetch(`${baseUrl}/api/dashboard`, { headers })
      .then((result) => result.json());
    assert.equal(refreshed.summary.pendingStocktakeEmailCount, 1);
  } finally {
    await app.locals.defectEmailService.stop();
    await app.locals.stocktakeEmailService.stop();
    await app.locals.procurementEmailService.stop();
    server.close();
  }
});
