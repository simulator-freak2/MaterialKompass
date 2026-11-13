const assert = require('node:assert/strict');
const test = require('node:test');

const { createProcurementMailMonitor } = require('../src/procurement-mail-monitor');
const { createStocktakeMailMonitor } = require('../src/stocktake-mail-monitor');
const { createProcurementEmailService } = require('../src/procurement-email-ingestion');
const { createStocktakeEmailService } = require('../src/stocktake-email-ingestion');

function fakeClient({ uidNext, available }) {
  const calls = [];
  return {
    calls,
    usable: true,
    on() {},
    async connect() {},
    async mailboxOpen() { return { uidValidity: 9, uidNext }; },
    async *fetch(range, query) {
      calls.push(['fetch', range, Boolean(query.source)]);
      const [first, last] = range.split(':').map(Number);
      for (const uid of available) {
        if (uid >= first && uid <= last) yield { uid, envelope: { messageId: `<m${uid}@example.org>` } };
      }
    },
    async fetchOne(uid, query) {
      calls.push(['fetchOne', uid, Boolean(query.source)]);
      return { uid, source: Buffer.from(`Subject: ${uid}\r\n\r\nText`) };
    },
    async list() { return [{ path: 'Verarbeitet' }]; },
    async messageMove() { return { uidMap: new Map() }; },
    async logout() {},
  };
}

for (const [label, createMonitor, prefix] of [
  ['procurement', createProcurementMailMonitor, 'PROCUREMENT'],
  ['stocktake', createStocktakeMailMonitor, 'INVENTORY'],
]) {
  test(`${label} mail monitor processes a bounded batch one source at a time`, async () => {
    let state = { mailbox: 'x', uidValidity: '9', lastUid: 0 };
    const client = fakeClient({ uidNext: 1000, available: [1, 2, 3, 5, 6, 900] });
    const ingested = [];
    const monitor = createMonitor({
      store: {
        async getMailboxProcessingState() { return state; },
        async saveMailboxProcessingState(value) { state = { ...value }; },
      },
      service: {
        async ingestSource(source, info) { ingested.push(info.uid); return { entry: {} }; },
        async recordFailure() { return {}; },
        async updateMoved() {},
        async stop() {},
      },
      clientFactory: () => client,
      env: { [`${prefix}_IMAP_HOST`]: 'imap.example.org', [`${prefix}_IMAP_BATCH_SIZE`]: '5' },
      logger: { error() {}, log() {} },
    });
    assert.equal(await monitor.runOnce(), true);
    assert.deepEqual(client.calls[0], ['fetch', '1:5', false]);
    assert.deepEqual(ingested, [1, 2, 3, 5]);
    assert.equal(state.lastUid, 5);
    assert.ok(client.calls.filter(([kind]) => kind === 'fetchOne').every(([, , source]) => source));

    await monitor.runOnce();
    const fetches = client.calls.filter(([kind]) => kind === 'fetch');
    assert.deepEqual(fetches, [['fetch', '1:5', false], ['fetch', '6:10', false]]);
    assert.deepEqual(ingested, [1, 2, 3, 5, 6]);
    // UID gaps still advance to the end of the bounded range.
    assert.equal(state.lastUid, 10);
  });
}

function mailWithAttachment(bytes) {
  const content = Buffer.alloc(bytes, 1).toString('base64');
  return Buffer.from([
    'From: lieferant@example.org',
    'Subject: Angebot',
    'MIME-Version: 1.0',
    'Content-Type: multipart/mixed; boundary="b"',
    '',
    '--b',
    'Content-Type: text/plain',
    '',
    'Hallo',
    '--b',
    'Content-Type: application/pdf; name="a.pdf"',
    'Content-Disposition: attachment; filename="a.pdf"',
    'Content-Transfer-Encoding: base64',
    '',
    content,
    '--b--',
    '',
  ].join('\r\n'));
}

test('mail ingestion services refuse new imports beyond storage and record limits', async () => {
  const big = Buffer.alloc(4 * 1024 * 1024).toString('base64');
  const filled = Array.from({ length: 64 }, (_, index) => ({
    id: `e${index}`, attachments: [{ fileBase64: big }],
  }));
  const nextId = (prefix, list) => `${prefix}-${list.length + 1}`;
  const procurement = createProcurementEmailService({
    procurementEmailImports: [...filled], procurementRequests: [], suppliers: [], nextId,
  });
  await assert.rejects(procurement.ingestSource(mailWithAttachment(1024)), /Speicherlimit/);
  const stocktake = createStocktakeEmailService({
    stocktakeEmailImports: [...filled], stocktakes: [], nextId,
  });
  await assert.rejects(stocktake.ingestSource(mailWithAttachment(1024)), /Speicherlimit/);

  const many = Array.from({ length: 10_000 }, (_, index) => ({ id: `e${index}`, attachments: [] }));
  const full = createProcurementEmailService({
    procurementEmailImports: many, procurementRequests: [], suppliers: [], nextId,
  });
  await assert.rejects(full.ingestSource(mailWithAttachment(10)), /maximale Anzahl/);
  await full.recordFailure({}, new Error('x'));
  assert.equal(many.length, 10_000);

  const empty = [];
  const ok = createProcurementEmailService({
    procurementEmailImports: empty, procurementRequests: [], suppliers: [], nextId,
  });
  const { entry } = await ok.ingestSource(mailWithAttachment(1024));
  assert.equal(entry.attachments.length, 1);
  assert.equal(empty.length, 1);
});
