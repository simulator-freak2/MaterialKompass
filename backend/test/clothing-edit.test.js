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

test('automatically generated clothing numbers use category IDs', async () => {
  const { server, baseUrl } = await startServer();
  try {
    const loginResponse = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email: 'admin@materialkompass.org',
        password: 'MaterialKompass2026!',
      }),
    });
    const token = (await loginResponse.json()).token;
    const response = await fetch(`${baseUrl}/api/clothing`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        name: 'Automatisch nummerierte Jacke',
        categoryId: '04-04',
        size: 'M',
        locationId: 'loc-2',
        storagePositionId: 'stock-2',
      }),
    });
    assert.equal(response.status, 201);
    assert.equal((await response.json()).inventoryNumber, '10050035-04-04-0001');
  } finally {
    server.close();
  }
});

test('edit clothing item updates stored values', async () => {
  const { server, baseUrl } = await startServer();

  try {
    const loginResponse = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email: 'admin@materialkompass.org',
        password: 'MaterialKompass2026!',
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
        storagePositionId: 'stock-2',
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
        storagePositionId: 'stock-3',
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
        email: 'admin@materialkompass.org',
        password: 'MaterialKompass2026!',
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
        storagePositionId: 'stock-2',
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
        email: 'admin@materialkompass.org',
        password: 'MaterialKompass2026!',
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
        storagePositionId: 'stock-3',
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

test('bulk transaction with multiple clothing items succeeds', async () => {
  const { server, baseUrl } = await startServer();

  try {
    const loginResponse = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email: 'admin@materialkompass.org',
        password: 'MaterialKompass2026!',
      }),
    });

    assert.equal(loginResponse.status, 200);
    const loginData = await loginResponse.json();
    const token = loginData.token;

    const items = await Promise.all([
      fetch(`${baseUrl}/api/clothing`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
        },
        body: JSON.stringify({
          name: 'Bulk Jacke 1',
          inventoryNumber: 'KK-0400',
          size: 'M',
          locationId: 'loc-2',
          storagePositionId: 'stock-2',
          status: 'Lagernd',
        }),
      }).then((res) => res.json()),
      fetch(`${baseUrl}/api/clothing`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${token}`,
        },
        body: JSON.stringify({
          name: 'Bulk Jacke 2',
          inventoryNumber: 'KK-0401',
          size: 'L',
          locationId: 'loc-2',
          storagePositionId: 'stock-2',
          status: 'Lagernd',
        }),
      }).then((res) => res.json()),
    ]);

    const transactionResponse = await fetch(`${baseUrl}/api/transactions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        clothingIds: items.map((item) => item.id),
        personName: 'Max Mustermann',
        action: 'ausgegeben',
      }),
    });

    assert.equal(transactionResponse.status, 201);
    const transactions = await transactionResponse.json();
    assert.equal(Array.isArray(transactions), true);
    assert.equal(transactions.length, 2);

    const listResponse = await fetch(`${baseUrl}/api/clothing`, {
      headers: {
        Authorization: `Bearer ${token}`,
      },
    });

    assert.equal(listResponse.status, 200);
    const clothingItems = await listResponse.json();
    const issuedItems = clothingItems.filter((item) => items.some((created) => created.id === item.id));
    assert.equal(issuedItems.length, 2);
    assert.equal(issuedItems.every((item) => item.status === 'Ausgegeben'), true);
  } finally {
    server.close();
  }
});

test('transactions endpoint returns existing transactions for authorized users', async () => {
  const { server, baseUrl } = await startServer();

  try {
    const loginResponse = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email: 'admin@materialkompass.org',
        password: 'MaterialKompass2026!',
      }),
    });

    assert.equal(loginResponse.status, 200);
    const loginData = await loginResponse.json();
    const token = loginData.token;

    const response = await fetch(`${baseUrl}/api/transactions`, {
      headers: {
        Authorization: `Bearer ${token}`,
      },
    });

    assert.equal(response.status, 200);
    const transactions = await response.json();
    assert.ok(Array.isArray(transactions));
  } finally {
    server.close();
  }
});

test('posting invalid transaction action returns 400', async () => {
  const { server, baseUrl } = await startServer();

  try {
    const loginResponse = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email: 'admin@materialkompass.org',
        password: 'MaterialKompass2026!',
      }),
    });

    assert.equal(loginResponse.status, 200);
    const loginData = await loginResponse.json();
    const token = loginData.token;

    const response = await fetch(`${baseUrl}/api/transactions`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        clothingIds: ['clothing-1'],
        personName: 'Test User',
        action: 'ausgeben',
      }),
    });

    assert.equal(response.status, 400);
    const errorData = await response.json();
    assert.equal(errorData.error, 'Invalid action. Use ausgegeben or zurückgegeben.');
  } finally {
    server.close();
  }
});

test('bulk category change moves same-category clothing and assigns new inventory numbers', async () => {
  const { server, baseUrl } = await startServer();
  try {
    const loginResponse = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email: 'admin@materialkompass.org',
        password: 'MaterialKompass2026!',
      }),
    });
    const token = (await loginResponse.json()).token;
    const headers = {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    };
    const items = await Promise.all(['1', '2'].map((suffix) =>
      fetch(`${baseUrl}/api/clothing`, {
        method: 'POST',
        headers,
        body: JSON.stringify({
          name: `Jacke ${suffix}`,
          inventoryNumber: `BULK-CATEGORY-${suffix}`,
          categoryId: '04-01',
          size: 'M',
          locationId: 'loc-2',
          storagePositionId: 'stock-2',
        }),
      }).then((response) => response.json())));

    const response = await fetch(`${baseUrl}/api/clothing/bulk-category`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        clothingIds: items.map((item) => item.id),
        categoryId: '04-04',
        reassignInventoryNumbers: true,
      }),
    });

    assert.equal(response.status, 200);
    const updated = await response.json();
    assert.equal(updated.length, 2);
    assert.equal(updated.every((item) => item.categoryId === '04-04'), true);
    assert.deepEqual(updated.map((item) => item.inventoryNumber), [
      '10050035-04-04-0001',
      '10050035-04-04-0002',
    ]);
  } finally {
    server.close();
  }
});

test('bulk category change is atomic for mixed source categories or incompatible sizes', async () => {
  const { server, baseUrl } = await startServer();
  try {
    const loginResponse = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email: 'admin@materialkompass.org',
        password: 'MaterialKompass2026!',
      }),
    });
    const token = (await loginResponse.json()).token;
    const headers = {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    };
    const otherCategoryItem = await fetch(`${baseUrl}/api/clothing`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        name: 'Andere Kategorie',
        inventoryNumber: 'BULK-MIXED-CATEGORY',
        categoryId: '04-04',
        size: 'M',
        locationId: 'loc-2',
        storagePositionId: 'stock-2',
      }),
    }).then((response) => response.json());

    let response = await fetch(`${baseUrl}/api/clothing/bulk-category`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        clothingIds: ['clothing-1', otherCategoryItem.id],
        categoryId: '04-05',
        reassignInventoryNumbers: true,
      }),
    });
    assert.equal(response.status, 400);

    response = await fetch(`${baseUrl}/api/clothing/bulk-category`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        clothingIds: ['clothing-1'],
        categoryId: '04-05',
        reassignInventoryNumbers: true,
      }),
    });
    assert.equal(response.status, 400);

    const clothing = await fetch(`${baseUrl}/api/clothing`, { headers })
      .then((result) => result.json());
    const unchanged = clothing.find((item) => item.id === 'clothing-1');
    assert.equal(unchanged.categoryId, '04-01');
    assert.equal(unchanged.inventoryNumber, '10050035-04-01-0001');
  } finally {
    server.close();
  }
});

test('new app instances start with independent seed data', async () => {
  const first = await startServer();
  let token;

  try {
    const loginResponse = await fetch(`${first.baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email: 'admin@materialkompass.org',
        password: 'MaterialKompass2026!',
      }),
    });
    token = (await loginResponse.json()).token;

    const createResponse = await fetch(`${first.baseUrl}/api/clothing`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({ name: 'Nur in Instanz 1', locationId: 'loc-2', storagePositionId: 'stock-2' }),
    });
    assert.equal(createResponse.status, 201);
  } finally {
    first.server.close();
  }

  const second = await startServer();
  try {
    const loginResponse = await fetch(`${second.baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email: 'admin@materialkompass.org',
        password: 'MaterialKompass2026!',
      }),
    });
    token = (await loginResponse.json()).token;

    const listResponse = await fetch(`${second.baseUrl}/api/clothing`, {
      headers: { Authorization: `Bearer ${token}` },
    });
    const clothingItems = await listResponse.json();
    assert.equal(
      clothingItems.some((item) => item.name === 'Nur in Instanz 1'),
      false,
    );
  } finally {
    second.server.close();
  }
});

test('issue and return keep clothing state consistent', async () => {
  const { server, baseUrl } = await startServer();
  try {
    const loginResponse = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: 'admin@materialkompass.org', password: 'MaterialKompass2026!' }),
    });
    const token = (await loginResponse.json()).token;
    const headers = { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` };

    const issueResponse = await fetch(`${baseUrl}/api/transactions`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ clothingId: 'clothing-1', personName: 'Erika Musterfrau', action: 'ausgegeben' }),
    });
    assert.equal(issueResponse.status, 201);

    let clothing = await fetch(`${baseUrl}/api/clothing`, { headers }).then((response) => response.json());
    let item = clothing.find((entry) => entry.id === 'clothing-1');
    assert.equal(item.status, 'Ausgegeben');
    assert.equal(item.assignedPerson, 'Erika Musterfrau');

    const deleteResponse = await fetch(`${baseUrl}/api/clothing/clothing-1`, { method: 'DELETE', headers });
    assert.equal(deleteResponse.status, 409);

    const returnResponse = await fetch(`${baseUrl}/api/transactions`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ clothingId: 'clothing-1', action: 'zurückgegeben' }),
    });
    assert.equal(returnResponse.status, 201);
    const returnTransaction = await returnResponse.json();
    assert.equal(returnTransaction.personName, 'nicht Ausgegeben');

    clothing = await fetch(`${baseUrl}/api/clothing`, { headers }).then((response) => response.json());
    item = clothing.find((entry) => entry.id === 'clothing-1');
    assert.equal(item.status, 'Lagernd');
    assert.equal(item.assignedPerson, null);
  } finally {
    server.close();
  }
});

test('bulk transactions are atomic when one item is invalid', async () => {
  const { server, baseUrl } = await startServer();
  try {
    const loginResponse = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email: 'admin@materialkompass.org', password: 'MaterialKompass2026!' }),
    });
    const token = (await loginResponse.json()).token;
    const headers = { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` };
    const response = await fetch(`${baseUrl}/api/transactions`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ clothingIds: ['clothing-1', 'missing'], personName: 'Max', action: 'ausgegeben' }),
    });
    assert.equal(response.status, 409);

    const clothing = await fetch(`${baseUrl}/api/clothing`, { headers }).then((result) => result.json());
    const item = clothing.find((entry) => entry.id === 'clothing-1');
    assert.equal(item.status, 'Lagernd');
    assert.equal(item.assignedPerson, null);
  } finally {
    server.close();
  }
});
