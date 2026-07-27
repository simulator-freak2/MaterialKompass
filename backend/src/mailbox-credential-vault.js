const { createCipheriv, createDecipheriv, randomBytes } = require('node:crypto');

function parseKey(value) {
  const keyText = String(value || '').trim();
  if (!/^[a-f0-9]{64}$/i.test(keyText)) {
    throw new Error(
      'MAILBOX_PASSWORD_ENCRYPTION_KEY muss ein 64-stelliger Hex-Wert sein.',
    );
  }
  return Buffer.from(keyText, 'hex');
}

function createMailboxCredentialVault(options = {}) {
  const key = parseKey(
    options.key ?? process.env.MAILBOX_PASSWORD_ENCRYPTION_KEY,
  );

  return {
    encrypt(password, email) {
      const iv = randomBytes(12);
      const cipher = createCipheriv('aes-256-gcm', key, iv);
      cipher.setAAD(Buffer.from(String(email).toLowerCase(), 'utf8'));
      const encrypted = Buffer.concat([
        cipher.update(String(password), 'utf8'),
        cipher.final(),
      ]);
      return {
        passwordCiphertext: encrypted.toString('base64'),
        passwordIv: iv.toString('base64'),
        passwordTag: cipher.getAuthTag().toString('base64'),
        passwordEncryptionVersion: 2,
      };
    },

    decrypt(record) {
      if (record.passwordEncryptionVersion !== 2) {
        throw new Error('Unbekannte Verschlüsselungsversion.');
      }
      const decipher = createDecipheriv(
        'aes-256-gcm',
        key,
        Buffer.from(record.passwordIv, 'base64'),
      );
      decipher.setAAD(Buffer.from(String(record.email).toLowerCase(), 'utf8'));
      decipher.setAuthTag(Buffer.from(record.passwordTag, 'base64'));
      return Buffer.concat([
        decipher.update(Buffer.from(record.passwordCiphertext, 'base64')),
        decipher.final(),
      ]).toString('utf8');
    },
  };
}

module.exports = { createMailboxCredentialVault };
