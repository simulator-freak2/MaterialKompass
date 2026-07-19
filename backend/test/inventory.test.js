const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');

async function serverAndToken() {
  const app = createApp();
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  const login = await fetch(`${baseUrl}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      email: 'admin@materialkompass.org',
      password: 'MaterialKompass2026!',
    }),
  });
  return { server, baseUrl, token: (await login.json()).token };
}

test('inventory creates quantity items and tracks issue and return', async () => {
  const { server, baseUrl, token } = await serverAndToken();
  const headers = {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${token}`,
  };
  try {
    const createdResponse = await fetch(`${baseUrl}/api/material`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        name: 'Karabiner',
        categoryCode: '02',
        subcategoryCode: '02-02',
        locationId: 'loc-1',
        stockStructureId: 'stock-1',
        status: 'Lagernd',
        itemType: 'bulk',
        quantity: 50,
        unit: 'Stück',
      }),
    });
    assert.equal(createdResponse.status, 201);
    const item = await createdResponse.json();
    assert.match(item.inventoryNumber, /^10050035-02-02-\d{3,}$/);
    assert.equal(item.availableQuantity, 50);

    const immutable = await fetch(`${baseUrl}/api/material/${item.id}`, {
      method: 'PUT',
      headers,
      body: JSON.stringify({ inventoryNumber: 'NEU' }),
    });
    assert.equal(immutable.status, 400);

    const issue = await fetch(`${baseUrl}/api/material/transactions/bulk`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        action: 'issue',
        recipient: 'Einsatz',
        items: [{ materialId: item.id, quantity: 10 }],
      }),
    });
    assert.equal(issue.status, 201);
    let detail = await fetch(`${baseUrl}/api/material/${item.id}`, { headers })
      .then((response) => response.json());
    assert.equal(detail.availableQuantity, 40);
    assert.equal(detail.status, 'Ausgegeben');

    const returned = await fetch(`${baseUrl}/api/material/transactions/bulk`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        action: 'return',
        items: [{ materialId: item.id, quantity: 10 }],
      }),
    });
    assert.equal(returned.status, 201);
    detail = await fetch(`${baseUrl}/api/material/${item.id}`, { headers })
      .then((response) => response.json());
    assert.equal(detail.status, 'Lagernd');
    assert.equal(detail.movements.length, 2);
  } finally {
    server.close();
  }
});

test('inventory bulk operations are atomic and archive is reversible', async () => {
  const { server, baseUrl, token } = await serverAndToken();
  const headers = {
    'Content-Type': 'application/json',
    Authorization: `Bearer ${token}`,
  };
  try {
    const issue = await fetch(`${baseUrl}/api/material/transactions/bulk`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        action: 'issue',
        recipient: 'Test',
        items: [
          { materialId: 'material-1', quantity: 1 },
          { materialId: 'missing', quantity: 1 },
        ],
      }),
    });
    assert.equal(issue.status, 409);
    let detail = await fetch(`${baseUrl}/api/material/material-1`, { headers })
      .then((response) => response.json());
    assert.equal(detail.issuedQuantity, 0);

    assert.equal((await fetch(`${baseUrl}/api/material/material-1/archive`, {
      method: 'POST', headers,
    })).status, 200);
    const archived = await fetch(`${baseUrl}/api/material?archived=true`, { headers })
      .then((response) => response.json());
    assert.ok(archived.some((item) => item.id === 'material-1'));

    const restored = await fetch(`${baseUrl}/api/material/material-1/restore`, {
      method: 'POST', headers,
    });
    assert.equal(restored.status, 200);
    detail = await restored.json();
    assert.equal(detail.archived, false);
  } finally {
    server.close();
  }
});
