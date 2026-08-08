const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');

async function start() {
  const app = createApp({ skipEmailVerification: true });
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
  return {
    server,
    baseUrl,
    token: (await login.json()).token,
  };
}

const headers = (token) => ({
  Authorization: `Bearer ${token}`,
  'Content-Type': 'application/json',
});

test('material and clothing persist label metadata', async () => {
  const { server, baseUrl, token } = await start();
  try {
    const materialResponse = await fetch(`${baseUrl}/api/material`, {
      method: 'POST',
      headers: headers(token),
      body: JSON.stringify({
        name: 'Stromerzeuger',
        categoryCode: '02',
        subcategoryCode: '02-02',
        locationId: 'loc-1',
        storagePositionId: 'stock-1',
        status: 'Lagernd',
        itemType: 'individual',
        quantity: 1,
        manufacturer: 'Honda',
        manufacturingYear: '2023',
        purchaseDate: '2024-02-01',
      }),
    });
    assert.equal(materialResponse.status, 201);
    const material = await materialResponse.json();
    assert.equal(material.manufacturer, 'Honda');
    assert.equal(material.manufacturingYear, '2023');

    const clothingResponse = await fetch(`${baseUrl}/api/clothing`, {
      method: 'POST',
      headers: headers(token),
      body: JSON.stringify({
        name: 'Softshelljacke',
        categoryId: '04-01',
        size: 'M',
        locationId: 'loc-2',
        storagePositionId: 'stock-2',
        manufacturer: 'JET',
        manufacturingYear: '2026',
        purchaseDate: '2026-01-15',
      }),
    });
    assert.equal(clothingResponse.status, 201);
    const clothing = await clothingResponse.json();
    assert.equal(clothing.manufacturer, 'JET');
    assert.equal(clothing.manufacturingYear, '2026');
    assert.equal(clothing.purchaseDate, '2026-01-15');
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
