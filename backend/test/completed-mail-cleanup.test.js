const assert = require('node:assert/strict');
const test = require('node:test');

const { createProcurementMailMonitor } = require('../src/procurement-mail-monitor');
const { createStocktakeMailMonitor } = require('../src/stocktake-mail-monitor');

function cleanupClient({ uidValidity = 88, failDelete = false } = {}) {
  const deleted = [];
  return {
    deleted,
    async list() { return [{ path: 'Verarbeitet' }]; },
    async mailboxOpen() { return { uidValidity }; },
    async fetchOne(uid) { return { uid }; },
    async search() { return [202]; },
    async messageDelete(uids) {
      if (failDelete) throw new Error('IMAP nicht erreichbar');
      deleted.push(...uids);
      return true;
    },
  };
}

test('completed stocktakes delete every linked source mail and keep import data', async () => {
  const imports = [
    { id: 'mail-1', stocktakeId: 'stocktake-1', subject: 'Liste 1', emailSource: { uid: 101, uidValidity: '88' } },
    { id: 'mail-2', stocktakeId: 'stocktake-1', subject: 'Liste 2', emailSource: { messageId: '<mail-2@example.org>' } },
    { id: 'mail-open', stocktakeId: 'stocktake-2', emailSource: { uid: 103, uidValidity: '88' } },
  ];
  const client = cleanupClient();
  const monitor = createStocktakeMailMonitor({
    store: {}, service: { async stop() {} },
    stocktakes: [
      { id: 'stocktake-1', status: 'Abgeschlossen' },
      { id: 'stocktake-2', status: 'In Arbeit' },
    ],
    stocktakeEmailImports: imports,
    env: {},
  });

  await monitor.deleteCompletedMessages(client);

  assert.deepEqual(client.deleted, [101, 202]);
  assert.equal(imports[0].subject, 'Liste 1');
  assert.equal(imports[0].emailSource.deleteResult, 'deleted');
  assert.equal(imports[1].emailSource.deleteResult, 'deleted');
  assert.equal(imports[2].emailSource.deletedAt, undefined);
});

test('completed procurement mail deletion is retried after an IMAP error', async () => {
  const entry = {
    id: 'offer-mail-1', requestId: 'proc-1',
    emailSource: { uid: 301, uidValidity: '88' },
  };
  const errors = [];
  const monitor = createProcurementMailMonitor({
    store: {}, service: { async stop() {} },
    procurementRequests: [{ id: 'proc-1', status: 'Abgeschlossen' }],
    procurementEmailImports: [entry],
    logger: { error: (...values) => errors.push(values) },
    env: {},
  });

  await monitor.deleteCompletedMessages(cleanupClient({ failDelete: true }));
  assert.ok(entry.emailSource.deleteRequestedAt);
  assert.equal(entry.emailSource.deletedAt, undefined);
  assert.match(entry.emailSource.deleteError, /IMAP nicht erreichbar/);
  assert.equal(errors.length, 1);

  const retryClient = cleanupClient();
  await monitor.deleteCompletedMessages(retryClient);
  assert.deepEqual(retryClient.deleted, [301]);
  assert.ok(entry.emailSource.deletedAt);
  assert.equal(entry.emailSource.deleteResult, 'deleted');
  assert.equal(entry.emailSource.deleteError, undefined);
});
