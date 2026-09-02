const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');
const { seedData } = require('../src/data/seed');

const credentialId = 'Y3JlZGVudGlhbC0x';
const publicKey = Buffer.from('test-public-key');

function fakeWebAuthn() {
  return {
    async generateRegistrationOptions(options) {
      return {
        challenge: 'cmVnaXN0cmF0aW9uLWNoYWxsZW5nZQ',
        rp: { id: options.rpID, name: options.rpName },
        user: {
          id: Buffer.from(options.userID).toString('base64url'),
          name: options.userName,
          displayName: options.userDisplayName,
        },
        pubKeyCredParams: [{ type: 'public-key', alg: -7 }],
        excludeCredentials: options.excludeCredentials,
        authenticatorSelection: options.authenticatorSelection,
        timeout: options.timeout,
        attestation: options.attestationType,
      };
    },
    async verifyRegistrationResponse(options) {
      assert.equal(options.requireUserVerification, true);
      assert.deepEqual(options.expectedOrigin, ['https://materialkompass.org']);
      return {
        verified: true,
        registrationInfo: {
          credential: {
            id: credentialId,
            publicKey,
            counter: 0,
            transports: ['internal'],
          },
          userVerified: true,
          credentialDeviceType: 'multiDevice',
          credentialBackedUp: true,
        },
      };
    },
    async generateAuthenticationOptions(options) {
      assert.equal(options.userVerification, 'required');
      assert.equal(options.allowCredentials, undefined);
      return {
        challenge: 'YXV0aGVudGljYXRpb24tY2hhbGxlbmdl',
        rpId: options.rpID,
        timeout: options.timeout,
        userVerification: options.userVerification,
      };
    },
    async verifyAuthenticationResponse(options) {
      assert.equal(options.requireUserVerification, true);
      assert.deepEqual(options.expectedOrigin, ['https://materialkompass.org']);
      assert.equal(options.expectedRPID, 'materialkompass.org');
      assert.equal(options.advancedFIDOConfig.userVerification, 'required');
      assert.deepEqual(Buffer.from(options.credential.publicKey), publicKey);
      return {
        verified: true,
        authenticationInfo: {
          newCounter: Number(options.credential.counter) + 1,
          userVerified: true,
          credentialDeviceType: 'multiDevice',
          credentialBackedUp: true,
        },
      };
    },
  };
}

async function start() {
  const data = structuredClone(seedData);
  const admin = data.users.find((user) => user.username === 'admin');
  admin.mfaRequired = true;
  admin.mfaGraceEndsAt = '2099-01-01T00:00:00.000Z';
  const savedPasskeys = [];
  const app = createApp({
    data,
    passkeyConfig: {
      rpID: 'materialkompass.org',
      rpName: 'MaterialKompass',
      expectedOrigins: ['https://materialkompass.org'],
    },
    passkeyWebAuthn: fakeWebAuthn(),
    userStore: {
      saveUser: async () => {},
      savePasskey: async (passkey) => savedPasskeys.push(structuredClone(passkey)),
      deletePasskey: async () => {},
      deleteUserPasskeys: async () => {},
    },
  });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  async function request(path, { method = 'GET', token, body } = {}) {
    const response = await fetch(`${baseUrl}${path}`, {
      method,
      headers: {
        ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
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
  assert.equal(login.response.status, 200);
  return { server, request, token: login.data.token, savedPasskeys };
}

test('passkeys are registered, listed, renamed, used once and revoked with step-up', async () => {
  const { server, request, token, savedPasskeys } = await start();
  try {
    const rejected = await request('/api/users/me/passkeys/options', {
      method: 'POST', token,
      body: { name: 'Notebook', currentPassword: 'falsch' },
    });
    assert.equal(rejected.response.status, 403);

    const started = await request('/api/users/me/passkeys/options', {
      method: 'POST', token,
      body: { name: 'Notebook', currentPassword: 'MaterialKompass2026!' },
    });
    assert.equal(started.response.status, 200);
    assert.equal(started.data.options.authenticatorSelection.residentKey, 'required');
    assert.equal(started.data.options.authenticatorSelection.userVerification, 'required');

    const registered = await request('/api/users/me/passkeys/verify', {
      method: 'POST', token,
      body: {
        challengeId: started.data.challengeId,
        credential: {
          id: credentialId,
          response: { userHandle: started.data.options.user.id },
        },
      },
    });
    assert.equal(registered.response.status, 201);
    assert.equal(savedPasskeys.length, 1);
    assert.equal(savedPasskeys[0].publicKey, publicKey.toString('base64url'));
    assert.equal((await request('/api/auth/me', { token })).response.status, 401);

    const weakLogin = await request('/api/auth/login', {
      method: 'POST',
      body: { identifier: 'admin', password: 'MaterialKompass2026!' },
    });
    assert.equal(weakLogin.response.status, 403);
    assert.equal(weakLogin.data.passkeyRequired, true);

    const authStarted = await request('/api/auth/passkey/options', {
      method: 'POST', body: {},
    });
    assert.equal(authStarted.response.status, 200);
    assert.equal(authStarted.data.options.allowCredentials, undefined);
    const authenticated = await request('/api/auth/passkey/verify', {
      method: 'POST',
      body: {
        challengeId: authStarted.data.challengeId,
        credential: {
          id: credentialId,
          response: { userHandle: started.data.options.user.id },
        },
      },
    });
    assert.equal(authenticated.response.status, 200);
    assert.ok(authenticated.data.token);
    const list = await request('/api/users/me/passkeys', {
      token: authenticated.data.token,
    });
    assert.equal(list.response.status, 200);
    assert.equal(list.data.length, 1);
    assert.equal(list.data[0].credentialId, undefined);
    const passkeyId = list.data[0].id;

    const renamed = await request(`/api/users/me/passkeys/${passkeyId}`, {
      method: 'PATCH', token: authenticated.data.token, body: { name: 'Windows Hello' },
    });
    assert.equal(renamed.response.status, 200);
    assert.equal(renamed.data.name, 'Windows Hello');

    const badRevoke = await request(`/api/users/me/passkeys/${passkeyId}`, {
      method: 'DELETE', token: authenticated.data.token,
      body: { currentPassword: 'falsch' },
    });
    assert.equal(badRevoke.response.status, 403);
    const revoked = await request(`/api/users/me/passkeys/${passkeyId}`, {
      method: 'DELETE', token: authenticated.data.token,
      body: { currentPassword: 'MaterialKompass2026!' },
    });
    assert.equal(revoked.response.status, 204);
    assert.equal((await request('/api/auth/me', { token: authenticated.data.token })).response.status, 401);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('passkey challenges are single-use and require the discoverable user handle', async () => {
  const { server, request, token } = await start();
  try {
    const started = await request('/api/users/me/passkeys/options', {
      method: 'POST', token,
      body: { name: 'Reserve', currentPassword: 'MaterialKompass2026!' },
    });
    const userHandle = started.data.options.user.id;
    assert.equal((await request('/api/users/me/passkeys/verify', {
      method: 'POST', token,
      body: {
        challengeId: started.data.challengeId,
        credential: { id: credentialId, response: { userHandle } },
      },
    })).response.status, 201);

    const authStarted = await request('/api/auth/passkey/options', {
      method: 'POST', body: {},
    });
    const credential = { id: credentialId, response: { userHandle } };
    assert.equal((await request('/api/auth/passkey/verify', {
      method: 'POST',
      body: { challengeId: authStarted.data.challengeId, credential },
    })).response.status, 200);
    assert.equal((await request('/api/auth/passkey/verify', {
      method: 'POST',
      body: { challengeId: authStarted.data.challengeId, credential },
    })).response.status, 401);

    const missingHandleChallenge = await request('/api/auth/passkey/options', {
      method: 'POST', body: {},
    });
    assert.equal((await request('/api/auth/passkey/verify', {
      method: 'POST',
      body: {
        challengeId: missingHandleChallenge.data.challengeId,
        credential: { id: credentialId, response: {} },
      },
    })).response.status, 401);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('association endpoints expose no unconfigured native identifiers', async () => {
  const { server, request } = await start();
  try {
    const android = await request('/.well-known/assetlinks.json');
    assert.equal(android.response.status, 200);
    assert.match(android.response.headers.get('cache-control'), /max-age=3600/);
    assert.deepEqual(android.data, []);
    assert.equal((await request('/.well-known/apple-app-site-association')).response.status, 404);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
