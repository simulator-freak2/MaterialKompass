const assert = require('node:assert/strict');
const test = require('node:test');

const { createProcurementMailMonitor } = require('../src/procurement-mail-monitor');
const {
  createProcurementEmailService,
  releaseProcurementEmail,
} = require('../src/procurement-email-ingestion');

test('released procurement emails are deleted from the processed mailbox', async () => {
  const entries = [
    { id: 'mail-1', status: 'offen', subject: 'Rechnung', messageText: 'Geheim', attachments: [{ id: 'a', fileBase64: 'eA==' }],
      emailSource: { mailbox: 'Verarbeitet', uid: 101, messageId: '<m1@example.org>' } },
    { id: 'mail-2', status: 'offen', attachments: [],
      emailSource: { mailbox: 'Verarbeitet', uid: 102, messageId: '<m2@example.org>' } },
    { id: 'mail-3', status: 'offen', attachments: [], emailSource: { mailbox: 'Verarbeitet' } },
  ];
  releaseProcurementEmail(entries, entries[0], { mailDeletionEnabled: true });
  releaseProcurementEmail(entries, entries[2], { mailDeletionEnabled: true });
  assert.equal(entries.length, 2, 'ohne Postfach-Referenz wird sofort entfernt');
  assert.equal(entries[0].status, 'gelöscht');
  assert.equal(entries[0].messageText, undefined);
  assert.deepEqual(entries[0].attachments, []);

  const service = createProcurementEmailService({
    procurementEmailImports: entries, procurementRequests: [], suppliers: [], nextId: () => 'x',
  });
  const calls = [];
  const client = {
    usable: true,
    on() {},
    async connect() {},
    async mailboxOpen(path) { calls.push(['open', path]); return { uidValidity: 1, uidNext: 1 }; },
    async list() { return [{ path: 'INBOX' }, { path: 'Verarbeitet' }]; },
    async fetchOne(uid) { return { uid, envelope: { messageId: '<m1@example.org>' } }; },
    async search() { return []; },
    async messageDelete(uids) { calls.push(['delete', uids]); },
    async logout() { this.usable = false; },
  };
  const monitor = createProcurementMailMonitor({
    store: {
      async getMailboxProcessingState() { return { uidValidity: '1', lastUid: 0 }; },
      async saveMailboxProcessingState() {},
    },
    service,
    clientFactory: () => client,
    env: { PROCUREMENT_IMAP_HOST: 'imap.example.org' },
    logger: { error() {}, warn() {} },
  });
  assert.equal(await monitor.runOnce(), true);
  assert.deepEqual(calls.filter(([kind]) => kind === 'delete'), [['delete', [101]]]);
  assert.deepEqual(entries.map((entry) => entry.id), ['mail-2']);
});

test('failed mailbox deletions stay queued for the next run', async () => {
  const entries = [{ id: 'mail-1', status: 'offen', attachments: [],
    emailSource: { mailbox: 'Verarbeitet', uid: 5, messageId: '<m@example.org>' } }];
  releaseProcurementEmail(entries, entries[0], { mailDeletionEnabled: true });
  const service = createProcurementEmailService({
    procurementEmailImports: entries, procurementRequests: [], suppliers: [], nextId: () => 'x',
  });
  const client = {
    usable: true, on() {}, async connect() {},
    async mailboxOpen() { return { uidValidity: 1, uidNext: 1 }; },
    async list() { return [{ path: 'Verarbeitet' }]; },
    async fetchOne(uid) { return { uid, envelope: { messageId: '<m@example.org>' } }; },
    async messageDelete() { throw new Error('IMAP nicht erreichbar'); },
    async logout() { this.usable = false; },
  };
  const monitor = createProcurementMailMonitor({
    store: { async getMailboxProcessingState() { return { uidValidity: '1', lastUid: 0 }; }, async saveMailboxProcessingState() {} },
    service, clientFactory: () => client, env: { PROCUREMENT_IMAP_HOST: 'imap.example.org' },
    logger: { error() {}, warn() {} },
  });
  await monitor.runOnce();
  assert.equal(entries.length, 1);
  assert.equal(entries[0].emailSource.deleteError, 'IMAP nicht erreichbar');
});
