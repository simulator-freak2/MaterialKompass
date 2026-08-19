const crypto = require('node:crypto');
const net = require('node:net');

const BASE32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

function normalize(value) {
  return String(value || '').trim().toLowerCase();
}

function hash(value) {
  return crypto.createHash('sha256').update(String(value || '')).digest('hex');
}

function safeHashEqual(stored, suppliedValue) {
  if (!stored) return false;
  const left = Buffer.from(stored, 'hex');
  const right = Buffer.from(hash(suppliedValue), 'hex');
  return left.length === right.length && crypto.timingSafeEqual(left, right);
}

function passwordIsValid(password) {
  return typeof password === 'string'
    && password.length >= 12
    && Buffer.byteLength(password, 'utf8') <= 72
    && /[a-z]/.test(password)
    && /[A-Z]/.test(password)
    && /\d/.test(password)
    && /[^A-Za-z0-9]/.test(password);
}

function ipToBigInt(value) {
  if (net.isIP(value) === 4) {
    return value
      .split('.')
      .reduce((result, part) => (result << 8n) + BigInt(Number(part)), 0n);
  }
  if (net.isIP(value) !== 6) return null;
  const [head, tail] = value.toLowerCase().split('::');
  const expandIpv4 = (parts) => parts.flatMap((part) => {
    if (!part.includes('.')) return [part];
    const bytes = part.split('.').map(Number);
    return [
      ((bytes[0] << 8) | bytes[1]).toString(16),
      ((bytes[2] << 8) | bytes[3]).toString(16),
    ];
  });
  const left = expandIpv4(head ? head.split(':') : []);
  const right = expandIpv4(tail ? tail.split(':') : []);
  const groups = tail === undefined
    ? left
    : [...left, ...Array(8 - left.length - right.length).fill('0'), ...right];
  if (groups.length !== 8) return null;
  return groups.reduce(
    (result, part) => (result << 16n) + BigInt(`0x${part || '0'}`),
    0n,
  );
}

function ipAllowed(address, rules) {
  if (!Array.isArray(rules) || rules.length === 0) return true;
  const clean = String(address || '').replace(/^::ffff:/, '');
  const version = net.isIP(clean);
  const raw = ipToBigInt(clean);
  if (!version || raw === null) return false;
  return rules.some((rule) => {
    const [network, prefixText] = String(rule).trim().split('/');
    if (net.isIP(network) !== version) return false;
    const bits = version === 4 ? 32 : 128;
    const prefix = prefixText === undefined ? bits : Number(prefixText);
    if (!Number.isInteger(prefix) || prefix < 0 || prefix > bits) return false;
    const networkRaw = ipToBigInt(network);
    const shift = BigInt(bits - prefix);
    return shift === 0n
      ? raw === networkRaw
      : (raw >> shift) === (networkRaw >> shift);
  });
}

function validNetworkRule(rule) {
  const [address, prefixText] = String(rule || '').trim().split('/');
  const version = net.isIP(address);
  if (!version) return false;
  if (prefixText === undefined) return true;
  const prefix = Number(prefixText);
  return Number.isInteger(prefix)
    && prefix >= 0
    && prefix <= (version === 4 ? 32 : 128);
}

function base32Encode(bytes) {
  let bits = 0;
  let value = 0;
  let output = '';
  for (const byte of bytes) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) {
      output += BASE32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
  }
  if (bits > 0) output += BASE32[(value << (5 - bits)) & 31];
  return output;
}

function base32Decode(input) {
  let bits = 0;
  let value = 0;
  const output = [];
  for (const char of String(input || '').replace(/=+$/, '').toUpperCase()) {
    const index = BASE32.indexOf(char);
    if (index < 0) return Buffer.alloc(0);
    value = (value << 5) | index;
    bits += 5;
    if (bits >= 8) {
      output.push((value >>> (bits - 8)) & 255);
      bits -= 8;
    }
  }
  return Buffer.from(output);
}

function totp(secret, timestamp = Date.now()) {
  const counter = BigInt(Math.floor(timestamp / 30_000));
  const message = Buffer.alloc(8);
  message.writeBigUInt64BE(counter);
  const digest = crypto
    .createHmac('sha1', base32Decode(secret))
    .update(message)
    .digest();
  const offset = digest[digest.length - 1] & 15;
  const number = (digest.readUInt32BE(offset) & 0x7fffffff) % 1_000_000;
  return String(number).padStart(6, '0');
}

function verifyTotp(secret, code) {
  const supplied = String(code || '').trim();
  if (!/^\d{6}$/.test(supplied)) return false;
  return [-30_000, 0, 30_000].some((offset) => {
    const expected = Buffer.from(totp(secret, Date.now() + offset));
    const actual = Buffer.from(supplied);
    return expected.length === actual.length
      && crypto.timingSafeEqual(expected, actual);
  });
}

module.exports = {
  base32Encode,
  hash,
  ipAllowed,
  normalize,
  passwordIsValid,
  safeHashEqual,
  validNetworkRule,
  verifyTotp,
};
