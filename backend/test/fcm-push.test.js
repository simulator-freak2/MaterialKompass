const assert = require('node:assert/strict');
const test = require('node:test');
const { approvalMessage } = require('../src/fcm-push');

test('FCM approval payload contains no authentication secrets or account data', () => {
  const message = approvalMessage({
    id: 'device-id',
    userId: 'user-id',
    pushToken: 'fcm-token',
    secretHash: 'server-only-secret-hash',
  }, {
    id: 'approval-id',
    mfaChallengeId: 'server-only-challenge',
    expiresAt: '2026-10-18T20:00:00.000Z',
  });

  assert.deepEqual(message.data, {
    type: 'mfa_approval',
    approvalId: 'approval-id',
    deviceId: 'device-id',
    expiresAt: '2026-10-18T20:00:00.000Z',
  });
  const serialized = JSON.stringify(message);
  assert.equal(serialized.includes('server-only-secret-hash'), false);
  assert.equal(serialized.includes('server-only-challenge'), false);
  assert.equal(serialized.includes('user-id'), false);
});
