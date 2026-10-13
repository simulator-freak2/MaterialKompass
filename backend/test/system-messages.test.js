const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { createApp } = require('../src/app');

async function withServer(messageDocument, callback) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'materialkompass-messages-'));
  const messagePath = path.join(directory, 'public-messages.json');
  fs.writeFileSync(messagePath, JSON.stringify(messageDocument), { mode: 0o600 });
  const app = createApp({ systemMessagesPath: messagePath });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  try {
    await callback(`http://127.0.0.1:${server.address().port}`);
  } finally {
    await new Promise((resolve) => server.close(resolve));
    fs.rmSync(directory, { recursive: true, force: true });
  }
}

function document() {
  return {
    schemaVersion: 1,
    messages: [
      {
        id: 'release-1.6.0', type: 'release', version: '1.6.0',
        title: 'MaterialKompass 1.6.0', message: 'Neue Funktionen',
        publishedAt: '2026-10-01T10:00:00.000Z',
      },
      {
        id: 'maintenance-2026-10-20', type: 'maintenance',
        title: 'Wartungsarbeiten', message: 'Kurze Unterbrechung möglich.',
        publishedAt: '2026-10-01T10:00:00.000Z',
        startsAt: '2099-10-20T18:00:00.000Z',
        endsAt: '2099-10-20T20:00:00.000Z',
      },
    ],
  };
}

test('maintenance information is public while release notes require login', async () => {
  await withServer(document(), async (baseUrl) => {
    const response = await fetch(`${baseUrl}/api/system/messages`);
    assert.equal(response.status, 200);
    const data = await response.json();
    assert.equal(data.messages.length, 1);
    assert.equal(data.messages[0].type, 'maintenance');
  });
});

test('release note acknowledgement is stored per user', async () => {
  await withServer(document(), async (baseUrl) => {
    const login = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email: 'admin@materialkompass.org', password: 'MaterialKompass2026!',
      }),
    });
    const { token } = await login.json();
    const headers = { Authorization: `Bearer ${token}` };
    const before = await (await fetch(`${baseUrl}/api/system/messages/me`, { headers })).json();
    assert.equal(before.messages.find((entry) => entry.type === 'release').acknowledged, false);

    const acknowledgement = await fetch(
      `${baseUrl}/api/system/messages/release-1.6.0/acknowledge`,
      { method: 'POST', headers },
    );
    assert.equal(acknowledgement.status, 204);
    const after = await (await fetch(`${baseUrl}/api/system/messages/me`, { headers })).json();
    assert.equal(after.messages.find((entry) => entry.type === 'release').acknowledged, true);
  });
});

test('invalid message files fail closed', async () => {
  await withServer({ schemaVersion: 1, messages: [{ id: '../bad' }] }, async (baseUrl) => {
    const response = await fetch(`${baseUrl}/api/system/messages`);
    assert.equal(response.status, 500);
  });
});
