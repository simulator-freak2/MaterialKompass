const test = require('node:test');
const assert = require('node:assert/strict');

const { createApp } = require('../src/app');
const { createMfaVault } = require('../src/mfa-security');
const { totp } = require('../src/totp');
const { offlineMfaEligible } = require('../src/user-mfa');

async function setup(options = {}) {
  const mails = [];
  const app = createApp({
    accountMailSender: async (message) => mails.push(message),
    ...options,
  });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  async function request(path, { method = 'GET', token, body } = {}) {
    const response = await fetch(`${baseUrl}${path}`, {
      method,
      headers: {
        'Content-Type': 'application/json',
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    return {
      response,
      data: response.status === 204 ? null : await response.json(),
    };
  }
  const login = await request('/api/auth/login', {
    method: 'POST',
    body: { identifier: 'admin', password: 'MaterialKompass2026!' },
  });
  return { server, request, token: login.data.token, mails };
}

test('MFA secrets use authenticated encryption and reject the wrong key', () => {
  const first = createMfaVault('1'.repeat(64));
  const second = createMfaVault('2'.repeat(64));
  const encrypted = first.encrypt('TOPSECRET');
  assert.notEqual(encrypted.includes('TOPSECRET'), true);
  assert.equal(first.decrypt(encrypted), 'TOPSECRET');
  assert.equal(second.decrypt(encrypted), '');
  assert.throws(() => createMfaVault('short'), /MFA_ENCRYPTION_KEY/);
});

test('mandatory MFA uses a grace period and then limits the session to enrollment', async () => {
  let timestamp = Date.now();
  const { server, request, token: adminToken } = await setup({
    skipEmailVerification: true,
    now: () => timestamp,
  });
  try {
    const created = await request('/api/users', {
      method: 'POST', token: adminToken, body: {
        name: 'Pflichtkonto',
        username: 'pflichtkonto',
        email: 'pflichtkonto@example.org',
        password: 'SehrSicher123!',
        roles: ['Nutzer'],
        mfaRequired: true,
      },
    });
    assert.equal(created.response.status, 201);
    assert.equal(created.data.mfa.required, true);
    assert.ok(created.data.mfa.graceEndsAt);

    const duringGrace = await request('/api/auth/login', {
      method: 'POST',
      body: { identifier: 'pflichtkonto', password: 'SehrSicher123!' },
    });
    assert.equal(duringGrace.response.status, 200);
    assert.equal(duringGrace.data.mfaSetupRequired, undefined);

    timestamp += 15 * 24 * 60 * 60 * 1000;
    const afterGrace = await request('/api/auth/login', {
      method: 'POST',
      body: { identifier: 'pflichtkonto', password: 'SehrSicher123!' },
    });
    assert.equal(afterGrace.response.status, 200);
    assert.equal(afterGrace.data.mfaSetupRequired, true);
    assert.equal((await request('/api/dashboard', {
      token: afterGrace.data.token,
    })).response.status, 428);

    const enrollment = await request('/api/users/me/mfa/setup', {
      method: 'POST', token: afterGrace.data.token,
      body: { currentPassword: 'SehrSicher123!' },
    });
    assert.equal(enrollment.response.status, 200);
    const confirmation = await request('/api/users/me/mfa/confirm', {
      method: 'POST', token: afterGrace.data.token,
      body: { code: totp(enrollment.data.secret) },
    });
    assert.equal(confirmation.response.status, 200);
    assert.equal((await request('/api/dashboard', {
      token: confirmation.data.token,
    })).response.status, 200);
  } finally {
    server.close();
  }
});

test('TOTP follows the RFC 6238 SHA-1 test vector', () => {
  assert.equal(totp('GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ', 59_000), '287082');
});

test('account MFA setup, challenge and one-time recovery codes are enforced', async () => {
  const { server, request, token, mails } = await setup();
  try {
    const setupResponse = await request('/api/users/me/mfa/setup', {
      method: 'POST', token,
      body: { currentPassword: 'MaterialKompass2026!' },
    });
    assert.equal(setupResponse.response.status, 200);
    assert.match(setupResponse.data.provisioningUri, /^otpauth:\/\/totp\//);

    const confirmed = await request('/api/users/me/mfa/confirm', {
      method: 'POST', token,
      body: { code: totp(setupResponse.data.secret) },
    });
    assert.equal(confirmed.response.status, 200);
    assert.equal(confirmed.data.recoveryCodes.length, 10);
    assert.equal(mails.some((mail) => mail.subject.includes('aktiviert')), true);

    const publicAccount = await request('/api/auth/me', { token: confirmed.data.token });
    assert.equal(publicAccount.data.user.mfa.enabled, true);
    assert.equal(JSON.stringify(publicAccount.data).includes(setupResponse.data.secret), false);
    assert.equal((await request('/api/auth/me', { token })).response.status, 401);

    const login = await request('/api/auth/login', {
      method: 'POST',
      body: { identifier: 'admin', password: 'MaterialKompass2026!' },
    });
    assert.equal(login.response.status, 202);
    assert.equal(login.data.mfaRequired, true);
    assert.equal(login.data.token, undefined);

    const rejected = await request('/api/auth/mfa/verify', {
      method: 'POST', body: { challenge: login.data.challenge, code: '000000' },
    });
    assert.equal(rejected.response.status, 401);

    const verified = await request('/api/auth/mfa/verify', {
      method: 'POST',
      body: { challenge: login.data.challenge, code: totp(setupResponse.data.secret) },
    });
    assert.equal(verified.response.status, 200);
    assert.ok(verified.data.token);
    assert.equal((await request('/api/auth/mfa/verify', {
      method: 'POST',
      body: { challenge: login.data.challenge, code: totp(setupResponse.data.secret) },
    })).response.status, 401);

    const recoveryLogin = await request('/api/auth/login', {
      method: 'POST',
      body: { identifier: 'admin', password: 'MaterialKompass2026!' },
    });
    const recoveryCode = confirmed.data.recoveryCodes[0];
    assert.equal((await request('/api/auth/mfa/verify', {
      method: 'POST',
      body: { challenge: recoveryLogin.data.challenge, code: recoveryCode },
    })).response.status, 200);
    const reusedLogin = await request('/api/auth/login', {
      method: 'POST',
      body: { identifier: 'admin', password: 'MaterialKompass2026!' },
    });
    assert.equal((await request('/api/auth/mfa/verify', {
      method: 'POST',
      body: { challenge: reusedLogin.data.challenge, code: recoveryCode },
    })).response.status, 401);
  } finally {
    server.close();
  }
});

test('offline eligibility requires a successful MFA verification within one year', () => {
  const now = Date.parse('2026-08-21T12:00:00.000Z');
  const base = { mfaSecretEncrypted: 'encrypted', mfaEnabledAt: '2025-01-01T00:00:00.000Z' };
  assert.equal(offlineMfaEligible({
    ...base, mfaLastVerifiedAt: '2026-01-01T00:00:00.000Z',
  }, now), true);
  assert.equal(offlineMfaEligible({
    ...base, mfaLastVerifiedAt: '2025-01-01T00:00:00.000Z',
  }, now), false);
  assert.equal(offlineMfaEligible({}, now), false);
});
