const assert = require('node:assert/strict');
const test = require('node:test');
const XLSX = require('xlsx');

const { createApp } = require('../src/app');

async function startServer() {
  const app = createApp();
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const address = server.address();
  return { server, baseUrl: `http://127.0.0.1:${address.port}` };
}

async function login(baseUrl) {
  const response = await fetch(`${baseUrl}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      email: 'admin@materialkompass.org',
      password: 'MaterialKompass2026!',
    }),
  });
  assert.equal(response.status, 200);
  return (await response.json()).token;
}

function createTable(rows, format) {
  const workbook = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(workbook, XLSX.utils.json_to_sheet(rows), 'Kleiderkammer');
  return XLSX.write(workbook, { type: 'buffer', bookType: format });
}

for (const format of ['xlsx', 'ods']) {
  test(`imports ${format.toUpperCase()} clothing tables and reports skipped rows`, async () => {
    const { server, baseUrl } = await startServer();
    try {
      const token = await login(baseUrl);
      const table = createTable([
        {
          Inventarnummer: `IMPORT-${format.toUpperCase()}-1`,
          Name: 'Importierte Einsatzjacke',
          'Größe': 'L',
          Standort: 'loc-2',
          Status: 'Lagernd',
        },
        {
          Inventarnummer: `IMPORT-${format.toUpperCase()}-1`,
          Name: 'Bereits vorhanden',
        },
        {
          Inventarnummer: `IMPORT-${format.toUpperCase()}-2`,
          Name: '',
        },
      ], format);

      const response = await fetch(`${baseUrl}/api/clothing/import`, {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          fileName: `kleidung.${format}`,
          fileBase64: table.toString('base64'),
        }),
      });
      assert.equal(response.status, 200);
      const result = await response.json();
      assert.equal(result.imported, 1);
      assert.equal(result.skipped, 2);

      const listResponse = await fetch(`${baseUrl}/api/clothing`, {
        headers: { Authorization: `Bearer ${token}` },
      });
      const items = await listResponse.json();
      assert.ok(items.some((item) => item.inventoryNumber === `IMPORT-${format.toUpperCase()}-1`));
    } finally {
      server.close();
    }
  });
}

for (const format of ['xlsx', 'ods']) {
  test(`exports the wardrobe as ${format.toUpperCase()}`, async () => {
    const { server, baseUrl } = await startServer();
    try {
      const token = await login(baseUrl);
      const response = await fetch(`${baseUrl}/api/clothing/export?format=${format}`, {
        headers: { Authorization: `Bearer ${token}` },
      });
      assert.equal(response.status, 200);
      const result = await response.json();
      assert.match(result.fileName, new RegExp(`\\.${format}$`));

      const workbook = XLSX.read(Buffer.from(result.fileBase64, 'base64'), { type: 'buffer' });
      assert.deepEqual(workbook.SheetNames, ['Kleiderkammer', 'Hinweise']);
      const rows = XLSX.utils.sheet_to_json(workbook.Sheets.Kleiderkammer);
      assert.ok(rows.length > 0);
      assert.ok(Object.hasOwn(rows[0], 'Inventarnummer'));
      assert.ok(Object.hasOwn(rows[0], 'Name'));
    } finally {
      server.close();
    }
  });
}
