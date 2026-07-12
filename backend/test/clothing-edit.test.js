const test = require('node:test');
const assert = require('node:assert/strict');
const { createApp } = require('../src/app');

function startServer() {
  const app = createApp();
  return new Promise((resolve) => {
    const server = app.listen(0, () => {
      const address = server.address();
      resolve({ server, baseUrl: `http://127.0.0.1:${address.port}` });
    });
  });
}

test('edit clothing item updates stored values', async () => {
  const { server, baseUrl } = await startServer();

  try {
    const loginResponse = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email: 'admin@materialkompass.local',
        password: 'Admin123!',
      }),
    });

    assert.equal(loginResponse.status, 200);
    const loginData = await loginResponse.json();
    const token = loginData.token;

    const createResponse = await fetch(`${baseUrl}/api/clothing`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        name: 'Alte Jacke',
        inventoryNumber: 'KK-0100',
        size: 'M',
        locationId: 'loc-2',
        status: 'Lagernd',
      }),
    });

    assert.equal(createResponse.status, 201);
    const createdItem = await createResponse.json();

    const updateResponse = await fetch(`${baseUrl}/api/clothing/${createdItem.id}`, {
      method: 'PUT',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        name: 'Neue Jacke',
        inventoryNumber: 'KK-0101',
        size: 'L',
        locationId: 'loc-3',
        status: 'Lagernd',
      }),
    });

    assert.equal(updateResponse.status, 200);
    const updatedItem = await updateResponse.json();
    assert.equal(updatedItem.name, 'Neue Jacke');
    assert.equal(updatedItem.inventoryNumber, 'KK-0101');
    assert.equal(updatedItem.size, 'L');
    assert.equal(updatedItem.locationId, 'loc-3');
  } finally {
    server.close();
  }
});

test('delete clothing item removes it from storage', async () => {
  const { server, baseUrl } = await startServer();

  try {
    const loginResponse = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email: 'admin@materialkompass.local',
        password: 'Admin123!',
      }),
    });

    assert.equal(loginResponse.status, 200);
    const loginData = await loginResponse.json();
    const token = loginData.token;

    const createResponse = await fetch(`${baseUrl}/api/clothing`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        name: 'Zu löschende Jacke',
        inventoryNumber: 'KK-0200',
        size: 'S',
        locationId: 'loc-2',
        status: 'Lagernd',
      }),
    });

    assert.equal(createResponse.status, 201);
    const createdItem = await createResponse.json();

    const deleteResponse = await fetch(`${baseUrl}/api/clothing/${createdItem.id}`, {
      method: 'DELETE',
      headers: {
        Authorization: `Bearer ${token}`,
      },
    });

    assert.equal(deleteResponse.status, 200);
    const listResponse = await fetch(`${baseUrl}/api/clothing`, {
      headers: {
        Authorization: `Bearer ${token}`,
      },
    });

    assert.equal(listResponse.status, 200);
    const clothingItems = await listResponse.json();
    assert.equal(
      clothingItems.some((item) => item.id === createdItem.id),
      false,
    );
  } finally {
    server.close();
  }
});

test('history endpoint returns deleted clothing entries', async () => {
  const { server, baseUrl } = await startServer();

  try {
    const loginResponse = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email: 'admin@materialkompass.local',
        password: 'Admin123!',
      }),
    });

    assert.equal(loginResponse.status, 200);
    const loginData = await loginResponse.json();
    const token = loginData.token;

    const createResponse = await fetch(`${baseUrl}/api/clothing`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        name: 'Historie Jacke',
        inventoryNumber: 'KK-0300',
        size: 'XL',
        locationId: 'loc-3',
        status: 'Lagernd',
      }),
    });

    assert.equal(createResponse.status, 201);
    const createdItem = await createResponse.json();

    const deleteResponse = await fetch(`${baseUrl}/api/clothing/${createdItem.id}`, {
      method: 'DELETE',
      headers: {
        Authorization: `Bearer ${token}`,
      },
    });

    assert.equal(deleteResponse.status, 200);

    const historyResponse = await fetch(`${baseUrl}/api/clothing/history`, {
      headers: {
        Authorization: `Bearer ${token}`,
      },
    });

    assert.equal(historyResponse.status, 200);
    const history = await historyResponse.json();
    assert.ok(history.some((entry) => entry.id === createdItem.id));
  } finally {
    server.close();
  }
});
