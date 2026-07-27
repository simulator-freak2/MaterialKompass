const assert = require('node:assert/strict');
const test = require('node:test');
const bcrypt = require('bcryptjs');
const { PDFDocument } = require('pdf-lib');

const { createApp } = require('../src/app');
const { seedData } = require('../src/data/seed');
const { generateDefectReportPdf } = require('../src/defect-report-template');
const { renderPdfPages } = require('../src/defect-email-ingestion');

function createMaterialUser() {
  const role = seedData.roles.find((entry) => entry.name === 'Materialwart');
  return {
    id: 'user-materialwart',
    name: 'Mara Materialwart',
    username: 'materialwart',
    email: 'mara@example.org',
    passwordHash: bcrypt.hashSync('Material123!', 10),
    roles: ['Materialwart'],
    permissions: [...role.permissions],
    active: true,
    failedLoginAttempts: 0,
    createdAt: '2026-01-01T00:00:00.000Z',
    emailVerifiedAt: '2026-01-01T00:00:00.000Z',
  };
}

async function filledReportPdf({
  inventoryNumber = '10050035-02-02-001',
  name = 'Erika Beispiel',
  email = 'erika@example.org',
  description = 'Kettenschutz ist gebrochen und kann nicht verriegelt werden.',
} = {}) {
  const template = await generateDefectReportPdf();
  const document = await PDFDocument.load(template);
  const form = document.getForm();
  form.getTextField('Inventarnummer').setText(inventoryNumber);
  form.getTextField('Name').setText(name);
  form.getTextField('E-Mailadresse').setText(email);
  form.getTextField('Beschreibung_des_Mangels').setText(description);
  form.getCheckBox('Nicht_einsatzfaehig').check();
  form.updateFieldAppearances();
  return Buffer.from(await document.save({ useObjectStreams: false }));
}

function mailWithAttachment(pdf, body = 'Bitte den beigefügten Mangel bearbeiten.') {
  const boundary = 'materialkompass-test-boundary';
  return Buffer.from([
    'From: Erika Beispiel <erika@example.org>',
    'To: maengel@materialkompass.org',
    'Subject: Mangel an Kettensäge',
    'Message-ID: <defect-email-test@example.org>',
    'MIME-Version: 1.0',
    `Content-Type: multipart/mixed; boundary="${boundary}"`,
    '',
    `--${boundary}`,
    'Content-Type: text/plain; charset=utf-8',
    '',
    body,
    `--${boundary}`,
    'Content-Type: application/pdf',
    'Content-Disposition: attachment; filename="maengelbericht.pdf"',
    'Content-Transfer-Encoding: base64',
    '',
    pdf.toString('base64').match(/.{1,76}/g).join('\r\n'),
    `--${boundary}--`,
    '',
  ].join('\r\n'));
}

function mailWithImages(images) {
  const boundary = 'materialkompass-image-test-boundary';
  const lines = [
    'From: Erika Beispiel <erika@example.org>',
    'To: maengel@materialkompass.org',
    'Subject: Fotografierter Mängelbericht',
    'Message-ID: <defect-image-email-test@example.org>',
    'MIME-Version: 1.0',
    `Content-Type: multipart/mixed; boundary="${boundary}"`,
    '',
    `--${boundary}`,
    'Content-Type: text/plain; charset=utf-8',
    '',
    'Fotografierter Bericht im Anhang.',
  ];
  images.forEach((image, index) => {
    lines.push(
      `--${boundary}`,
      'Content-Type: image/png',
      `Content-Disposition: attachment; filename="bericht-${index + 1}.png"`,
      'Content-Transfer-Encoding: base64',
      '',
      image.toString('base64').match(/.{1,76}/g).join('\r\n'),
    );
  });
  lines.push(`--${boundary}--`, '');
  return Buffer.from(lines.join('\r\n'));
}

async function login(baseUrl) {
  const response = await fetch(`${baseUrl}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ identifier: 'materialwart', password: 'Material123!' }),
  });
  assert.equal(response.status, 200);
  return (await response.json()).token;
}

test('digital email report is recognized, created and keeps report plus email body', async () => {
  const data = structuredClone(seedData);
  const materialUser = createMaterialUser();
  const app = createApp({
    data,
    userData: {
      roles: structuredClone(seedData.roles),
      users: [structuredClone(seedData.users[0]), materialUser],
    },
  });
  const reportPdf = await filledReportPdf();
  const result = await app.locals.defectEmailService.ingestSource(mailWithAttachment(reportPdf), {
    mailbox: 'INBOX',
    uid: 23,
    uidValidity: '10',
    processedMailbox: 'Verarbeitet',
  });
  assert.equal(result.entry.status, 'processed');
  assert.ok(result.entry.defectId);
  assert.equal(data.defectReports.length, 0, 'createApp clones supplied data');

  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  try {
    const baseUrl = `http://127.0.0.1:${server.address().port}`;
    const token = await login(baseUrl);
    const response = await fetch(`${baseUrl}/api/defects/${result.entry.defectId}`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    assert.equal(response.status, 200);
    const defect = await response.json();
    assert.equal(defect.inventoryNumber, '10050035-02-02-001');
    assert.equal(defect.contactName, 'Erika Beispiel');
    assert.equal(defect.contactEmail, 'erika@example.org');
    assert.equal(defect.operationalSafety, 'Nicht einsatzfähig');
    assert.equal(defect.documents.length, 1);
    assert.equal(defect.documents[0].mimeType, 'application/pdf');
    assert.ok(defect.documents[0].fileBase64);
    assert.equal(defect.comments.length, 1);
    assert.match(defect.comments[0].text, /beigefügten Mangel/);
    assert.equal(defect.emailSource.mailbox, 'INBOX');
  } finally {
    server.close();
    await app.locals.defectEmailService.stop();
  }
});

test('template download supports blank and item-prefilled variants', async () => {
  const materialUser = createMaterialUser();
  const app = createApp({
    userData: {
      roles: structuredClone(seedData.roles),
      users: [structuredClone(seedData.users[0]), materialUser],
    },
  });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  try {
    const baseUrl = `http://127.0.0.1:${server.address().port}`;
    const token = await login(baseUrl);
    const headers = { Authorization: `Bearer ${token}` };
    const blankResponse = await fetch(`${baseUrl}/api/defect-report-template`, { headers });
    assert.equal(blankResponse.status, 200);
    const blank = await blankResponse.json();
    const blankPdf = await PDFDocument.load(Buffer.from(blank.fileBase64, 'base64'));
    assert.equal(blankPdf.getForm().getTextField('Inventarnummer').getText() || '', '');

    const filledResponse = await fetch(
      `${baseUrl}/api/defect-report-template?entityType=MaterialItem&entityId=material-1`,
      { headers },
    );
    assert.equal(filledResponse.status, 200);
    const filled = await filledResponse.json();
    const filledPdf = await PDFDocument.load(Buffer.from(filled.fileBase64, 'base64'));
    assert.equal(filledPdf.getForm().getTextField('Inventarnummer').getText(), '10050035-02-02-001');
    assert.equal(filledPdf.getForm().getTextField('Name').getText(), 'Mara Materialwart');
    assert.equal(filledPdf.getForm().getTextField('E-Mailadresse').getText(), 'mara@example.org');
  } finally {
    server.close();
    await app.locals.defectEmailService.stop();
  }
});

test('incomplete report waits for review and can be completed through the queue API', async () => {
  const materialUser = createMaterialUser();
  const app = createApp({
    userData: {
      roles: structuredClone(seedData.roles),
      users: [structuredClone(seedData.users[0]), materialUser],
    },
  });
  const incomplete = await filledReportPdf({ description: '' });
  const result = await app.locals.defectEmailService.ingestSource(
    mailWithAttachment(incomplete),
    { mailbox: 'INBOX', uid: 25, uidValidity: '10' },
  );
  assert.equal(result.entry.status, 'pending');
  assert.ok(result.entry.problems.some((problem) => /Beschreibung/.test(problem)));

  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  try {
    const baseUrl = `http://127.0.0.1:${server.address().port}`;
    const token = await login(baseUrl);
    const headers = {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    };
    const queue = await fetch(`${baseUrl}/api/defect-email-imports`, { headers })
      .then((response) => response.json());
    assert.equal(queue.length, 1);
    const processed = await fetch(
      `${baseUrl}/api/defect-email-imports/${result.entry.id}/process`,
      {
        method: 'POST',
        headers,
        body: JSON.stringify({
          inventoryNumber: '10050035-02-02-001',
          description: 'Schutz ist gebrochen.',
          operationalSafety: 'Nicht einsatzfähig',
          contactName: 'Erika Beispiel',
          contactEmail: 'erika@example.org',
        }),
      },
    );
    assert.equal(processed.status, 201);
    assert.equal(result.entry.status, 'processed');
  } finally {
    server.close();
    await app.locals.defectEmailService.stop();
  }
});

test('locally rendered scans are recognized as report pages rather than damage photos', async () => {
  const app = createApp();
  const reportPdf = await filledReportPdf();
  const pages = await renderPdfPages(reportPdf);
  const result = await app.locals.defectEmailService.ingestSource(mailWithImages(pages), {
    mailbox: 'INBOX',
    uid: 24,
    uidValidity: '10',
    processedMailbox: 'Verarbeitet',
  });
  assert.ok(result.entry.attachments.length >= 2);
  assert.ok(result.entry.attachments.every((attachment) => attachment.role === 'report'));
  assert.ok(!result.entry.problems.some((problem) => /Kein Mängelbericht/.test(problem)));
  await app.locals.defectEmailService.stop();
});
