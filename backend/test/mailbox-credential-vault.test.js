const assert = require('node:assert/strict');
const test = require('node:test');
const { createMailboxCredentialVault } = require('../src/mailbox-credential-vault');

test('mailbox passwords are encrypted with authenticated encryption', () => {
  const vault = createMailboxCredentialVault({ key: 'a'.repeat(64) });
  const encrypted = {
    email: 'scanner01@materialkompass.org',
    ...vault.encrypt('scanner-secret', 'scanner01@materialkompass.org'),
  };
  assert.equal(encrypted.passwordCiphertext.includes('scanner-secret'), false);
  assert.equal(vault.decrypt(encrypted), 'scanner-secret');

  assert.throws(() => vault.decrypt({
    ...encrypted,
    passwordCiphertext: Buffer.from('manipulated').toString('base64'),
  }));
  assert.throws(() => vault.decrypt({
    ...encrypted,
    email: 'other@materialkompass.org',
  }));
});

test('mailbox credential vault requires a 256-bit hex key', () => {
  assert.throws(
    () => createMailboxCredentialVault({ key: 'too-short' }),
    /64-stelliger Hex-Wert/,
  );
});
