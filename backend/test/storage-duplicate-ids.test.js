const assert = require('node:assert/strict');
const test = require('node:test');
const { repairDuplicateStorageIds } = require('../src/storage-hierarchy');

test('duplicate storage IDs of different units are renumbered with their references', () => {
  const data = {
    locations: [
      { id: 'loc-2', name: 'Fahrzeughalle', code: 'FH', organizationId: 'org', unitId: 'base' },
      { id: 'loc-2', name: 'Kleiderkammer', code: 'KK', organizationId: 'org', unitId: 'youth' },
    ],
    shelves: [
      { id: 'shelf-1', locationId: 'loc-2', name: 'Regal', code: 'R1', organizationId: 'org', unitId: 'base' },
      { id: 'shelf-2', locationId: 'loc-2', name: 'Regal', code: 'R1', organizationId: 'org', unitId: 'youth' },
    ],
    storageLevels: [],
    stockStructures: [],
    clothingItems: [
      { id: 'c1', locationId: 'loc-2', organizationId: 'org', unitId: 'youth' },
      { id: 'c2', locationId: 'loc-2', organizationId: 'org', unitId: 'base' },
    ],
    stocktakes: [
      { id: 's1', organizationId: 'org', unitId: 'youth', locationIds: ['loc-2'],
        lines: [{ expectedLocationId: 'loc-2' }] },
    ],
  };
  const repairs = repairDuplicateStorageIds(data);
  assert.equal(repairs.length, 1);
  assert.equal(data.locations[0].id, 'loc-2');
  assert.equal(data.locations[1].id, 'loc-3');
  assert.equal(data.shelves[0].locationId, 'loc-2');
  assert.equal(data.shelves[1].locationId, 'loc-3');
  assert.equal(data.clothingItems[0].locationId, 'loc-3');
  assert.equal(data.clothingItems[1].locationId, 'loc-2');
  assert.deepEqual(data.stocktakes[0].locationIds, ['loc-3']);
  assert.equal(data.stocktakes[0].lines[0].expectedLocationId, 'loc-3');
  assert.equal(data.shelves[1].path, 'Kleiderkammer / Regal');
});

test('exact copies of a storage record are dropped', () => {
  const entry = { id: 'loc-1', name: 'Lager', code: 'L', organizationId: 'org', unitId: 'u' };
  const data = { locations: [entry, { ...entry }], shelves: [], storageLevels: [], stockStructures: [] };
  repairDuplicateStorageIds(data);
  assert.equal(data.locations.length, 1);
});
