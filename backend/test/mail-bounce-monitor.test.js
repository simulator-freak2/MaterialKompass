const test = require('node:test');
const assert = require('node:assert/strict');

const {
  analyzeBounce,
  createMailBounceMonitor,
  forwardingRecipients,
} = require('../src/mail-bounce-monitor');

function dsn({ status = '5.1.1', action = 'failed', deliveryId = '11111111-1111-4111-8111-111111111111' } = {}) {
  return Buffer.from([
    'From: Mail Delivery System <Mailer-Daemon@example.org>',
    'To: noreply@materialkompass.org',
    'Subject: Mail delivery failed: returning message to sender',
    'MIME-Version: 1.0',
    'Content-Type: text/plain; charset=utf-8',
    '',
    `Action: ${action}`,
    `Status: ${status}`,
    'Final-Recipient: rfc822; unconfirmed@example.org',
    'Diagnostic-Code: smtp; 550 5.1.1 User unknown',
    `X-MaterialKompass-Delivery-ID: ${deliveryId}`,
  ].join('\r\n'));
}

test('only permanent mail-system failures are classified as bounces', async () => {
  assert.equal((await analyzeBounce(dsn())).permanent, true);
  assert.equal((await analyzeBounce(dsn({ status: '4.2.0', action: 'delayed' }))).permanent, false);
  const unrelated = Buffer.from('From: person@example.org\r\nSubject: 550 reasons\r\n\r\nStatus: 5.1.1');
  assert.equal((await analyzeBounce(unrelated)).permanent, false);
});

test('the active creator receives a bounce and managers are the fallback', () => {
  const users = [
    { id: 'creator', active: true, email: 'creator@example.org', permissions: ['users.write'] },
    { id: 'admin', active: true, email: 'admin@example.org', roles: ['Admin'] },
  ];
  assert.deepEqual(forwardingRecipients({ createdByUserId: 'creator' }, users),
    ['creator@example.org']);
  users[0].active = false;
  assert.deepEqual(forwardingRecipients({ createdByUserId: 'creator' }, users),
    ['admin@example.org']);
});

test('first mailbox connection records a watermark without processing old mail', async () => {
  let fetched = false;
  let saved;
  const client = {
    usable: true,
    async connect() {},
    async mailboxOpen() { return { uidValidity: 42n, uidNext: 8 }; },
    async *fetch() { fetched = true; },
    async logout() { this.usable = false; },
    close() {},
  };
  const monitor = createMailBounceMonitor({
    store: {
      async getMailboxProcessingState() { return null; },
      async saveMailboxProcessingState(state) { saved = state; },
    },
    users: [],
    env: { IMAP_HOST: 'imap.example.org', IMAP_USER: 'noreply@materialkompass.org' },
    clientFactory: () => client,
    logger: { log() {}, error() {} },
  });

  assert.equal(await monitor.runOnce(), true);
  assert.equal(fetched, false);
  assert.equal(saved.lastUid, 7);
});

test('a matched permanent verification bounce is forwarded before deletion', async () => {
  const source = dsn();
  const calls = [];
  const state = {
    mailbox: 'noreply@materialkompass.org:INBOX',
    uidValidity: '42',
    lastUid: 10,
    initializedAt: new Date(),
  };
  const store = {
    async getMailboxProcessingState() { return state; },
    async saveMailboxProcessingState(next) { Object.assign(state, next); },
    async findVerificationMailDelivery(reference) {
      calls.push(['lookup', reference]);
      return {
        id: reference.deliveryId,
        createdByUserId: 'creator',
        recipientEmail: 'unconfirmed@example.org',
        bounceForwardedAt: null,
      };
    },
    async markAccountMailBounceForwarded(id) { calls.push(['marked', id]); },
  };
  const client = {
    usable: true,
    async connect() {},
    async mailboxOpen() { return { uidValidity: 42n, uidNext: 12 }; },
    async *fetch() { yield { uid: 11, source }; },
    async messageDelete(uid, options) {
      calls.push(['deleted', uid, options]);
      return true;
    },
    async logout() { this.usable = false; },
    close() {},
  };
  const monitor = createMailBounceMonitor({
    store,
    users: [{ id: 'creator', active: true, email: 'creator@example.org' }],
    env: { IMAP_HOST: 'imap.example.org', IMAP_USER: 'noreply@materialkompass.org' },
    clientFactory: () => client,
    mailSender: async (mail) => {
      calls.push(['forwarded', mail]);
      return { messageId: '<forwarded@example.org>' };
    },
    logger: { log() {}, error() {} },
  });

  assert.equal(await monitor.runOnce(), true);
  const forwarded = calls.find(([name]) => name === 'forwarded')[1];
  assert.deepEqual(forwarded.to, ['creator@example.org']);
  assert.equal(forwarded.attachments[0].content.equals(source), true);
  assert.deepEqual(calls.map(([name]) => name), ['lookup', 'forwarded', 'marked', 'deleted']);
  assert.equal(state.lastUid, 11);
});

test('a failed forwarding attempt leaves the original bounce untouched for retry', async () => {
  const state = {
    mailbox: 'noreply@materialkompass.org:INBOX',
    uidValidity: '42',
    lastUid: 10,
    initializedAt: new Date(),
  };
  let deleted = false;
  const client = {
    usable: true,
    async connect() {},
    async mailboxOpen() { return { uidValidity: 42n, uidNext: 12 }; },
    async *fetch() { yield { uid: 11, source: dsn() }; },
    async messageDelete() { deleted = true; return true; },
    async logout() { this.usable = false; },
    close() {},
  };
  const monitor = createMailBounceMonitor({
    store: {
      async getMailboxProcessingState() { return state; },
      async saveMailboxProcessingState() {},
      async findVerificationMailDelivery() {
        return {
          id: 'delivery',
          createdByUserId: 'creator',
          recipientEmail: 'unconfirmed@example.org',
        };
      },
      async markAccountMailBounceForwarded() {},
    },
    users: [{ id: 'creator', active: true, email: 'creator@example.org' }],
    env: { IMAP_HOST: 'imap.example.org', IMAP_USER: 'noreply@materialkompass.org' },
    clientFactory: () => client,
    mailSender: async () => { throw new Error('SMTP unavailable'); },
    logger: { log() {}, error() {} },
  });

  await assert.rejects(monitor.runOnce(), /SMTP unavailable/);
  assert.equal(deleted, false);
  assert.equal(state.lastUid, 10);
});
