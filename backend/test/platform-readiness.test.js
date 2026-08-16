const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { createApp } = require('../src/app');
const {
  createCorsOptions, loadRuntimeConfig, parseOrigins, parsePort, parseTrustProxy,
} = require('../src/config');

async function withServer(callback, options = {}) {
  const app = createApp(options);
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  try {
    await callback(`http://127.0.0.1:${server.address().port}`);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

function checkOrigin(options, origin) {
  return new Promise((resolve) => options.origin(origin, (error, allowed) => resolve({ error, allowed })));
}

test('health and API information are available to every client platform', async () => {
  await withServer(async (baseUrl) => {
    const health = await fetch(`${baseUrl}/health`);
    assert.equal(health.status, 200);
    assert.equal(health.headers.get('x-api-version'), '1');
    assert.ok(health.headers.get('x-request-id'));
    assert.equal((await health.json()).status, 'ok');

    const readiness = await fetch(`${baseUrl}/ready`);
    assert.equal(readiness.status, 200);
    assert.equal((await readiness.json()).status, 'ready');

    const info = await fetch(`${baseUrl}/api/info`);
    const data = await info.json();
    assert.deepEqual(data.supportedClients, ['windows', 'linux', 'android', 'ios', 'macos']);

    const legal = await fetch(`${baseUrl}/api/legal`);
    assert.equal(legal.status, 200);
    const legalData = await legal.json();
    assert.equal(legalData.hasDummies, true);
    assert.equal(Array.isArray(legalData.privacy.rights), true);

    const missing = await fetch(`${baseUrl}/api/does-not-exist`);
    assert.equal(missing.status, 404);
    assert.equal(typeof (await missing.json()).requestId, 'string');
  });
});

test('desktop downloads report availability and stream configured release files', async () => {
  const fixture = path.resolve(__dirname, '..', 'package.json');
  await withServer(async (baseUrl) => {
    const metadataResponse = await fetch(`${baseUrl}/api/downloads`);
    assert.equal(metadataResponse.status, 200);
    const metadata = await metadataResponse.json();
    const windows = metadata.find((entry) => entry.platform === 'windows');
    const linux = metadata.find((entry) => entry.platform === 'linux');
    const android = metadata.find((entry) => entry.platform === 'android');
    const ios = metadata.find((entry) => entry.platform === 'ios');
    const macos = metadata.find((entry) => entry.platform === 'macos');
    assert.equal(windows.available, true);
    assert.equal(windows.fileName, 'MaterialKompass-Windows.exe');
    assert.equal(windows.downloadUrl, '/api/downloads/windows');
    assert.equal(linux.available, false);
    assert.equal(android.available, false);
    assert.equal(ios.available, false);
    assert.equal(macos.available, false);
    assert.equal(ios.label, 'iOS');
    assert.equal(macos.label, 'macOS');

    const updateResponse = await fetch(`${baseUrl}/api/client-updates/windows?currentVersion=0.9.0`);
    assert.equal(updateResponse.status, 200);
    const update = await updateResponse.json();
    assert.equal(update.version, '1.3.0');
    assert.equal(update.updateAvailable, true);
    assert.equal(update.required, false);
    assert.equal(update.downloadUrl, '/api/downloads/windows');
    assert.equal(update.fileName, 'MaterialKompass-Windows.exe');
    assert.equal(update.sizeBytes > 0, true);
    assert.match(update.sha256, /^[a-f0-9]{64}$/);

    const download = await fetch(`${baseUrl}${windows.downloadUrl}`);
    assert.equal(download.status, 200);
    assert.match(download.headers.get('content-disposition'), /MaterialKompass-Windows.exe/);
    assert.match(await download.text(), /materialkompass-backend/);

    const unavailable = await fetch(`${baseUrl}/api/downloads/linux`);
    assert.equal(unavailable.status, 404);
  }, {
    downloads: {
      windows: { filePath: fixture, fileName: 'MaterialKompass-Windows.exe' },
      linux: { filePath: path.resolve(__dirname, 'missing-linux-release.deb') },
    },
  });
});

test('CORS allows native clients and configured browser clients only', async () => {
  const options = createCorsOptions({ corsOrigin: 'https://app.example.org, http://localhost:8080/' });
  assert.equal((await checkOrigin(options, undefined)).allowed, true);
  assert.equal((await checkOrigin(options, 'https://app.example.org')).allowed, true);
  assert.equal((await checkOrigin(options, 'http://localhost:8080')).allowed, true);
  assert.equal((await checkOrigin(options, 'https://attacker.example')).error.status, 403);
});

test('runtime configuration validates network settings', () => {
  assert.equal(parsePort('3001'), 3001);
  assert.throws(() => parsePort('70000'), /PORT/);
  assert.deepEqual(parseOrigins('https://one.example/, https://two.example'), [
    'https://one.example',
    'https://two.example',
  ]);
  assert.deepEqual(loadRuntimeConfig({
    NODE_ENV: 'production',
    JWT_SECRET: 'a-secure-random-secret-with-32-characters',
    CORS_ORIGIN: 'https://app.example.org',
    APP_BASE_URL: 'https://app.example.org',
    TRUST_PROXY: '1',
    SMTP_HOST: 'smtp.example.org',
    SMTP_USER: 'mailer@example.org',
    SMTP_PASSWORD: 'secret',
    MAIL_FROM: 'MaterialKompass <mailer@example.org>',
    DEFECT_IMAP_HOST: 'imap.example.org',
    DEFECT_IMAP_USER: 'maengel@example.org',
    DEFECT_IMAP_PASSWORD: 'secret',
    PROCUREMENT_IMAP_HOST: 'imap.example.org',
    PROCUREMENT_IMAP_USER: 'angebote@example.org',
    PROCUREMENT_IMAP_PASSWORD: 'secret',
    MAILBOX_PROVISIONER_TOKEN: 'b'.repeat(64),
    MAILBOX_PASSWORD_ENCRYPTION_KEY: 'c'.repeat(64),
    MAILBOX_PROVISIONER_SOCKET: '/run/materialkompass/provisioner.sock',
    LEGAL_CONTROLLER_NAME: 'Example Organisation',
    LEGAL_LEGAL_FORM: 'e. V.',
    LEGAL_REPRESENTED_BY: 'Erika Beispiel',
    LEGAL_STREET: 'Beispielweg 1',
    LEGAL_POSTAL_CODE: '12345',
    LEGAL_CITY: 'Beispielstadt',
    LEGAL_COUNTRY: 'Deutschland',
    LEGAL_EMAIL: 'legal@example.org',
    LEGAL_PHONE: '+49 30 123456',
    LEGAL_SUPERVISORY_AUTHORITY: 'Landesaufsicht',
    LEGAL_SUPERVISORY_WEBSITE: 'https://authority.example.org',
    LEGAL_ACCOUNT_BASIS: 'Art. 6 Abs. 1 lit. b DSGVO',
    LEGAL_OPERATIONS_BASIS: 'Art. 6 Abs. 1 lit. f DSGVO',
    LEGAL_LEGITIMATE_INTERESTS: 'Sichere interne Materialverwaltung',
    DB_HOST: 'database',
    PORT: '4000',
  }), {
    nodeEnv: 'production',
    host: '0.0.0.0',
    port: 4000,
    shutdownTimeoutMs: 10000,
  });
  assert.equal(parseTrustProxy('1'), 1);
  assert.equal(parseTrustProxy('loopback'), 'loopback');
  assert.throws(() => parseTrustProxy('true'), /TRUST_PROXY/);
  assert.throws(() => loadRuntimeConfig({
    NODE_ENV: 'production',
    JWT_SECRET: 'short',
    CORS_ORIGIN: 'https://app.example.org',
  }), /JWT_SECRET/);
  assert.throws(() => loadRuntimeConfig({
    NODE_ENV: 'production',
    JWT_SECRET: 'a-secure-random-secret-with-32-characters',
    CORS_ORIGIN: '*',
  }), /CORS_ORIGIN/);
  assert.throws(() => loadRuntimeConfig({
    NODE_ENV: 'production',
    JWT_SECRET: 'a-secure-random-secret-with-32-characters',
    CORS_ORIGIN: 'https://app.example.org',
    APP_BASE_URL: 'https://app.example.org',
    TRUST_PROXY: '1',
    DB_HOST: 'database',
  }), /SMTP/);
  assert.throws(() => loadRuntimeConfig({
    NODE_ENV: 'production',
    JWT_SECRET: 'a-secure-random-secret-with-32-characters',
    CORS_ORIGIN: 'http://app.example.org',
  }), /CORS_ORIGIN/);
});

test('readiness reports database failures without failing liveness', async () => {
  await withServer(async (baseUrl) => {
    assert.equal((await fetch(`${baseUrl}/health`)).status, 200);
    const readiness = await fetch(`${baseUrl}/ready`);
    assert.equal(readiness.status, 503);
    assert.equal((await readiness.json()).status, 'not-ready');
  }, {
    dataStore: {
      async checkHealth() { throw new Error('database unavailable'); },
      async saveCollections() {},
    },
  });
});

test('production API rejects cleartext requests outside the health endpoint', async () => {
  const previous = {
    NODE_ENV: process.env.NODE_ENV,
    JWT_SECRET: process.env.JWT_SECRET,
    TRUST_PROXY: process.env.TRUST_PROXY,
    CORS_ORIGIN: process.env.CORS_ORIGIN,
    MAILBOX_PASSWORD_ENCRYPTION_KEY: process.env.MAILBOX_PASSWORD_ENCRYPTION_KEY,
  };
  Object.assign(process.env, {
    NODE_ENV: 'production',
    JWT_SECRET: 'a-secure-random-secret-with-32-characters',
    TRUST_PROXY: 'loopback',
    CORS_ORIGIN: 'https://app.example.org',
    MAILBOX_PASSWORD_ENCRYPTION_KEY: 'c'.repeat(64),
  });
  try {
    await withServer(async (baseUrl) => {
      assert.equal((await fetch(`${baseUrl}/health`)).status, 200);
      assert.equal((await fetch(`${baseUrl}/ready`)).status, 426);
      assert.equal((await fetch(`${baseUrl}/api/info`)).status, 426);
      assert.equal((await fetch(`${baseUrl}/api/info`, {
        headers: { 'X-Forwarded-Proto': 'https' },
      })).status, 200);
    });
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
});
