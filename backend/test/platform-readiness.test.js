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

    const info = await fetch(`${baseUrl}/api/info`);
    const data = await info.json();
    assert.deepEqual(data.supportedClients, ['windows', 'linux', 'android', 'ios', 'macos']);

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
    assert.equal(windows.available, true);
    assert.equal(windows.fileName, 'MaterialKompass-Windows.exe');
    assert.equal(windows.downloadUrl, '/api/downloads/windows');
    assert.equal(linux.available, false);
    assert.equal(android.available, false);

    const updateResponse = await fetch(`${baseUrl}/api/client-updates/windows?currentVersion=0.9.0`);
    assert.equal(updateResponse.status, 200);
    const update = await updateResponse.json();
    assert.equal(update.version, '1.0.0');
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
    SMTP_HOST: 'smtp.example.org',
    SMTP_USER: 'mailer@example.org',
    SMTP_PASSWORD: 'secret',
    MAIL_FROM: 'MaterialKompass <mailer@example.org>',
    IMAP_HOST: 'imap.example.org',
    IMAP_USER: 'mailer@example.org',
    IMAP_PASSWORD: 'secret',
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
    DB_HOST: 'database',
  }), /SMTP/);
  assert.throws(() => loadRuntimeConfig({
    NODE_ENV: 'production',
    JWT_SECRET: 'a-secure-random-secret-with-32-characters',
    CORS_ORIGIN: 'https://app.example.org',
    APP_BASE_URL: 'https://app.example.org',
    SMTP_HOST: 'smtp.example.org',
    SMTP_USER: 'mailer@example.org',
    SMTP_PASSWORD: 'secret',
    MAIL_FROM: 'MaterialKompass <mailer@example.org>',
    DB_HOST: 'database',
  }), /IMAP/);
});
