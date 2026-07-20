const assert = require('node:assert/strict');
const test = require('node:test');

const { createApp } = require('../src/app');

async function startServer() {
  const app = createApp();
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  return {
    server,
    baseUrl: `http://127.0.0.1:${server.address().port}`,
  };
}

async function login(baseUrl) {
  const response = await fetch(`${baseUrl}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      email: 'admin@materialkompass.org',
      password: 'MaterialKompass2026!',
    }),
  });
  assert.equal(response.status, 200);
  return (await response.json()).token;
}

test('global categories can be created with explicit IDs and hierarchy', async () => {
  const { server, baseUrl } = await startServer();
  try {
    const token = await login(baseUrl);
    const headers = {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    };

    const createResponse = await fetch(`${baseUrl}/api/categories`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        id: 'PSA',
        name: 'PSA',
        parentId: null,
        useInWardrobe: true,
      }),
    });
    assert.equal(createResponse.status, 201);
    const mainCategory = await createResponse.json();
    assert.equal(mainCategory.id, 'PSA');
    assert.equal(mainCategory.parentId, null);
    assert.equal(mainCategory.useInWardrobe, true);

    const childResponse = await fetch(`${baseUrl}/api/categories`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        id: 'PSA-HELM',
        name: 'Helme',
        parentId: 'PSA',
      }),
    });
    assert.equal(childResponse.status, 201);
    const childCategory = await childResponse.json();
    assert.equal(childCategory.parentId, 'PSA');
    assert.equal(childCategory.useInWardrobe, false);

    const updateResponse = await fetch(`${baseUrl}/api/categories/PSA-HELM`, {
      method: 'PUT',
      headers,
      body: JSON.stringify({ name: 'Schutzhelme', parentId: 'PSA' }),
    });
    assert.equal(updateResponse.status, 200);
    assert.equal((await updateResponse.json()).name, 'Schutzhelme');

    const grandchildResponse = await fetch(`${baseUrl}/api/categories`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        id: 'PSA-HELM-ROT',
        name: 'Rote Helme',
        parentId: 'PSA-HELM',
      }),
    });
    assert.equal(grandchildResponse.status, 400);

    const protectedMainResponse = await fetch(`${baseUrl}/api/categories/PSA`, {
      method: 'DELETE',
      headers,
    });
    assert.equal(protectedMainResponse.status, 409);

    assert.equal(
      (await fetch(`${baseUrl}/api/categories/PSA-HELM`, {
        method: 'DELETE',
        headers,
      })).status,
      200,
    );
    assert.equal(
      (await fetch(`${baseUrl}/api/categories/PSA`, {
        method: 'DELETE',
        headers,
      })).status,
      200,
    );
  } finally {
    server.close();
  }
});

test('clothing uses global categories and protects referenced categories', async () => {
  const { server, baseUrl } = await startServer();
  try {
    const token = await login(baseUrl);
    const headers = {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    };

    const invalidResponse = await fetch(`${baseUrl}/api/clothing`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        name: 'Unbekannte Kategorie',
        categoryId: 'missing-category',
      }),
    });
    assert.equal(invalidResponse.status, 400);

    const disabledCategoryResponse = await fetch(`${baseUrl}/api/clothing`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        name: 'Nicht für Kleiderkammer',
        categoryId: '02-02',
      }),
    });
    assert.equal(disabledCategoryResponse.status, 400);

    const mainCategoryResponse = await fetch(`${baseUrl}/api/clothing`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        name: 'Allgemeine Kleidung',
        categoryId: '04',
      }),
    });
    assert.equal(mainCategoryResponse.status, 201);

    const createResponse = await fetch(`${baseUrl}/api/clothing`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        name: 'Einsatzhose',
        categoryId: '04-01',
      }),
    });
    assert.equal(createResponse.status, 201);
    assert.equal(
      (await createResponse.json()).categoryId,
      '04-01',
    );

    const deleteResponse = await fetch(
      `${baseUrl}/api/categories/04-01`,
      { method: 'DELETE', headers },
    );
    assert.equal(deleteResponse.status, 409);
  } finally {
    server.close();
  }
});

test('a category can be deleted after its clothing items were deleted', async () => {
  const { server, baseUrl } = await startServer();
  try {
    const token = await login(baseUrl);
    const headers = {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
    };

    const categoryResponse = await fetch(`${baseUrl}/api/categories`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        id: 'DELETE-AFTER-CLOTHING',
        name: 'Löschbare Kleidung',
        useInWardrobe: true,
      }),
    });
    assert.equal(categoryResponse.status, 201);

    const clothingResponse = await fetch(`${baseUrl}/api/clothing`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        name: 'Vorübergehender Artikel',
        categoryId: 'DELETE-AFTER-CLOTHING',
      }),
    });
    assert.equal(clothingResponse.status, 201);
    const clothing = await clothingResponse.json();

    assert.equal((await fetch(
      `${baseUrl}/api/categories/DELETE-AFTER-CLOTHING`,
      { method: 'DELETE', headers },
    )).status, 409);

    assert.equal((await fetch(`${baseUrl}/api/clothing/${clothing.id}`, {
      method: 'DELETE',
      headers,
    })).status, 200);

    assert.equal((await fetch(
      `${baseUrl}/api/categories/DELETE-AFTER-CLOTHING`,
      { method: 'DELETE', headers },
    )).status, 200);
  } finally {
    server.close();
  }
});
