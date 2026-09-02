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

    const ingested = await app.locals.procurementEmailService.ingestSource(
      mailWithOffer(created.number), { mailbox: 'INBOX', uid: 7 },
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

    const detailResponse = await fetch(`${baseUrl}/api/procurement/${created.id}`, { headers });
    const detail = await detailResponse.json();
    assert.equal(detail.offers[0].sourceEmailImportId, ingested.entry.id);
    assert.equal(detail.documents[0].documentType, 'Angebot');
    assert.equal(detail.documents[0].fileName, 'Angebot-4711.pdf');
  } finally {
    await app.locals.procurementEmailService.stop();
    server.close();
  }
});
