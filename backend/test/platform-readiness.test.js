const test = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');
const {
  createCorsOptions, loadRuntimeConfig, parseOrigins, parsePort, parseTrustProxy,
} = require('../src/config');

async function withServer(callback) {
  const app = createApp();
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
});
