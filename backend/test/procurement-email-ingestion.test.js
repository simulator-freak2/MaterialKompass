const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');

async function start() {
  const app = createApp({ skipEmailVerification: true });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  const response = await fetch(`${baseUrl}/api/auth/login`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: 'admin@materialkompass.org', password: 'MaterialKompass2026!' }),
  });
  return { app, server, baseUrl, token: (await response.json()).token };
}

function mailWithOffer(number) {
  return Buffer.from([
    'From: DLRG Fachhandel <info@fachhandel.example>',
    'To: angebote@materialkompass.org',
    `Subject: Angebot zu ${number}`,
    'MIME-Version: 1.0',
    'Content-Type: multipart/mixed; boundary="offer-boundary"',
    '',
    '--offer-boundary',
    'Content-Type: text/plain; charset=utf-8',
    '',
    'Anbei erhalten Sie unser Angebot.',
    '--offer-boundary',
    'Content-Type: application/pdf; name="Angebot-4711.pdf"',
    'Content-Disposition: attachment; filename="Angebot-4711.pdf"',
    'Content-Transfer-Encoding: base64',
    '',
    Buffer.from('%PDF test offer').toString('base64'),
    '--offer-boundary--',
  ].join('\r\n'));
}

test('email offer appears in the procurement inbox and can be imported', async () => {
  const { app, server, baseUrl, token } = await start();
  const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
  try {
    const createdResponse = await fetch(`${baseUrl}/api/procurement`, {
      method: 'POST', headers, body: JSON.stringify({
        title: 'Rettungswesten', reason: 'Ersatzbedarf', requestedBudgetGross: 500,
        items: [{ name: 'Rettungsweste', categoryId: '04', subcategoryId: '04-04', size: 'M', quantity: 2, unit: 'Stück' }],
      }),
    });
    assert.equal(createdResponse.status, 201);
    const created = await createdResponse.json();
    await fetch(`${baseUrl}/api/procurement/${created.id}/submit`, {
      method: 'POST', headers, body: '{}',
    });

    const ingested = await app.locals.runInOrganization(
      'org-default',
      'unit-default-root',
      () => app.locals.procurementEmailService.ingestSource(
        mailWithOffer(created.number), { mailbox: 'INBOX', uid: 7 },
      ),
    );
    assert.equal(ingested.entry.requestId, created.id);
    assert.equal(ingested.entry.supplierId, 'supplier-1');
    assert.equal(ingested.entry.attachments.length, 1);

    const inboxResponse = await fetch(`${baseUrl}/api/procurement-email-inbox`, { headers });
    assert.equal(inboxResponse.status, 200);
    const inbox = await inboxResponse.json();
    assert.equal(inbox.address, 'angebote@materialkompass.org');
    assert.equal(inbox.entries[0].attachments[0].fileBase64, undefined);

    const processResponse = await fetch(
      `${baseUrl}/api/procurement-email-inbox/${ingested.entry.id}/process`,
      { method: 'POST', headers, body: JSON.stringify({
        requestId: created.id, supplierId: 'supplier-1', offerNumber: '4711',
        documentGrossTotal: '437,50',
        items: [{ requestItemId: created.items[0].id, offered: true, grossTotal: '432,50' }],
        components: [
          { kind: 'shipping', label: 'Versandkosten', operation: 'add', grossAmount: '5,00' },
          { kind: 'discount', label: 'Rabatt', operation: 'subtract', grossAmount: '0,00' },
        ],
      }) },
    );
    assert.equal(processResponse.status, 200);
    const processed = await processResponse.json();
    assert.equal(processed.offer.grossTotal, 432.5);
    assert.equal(processed.offer.calculatedGrossTotal, 437.5);
    assert.equal(processed.entry.status, 'verarbeitet');
    const afterProcess = await (await fetch(`${baseUrl}/api/procurement-email-inbox`, { headers })).json();
    assert.equal(afterProcess.entries.some((entry) => entry.id === ingested.entry.id), false);

    const detailResponse = await fetch(`${baseUrl}/api/procurement/${created.id}`, { headers });
    const detail = await detailResponse.json();
    assert.equal(detail.offers[0].sourceEmailImportId, ingested.entry.id);
    assert.equal(detail.documents[0].documentType, 'Angebot');
    assert.equal(detail.documents[0].fileName, 'Angebot-4711.pdf');
    const historyEntry = detail.history.find((entry) => entry.action === 'Angebot aus E-Mail übernommen');
    assert.match(historyEntry.details.messageText, /Anbei erhalten Sie unser Angebot/);
  } finally {
    await app.locals.procurementEmailService.stop();
    server.close();
  }
});

function mailWithDocuments() {
  const part = (name, content) => [
    '--doc-boundary',
    `Content-Type: application/pdf; name="${name}"`,
    `Content-Disposition: attachment; filename="${name}"`,
    'Content-Transfer-Encoding: base64',
    '',
    Buffer.from(content).toString('base64'),
  ];
  return Buffer.from([
    'From: Lieferant <info@fachhandel.example>',
    'To: angebote@materialkompass.org',
    'Message-ID: <docs-1@fachhandel.example>',
    'Subject: Lieferscheine und Rechnung',
    'MIME-Version: 1.0',
    'Content-Type: multipart/mixed; boundary="doc-boundary"',
    '',
    '--doc-boundary',
    'Content-Type: text/plain; charset=utf-8',
    '',
    'Anbei Lieferschein und Rechnung zu Ihren Bestellungen.',
    ...part('Lieferschein.pdf', '%PDF delivery'),
    ...part('Rechnung.pdf', '%PDF invoice'),
    '--doc-boundary--',
  ].join('\r\n'));
}

async function submittedRequest(baseUrl, headers, title) {
  const response = await fetch(`${baseUrl}/api/procurement`, {
    method: 'POST', headers, body: JSON.stringify({
      title, reason: 'Ersatzbedarf', requestedBudgetGross: 100,
      items: [{ name: 'Leine', categoryId: '04', subcategoryId: '04-04', size: 'M', quantity: 1, unit: 'Stück' }],
    }),
  });
  assert.equal(response.status, 201);
  const created = await response.json();
  await fetch(`${baseUrl}/api/procurement/${created.id}/submit`, { method: 'POST', headers, body: '{}' });
  return created;
}

test('postbox documents can be assigned per attachment to several requests', async () => {
  const { app, server, baseUrl, token } = await start();
  const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
  try {
    const first = await submittedRequest(baseUrl, headers, 'Leinen A');
    const second = await submittedRequest(baseUrl, headers, 'Leinen B');
    const closed = await submittedRequest(baseUrl, headers, 'Leinen C');
    const ingest = () => app.locals.runInOrganization('org-default', 'unit-default-root',
      () => app.locals.procurementEmailService.ingestSource(mailWithDocuments(), { mailbox: 'INBOX', uid: 9 }));
    const { entry } = await ingest();
    assert.deepEqual(entry.attachments.map((item) => item.fileName), ['Lieferschein.pdf', 'Rechnung.pdf']);
    const assign = (assignments) => fetch(`${baseUrl}/api/procurement-email-inbox/${entry.id}/assign`, {
      method: 'POST', headers, body: JSON.stringify({ assignments }),
    });

    const closedRequest = app.locals.appData.procurementRequests.find((item) => item.id === closed.id);
    closedRequest.status = 'Abgeschlossen';
    const rejected = await assign([
      { requestId: first.id, documentType: 'Lieferschein', attachmentIds: ['attachment-1'] },
      { requestId: closed.id, documentType: 'Lieferschein', attachmentIds: ['attachment-1'] },
    ]);
    assert.equal(rejected.status, 409);
    const untouched = await (await fetch(`${baseUrl}/api/procurement/${first.id}`, { headers })).json();
    assert.equal(untouched.documents.length, 0, 'eine fehlerhafte Zuweisung darf nichts übernehmen');

    const response = await assign([
      { requestId: first.id, documentType: 'Lieferschein', attachmentIds: ['attachment-1'] },
      { requestId: second.id, documentType: 'Rechnung', attachmentIds: ['attachment-1', 'attachment-2'] },
      { requestId: closed.id, documentType: 'Rechnung', attachmentIds: ['attachment-2'] },
    ]);
    assert.equal(response.status, 200);
    assert.equal((await response.json()).assignments.length, 3);

    const firstDetail = await (await fetch(`${baseUrl}/api/procurement/${first.id}`, { headers })).json();
    assert.deepEqual(firstDetail.documents.map((item) => [item.fileName, item.documentType]),
      [['Lieferschein.pdf', 'Lieferschein']]);
    const history = firstDetail.history.find((item) => item.action === 'Dokumente aus Postbox zugewiesen');
    assert.match(history.details.messageText, /Lieferschein und Rechnung/);
    assert.equal(history.details.subject, 'Lieferscheine und Rechnung');
    const secondDetail = await (await fetch(`${baseUrl}/api/procurement/${second.id}`, { headers })).json();
    assert.equal(secondDetail.documents.length, 2);
    const closedDetail = await (await fetch(`${baseUrl}/api/procurement/${closed.id}`, { headers })).json();
    assert.deepEqual(closedDetail.documents.map((item) => item.documentType), ['Rechnung']);

    const inbox = await (await fetch(`${baseUrl}/api/procurement-email-inbox`, { headers })).json();
    assert.equal(inbox.entries.some((item) => item.id === entry.id), false);
    assert.equal((await assign([{ requestId: first.id, documentType: 'Rechnung', attachmentIds: ['attachment-2'] }])).status, 404);
  } finally {
    await app.locals.procurementEmailService.stop();
    server.close();
  }
});

test('discarding a postbox email removes it', async () => {
  const { app, server, baseUrl, token } = await start();
  const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
  try {
    const { entry } = await app.locals.runInOrganization('org-default', 'unit-default-root',
      () => app.locals.procurementEmailService.ingestSource(mailWithDocuments(), { mailbox: 'INBOX', uid: 10 }));
    const response = await fetch(`${baseUrl}/api/procurement-email-inbox/${entry.id}/discard`, {
      method: 'POST', headers, body: JSON.stringify({ reason: 'Spam' }),
    });
    assert.equal(response.status, 200);
    const inbox = await (await fetch(`${baseUrl}/api/procurement-email-inbox`, { headers })).json();
    assert.equal(inbox.entries.some((item) => item.id === entry.id), false);
  } finally {
    await app.locals.procurementEmailService.stop();
    server.close();
  }
});
