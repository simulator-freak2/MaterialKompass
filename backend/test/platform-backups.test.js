const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const zlib = require('node:zlib');
const { createApp } = require('../src/app');
const { seedData } = require('../src/data/seed');
const { centralToken } = require('../test-support/accounts');
const { scheduledSlot } = require('../src/platform-backups');

const PASSWORD = 'MaterialKompass2026!';

function writeDump(directory, date, { complete = true } = {}) {
  const stamp = date.toISOString().replace(/[-:]/g, '').replace(/\.\d{3}Z$/, 'Z');
  const name = `materialkompass-v2-${stamp}.sql.gz`;
  const sql = [
    'CREATE TABLE `users` (id int);',
    'CREATE TABLE `application_collections` (id int);',
    'CREATE TABLE `identity_protection_state` (id int);',
    complete ? '-- Dump completed on 2026-11-21' : '',
  ].join('\n');
  const content = zlib.gzipSync(Buffer.from(sql));
  fs.writeFileSync(path.join(directory, name), content);
  const hash = crypto.createHash('sha256').update(content).digest('hex');
  fs.writeFileSync(path.join(directory, `${name}.sha256`), `${hash}  ${name}\n`);
  return name;
}

async function setup({ now = () => new Date(), dumps = true, platformAdmin = true } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'mk-platform-backups-'));
  const backupDirectory = path.join(root, 'platform');
  const dumpDirectory = path.join(root, 'dumps');
  fs.mkdirSync(dumpDirectory);
  if (dumps) writeDump(dumpDirectory, new Date(now().getTime() - 2 * 60 * 60 * 1000));
  const data = structuredClone(seedData);
  data.users.find((user) => user.id === 'user-admin').platformAdmin = platformAdmin;
  const app = createApp({
    data,
    platformBackupDirectory: backupDirectory,
    databaseDumpDirectory: dumpDirectory,
    platformBackupNow: now,
    platformBackupOptions: { manualIntervalMs: 0, manualCheckIntervalMs: 0 },
  });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  const request = async (urlPath, { method = 'GET', token, body } = {}) => {
    const response = await fetch(`${baseUrl}${urlPath}`, {
      method,
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return { response, data: response.status === 204 ? null : await response.json() };
  };
  const login = await request('/api/auth/login', {
    method: 'POST', body: { identifier: 'admin', password: PASSWORD },
  });
  const token = platformAdmin ? await centralToken(request, login.data.token) : login.data.token;
  const close = () => {
    server.close();
    fs.rmSync(root, { recursive: true, force: true });
  };
  return { app, request, token, organizationToken: login.data.token, login: login.data,
    backupDirectory, dumpDirectory, close };
}

test('scheduled slot is the most recent Monday 03:30 UTC', () => {
  assert.equal(scheduledSlot(new Date('2026-11-21T12:00:00Z'), 1, 210).toISOString(), '2026-11-16T03:30:00.000Z');
  assert.equal(scheduledSlot(new Date('2026-11-23T03:29:00Z'), 1, 210).toISOString(), '2026-11-16T03:30:00.000Z');
  assert.equal(scheduledSlot(new Date('2026-11-23T03:30:00Z'), 1, 210).toISOString(), '2026-11-23T03:30:00.000Z');
});

test('platform administrators create encrypted server backups only after reauthentication', async () => {
  const context = await setup();
  try {
    const denied = await context.request('/api/platform/backups', {
      method: 'POST', token: context.token, body: { currentPassword: 'falsch' },
    });
    assert.equal(denied.response.status, 403);

    const created = await context.request('/api/platform/backups', {
      method: 'POST', token: context.token, body: { currentPassword: PASSWORD },
    });
    assert.equal(created.response.status, 201, JSON.stringify(created.data));
    const { backup } = created.data;
    assert.match(backup.id, /^pb-\d{8}T\d{6}Z-[a-f0-9]{8}$/);
    assert.equal(backup.reason, 'manual');
    assert.equal(backup.createdByUserId, 'user-admin');

    const file = path.join(context.backupDirectory, `${backup.id}.mkbackup`);
    const content = fs.readFileSync(file);
    assert.equal(content.subarray(0, 6).toString(), 'MKPB1\n');
    assert.equal(content.includes(Buffer.from('MaterialKompass Gesamtdatensicherung')), false);
    assert.equal(content.includes(Buffer.from('passwordHash')), false);
    assert.equal(fs.statSync(file).mode & 0o777, 0o600);

    const listed = await context.request('/api/platform/backups', { token: context.token });
    assert.equal(listed.response.status, 200);
    assert.equal(listed.data.backups.length, 1);
    assert.equal(listed.data.backups[0].id, backup.id);
    assert.equal(listed.data.status.configured, true);
  } finally {
    context.close();
  }
});

test('backup routes are restricted to the central administration context', async () => {
  const organizationAdmin = await setup({ platformAdmin: false });
  try {
    const listed = await organizationAdmin.request('/api/platform/backups', { token: organizationAdmin.token });
    assert.equal(listed.response.status, 403);
    const created = await organizationAdmin.request('/api/platform/backups', {
      method: 'POST', token: organizationAdmin.token, body: { currentPassword: PASSWORD },
    });
    assert.equal(created.response.status, 403);
  } finally {
    organizationAdmin.close();
  }
  const platformAdmin = await setup();
  try {
    // A platform administrator acting inside an ordinary organization does not
    // get the platform backup functions.
    const listed = await platformAdmin.request('/api/platform/backups', { token: platformAdmin.organizationToken });
    assert.equal(listed.response.status, 403);
    const dashboard = await platformAdmin.request('/api/dashboard', { token: platformAdmin.organizationToken });
    assert.equal(dashboard.response.status, 200);
    assert.equal(dashboard.data.backupStatus, undefined);
  } finally {
    platformAdmin.close();
  }
});

test('manual check validates backups and dumps and detects corruption', async () => {
  const context = await setup();
  try {
    const created = await context.request('/api/platform/backups', {
      method: 'POST', token: context.token, body: { currentPassword: PASSWORD },
    });
    const ok = await context.request('/api/platform/backups/checks', { method: 'POST', token: context.token });
    assert.equal(ok.response.status, 201, JSON.stringify(ok.data));
    assert.equal(ok.data.check.status, 'ok', JSON.stringify(ok.data.check.items));
    assert.ok(ok.data.check.items.some((item) => item.key === 'platform-backup-restore-validation' && item.status === 'ok'));
    assert.ok(ok.data.check.items.some((item) => item.key === 'database-dump-content' && item.status === 'ok'));

    // Flip one ciphertext byte and repair the checksum: only authenticated
    // decryption can detect this kind of manipulation.
    const id = created.data.backup.id;
    const file = path.join(context.backupDirectory, `${id}.mkbackup`);
    const content = fs.readFileSync(file);
    content[content.length - 1] ^= 0xff;
    fs.writeFileSync(file, content);
    const metadataPath = path.join(context.backupDirectory, `${id}.json`);
    const metadata = JSON.parse(fs.readFileSync(metadataPath, 'utf8'));
    metadata.sha256 = crypto.createHash('sha256').update(content).digest('hex');
    fs.writeFileSync(metadataPath, JSON.stringify(metadata));
    const damaged = await context.request('/api/platform/backups/checks', { method: 'POST', token: context.token });
    assert.equal(damaged.data.check.status, 'error');
    const validation = damaged.data.check.items.find((item) => item.key === 'platform-backup-restore-validation');
    assert.equal(validation.status, 'error');
    assert.match(validation.detail, /authentifiziert/);

    // Incomplete or tampered dumps are reported as errors as well.
    for (const name of fs.readdirSync(context.dumpDirectory)) fs.rmSync(path.join(context.dumpDirectory, name));
    const dumpName = writeDump(context.dumpDirectory, new Date(Date.now() - 60 * 60 * 1000), { complete: false });
    let check = await context.request('/api/platform/backups/checks', { method: 'POST', token: context.token });
    assert.equal(check.data.check.items.find((item) => item.key === 'database-dump-content').status, 'error');
    fs.appendFileSync(path.join(context.dumpDirectory, dumpName), 'x');
    check = await context.request('/api/platform/backups/checks', { method: 'POST', token: context.token });
    assert.equal(check.data.check.items.find((item) => item.key === 'database-dump-checksum').status, 'error');
  } finally {
    context.close();
  }
});

test('stale or missing database dumps make the check fail', async () => {
  const context = await setup({ dumps: false });
  try {
    let check = await context.request('/api/platform/backups/checks', { method: 'POST', token: context.token });
    assert.equal(check.data.check.status, 'error');
    assert.ok(check.data.check.items.some((item) => item.key === 'platform-backups' && item.status === 'error'));
    assert.ok(check.data.check.items.some((item) => item.key === 'database-dump' && item.status === 'error'));
    writeDump(context.dumpDirectory, new Date(Date.now() - 3 * 24 * 60 * 60 * 1000));
    check = await context.request('/api/platform/backups/checks', { method: 'POST', token: context.token });
    assert.equal(check.data.check.items.find((item) => item.key === 'database-dump-age').status, 'error');
  } finally {
    context.close();
  }
});

test('restore requires exact confirmation, creates a safety backup and revokes sessions', async () => {
  const context = await setup();
  try {
    const created = await context.request('/api/platform/backups', {
      method: 'POST', token: context.token, body: { currentPassword: PASSWORD },
    });
    const id = created.data.backup.id;
    const added = await context.request('/api/users', {
      method: 'POST', token: context.token,
      body: { username: 'nach.sicherung', email: 'nach.sicherung@example.org', name: 'Nach Sicherung' },
    });
    assert.equal(added.response.status, 201, JSON.stringify(added.data));

    const wrongConfirmation = await context.request(`/api/platform/backups/${id}/restore`, {
      method: 'POST', token: context.token,
      body: { currentPassword: PASSWORD, confirmation: 'ALLE DATEN ERSETZEN' },
    });
    assert.equal(wrongConfirmation.response.status, 400);
    const wrongPassword = await context.request(`/api/platform/backups/${id}/restore`, {
      method: 'POST', token: context.token,
      body: { currentPassword: 'falsch', confirmation: `SICHERUNG ${id} ZURÜCKSPIELEN` },
    });
    assert.equal(wrongPassword.response.status, 403);
    const traversal = await context.request('/api/platform/backups/..%2F..%2Fetc%2Fpasswd/restore', {
      method: 'POST', token: context.token,
      body: { currentPassword: PASSWORD, confirmation: 'SICHERUNG ../../etc/passwd ZURÜCKSPIELEN' },
    });
    assert.equal(traversal.response.status, 404);

    const restored = await context.request(`/api/platform/backups/${id}/restore`, {
      method: 'POST', token: context.token,
      body: { currentPassword: PASSWORD, confirmation: `SICHERUNG ${id} ZURÜCKSPIELEN` },
    });
    assert.equal(restored.response.status, 200, JSON.stringify(restored.data));
    assert.equal(restored.data.restored.id, id);
    assert.equal(restored.data.safetyBackup.reason, 'pre-restore');
    assert.equal(restored.data.safetyBackup.restoredFromId, id);
    assert.equal(restored.data.reauthenticationRequired, true);

    const refreshed = await context.request('/api/auth/refresh', {
      method: 'POST', body: { refreshToken: context.login.refreshToken },
    });
    assert.equal(refreshed.response.status, 401);

    const login = await context.request('/api/auth/login', {
      method: 'POST', body: { identifier: 'admin', password: PASSWORD },
    });
    const token = await centralToken(context.request, login.data.token);
    const users = await context.request('/api/users?search=nach.sicherung', { token });
    assert.equal(users.response.status, 200);
    assert.equal(users.data.some((user) => user.id === added.data.id), false);
    const listed = await context.request('/api/platform/backups', { token });
    assert.equal(listed.data.backups.length, 2);
    assert.equal(listed.data.backups[0].userIds, undefined);

    // Undoing the restore with the automatic safety backup must bring the
    // newer account back with a readable identity, not as an erased tombstone.
    const safetyId = restored.data.safetyBackup.id;
    const undone = await context.request(`/api/platform/backups/${safetyId}/restore`, {
      method: 'POST', token,
      body: { currentPassword: PASSWORD, confirmation: `SICHERUNG ${safetyId} ZURÜCKSPIELEN` },
    });
    assert.equal(undone.response.status, 200, JSON.stringify(undone.data));
    const relogin = await context.request('/api/auth/login', {
      method: 'POST', body: { identifier: 'admin', password: PASSWORD },
    });
    const afterUndo = await context.request('/api/users?search=nach.sicherung', {
      token: await centralToken(context.request, relogin.data.token),
    });
    const returned = afterUndo.data.find((user) => user.id === added.data.id);
    assert.ok(returned, JSON.stringify(afterUndo.data));
    assert.equal(returned.email, 'nach.sicherung@example.org');
    assert.notEqual(returned.identityErased, true);
  } finally {
    context.close();
  }
});

test('weekly scheduled check creates a backup and a dashboard message until acknowledged', async () => {
  let current = new Date('2026-11-23T04:00:00Z');
  const context = await setup({ now: () => current });
  try {
    const first = await context.app.locals.platformBackups.runScheduledCheckIfDue();
    assert.equal(first.kind, 'scheduled');
    assert.equal(first.status, 'ok', JSON.stringify(first.items));
    assert.ok(first.items.some((item) => item.key === 'platform-backup-create' && item.status === 'ok'));
    assert.equal(await context.app.locals.platformBackups.runScheduledCheckIfDue(), null);

    const dashboard = await context.request('/api/dashboard', { token: context.token });
    assert.equal(dashboard.response.status, 200);
    assert.equal(dashboard.data.backupStatus.latestCheck.id, first.id);
    assert.equal(dashboard.data.backupStatus.weeklyMessage.id, first.id);
    assert.equal(dashboard.data.backupStatus.backupCount, 1);
    assert.equal(dashboard.data.backupStatus.nextScheduledCheckAt, '2026-11-30T03:30:00.000Z');

    const acknowledged = await context.request(`/api/platform/backups/checks/${first.id}/acknowledge`, {
      method: 'POST', token: context.token,
    });
    assert.equal(acknowledged.response.status, 204);
    const after = await context.request('/api/dashboard', { token: context.token });
    assert.equal(after.data.backupStatus.weeklyMessage, null);
    assert.equal(after.data.backupStatus.latestCheck.acknowledged, true);

    current = new Date('2026-11-30T03:31:00Z');
    const next = await context.app.locals.platformBackups.runScheduledCheckIfDue();
    assert.equal(next.kind, 'scheduled');
    const unknown = await context.request('/api/platform/backups/checks/bc-x/acknowledge', {
      method: 'POST', token: context.token,
    });
    assert.equal(unknown.response.status, 404);
  } finally {
    context.close();
  }
});

test('retention removes expired backups but keeps the newest ones', async () => {
  let current = new Date('2026-10-01T10:00:00Z');
  const context = await setup({ now: () => current });
  try {
    const service = context.app.locals.platformBackups;
    for (let index = 0; index < 5; index += 1) {
      await service.createManual('user-admin');
      current = new Date(current.getTime() + 60 * 60 * 1000);
    }
    current = new Date('2026-12-01T10:00:00Z');
    await service.createManual('user-admin');
    const remaining = await service.list();
    assert.equal(remaining.length, 4);
  } finally {
    context.close();
  }
});

test('password guessing through backup actions is rate limited', async () => {
  const context = await setup();
  try {
    let last;
    for (let attempt = 0; attempt < 12; attempt += 1) {
      last = await context.request('/api/platform/backups', {
        method: 'POST', token: context.token, body: { currentPassword: `falsch-${attempt}` },
      });
      if (last.response.status === 429) break;
      assert.equal(last.response.status, 403);
    }
    assert.equal(last.response.status, 429);
  } finally {
    context.close();
  }
});
