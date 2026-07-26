const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');

async function start(data) {
  const snapshots = [];
  const app = createApp({
    data,
    dataStore: {
      async saveCollections(snapshot) { snapshots.push(snapshot); },
    },
  });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  const request = async (path, { method = 'GET', token, body } = {}) => {
    const response = await fetch(`${baseUrl}${path}`, {
      method,
      headers: {
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
        ...(body ? { 'Content-Type': 'application/json' } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });
    return {
      response,
      data: response.status === 204 ? null : await response.json(),
    };
  };
  const login = async (identifier, password) => (
    await request('/api/auth/login', {
      method: 'POST',
      body: { identifier, password },
    })
  ).data.token;
  return { server, request, login, snapshots };
}

test('admins can create, update and delete persisted notices', async () => {
  const { server, request, login, snapshots } = await start();
  try {
    const admin = await login('admin', 'MaterialKompass2026!');
    const created = await request('/api/admin/notices', {
      method: 'POST',
      token: admin,
      body: {
        title: 'Wartungsfenster',
        message: 'Die Webseite ist vorübergehend nicht verfügbar.',
        level: 'warning',
        startsAt: '2026-10-24T10:00:00.000Z',
        endsAt: '2026-10-24T11:00:00.000Z',
      },
    });
    assert.equal(created.response.status, 201);
    assert.equal(created.data.active, true);
    assert.equal(snapshots.at(-1).adminNotices.length, 1);

    const updated = await request(`/api/admin/notices/${created.data.id}`, {
      method: 'PUT',
      token: admin,
      body: {
        title: 'Geändertes Wartungsfenster',
        message: created.data.message,
        level: 'critical',
        active: false,
      },
    });
    assert.equal(updated.response.status, 200);
    assert.equal(updated.data.level, 'critical');
    assert.equal(updated.data.active, false);

    const removed = await request(`/api/admin/notices/${created.data.id}`, {
      method: 'DELETE',
      token: admin,
    });
    assert.equal(removed.response.status, 204);
    assert.equal(snapshots.at(-1).adminNotices.length, 0);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('non-admins cannot manage notices and invalid periods are rejected', async () => {
  const { server, request, login } = await start();
  try {
    const user = await login('materialwart', 'Material123!');
    const forbidden = await request('/api/admin/notices', { token: user });
    assert.equal(forbidden.response.status, 403);

    const admin = await login('admin', 'MaterialKompass2026!');
    const invalid = await request('/api/admin/notices', {
      method: 'POST',
      token: admin,
      body: {
        message: 'Ungültiger Zeitraum',
        startsAt: '2026-10-24T12:00:00.000Z',
        endsAt: '2026-10-24T11:00:00.000Z',
      },
    });
    assert.equal(invalid.response.status, 400);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});

test('dashboard only returns active notices inside their visibility period', async () => {
  const now = Date.now();
  const { seedData } = require('../src/data/seed');
  const data = structuredClone(seedData);
  data.adminNotices = [
    {
      id: 'visible',
      title: 'Aktuell',
      message: 'Dieser Hinweis ist sichtbar.',
      level: 'info',
      active: true,
      startsAt: new Date(now - 60_000).toISOString(),
      endsAt: new Date(now + 60_000).toISOString(),
      createdAt: new Date(now).toISOString(),
    },
    {
      id: 'future',
      title: 'Später',
      message: 'Noch nicht sichtbar.',
      level: 'warning',
      active: true,
      startsAt: new Date(now + 60_000).toISOString(),
      endsAt: null,
      createdAt: new Date(now).toISOString(),
    },
    {
      id: 'inactive',
      title: 'Aus',
      message: 'Deaktiviert.',
      level: 'critical',
      active: false,
      startsAt: null,
      endsAt: null,
      createdAt: new Date(now).toISOString(),
    },
  ];
  const { server, request, login } = await start(data);
  try {
    const user = await login('materialwart', 'Material123!');
    const dashboard = await request('/api/dashboard', { token: user });
    assert.equal(dashboard.response.status, 200);
    assert.deepEqual(dashboard.data.notices.map((notice) => notice.id), ['visible']);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
});
