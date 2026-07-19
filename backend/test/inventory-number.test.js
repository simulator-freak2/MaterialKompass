const assert = require('node:assert/strict');
const test = require('node:test');

const { inventoryPrefix, nextInventoryNumber } = require('../src/inventory-number');

test('inventory numbers use organization, category IDs and a running number', () => {
  assert.equal(inventoryPrefix('04', '04-04'), '10050035-04-04-');
  assert.equal(nextInventoryNumber([
    { inventoryNumber: '10050035-04-04-0001' },
    { inventoryNumber: '10050035-04-04-0007' },
    { inventoryNumber: 'KK-9999' },
  ], '04', '04-04'), '10050035-04-04-0008');
});
