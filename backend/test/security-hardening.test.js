const assert = require('node:assert/strict');
const test = require('node:test');
const bcrypt = require('bcryptjs');
const XLSX = require('xlsx');
const { createApp } = require('../src/app');
const { seedData } = require('../src/data/seed');
const {
  inspectZipArchive,
  neutralizeSpreadsheetCell,
} = require('../src/security-utils');

async function startApp(options = {}) {
  const app = createApp(options);
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  return {
    app,
    server,
    baseUrl: `http://127.0.0.1:${server.address().port}`,
  };
}

test('rejected anonymous mutations do not trigger a full persistence snapshot', async () => {
  let saves = 0;
  const { server, baseUrl } = await startApp({
    dataStore: { saveCollections: async () => { saves += 1; } },
  });
  try {
    const response = await fetch(`${baseUrl}/api/clothing`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: 'Nicht autorisiert' }),
    });
    assert.equal(response.status, 401);
    await new Promise((resolve) => setImmediate(resolve));
    assert.equal(saves, 0);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('rejected async route promises return 500 without terminating the server', async () => {
  const { server, baseUrl } = await startApp({
    skipEmailVerification: true,
    userStore: { saveUser: async () => { throw new Error('database unavailable'); } },
  });
  try {
    const response = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ identifier: 'admin', password: 'MaterialKompass2026!' }),
    });
    assert.equal(response.status, 500);
    assert.equal((await fetch(`${baseUrl}/health`)).status, 200);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('personal data export exposes matching fields but not restricted records', async () => {
  const data = structuredClone(seedData);
  data.users.push({
    id: 'user-limited',
    name: 'Limitierte Person',
    username: 'limited',
    email: 'limited@example.org',
    passwordHash: bcrypt.hashSync('LimitedPass123!', 10),
    roles: ['Nutzer'],
    departmentIds: [],
    permissions: ['categories.read', 'locations.read', 'material.read', 'inventory.read', 'dashboard.read'],
    active: true,
    failedLoginAttempts: 0,
    createdAt: '2026-01-01T00:00:00.000Z',
    lastLoginAt: null,
    emailVerifiedAt: '2026-01-01T00:00:00.000Z',
  });
  data.procurementRequests.push({
    id: 'proc-secret',
    requestedByUserId: 'user-limited',
    requestedByEmail: 'limited@example.org',
    title: 'VERTRAULICHER BESCHAFFUNGSTITEL',
    reason: 'INTERNES GEHEIMNIS',
  });
  const { server, baseUrl } = await startApp({ data });
  try {
    const login = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ identifier: 'limited', password: 'LimitedPass123!' }),
    });
    const token = (await login.json()).token;
    const headers = { Authorization: `Bearer ${token}` };
    assert.equal((await fetch(`${baseUrl}/api/procurement/proc-secret`, { headers })).status, 403);
    const exported = await fetch(`${baseUrl}/api/users/me/export`, { headers });
    assert.equal(exported.status, 200);
    const body = await exported.json();
    const serialized = JSON.stringify(body);
    assert.doesNotMatch(serialized, /VERTRAULICHER BESCHAFFUNGSTITEL|INTERNES GEHEIMNIS/);
    assert.ok(body.relatedData.procurementRequests[0].matches
      .some((match) => match.path === 'requestedByUserId' && match.value === 'user-limited'));
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('department visibility does not grant ownership of another procurement draft', async () => {
  const data = structuredClone(seedData);
  const role = data.roles.find((entry) => entry.name === 'Fachbereichsleiter');
  for (const [id, username] of [['user-owner', 'owner'], ['user-colleague', 'colleague']]) {
    data.users.push({
      id,
      name: username,
      username,
      email: `${username}@example.org`,
      passwordHash: bcrypt.hashSync('LimitedPass123!', 10),
      roles: ['Fachbereichsleiter'],
      departmentIds: ['department-technik'],
      permissions: [...role.permissions],
      active: true,
      failedLoginAttempts: 0,
      createdAt: '2026-01-01T00:00:00.000Z',
      lastLoginAt: null,
      emailVerifiedAt: '2026-01-01T00:00:00.000Z',
    });
  }
  data.procurementRequests.push({
    id: 'proc-owner-check',
    number: 'BA-2026-9999',
    status: 'Entwurf',
    title: 'Eigentümertest',
    reason: 'Test',
    requestedBy: 'owner',
    requestedByEmail: 'owner@example.org',
    requestedByUserId: 'user-owner',
    departmentId: 'department-technik',
    department: 'Technik',
    requestedBudgetGross: 10,
    approvals: [],
    items: [{ id: 'item-1', name: 'Test', categoryId: '02', quantity: 1, unit: 'Stück', taxRate: 19 }],
    history: [],
  });
  const { server, baseUrl } = await startApp({ data });
  try {
    const login = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ identifier: 'colleague', password: 'LimitedPass123!' }),
    });
    const token = (await login.json()).token;
    const headers = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' };
    assert.equal((await fetch(`${baseUrl}/api/procurement/proc-owner-check`, { headers })).status, 200);
    const submitted = await fetch(`${baseUrl}/api/procurement/proc-owner-check/submit`, {
      method: 'POST', headers, body: '{}',
    });
    assert.equal(submitted.status, 403);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('spreadsheet formulas are neutralized and malformed ZIP files are rejected', () => {
  assert.equal(neutralizeSpreadsheetCell(' =HYPERLINK("https://example.invalid")'), '\' =HYPERLINK("https://example.invalid")');
  assert.equal(neutralizeSpreadsheetCell('normal'), 'normal');

  const workbook = XLSX.utils.book_new();
  XLSX.utils.book_append_sheet(workbook, XLSX.utils.aoa_to_sheet([['Wert'], ['sicher']]), 'Daten');
  const validArchive = XLSX.write(workbook, { type: 'buffer', bookType: 'xlsx' });
  assert.equal(inspectZipArchive(validArchive).error, undefined);
  assert.match(inspectZipArchive(Buffer.from('PK\u0003\u0004kein-verzeichnis')).error, /ZIP/);
});
