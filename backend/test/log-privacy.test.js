const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');
const { seedData } = require('../src/data/seed');

async function start(options = {}) {
  const app = createApp({ skipEmailVerification: true, ...options });
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

test('dashboard only returns activity from permitted areas', async () => {
  const users = structuredClone(seedData.users);
  const restrictedUser = users.find((user) => user.id === 'user-materialwart');
  restrictedUser.permissions = ['dashboard.read', 'inventory.read'];
  restrictedUser.roles = ['Nutzer'];
  const { server, baseUrl } = await start({
    userData: { users, roles: seedData.roles },
  });

  try {
    const admin = await login(baseUrl, 'admin', 'MaterialKompass2026!');
    const locationResponse = await fetch(`${baseUrl}/api/locations`, {
      method: 'POST',
      headers: headers(admin),
      body: JSON.stringify({ name: 'Geheimes Lager', code: 'GL', type: 'Lager' }),
    });
    assert.equal(locationResponse.status, 201);

    const materialResponse = await fetch(`${baseUrl}/api/material`, {
      method: 'POST',
      headers: headers(admin),
      body: JSON.stringify({
        name: 'Sichtbarer Artikel',
        categoryCode: '02',
        subcategoryCode: '02-02',
        locationId: 'loc-1',
        status: 'Lagernd',
        itemType: 'individual',
        quantity: 1,
      }),
    });
    assert.equal(materialResponse.status, 201);

    const restricted = await login(baseUrl, 'materialwart', 'Material123!');
    const dashboard = await fetch(`${baseUrl}/api/dashboard`, { headers: headers(restricted) })
      .then((response) => response.json());
    assert.equal(dashboard.recentActivity.some((entry) => entry.entity === 'MaterialItem'), true);
    assert.equal(dashboard.recentActivity.some((entry) => entry.entity === 'Location'), false);
    assert.equal(dashboard.recentActivity.some((entry) => entry.entity === 'User'), false);
  } finally {
    server.close();
  }
});

test('dashboard excludes logins and describes article activity without email addresses', async () => {
  const { server, baseUrl } = await start();
  try {
    const admin = await login(baseUrl, 'admin@materialkompass.org', 'MaterialKompass2026!');
    const createdResponse = await fetch(`${baseUrl}/api/material`, {
      method: 'POST',
      headers: headers(admin),
      body: JSON.stringify({
        name: 'Datenschutz-Karabiner',
        categoryCode: '02',
        subcategoryCode: '02-02',
        locationId: 'loc-1',
        status: 'Lagernd',
        itemType: 'individual',
        quantity: 1,
      }),
    });
    assert.equal(createdResponse.status, 201);
    const created = await createdResponse.json();
    const dashboard = await fetch(`${baseUrl}/api/dashboard`, { headers: headers(admin) })
      .then((response) => response.json());
    assert.equal(dashboard.recentActivity.some((entry) => entry.action === 'login'), false);
    assert.equal(dashboard.recentActivity.some((entry) => entry.action === 'login_failed'), false);
    const createEntry = dashboard.recentActivity.find((entry) =>
      entry.entity === 'MaterialItem' && entry.details.id === created.id);
    assert.equal(createEntry.actor, 'admin');
    assert.equal(createEntry.actor.includes('@'), false);
    assert.equal(createEntry.itemName, 'Datenschutz-Karabiner');
    assert.equal(createEntry.category, 'Werkzeug / Handwerk');
    assert.equal(createEntry.inventoryNumber, created.inventoryNumber);
    assert.equal(createEntry.area, 'Inventar');
    assert.equal(createEntry.actionLabel, 'angelegt');
    assert.ok(createEntry.timestamp);

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
