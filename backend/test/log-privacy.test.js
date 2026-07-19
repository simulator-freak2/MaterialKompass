const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');

async function start() {
  const app = createApp({ skipEmailVerification: true });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  return { server, baseUrl: `http://127.0.0.1:${server.address().port}` };
}

async function login(baseUrl, identifier, password) {
  const response = await fetch(`${baseUrl}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ identifier, password }),
  });
  assert.equal(response.status, 200);
  return (await response.json()).token;
}

const headers = (token) => ({
  Authorization: `Bearer ${token}`,
  'Content-Type': 'application/json',
});

test('logs expose usernames instead of email addresses', async () => {
  const { server, baseUrl } = await start();
  try {
    const admin = await login(baseUrl, 'admin@materialkompass.org', 'MaterialKompass2026!');
    const dashboard = await fetch(`${baseUrl}/api/dashboard`, { headers: headers(admin) })
      .then((response) => response.json());
    const loginEntry = dashboard.recentActivity.find((entry) => entry.action === 'login');
    assert.equal(loginEntry.actor, 'admin');
    assert.equal(loginEntry.actor.includes('@'), false);

    const materialwart = await login(baseUrl, 'materialwart@materialkompass.local', 'Material123!');
    const procurement = await fetch(`${baseUrl}/api/procurement`, {
      method: 'POST',
      headers: headers(materialwart),
      body: JSON.stringify({
        title: 'Datenschutztest',
        reason: 'Protokoll prüfen',
        requestedBudgetGross: 10,
        items: [{ name: 'Testmaterial', categoryId: '02', quantity: 1 }],
      }),
    }).then((response) => response.json());
    assert.equal(procurement.history[0].actor, 'materialwart');
    assert.equal(procurement.history[0].actor.includes('@'), false);

    const movements = await fetch(`${baseUrl}/api/material/transactions/bulk`, {
      method: 'POST',
      headers: headers(materialwart),
      body: JSON.stringify({
        action: 'issue',
        recipient: 'Datenschutztest',
        items: [{ materialId: 'material-1', quantity: 1 }],
      }),
    }).then((response) => response.json());
    assert.equal(movements[0].actor, 'materialwart');
    assert.equal(movements[0].actor.includes('@'), false);
  } finally {
    server.close();
  }
});
