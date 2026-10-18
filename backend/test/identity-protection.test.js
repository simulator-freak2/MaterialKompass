const assert = require('node:assert/strict');
const test = require('node:test');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const {
  createIdentityProtection,
  createMemoryIdentityProtection,
} = require('../src/identity-protection');

function fixture() {
  return {
    users: [{
      id: 'user-alice',
      name: 'Alice Example',
      username: 'alice',
      email: 'alice@example.org',
      passwordHash: 'a'.repeat(60),
      roles: ['Nutzer'],
      permissions: [],
      active: true,
    }],
    roles: [{ id: 'role-user', name: 'Nutzer', permissions: [] }],
    passkeys: [{ id: 'passkey-1', userId: 'user-alice' }],
    memberships: [{
      id: 'membership-1', userId: 'user-alice', status: 'active',
      scopes: [{ unitId: 'unit-1', roles: ['Nutzer'] }],
    }],
    auditLogs: [{ id: 'audit-1', actor: 'alice', action: 'login' }],
  };
}

test('backup identities are authenticated ciphertext and become tombstones after key erasure', async () => {
  const protection = createMemoryIdentityProtection('a'.repeat(64));
  const protectedData = await protection.protectBackupData(fixture());
  const serialized = JSON.stringify(protectedData);
  assert.doesNotMatch(serialized, /alice@example\.org/);
  assert.doesNotMatch(serialized, /Alice Example/);
  assert.doesNotMatch(serialized, /"actor":"alice"/);

  assert.equal(protection.unprotectBackupData(protectedData).data.users[0].username, 'alice');
  await protection.destroyUser('user-alice');
  const restored = protection.unprotectBackupData(protectedData).data;
  assert.match(restored.users[0].username, /^deleted-/);
  assert.equal(restored.users[0].active, false);
  assert.equal(restored.users[0].platformAdmin, false);
  assert.deepEqual(restored.users[0].roles, []);
  assert.deepEqual(restored.passkeys, []);
  assert.equal(restored.memberships[0].status, 'archived');
  assert.deepEqual(restored.memberships[0].scopes, []);
});

test('rotating an identity key makes prior names unreadable', async () => {
  const protection = createMemoryIdentityProtection('b'.repeat(64));
  const data = fixture();
  const oldBackup = await protection.protectBackupData(data);
  data.users[0].username = 'alice-new';
  await protection.rotateUser(data.users[0]);
  const restored = protection.unprotectBackupData(oldBackup).data.users[0];
  assert.equal(restored.active, false);
  assert.match(restored.username, /^deleted-/);
});

test('rotation re-encrypts references to the previous identity with the current key', async () => {
  const protection = createMemoryIdentityProtection('e'.repeat(64));
  const data = fixture();
  await protection.protectBackupData(data);
  data.users[0].username = 'alice-new';
  await protection.rotateUser(data.users[0]);

  const protectedReference = protection.protectValue({ actor: 'alice' });
  assert.match(protectedReference.actor, /^mkid:v1:/);
  assert.equal(protection.unprotectValue(protectedReference).actor, 'alice');
});

test('replacing all data prunes keys for accounts absent from the restored backup', async () => {
  const protection = createMemoryIdentityProtection('9'.repeat(64));
  const data = fixture();
  data.users.push({
    ...data.users[0], id: 'user-bob', name: 'Bob Example', username: 'bob',
    email: 'bob@example.org',
  });
  const protectedData = await protection.protectBackupData(data);
  await protection.pruneUsers(['user-alice']);
  const restored = protection.unprotectBackupData(protectedData).data;
  assert.equal(restored.users.find((user) => user.id === 'user-bob').active, false);
});

test('tampered backup identities fail closed', async () => {
  const protection = createMemoryIdentityProtection('c'.repeat(64));
  const protectedData = await protection.protectBackupData(fixture());
  const parts = protectedData.users[0].email.split(':');
  const ciphertext = parts.at(-1);
  const index = Math.floor(ciphertext.length / 2);
  parts[parts.length - 1] = `${ciphertext.slice(0, index)}${ciphertext[index] === 'A' ? 'B' : 'A'}${ciphertext.slice(index + 1)}`;
  protectedData.users[0].email = parts.join(':');
  assert.throws(
    () => protection.unprotectBackupData(protectedData),
    /authenticate|Identity|Chiffrat|protected|unable/i,
  );
});

test('a shared display name remains available until every matching account key is erased', async () => {
  const protection = createMemoryIdentityProtection('d'.repeat(64));
  const data = fixture();
  data.users.push({
    ...data.users[0],
    id: 'user-alex-2',
    username: 'alex-2',
    email: 'alex-2@example.org',
  });
  data.users[0].name = 'Alex Example';
  data.users[1].name = 'Alex Example';
  data.auditLogs[0] = { id: 'audit-1', author: 'Alex Example' };
  const protectedData = await protection.protectBackupData(data);
  assert.match(protectedData.auditLogs[0].author, /^mkid:v2:/);

  await protection.destroyUser('user-alice');
  assert.equal(
    protection.unprotectBackupData(protectedData).data.auditLogs[0].author,
    'Alex Example',
  );
  await protection.destroyUser('user-alex-2');
  assert.equal(
    protection.unprotectBackupData(protectedData).data.auditLogs[0].author,
    'Gelöschte Person',
  );
});

test('the encrypted keyring preserves current keys and reconstructs protected aliases', async (t) => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), 'mk-identity-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const options = {
    masterKey: 'f'.repeat(64),
    keyringPath: path.join(directory, 'keyring.enc'),
  };
  const first = createIdentityProtection(options);
  await first.initialize();
  const data = fixture();
  await first.ensureUser(data.users[0]);
  data.users[0].username = 'alice-new';
  await first.rotateUser(data.users[0]);
  const protectedUser = first.protectUserRecord(data.users[0]);
  const protectedReference = first.protectValue({ actor: 'alice' });

  const restarted = createIdentityProtection(options);
  await restarted.initialize();
  restarted.unprotectUserRecord(
    { ...data.users[0], name: '', username: '', email: '' },
    protectedUser.identityCiphertext,
  );
  assert.equal(restarted.unprotectValue(protectedReference).actor, 'alice');
  assert.match(restarted.protectValue({ actor: 'alice' }).actor, /^mkid:v1:/);

  await restarted.destroyUser('user-alice');
  const afterDeletion = createIdentityProtection(options);
  await afterDeletion.initialize();
  assert.match(afterDeletion.unprotectValue(protectedReference).actor, /^deleted-/);
});
