const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');
const { seedData } = require('../src/data/seed');
const { createImapMessageDeleter } = require('../src/imap-message-deleter');

test('IMAP deleter expunges the exact UID from the processed mailbox', async () => {
  const calls = [];
  const client = {
    usable: true,
    connect: async () => calls.push('connect'),
    mailboxOpen: async (mailbox) => {
      calls.push(['open', mailbox]);
      return { uidValidity: '42' };
    },
    fetchOne: async (uid) => ({ uid }),
    messageDelete: async (uids, options) => {
      calls.push(['delete', uids, options]);
      return true;
    },
    logout: async () => calls.push('logout'),
    close: () => {},
  };
  const deleter = createImapMessageDeleter({ clientFactory: () => client });
  await deleter.deleteMessage({ mailbox: 'Verarbeitet', uid: 17, uidValidity: '42' });
  assert.deepEqual(calls, [
    'connect', ['open', 'Verarbeitet'], ['delete', [17], { uid: true }], 'logout',
  ]);
});

async function start({ failProcurementDelete = false } = {}) {
  const data = structuredClone(seedData);
  data.defectEmailImports = [{
    id: 'defect-email-1', status: 'pending', subject: 'Mangel', sender: 'a@example.org',
    attachments: [], problems: [], extractedData: { entityType: 'MaterialItem' },
    emailSource: { messageId: '<defect@example.org>' },
    processedMailbox: 'Verarbeitet', processedUid: 11, processedUidValidity: '21',
  }];
  data.stocktakeEmailImports = [{
    id: 'stocktake-email-1', stocktakeId: null, status: 'unzugeordnet',
    sender: 'b@example.org', subject: 'Inventur', attachments: [],
    emailSource: { mailbox: 'Verarbeitet', uid: 12, uidValidity: '22' },
  }];
  data.procurementEmailImports = [{
    id: 'procurement-email-1', requestId: null, status: 'offen',
    sender: 'c@example.org', subject: 'Angebot', attachments: [],
    emailSource: { mailbox: 'Verarbeitet', uid: 13, uidValidity: '23' },
  }];
  const deleted = [];
  const deleter = (mailbox) => ({
    deleteMessage: async (source) => {
      if (mailbox === 'procurement' && failProcurementDelete) {
        throw new Error('IMAP nicht erreichbar');
      }
      deleted.push({ mailbox, source });
    },
  });
  const app = createApp({
    data,
    skipEmailVerification: true,
    mailDeleters: {
      defects: deleter('defects'),
      stocktakes: deleter('stocktakes'),
      procurement: deleter('procurement'),
    },
  });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  const login = await fetch(`${baseUrl}/api/auth/login`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      email: 'admin@materialkompass.org', password: 'MaterialKompass2026!',
    }),
  });
  const token = (await login.json()).token;
  return {
    app, server, baseUrl, deleted,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
  };
}

test('discard permanently deletes mail and removes app entries in all three inboxes', async () => {
  const { app, server, baseUrl, headers, deleted } = await start();
  try {
    const requests = [
      ['/api/defect-email-imports/defect-email-1/discard', 'defects'],
      ['/api/stocktake-email-imports/stocktake-email-1/discard', 'stocktakes'],
      ['/api/procurement-email-inbox/procurement-email-1/discard', 'procurement'],
    ];
    for (const [path] of requests) {
      const response = await fetch(`${baseUrl}${path}`, {
        method: 'POST', headers, body: JSON.stringify({ reason: 'Nicht benötigt' }),
      });
      assert.equal(response.status, 200, await response.text());
    }
    assert.deepEqual(deleted.map((entry) => entry.mailbox), requests.map((entry) => entry[1]));
    assert.equal(app.locals.defectEmailService.list().length, 0);
    assert.equal(app.locals.stocktakeEmailImports.length, 0);
    assert.equal(app.locals.procurementEmailImports.length, 0);
  } finally {
    await app.locals.defectEmailService.stop();
    server.close();
  }
});

test('discard keeps the app entry and reports an error when IMAP deletion fails', async () => {
  const { app, server, baseUrl, headers } = await start({ failProcurementDelete: true });
  try {
    const response = await fetch(
      `${baseUrl}/api/procurement-email-inbox/procurement-email-1/discard`,
      { method: 'POST', headers, body: JSON.stringify({ reason: 'Nicht benötigt' }) },
    );
    assert.equal(response.status, 502);
    assert.match((await response.json()).error, /bleibt erhalten/);
    assert.equal(app.locals.procurementEmailImports.length, 1);
    assert.equal(app.locals.procurementEmailImports[0].status, 'offen');
  } finally {
    await app.locals.defectEmailService.stop();
    server.close();
  }
});
