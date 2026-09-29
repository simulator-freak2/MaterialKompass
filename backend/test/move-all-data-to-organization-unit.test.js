const assert = require('node:assert/strict');
const test = require('node:test');

const {
  UNIT_COLLECTIONS,
  findTargetUnit,
  parseArguments,
  planMove,
} = require('../src/scripts/move-all-data-to-organization-unit');

function fixture() {
  const collections = {
    organizations: [
      { id: 'org-source', name: 'Quelle', status: 'active' },
      { id: 'org-target', name: 'Zielorganisation', status: 'active' },
    ],
    organizationUnits: [
      { id: 'unit-source', organizationId: 'org-source', parentId: null, name: 'Quelle', edvNumber: '1', status: 'active' },
      { id: 'unit-root', organizationId: 'org-target', parentId: null, name: 'Zielorganisation', edvNumber: '2', status: 'active' },
      { id: 'unit-youth', organizationId: 'org-target', parentId: 'unit-root', name: 'Jugend Ingelheim am Rhein', edvNumber: '10050035', status: 'active' },
    ],
    categories: [{
      id: 'category-1', name: 'PSA', organizationId: 'org-source',
      scope: 'organization', unitId: null,
    }],
    materials: [{
      id: 'material-1', inventoryNumber: 'INV-1',
      organizationId: 'org-source', unitId: 'unit-source',
    }],
    clothingItems: [{
      id: 'clothing-1', inventoryNumber: 'CLOTHING-1',
      organizationId: 'org-target', unitId: 'unit-root',
    }],
    locations: [{
      id: 'location-1', code: 'L1',
      organizationId: 'org-source', unitId: 'unit-source',
    }],
    departments: [{
      id: 'department-1', name: 'Technik', code: 'TECH', active: true,
      organizationId: 'org-source', unitId: 'unit-source',
    }],
    auditLogs: [],
  };
  for (const name of UNIT_COLLECTIONS) collections[name] ||= [];
  return collections;
}

test('argument parser defaults to a safe preview', () => {
  const options = parseArguments([]);
  assert.equal(options.apply, false);
  assert.equal(options.targetEdv, '10050035');
  assert.equal(options.targetName, 'Jugend Ingelheim am Rhein');
});

test('move plan assigns requested domains and categories to the target unit', () => {
  const plan = planMove(fixture());
  assert.equal(plan.target.id, 'unit-youth');
  assert.equal(plan.changed, 5);
  assert.deepEqual(
    {
      organizationId: plan.updated.materials[0].organizationId,
      unitId: plan.updated.materials[0].unitId,
    },
    { organizationId: 'org-target', unitId: 'unit-youth' },
  );
  assert.equal(plan.updated.clothingItems[0].unitId, 'unit-youth');
  assert.equal(plan.updated.departments[0].unitId, 'unit-youth');
  assert.deepEqual(
    {
      organizationId: plan.updated.categories[0].organizationId,
      unitId: plan.updated.categories[0].unitId,
      scope: plan.updated.categories[0].scope,
    },
    { organizationId: 'org-target', unitId: 'unit-youth', scope: 'unit' },
  );
  assert.equal(plan.updated.auditLogs.length, 1);
});

test('second move is idempotent and creates no additional audit entry', () => {
  const first = planMove(fixture());
  const collections = fixture();
  Object.assign(collections, first.updated);
  const second = planMove(collections);
  assert.equal(second.changed, 0);
  assert.equal(second.updated.auditLogs, undefined);
});

test('migration rejects a root organization as target', () => {
  const collections = fixture();
  collections.organizationUnits[1].name = 'Jugend Ingelheim am Rhein';
  collections.organizationUnits[1].edvNumber = '10050035';
  collections.organizationUnits = collections.organizationUnits.filter((entry) =>
    entry.id !== 'unit-youth');
  assert.throws(
    () => findTargetUnit(collections, {
      targetName: 'Jugend Ingelheim am Rhein', targetEdv: '10050035',
    }),
    /Wurzeleinheit/,
  );
});

test('migration aborts before merging duplicate inventory numbers', () => {
  const collections = fixture();
  collections.clothingItems[0].inventoryNumber = 'INV-1';
  assert.throws(() => planMove(collections), /Inventarnummer/);
});
