const assert = require('node:assert/strict');
const test = require('node:test');
const { createProvisionerServer } = require('./server');

test('provisioner accepts only authenticated, valid mailbox creation', async () => {
  const created = [];
  const token = 'a'.repeat(32);
  const server = createProvisionerServer({
    token,
    domain: 'materialkompass.org',
    async createMailbox(mailbox) { created.push(mailbox); },
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  try {
    assert.equal((await fetch(`${baseUrl}/mailboxes`, { method: 'POST' })).status, 401);
    const response = await fetch(`${baseUrl}/mailboxes`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        email: 'scanner01@materialkompass.org',
        password: 'a-secure-password',
      }),
    });
    assert.equal(response.status, 201);
    assert.deepEqual(created, [{
      email: 'scanner01@materialkompass.org',
      password: 'a-secure-password',
    }]);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('provisioner rejects other domains', async () => {
  const token = 'b'.repeat(32);
  const server = createProvisionerServer({
    token,
    domain: 'materialkompass.org',
    async createMailbox() { throw new Error('must not be called'); },
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  try {
    const response = await fetch(
      `http://127.0.0.1:${server.address().port}/mailboxes`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${token}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          email: 'scanner@example.org',
          password: 'a-secure-password',
        }),
      },
    );
    assert.equal(response.status, 400);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
