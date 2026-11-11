const test = require('node:test');
const assert = require('node:assert/strict');
const {
  backupScope, backupDocument, validatedScopedBackup,
} = require('../src/data-backup');

const names = ['organizations', 'organizationUnits', 'memberships', 'materials',
  'categories', 'defectReports', 'auditLogs', 'serviceDevices'];
const protection = {
  async protectBackupData(data) { return structuredClone(data); },
  unprotectBackupData(data) { return { data: structuredClone(data) }; },
};
function fixture() {
  const unit = (id, parentId = null, youth = false, organizationId = 'org') => ({
    id, organizationId, parentId, status: 'active',
    unitKind: youth ? 'youth' : 'standard', baseUnitId: youth ? parentId : null,
  });
  const record = (id, unitId, organizationId = 'org') => ({ id, unitId, organizationId });
  return {
    users: [{ id: 'central-user', platformAdmin: true, passwordHash: 'secret' }],
    roles: [{ id: 'global-admin', permissions: ['everything'] }],
    passkeys: [{ id: 'secret-passkey' }],
    organizations: [{ id: 'org' }, { id: 'other' }],
    organizationUnits: [unit('district'), unit('district-youth', 'district', true),
      unit('local', 'district'), unit('local-youth', 'local', true),
      unit('sibling', 'district'), unit('foreign', null, false, 'other')],
    memberships: [{ id: 'central-membership' }],
    materials: ['district', 'district-youth', 'local', 'local-youth', 'sibling']
      .map((id) => record(`material-${id}`, id))
      .concat(record('foreign-material', 'foreign', 'other')),
    categories: [{ ...record('own-category', 'local'), scope: 'unit' },
      { id: 'shared-category', organizationId: 'org', scope: 'organization' }],
    defectReports: [], auditLogs: [], serviceDevices: [record('device', 'local')],
  };
}
const request = (unitId) => ({ tenant: { organizationId: 'org', unitId } });
const section = (backup, name) => backup.sections.find((entry) => entry.name === name);

test('district, local and youth backups stop at their exact direct youth boundary', () => {
  const data = fixture();
  for (const [unitId, expected] of [
    ['district', ['district', 'district-youth']],
    ['local', ['local', 'local-youth']], ['local-youth', ['local-youth']],
  ]) assert.deepEqual(backupScope(data, request(unitId)).unitIds, expected);
  assert.throws(() => backupScope(data, request('foreign')), { status: 403 });
});

test('scoped export and validation exclude unrelated units and all central credentials', async () => {
  const data = fixture();
  const scope = backupScope(data, request('local'));
  const backup = await backupDocument(data, names, 'test', protection, scope);
  assert.deepEqual(section(backup, 'materials').records.map((entry) => entry.id),
    ['material-local', 'material-local-youth']);
  for (const name of ['users', 'roles', 'passkeys', 'memberships', 'serviceDevices']) {
    assert.deepEqual(section(backup, name).records, []);
  }
  assert.deepEqual(section(backup, 'categories').records.map((entry) => entry.id), ['own-category']);
  await validatedScopedBackup(backup, data, names, scope, protection);
});

test('tampered scope, foreign records, ID collisions, central accounts and cross-unit references are rejected', async () => {
  const data = fixture();
  const scope = backupScope(data, request('local'));
  const original = await backupDocument(data, names, 'test', protection, scope);
  const attempts = [
    (backup) => { delete backup.scope; },
    (backup) => { backup.scope.unitIds.push('sibling'); },
    (backup) => { section(backup, 'materials').records[0].unitId = 'sibling'; },
    (backup) => { section(backup, 'materials').records[0].id = 'foreign-material'; },
    (backup) => { section(backup, 'users').records.push(data.users[0]); },
    (backup) => { section(backup, 'defectReports').records.push({
      id: 'forged-defect', organizationId: 'org', unitId: 'local',
      entityType: 'MaterialItem', entityId: 'material-sibling',
    }); },
    (backup) => { section(backup, 'materials').records[0].locationId = 'foreign'; },
  ];
  for (const change of attempts) {
    const backup = structuredClone(original);
    change(backup);
    await assert.rejects(validatedScopedBackup(backup, data, names, scope, protection), { status: 403 });
  }
});

test('historical defects and intentionally linked youth reports remain restorable', async () => {
  const data = fixture();
  data.defectReports.push({ id: 'historical', organizationId: 'org', unitId: 'local-youth',
    entityType: 'MaterialItem', entityId: 'deleted-material', archivedAt: '2026-01-01' },
  { id: 'linked-report', organizationId: 'org', unitId: 'local-youth',
    entityType: 'MaterialItem', entityId: 'material-local' });
  const scope = backupScope(data, request('local-youth'));
  const backup = await backupDocument(data, names, 'test', protection, scope);
  assert.deepEqual(section(backup, 'materials').records.map((entry) => entry.id), ['material-local-youth']);
  const restored = await validatedScopedBackup(backup, data, names, scope, protection);
  assert.equal(restored.defectReports.length, 2);
});

test('decrypted records undergo ID collision validation again', async () => {
  const data = fixture();
  const scope = backupScope(data, request('local'));
  const backup = await backupDocument(data, names, 'test', protection, scope);
  const decryptCollision = { ...protection, unprotectBackupData(input) {
    const decrypted = structuredClone(input);
    decrypted.materials[0].id = 'foreign-material';
    return { data: decrypted };
  } };
  await assert.rejects(validatedScopedBackup(backup, data, names, scope, decryptCollision), { status: 403 });
});
