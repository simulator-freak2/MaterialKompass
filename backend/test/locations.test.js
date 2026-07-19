const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');

async function fixture() {
  const app = createApp();
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  const login = await fetch(`${baseUrl}/api/auth/login`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: 'admin@materialkompass.org', password: 'MaterialKompass2026!' }),
  });
  const token = (await login.json()).token;
  return { server, baseUrl, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' } };
}

test('central locations manage locations and nested stock structures safely', async () => {
  const { server, baseUrl, headers } = await fixture();
  try {
    let response = await fetch(`${baseUrl}/api/locations`, {
      method: 'POST', headers, body: JSON.stringify({ name: 'Außenlager', code: 'AL', type: 'Lager' }),
    });
    assert.equal(response.status, 201);
    const location = await response.json();

    response = await fetch(`${baseUrl}/api/stock-structures`, {
      method: 'POST', headers, body: JSON.stringify({ name: 'Regal B', section: 'B1', locationId: location.id }),
    });
    assert.equal(response.status, 201);
    const stock = await response.json();

    response = await fetch(`${baseUrl}/api/clothing`, {
      method: 'POST', headers, body: JSON.stringify({ name: 'Testjacke', categoryId: '04-01', size: 'M', locationId: location.id, stockStructureId: stock.id }),
    });
    assert.equal(response.status, 201);
    assert.equal((await response.json()).stockStructureId, stock.id);

    assert.equal((await fetch(`${baseUrl}/api/stock-structures/${stock.id}`, { method: 'DELETE', headers })).status, 409);
    assert.equal((await fetch(`${baseUrl}/api/locations/${location.id}`, { method: 'DELETE', headers })).status, 409);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
