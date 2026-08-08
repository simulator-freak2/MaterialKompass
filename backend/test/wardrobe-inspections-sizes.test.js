const assert = require('node:assert/strict');
const test = require('node:test');
const bcrypt = require('bcryptjs');

const { createApp } = require('../src/app');
const { seedData } = require('../src/data/seed');

async function startServer() {
  const roles = structuredClone(seedData.roles);
  const userForRole = (id, roleName, password) => {
    const role = roles.find((entry) => entry.name === roleName);
    return {
      id,
      name: roleName,
      username: id,
      email: `${id}@materialkompass.local`,
      passwordHash: bcrypt.hashSync(password, 10),
      roles: [roleName],
      permissions: [...role.permissions],
      active: true,
      failedLoginAttempts: 0,
      createdAt: '2026-01-01T00:00:00.000Z',
      lastLoginAt: null,
      emailVerifiedAt: '2026-01-01T00:00:00.000Z',
    };
  };
  const app = createApp({
    userData: {
      roles,
      users: [
        structuredClone(seedData.users[0]),
        userForRole('kleiderwart-test', 'Kleiderwart', 'Kleiderwart123!'),
        userForRole('psage-test', 'Sachkundiger PSAgE', 'Sachkundig123!'),
      ],
    },
  });
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

test('wardrobe categories define sizes, intervals and PSAgE inspection rules', async () => {
  const { server, baseUrl } = await startServer();
  try {
    const adminToken = await login(
      baseUrl,
      'admin@materialkompass.org',
      'MaterialKompass2026!',
    );
    const headers = {
      Authorization: `Bearer ${adminToken}`,
      'Content-Type': 'application/json',
    };
    const categoryResponse = await fetch(`${baseUrl}/api/categories/04-04`, {
      method: 'PUT',
      headers,
      body: JSON.stringify({
        name: 'Schutzkleidung',
        parentId: '04',
        sizes: ['S', 'M', 'L'],
        inspectionIntervalMonths: 6,
        requiresPsageInspection: true,
      }),
    });
    assert.equal(categoryResponse.status, 200);
    const category = await categoryResponse.json();
    assert.deepEqual(category.sizes, ['S', 'M', 'L']);
    assert.equal(category.inspectionIntervalMonths, 6);
    assert.equal(category.requiresPsageInspection, true);

    const invalidSize = await fetch(`${baseUrl}/api/clothing`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        name: 'PSA-Jacke',
        categoryId: '04-04',
        size: 'XXL',
      }),
    });
    assert.equal(invalidSize.status, 400);

    const createResponse = await fetch(`${baseUrl}/api/clothing`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        name: 'PSA-Jacke',
        categoryId: '04-04',
        size: 'M',
        locationId: 'loc-2',
        storagePositionId: 'stock-2',
      }),
    });
    assert.equal(createResponse.status, 201);
    const clothing = await createResponse.json();
    assert.equal(clothing.inspectionIntervalMonths, 6);
    assert.match(clothing.nextInspectionDate, /^\d{4}-\d{2}-\d{2}$/);

    const wardrobeToken = await login(
      baseUrl,
      'kleiderwart-test',
      'Kleiderwart123!',
    );
    const forbiddenInspection = await fetch(
      `${baseUrl}/api/clothing/${clothing.id}/inspections`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${wardrobeToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          inspectionDate: '2026-07-19',
          result: 'Bestanden',
        }),
      },
    );
    assert.equal(forbiddenInspection.status, 403);

    const psageToken = await login(
      baseUrl,
      'psage-test',
      'Sachkundig123!',
    );
    const inspectionResponse = await fetch(
      `${baseUrl}/api/clothing/${clothing.id}/inspections`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${psageToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          inspectionDate: '2026-07-19',
          result: 'Bestanden',
          notes: 'Sicht- und Funktionsprüfung',
        }),
      },
    );
    assert.equal(inspectionResponse.status, 201);
    const inspection = await inspectionResponse.json();
    assert.equal(inspection.psageInspection, true);
    assert.equal(inspection.inspector, 'Sachkundiger PSAgE');
    assert.equal(inspection.nextInspectionDate, '2027-01-19');

    const list = await fetch(`${baseUrl}/api/clothing`, { headers })
      .then((response) => response.json());
    const saved = list.find((entry) => entry.id === clothing.id);
    assert.equal(saved.inspections.length, 1);
    assert.equal(saved.lastInspectionDate, '2026-07-19');
  } finally {
    server.close();
  }
});
