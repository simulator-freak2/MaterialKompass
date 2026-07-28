const assert = require('node:assert/strict');
const test = require('node:test');
const http = require('node:http');
const { createMailboxProvisioner } = require('../src/mailbox-provisioner-client');

test('mailbox provisioner client authenticates and sends mailbox credentials', async () => {
  let received;
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      received = {
        authorization: req.headers.authorization,
        body: JSON.parse(body),
      };
      res.writeHead(201, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ created: true, email: received.body.email }));
    });
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  try {
    const provisioner = createMailboxProvisioner({
      baseUrl: `http://127.0.0.1:${server.address().port}`,
      token: 'test-token',
    });
    await provisioner.createMailbox({
      email: 'scanner01@materialkompass.org',
      password: 'secret-password',
    });
    assert.equal(received.authorization, 'Bearer test-token');
    assert.deepEqual(received.body, {
      email: 'scanner01@materialkompass.org',
      password: 'secret-password',
    });
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('mailbox provisioner client reports missing configuration', async () => {
  const provisioner = createMailboxProvisioner({ baseUrl: '', token: '' });
  await assert.rejects(
    provisioner.createMailbox({ email: 'scanner@example.org', password: 'secret' }),
    (error) => error.status === 503,
  );
});

test('mailbox provisioner client can keep credentials off the TCP network', async () => {
  const pipePath = process.platform === 'win32'
    ? `\\\\.\\pipe\\materialkompass-test-${process.pid}-${Date.now()}`
    : `/tmp/materialkompass-test-${process.pid}-${Date.now()}.sock`;
  let received;
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', (chunk) => { body += chunk; });
    req.on('end', () => {
      received = JSON.parse(body);
      res.writeHead(201, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ created: true }));
    });
  });
  await new Promise((resolve) => server.listen(pipePath, resolve));
  try {
    const provisioner = createMailboxProvisioner({
      socketPath: pipePath,
      token: 'local-socket-token',
    });
    await provisioner.createMailbox({
      email: 'scanner02@materialkompass.org',
      password: 'local-only-password',
    });
    assert.deepEqual(received, {
      email: 'scanner02@materialkompass.org',
      password: 'local-only-password',
    });
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
