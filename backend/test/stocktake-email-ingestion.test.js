const assert = require('node:assert/strict');
const test = require('node:test');
const { createStocktakeEmailService } = require('../src/stocktake-email-ingestion');

test('inventory mailbox links scanned lists by stocktake id and keeps attachments for review', async () => {
  const imports = []; let persisted = 0;
  const service = createStocktakeEmailService({
    stocktakeEmailImports: imports,
    stocktakes: [{ id: 'stocktake-7', name: 'Jahresinventur' }],
    nextId: (prefix, entries) => `${prefix}-${entries.length + 1}`,
    persistData: async () => { persisted += 1; },
  });
  const source = Buffer.from([
    'From: Zaehler <zaehler@example.org>',
    'To: inventur@materialkompass.org',
    'Subject: Ausgefuellte Liste stocktake-7',
    'MIME-Version: 1.0',
    'Content-Type: multipart/mixed; boundary="test-boundary"',
    '', '--test-boundary', 'Content-Type: text/plain; charset=utf-8', '',
    'Anbei die unterschriebene Liste.', '--test-boundary',
    'Content-Type: application/pdf; name="stocktake-7.pdf"',
    'Content-Disposition: attachment; filename="stocktake-7.pdf"',
    'Content-Transfer-Encoding: base64', '', Buffer.from('%PDF-1.4 test').toString('base64'),
    '--test-boundary--', '',
  ].join('\r\n'));
  const result = await service.ingestSource(source, { uid: 5, mailbox: 'INBOX' });
  assert.equal(result.entry.stocktakeId, 'stocktake-7');
  assert.equal(result.entry.status, 'offen');
  assert.equal(result.entry.attachments.length, 1);
  assert.equal(Buffer.from(result.entry.attachments[0].fileBase64, 'base64').subarray(0, 4).toString(), '%PDF');
  assert.equal(persisted, 1);
});

test('inventory mailbox keeps unassigned mails visible for chair review', async () => {
  const imports = [];
  const service = createStocktakeEmailService({
    stocktakeEmailImports: imports, stocktakes: [],
    nextId: (prefix) => `${prefix}-1`,
  });
  const result = await service.ingestSource(Buffer.from([
    'From: unknown@example.org', 'To: inventur@materialkompass.org',
    'Subject: Inventurliste', '', 'Keine Zuordnung',
  ].join('\r\n')));
  assert.equal(result.entry.status, 'unzugeordnet');
  assert.match(result.entry.problem, /Keine Inventur-ID/);
});
