const crypto = require('node:crypto');
const { base32Encode, verifyTotp } = require('./totp');

const RECOVERY_CODE_COUNT = 10;

function createMfaVault(keyHex) {
  if (!/^[a-f0-9]{64}$/i.test(String(keyHex || ''))) {
    throw new Error('MFA_ENCRYPTION_KEY muss ein 64-stelliger Hex-Wert sein.');
  }
  const key = Buffer.from(keyHex, 'hex');

  return {
    encrypt(value) {
      const iv = crypto.randomBytes(12);
      const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
      const encrypted = Buffer.concat([
        cipher.update(String(value), 'utf8'),
        cipher.final(),
      ]);
      return [iv, cipher.getAuthTag(), encrypted]
        .map((part) => part.toString('base64url'))
        .join('.');
    },
    decrypt(value) {
      try {
        const [iv, tag, encrypted] = String(value || '')
          .split('.')
          .map((part) => Buffer.from(part, 'base64url'));
        const decipher = crypto.createDecipheriv('aes-256-gcm', key, iv);
        decipher.setAuthTag(tag);
        return Buffer.concat([
          decipher.update(encrypted),
          decipher.final(),
        ]).toString('utf8');
      } catch (_) {
        return '';
      }
    },
  };
}

function createTotpSecret() {
  return base32Encode(crypto.randomBytes(20));
}

function provisioningUri(secret, account, issuer = 'MaterialKompass') {
  const label = `${issuer}:${account}`;
  return `otpauth://totp/${encodeURIComponent(label)}`
    + `?secret=${encodeURIComponent(secret)}`
    + `&issuer=${encodeURIComponent(issuer)}&algorithm=SHA1&digits=6&period=30`;
}

function recoveryCodeHash(code) {
  return crypto.createHash('sha256')
    .update(String(code || '').replace(/[^A-Za-z0-9]/g, '').toUpperCase())
    .digest('hex');
}

function createRecoveryCodes() {
  const codes = Array.from({ length: RECOVERY_CODE_COUNT }, () => {
    const value = crypto.randomBytes(10).toString('hex').toUpperCase();
    return `${value.slice(0, 5)}-${value.slice(5, 10)}-${value.slice(10, 15)}-${value.slice(15)}`;
  });
  return { codes, hashes: codes.map(recoveryCodeHash) };
}

function safeHashEqual(left, right) {
  const expected = Buffer.from(String(left || ''), 'hex');
  const actual = Buffer.from(String(right || ''), 'hex');
  return expected.length === actual.length
    && crypto.timingSafeEqual(expected, actual);
}

function consumeRecoveryCode(user, code) {
  const suppliedHash = recoveryCodeHash(code);
  const index = (user.mfaRecoveryCodeHashes || [])
    .findIndex((stored) => safeHashEqual(stored, suppliedHash));
  if (index < 0) return false;
  user.mfaRecoveryCodeHashes.splice(index, 1);
  return true;
}

module.exports = {
  RECOVERY_CODE_COUNT,
  consumeRecoveryCode,
  createMfaVault,
  createRecoveryCodes,
  createTotpSecret,
  provisioningUri,
  recoveryCodeHash,
  verifyTotp,
};
