const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');
const { seedData } = require('../src/data/seed');

async function setup({ platformAdmin = true } = {}) {
  const data = structuredClone(seedData);
  data.users.find((user) => user.id === 'user-admin').platformAdmin = platformAdmin;
  const app = createApp({ data });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  const request = async (path, { method = 'GET', token, body } = {}) => {
    const response = await fetch(`${baseUrl}${path}`, {
      method,
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return {
      response,
      data: response.status === 204 ? null : await response.json(),
    };
  };
  const login = await request('/api/auth/login', {
    method: 'POST',
    body: { identifier: 'admin', password: 'MaterialKompass2026!' },
  });
  return { server, baseUrl, request, token: login.data.token };
}

function records(backup, name) {
  return backup.sections.find((section) => section.name === name)?.records;
}

test('organization administrators cannot export or replace platform-wide backups', async () => {
  const { server, request, token } = await setup({ platformAdmin: false });
  try {
    const exported = await request('/api/system/backup/export', {
      method: 'POST',
      token,
      body: { currentPassword: 'MaterialKompass2026!' },
    });
    assert.equal(exported.response.status, 403);
    assert.match(exported.data.error, /Plattformadministratoren/);

    const imported = await request('/api/system/backup/import', {
      method: 'POST',
      token,
      body: {
        currentPassword: 'MaterialKompass2026!',
        confirmation: 'ALLE DATEN ERSETZEN',
        backup: {},
      },
    });
    assert.equal(imported.response.status, 403);
    assert.match(imported.data.error, /Plattformadministratoren/);
  } finally {
    server.close();
  }
});

test('backup import authenticates before parsing the large JSON body', async () => {
  const { server, baseUrl } = await setup();
  try {
    const response = await fetch(`${baseUrl}/api/system/backup/import`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: '{',
    });
    assert.equal(response.status, 401);
  } finally {
    server.close();
  }
});

test('admin can export and restore the complete application data', async () => {
  const { server, request, token } = await setup();
  try {
    const rejected = await request('/api/system/backup/export', {
      method: 'POST',
      token,
      body: { currentPassword: 'falsch' },
    });
    assert.equal(rejected.response.status, 403);

    const exported = await request('/api/system/backup/export', {
      method: 'POST',
      token,
      body: { currentPassword: 'MaterialKompass2026!' },
    });
    assert.equal(exported.response.status, 200);
    assert.equal(exported.data.format, 'MaterialKompass Gesamtdatensicherung');
    assert.equal(exported.data.schemaVersion, 3);
    assert.ok(Array.isArray(exported.data.editInstructions));
    assert.ok(records(exported.data, 'users')[0].passwordHash);
    const serializedBackup = JSON.stringify(exported.data);
    assert.doesNotMatch(serializedBackup, /admin@materialkompass\.org/);
    assert.doesNotMatch(serializedBackup, /Admin User/);
    assert.doesNotMatch(serializedBackup, /"username":"admin"/);
    assert.ok(records(exported.data, 'materials').some((entry) => entry.id === 'material-1'));
    assert.ok(records(exported.data, 'auditLogs').some((entry) => entry.entity === 'DataBackup'));

    const created = await request('/api/categories', {
      method: 'POST',
      token,
      body: { id: '99', name: 'Nur nach Export', parentId: null },
    });
    assert.equal(created.response.status, 201);

    const imported = await request('/api/system/backup/import', {
      method: 'POST',
      token,
      body: {
        currentPassword: 'MaterialKompass2026!',
        confirmation: 'ALLE DATEN ERSETZEN',
        backup: exported.data,
      },
    });
    assert.equal(imported.response.status, 200);
    assert.equal(imported.data.reauthenticationRequired, true);

    const categories = await request('/api/categories', { token });
    assert.equal(categories.response.status, 200);
    assert.equal(categories.data.some((entry) => entry.id === '99'), false);
  } finally {
    server.close();
  }
});

test('backup import rejects incomplete data and backups without an active admin', async () => {
  const { server, request, token } = await setup();
  try {
    const exported = await request('/api/system/backup/export', {
      method: 'POST',
      token,
      body: { currentPassword: 'MaterialKompass2026!' },
    });
    records(exported.data, 'users').forEach((user) => { user.active = false; });
    const imported = await request('/api/system/backup/import', {
      method: 'POST',
      token,
      body: {
        currentPassword: 'MaterialKompass2026!',
        confirmation: 'ALLE DATEN ERSETZEN',
        backup: exported.data,
      },
    });
    assert.equal(imported.response.status, 400);
    assert.match(imported.data.error, /keinen aktiven Admin/);
  } finally {
    server.close();
  }
});

test('editable backup sections can omit optional data and legacy v2 remains importable', async () => {
  const { server, request, token } = await setup();
  try {
    const exported = await request('/api/system/backup/export', {
      method: 'POST', token, body: { currentPassword: 'MaterialKompass2026!' },
    });
    const materialSection = exported.data.sections.find((section) => section.name === 'materials');
    materialSection.enabled = false;
    delete materialSection.records;
    const imported = await request('/api/system/backup/import', {
      method: 'POST', token,
      body: {
        currentPassword: 'MaterialKompass2026!',
        confirmation: 'ALLE DATEN ERSETZEN',
        backup: exported.data,
      },
    });
    assert.equal(imported.response.status, 200);
    assert.deepEqual((await request('/api/material', { token })).data, []);

    const secondExport = await request('/api/system/backup/export', {
      method: 'POST', token, body: { currentPassword: 'MaterialKompass2026!' },
    });
    const legacy = {
      ...secondExport.data,
      schemaVersion: 2,
      data: Object.fromEntries(secondExport.data.sections.map((section) => [
        section.name, section.records,
      ])),
    };
    delete legacy.sections;
    delete legacy.editInstructions;
    const legacyImport = await request('/api/system/backup/import', {
      method: 'POST', token,
      body: {
        currentPassword: 'MaterialKompass2026!',
        confirmation: 'ALLE DATEN ERSETZEN',
        backup: legacy,
      },
    });
    assert.equal(legacyImport.response.status, 200);
  } finally {
    server.close();
  }
});

test('editable backup rejects disabled core sections and duplicate section names', async () => {
  const { server, request, token } = await setup();
  try {
    const exported = await request('/api/system/backup/export', {
      method: 'POST', token, body: { currentPassword: 'MaterialKompass2026!' },
    });
    const users = exported.data.sections.find((section) => section.name === 'users');
    users.enabled = false;
    let imported = await request('/api/system/backup/import', {
      method: 'POST', token,
      body: {
        currentPassword: 'MaterialKompass2026!', confirmation: 'ALLE DATEN ERSETZEN',
        backup: exported.data,
      },
    });
    assert.equal(imported.response.status, 400);
    assert.match(imported.data.error, /Pflichtsektion/);

    users.enabled = true;
    exported.data.sections.push(structuredClone(users));
    imported = await request('/api/system/backup/import', {
      method: 'POST', token,
      body: {
        currentPassword: 'MaterialKompass2026!', confirmation: 'ALLE DATEN ERSETZEN',
        backup: exported.data,
      },
    });
    assert.equal(imported.response.status, 400);
    assert.match(imported.data.error, /doppelt/);
  } finally {
    server.close();
  }
});
