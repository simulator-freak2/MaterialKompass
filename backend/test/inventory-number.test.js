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

test('automatic inventory numbering reuses explicitly released numbers first', () => {
  assert.equal(nextInventoryNumber([
    { inventoryNumber: '10050035-04-04-0001' },
    {
      inventoryNumber: '10050035-04-04-0002',
      inventoryNumberReleasedAt: '2026-08-22T10:00:00.000Z',
    },
    { inventoryNumber: '10050035-04-04-0007' },
  ], '04', '04-04'), '10050035-04-04-0002');
});

test('released legacy numbers keep their exact representation when reused', () => {
  assert.equal(nextInventoryNumber([
    {
      inventoryNumber: '10050035-02-02-001',
      inventoryNumberReleasedAt: '2026-08-22T10:00:00.000Z',
    },
  ], '02', '02-02'), '10050035-02-02-001');
});
