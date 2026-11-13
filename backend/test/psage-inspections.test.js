const assert = require('node:assert/strict');
const test = require('node:test');
const bcrypt = require('bcryptjs');

const { createApp } = require('../src/app');
const { seedData } = require('../src/data/seed');
const { applicableChecklist } = require('../src/psage-checklists');
const { assessPsageSafety, normalizeManufactureDate } = require('../src/psage-inspections');

const ADMIN = ['admin@materialkompass.org', 'MaterialKompass2026!'];

async function startServer() {
  const roles = structuredClone(seedData.roles);
  const userForRole = (id, roleName, password) => {
    const role = roles.find((entry) => entry.name === roleName);
    return {
      id, name: roleName, username: id, email: `${id}@materialkompass.local`,
      passwordHash: bcrypt.hashSync(password, 10), roles: [roleName],
      permissions: [...role.permissions], active: true, failedLoginAttempts: 0,
      createdAt: '2026-01-01T00:00:00.000Z', lastLoginAt: null,
      emailVerifiedAt: '2026-01-01T00:00:00.000Z',
    };
  };
  const app = createApp({
    userData: {
      roles,
      users: [
        structuredClone(seedData.users[0]),
        userForRole('kleiderwart-test', 'Kleiderwart', 'Kleiderwart123!'),
        userForRole('psage-test', 'Sachkundiger PSAgE', 'Sachkundig123!'),
      ],
    },
  });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  return { app, server, baseUrl: `http://127.0.0.1:${server.address().port}` };
}

async function login(baseUrl, identifier, password) {
  const response = await fetch(`${baseUrl}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ identifier, password }),
  });
  assert.equal(response.status, 200);
  const token = (await response.json()).token;
  return {
    get: (path) => fetch(`${baseUrl}${path}`, { headers: { Authorization: `Bearer ${token}` } }),
    send: (method, path, body) => fetch(`${baseUrl}${path}`, {
      method,
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }),
  };
}

const isoToday = () => new Date().toISOString().slice(0, 10);
const yearsAgo = (years) => {
  const date = new Date();
  date.setUTCFullYear(date.getUTCFullYear() - years);
  return date.toISOString().slice(0, 10);
};

function allRatings(kind, vestType, vest, overrides = {}) {
  const checklist = applicableChecklist(kind, vestType, vest);
  const ratings = {};
  for (const section of checklist.sections) {
    for (const entry of section.items) ratings[entry.id] = { rating: 'ok', remark: '' };
  }
  return { ...ratings, ...overrides };
}

const validMeasurements = {
  gasType: 'CO2', grossMass: 130, grossTolerance: 5, gasMass: 33, gasTolerance: 2, actualMass: 164,
};

test('checklists filter swift water and automatic-only positions', () => {
  const plain = applicableChecklist('expert', 'buoyancy-aid', { swiftwaterRescue: false });
  const swift = applicableChecklist('expert', 'buoyancy-aid', { swiftwaterRescue: true });
  const ids = (checklist) => checklist.sections.flatMap((section) => section.items.map((entry) => entry.id));
  assert.ok(!ids(plain).includes('ba-swiftwater'));
  assert.ok(ids(swift).includes('ba-swiftwater'));
  const manual = applicableChecklist('expert', 'lifejacket', { releaseType: 'manual' });
  const automatic = applicableChecklist('expert', 'lifejacket', { releaseType: 'automatic' });
  assert.ok(!ids(manual).includes('lj-2.8'));
  assert.ok(ids(automatic).includes('lj-2.8'));
  assert.deepEqual(automatic.sections.map((section) => section.id), ['A', 'B', 'C', 'D', 'E']);
});

test('manufacture dates accept day, month and year precision', () => {
  assert.equal(normalizeManufactureDate('2020-05-17'), '2020-05-17');
  assert.equal(normalizeManufactureDate('2020-05'), '2020-05-01');
  assert.equal(normalizeManufactureDate('2020'), '2020-01-01');
  assert.equal(normalizeManufactureDate('2020-13-01'), null);
});

test('safety assessment blocks old, uninspected and failed vests', () => {
  const category = { psageVestType: 'lifejacket' };
  const fresh = assessPsageSafety({ item: { manufactureDate: '2024-01-01' }, category, inspections: [], now: new Date('2026-06-01') });
  assert.equal(fresh.blocked, true);
  assert.match(fresh.reasons.join(' '), /Sachkundigen/);
  const old = assessPsageSafety({
    item: { manufactureDate: '2010-01-01', nextInspectionDate: '2027-01-01' },
    category,
    inspections: [{ psageChecklist: true, kind: 'expert', ready: true, inspectionDate: '2026-01-01', createdAt: 'a' }],
    now: new Date('2026-06-01'),
  });
  assert.equal(old.blocked, true);
  assert.match(old.reasons.join(' '), /15 Jahre/);
  const ok = assessPsageSafety({
    item: { manufactureDate: '2020-01-01', nextInspectionDate: '2027-01-01' },
    category,
    inspections: [
      { psageChecklist: true, kind: 'expert', ready: true, inspectionDate: '2026-01-01', createdAt: 'a' },
    ],
    now: new Date('2026-06-01'),
  });
  assert.equal(ok.blocked, false);
  const visualFail = assessPsageSafety({
    item: { manufactureDate: '2020-01-01', nextInspectionDate: '2027-01-01' },
    category,
    inspections: [
      { psageChecklist: true, kind: 'expert', ready: true, inspectionDate: '2026-01-01', createdAt: 'a' },
      { psageChecklist: true, kind: 'visual', ready: false, inspectionDate: '2026-02-01', createdAt: 'b' },
    ],
    now: new Date('2026-06-01'),
  });
  assert.equal(visualFail.blocked, true);
  assert.equal(assessPsageSafety({ item: {}, category: {} }), null);
});

test('PSAgE checklist inspections, organisation settings, issue lock and PDF protocol', async () => {
  const { app, server } = await startServer();
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  try {
    const admin = await login(baseUrl, ...ADMIN);
    const category = await admin.send('PUT', '/api/categories/04-04', {
      name: 'Rettungswesten', parentId: '04', sizes: ['Universal'],
      inspectionIntervalMonths: 24, psageVestType: 'lifejacket',
    });
    assert.equal(category.status, 200);
    const savedCategory = await category.json();
    assert.equal(savedCategory.psageVestType, 'lifejacket');
    assert.equal(savedCategory.requiresPsageInspection, true);

    const invalidDate = await admin.send('POST', '/api/clothing', {
      name: 'Rettungsweste', categoryId: '04-04', size: 'Universal', manufactureDate: 'gestern',
    });
    assert.equal(invalidDate.status, 400);

    const created = await admin.send('POST', '/api/clothing', {
      name: 'Rettungsweste 150 N', categoryId: '04-04', size: 'Universal',
      manufactureDate: yearsAgo(3), serialNumber: 'SN-4711',
      psageReleaseType: 'automatic', psageBuoyancyNewton: 150,
    });
    assert.equal(created.status, 201);
    const vest = await created.json();
    assert.equal(vest.psageSafety.vestType, 'lifejacket');
    assert.equal(vest.psageSafety.blocked, true);

    const blockedIssue = await admin.send('POST', '/api/transactions', {
      clothingIds: [vest.id], action: 'ausgegeben', personName: 'Test Person',
    });
    assert.equal(blockedIssue.status, 409);
    assert.match((await blockedIssue.json()).error, /PSAgE/);

    const legacy = await admin.send('POST', `/api/clothing/${vest.id}/inspections`, {
      inspectionDate: isoToday(), result: 'Bestanden',
    });
    assert.equal(legacy.status, 409);

    const vestInfo = { releaseType: 'automatic' };
    const wardrobe = await login(baseUrl, 'kleiderwart-test', 'Kleiderwart123!');
    const forbidden = await wardrobe.send('POST', `/api/clothing/${vest.id}/psage-inspections`, {
      kind: 'expert', inspectionDate: isoToday(),
      ratings: allRatings('expert', 'lifejacket', vestInfo), measurements: validMeasurements,
    });
    assert.equal(forbidden.status, 403);
    const visualDisabled = await wardrobe.send('POST', `/api/clothing/${vest.id}/psage-inspections`, {
      kind: 'visual', inspectionDate: isoToday(), ratings: allRatings('visual', 'lifejacket', vestInfo),
    });
    assert.equal(visualDisabled.status, 403);

    const forbiddenSettings = await wardrobe.send('PUT', '/api/psage/settings', { visualCheckEnabled: true });
    assert.equal(forbiddenSettings.status, 403);
    const settings = await admin.send('PUT', '/api/psage/settings', {
      visualCheckEnabled: true, pdfEnabled: false, pdfArchiveRequired: true,
    });
    assert.equal(settings.status, 200);
    assert.deepEqual(
      (({ visualCheckEnabled, pdfEnabled, pdfArchiveRequired }) =>
        ({ visualCheckEnabled, pdfEnabled, pdfArchiveRequired }))(await settings.json()),
      { visualCheckEnabled: true, pdfEnabled: false, pdfArchiveRequired: false },
    );

    const expert = await login(baseUrl, 'psage-test', 'Sachkundig123!');
    const incomplete = await expert.send('POST', `/api/clothing/${vest.id}/psage-inspections`, {
      kind: 'expert', inspectionDate: isoToday(), ratings: { 'lj-4.3': 'ok' },
    });
    assert.equal(incomplete.status, 400);
    const noMass = await expert.send('POST', `/api/clothing/${vest.id}/psage-inspections`, {
      kind: 'expert', inspectionDate: isoToday(), ratings: allRatings('expert', 'lifejacket', vestInfo),
    });
    assert.equal(noMass.status, 400);

    const passed = await expert.send('POST', `/api/clothing/${vest.id}/psage-inspections`, {
      kind: 'expert', inspectionDate: isoToday(),
      ratings: allRatings('expert', 'lifejacket', vestInfo), measurements: validMeasurements,
    });
    assert.equal(passed.status, 201);
    const passedInspection = await passed.json();
    assert.equal(passedInspection.ready, true);
    assert.equal(passedInspection.measurements.expectedMass, 163);
    assert.equal(passedInspection.measurements.withinTolerance, true);
    assert.match(passedInspection.nextInspectionDate, /^\d{4}-\d{2}-\d{2}$/);
    assert.equal(passedInspection.protocolDocumentId, null);

    const pdfDisabled = await expert.get(`/api/clothing/${vest.id}/psage-inspections/${passedInspection.id}/pdf`);
    assert.equal(pdfDisabled.status, 403);

    const issued = await admin.send('POST', '/api/transactions', {
      clothingIds: [vest.id], action: 'ausgegeben', personName: 'Test Person',
    });
    assert.equal(issued.status, 201);
    await admin.send('POST', '/api/transactions', { clothingIds: [vest.id], action: 'zurückgegeben' });

    const visualFailed = await wardrobe.send('POST', `/api/clothing/${vest.id}/psage-inspections`, {
      kind: 'visual', inspectionDate: isoToday(),
      ratings: allRatings('visual', 'lifejacket', vestInfo, { 'vlj-indicators': { rating: 'ko', remark: 'Indikator rot' } }),
    });
    assert.equal(visualFailed.status, 400, 'Mängeltext ist bei nicht einsatzbereit Pflicht');
    const visualSaved = await wardrobe.send('POST', `/api/clothing/${vest.id}/psage-inspections`, {
      kind: 'visual', inspectionDate: isoToday(),
      ratings: allRatings('visual', 'lifejacket', vestInfo, { 'vlj-indicators': { rating: 'ko', remark: 'Indikator rot' } }),
      defectsText: 'Auslöseindikator rot', followUp: 'An Sachkundigen übergeben',
    });
    assert.equal(visualSaved.status, 201);
    const visual = await visualSaved.json();
    assert.equal(visual.ready, false);
    assert.equal(visual.nextInspectionDate, null);

    const list = await admin.get('/api/clothing').then((response) => response.json());
    const afterVisual = list.find((entry) => entry.id === vest.id);
    assert.equal(afterVisual.psageSafety.blocked, true);
    assert.ok(afterVisual.defects.length >= 1);

    await admin.send('PUT', '/api/psage/settings', { pdfEnabled: true, pdfArchiveRequired: true });
    const outOfTolerance = await expert.send('POST', `/api/clothing/${vest.id}/psage-inspections`, {
      kind: 'expert', inspectionDate: isoToday(),
      ratings: allRatings('expert', 'lifejacket', vestInfo),
      measurements: { ...validMeasurements, actualMass: 140 },
      followUp: 'Neue Patrone einsetzen und erneut prüfen.',
    });
    assert.equal(outOfTolerance.status, 201);
    const failed = await outOfTolerance.json();
    assert.equal(failed.ready, false);
    assert.match(failed.autoFindings.join(' '), /Toleranz/);
    assert.ok(failed.protocolDocumentId);
    assert.equal(app.locals.appData.clothingInspectionDocuments.length, 1);

    const archivedPdf = await expert.get(`/api/clothing/${vest.id}/psage-inspections/${failed.id}/pdf`);
    assert.equal(archivedPdf.status, 200);
    const archived = await archivedPdf.json();
    assert.equal(archived.archived, true);
    assert.equal(archived.mimeType, 'application/pdf');
    assert.equal(Buffer.from(archived.fileBase64, 'base64').subarray(0, 5).toString(), '%PDF-');

    const generated = await expert.get(`/api/clothing/${vest.id}/psage-inspections/${passedInspection.id}/pdf`)
      .then((response) => response.json());
    assert.equal(generated.archived, false);
    assert.equal(Buffer.from(generated.fileBase64, 'base64').subarray(0, 5).toString(), '%PDF-');

    const settingsView = await wardrobe.get('/api/psage/settings').then((response) => response.json());
    assert.equal(settingsView.canManage, false);
    assert.equal(settingsView.canInspect, false);
    assert.equal(settingsView.pdfArchiveRequired, true);
    assert.ok(settingsView.checklists.expert.lifejacket.sections.length === 5);
  } finally {
    server.close();
  }
});
