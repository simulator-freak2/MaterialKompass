const test = require('node:test');
const assert = require('node:assert/strict');
const { normalizeIdentifier, identityConflict, identityConflicts } = require('../src/user-identity');

test('login identifiers are globally unique across email and username fields', () => {
  const users = [{ id: 'one', username: 'Alice', email: 'alice@example.org' }];
  assert.equal(normalizeIdentifier(' ALICE@EXAMPLE.ORG '), 'alice@example.org');
  assert.equal(identityConflict(users, { username: ' ALICE ', email: 'other@example.org' }), true);
  assert.equal(identityConflict(users, { username: 'alice@example.org', email: 'other@example.org' }), true);
  assert.equal(identityConflict(users, { username: 'other', email: ' ALICE ' }), true);
  assert.equal(identityConflict(users, { id: 'one', username: 'Alice', email: 'alice@example.org' }), false);
});

test('legacy conflicts are reported by IDs without copying personal identifiers', () => {
  const result = identityConflicts([
    { id: 'one', username: 'Alice', email: 'alice@example.org' },
    { id: 'two', username: ' ALICE@EXAMPLE.ORG ', email: 'two@example.org' },
    { id: 'erased', identityErased: true, username: 'Alice', email: 'alice@example.org' },
  ]);
  assert.deepEqual(result, [{ userIds: ['one', 'two'] }]);
  assert.equal(JSON.stringify(result).includes('example.org'), false);
});
