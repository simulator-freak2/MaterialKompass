const assert = require('node:assert/strict');
const test = require('node:test');

const { createDefectMailMonitor } = require('../src/defect-mail-monitor');

function messageSource(messageId = '<mail-1@example.org>') {
  return Buffer.from([
    'From: sender@example.org',
    'To: maengel@materialkompass.org',
    `Message-ID: ${messageId}`,
    'Subject: Test',
    '',
    'Test',
  ].join('\r\n'));
}

test('mail monitor imports each UID once and moves it to the processed mailbox', async () => {
  let state = {
    mailbox: 'defects:maengel@materialkompass.org:INBOX',
    uidValidity: '77',
    lastUid: 0,
  };
  const calls = [];
  const entry = { id: 'entry-1' };
  const store = {
    async getMailboxProcessingState() { return state; },
    async saveMailboxProcessingState(value) { state = { ...value }; },
  };
  const service = {
    async ingestSource(source, info) {
      calls.push(['ingest', source.toString('utf8'), info]);
      return { entry };
    },
    async updateMoved(value, info) { calls.push(['moved', value, info]); },
    async recordFailure() { throw new Error('unexpected'); },
    async stop() {},
  };
  const client = {
    usable: true,
    on() {},
    async connect() {},
    async mailboxOpen() {
      return { uidValidity: 77, uidNext: 2 };
    },
    async *fetch() {
      yield {
        uid: 1,
        source: messageSource(),
        envelope: { messageId: '<mail-1@example.org>' },
      };
    },
    async list() { return [{ path: 'Verarbeitet' }]; },
    async messageMove() { return { uidMap: new Map([[1, 101]]) }; },
    async status() { return { uidValidity: 88 }; },
    async logout() { this.usable = false; },
  };
  const monitor = createDefectMailMonitor({
    store,
    service,
    defectReports: [],
    clientFactory: () => client,
    env: {
      DEFECT_IMAP_HOST: 'imap.example.org',
      DEFECT_IMAP_USER: 'maengel@materialkompass.org',
      DEFECT_IMAP_PASSWORD: 'secret',
    },
  });

  assert.equal(await monitor.runOnce(), true);
  assert.equal(calls[0][0], 'ingest');
  assert.equal(calls[0][2].uid, 1);
  assert.equal(calls[1][0], 'moved');
  assert.deepEqual(calls[1][2], {
    mailbox: 'Verarbeitet',
    uid: 101,
    uidValidity: '88',
  });
  assert.equal(state.lastUid, 1);
});

test('archiving removes the linked source mail from the processed mailbox', async () => {
  const report = {
    archivedAt: '2026-07-27T10:00:00.000Z',
    emailSource: {
      uid: 101,
      uidValidity: '88',
      messageId: '<mail-1@example.org>',
      deleteRequestedAt: '2026-07-27T10:00:00.000Z',
    },
  };
  const deleted = [];
  let persisted = 0;
  const client = {
    async list() { return [{ path: 'Verarbeitet' }]; },
    async mailboxOpen() { return { uidValidity: 88 }; },
    async fetchOne(uid) { return { uid }; },
    async messageDelete(uids) { deleted.push(...uids); return true; },
  };
  const monitor = createDefectMailMonitor({
    store: {},
    service: { async stop() {} },
    defectReports: [report],
    persistData: async () => { persisted += 1; },
    env: {},
  });

  await monitor.deleteArchivedMessages(client);
  assert.deepEqual(deleted, [101]);
  assert.equal(report.emailSource.deleteResult, 'deleted');
  assert.ok(report.emailSource.deletedAt);
  assert.equal(persisted, 1);
});
