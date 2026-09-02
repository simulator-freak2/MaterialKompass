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

test('reservations require approval per material and prevent overlaps', async () => {
  const { server, baseUrl, token } = await serverAndToken();
  const headers = { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` };
  try {
    const material = await fetch(`${baseUrl}/api/material/material-1`, { headers })
      .then((response) => response.json());
    material.reservationApprovalRequired = true;
    assert.equal((await fetch(`${baseUrl}/api/material/material-1`, {
      method: 'PUT', headers, body: JSON.stringify(material),
    })).status, 200);

    const response = await fetch(`${baseUrl}/api/reservations`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        purpose: 'Sommerfest',
        startAt: '2027-06-01T08:00:00.000Z',
        endAt: '2027-06-01T18:00:00.000Z',
        items: [{ materialId: 'material-1', quantity: 1 }],
      }),
    });
    assert.equal(response.status, 201);
    const reservation = await response.json();
    assert.equal(reservation.status, 'Ausstehend');
    assert.equal(reservation.approvalRequired, true);

    const conflict = await fetch(`${baseUrl}/api/reservations`, {
      method: 'POST',
      headers,
      body: JSON.stringify({
        purpose: 'Parallelveranstaltung',
        startAt: '2027-06-01T12:00:00.000Z',
        endAt: '2027-06-01T19:00:00.000Z',
        items: [{ materialId: 'material-1', quantity: 1 }],
      }),
    });
    assert.equal(conflict.status, 409);

    const decision = await fetch(`${baseUrl}/api/reservations/${reservation.id}/decision`, {
      method: 'POST', headers, body: JSON.stringify({ approved: true }),
    });
    assert.equal(decision.status, 200);
    assert.equal((await decision.json()).status, 'Freigegeben');
  } finally {
    server.close();
  }
});

test('reservation issue and return update inventory atomically', async () => {
  const { server, baseUrl, token } = await serverAndToken();
  const headers = { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` };
  try {
    const reservation = await fetch(`${baseUrl}/api/reservations`, {
      method: 'POST', headers, body: JSON.stringify({
        purpose: 'Übung',
        startAt: '2027-07-02T08:00:00.000Z',
        endAt: '2027-07-02T18:00:00.000Z',
        items: [{ materialId: 'material-1', quantity: 1 }],
      }),
    }).then((response) => response.json());
    assert.equal(reservation.status, 'Freigegeben');

    const issued = await fetch(`${baseUrl}/api/reservations/${reservation.id}/issue`, {
      method: 'POST', headers,
    });
    assert.equal(issued.status, 200);
    assert.equal((await issued.json()).status, 'Ausgegeben');
    let material = await fetch(`${baseUrl}/api/material/material-1`, { headers })
      .then((response) => response.json());
    assert.equal(material.issuedQuantity, 1);

    const returned = await fetch(`${baseUrl}/api/reservations/${reservation.id}/return`, {
      method: 'POST', headers,
    });
    assert.equal(returned.status, 200);
    assert.equal((await returned.json()).status, 'Abgeschlossen');
    material = await fetch(`${baseUrl}/api/material/material-1`, { headers })
      .then((response) => response.json());
    assert.equal(material.issuedQuantity, 0);
  } finally {
    server.close();
  }
});

test('maintenance blocks reservations and calendar includes planned material dates', async () => {
  const { server, baseUrl, token } = await serverAndToken();
  const headers = { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` };
  try {
    const maintenance = await fetch(`${baseUrl}/api/maintenance`, {
      method: 'POST', headers, body: JSON.stringify({
        materialId: 'material-1',
        startAt: '2027-08-01T07:00:00.000Z',
        endAt: '2027-08-01T15:00:00.000Z',
        type: 'Jahreswartung',
        responsible: 'Werkstatt',
        status: 'Geplant',
        description: 'Funktionskontrolle',
      }),
    });
    assert.equal(maintenance.status, 201);

    const conflict = await fetch(`${baseUrl}/api/reservations`, {
      method: 'POST', headers, body: JSON.stringify({
        purpose: 'Einsatz',
        startAt: '2027-08-01T08:00:00.000Z',
        endAt: '2027-08-01T12:00:00.000Z',
        items: [{ materialId: 'material-1', quantity: 1 }],
      }),
    });
    assert.equal(conflict.status, 409);

    const calendar = await fetch(
      `${baseUrl}/api/calendar?from=2027-01-01T00%3A00%3A00.000Z&to=2027-12-31T00%3A00%3A00.000Z`,
      { headers },
    );
    assert.equal(calendar.status, 200);
    const events = (await calendar.json()).events;
    assert.ok(events.some((entry) => entry.kind === 'maintenance'));
    assert.ok(events.some((entry) => entry.kind === 'inspection'));
  } finally {
    server.close();
  }
});

test('calendar export returns a bounded ICS document', async () => {
  const { server, baseUrl, token } = await serverAndToken();
  try {
    const response = await fetch(
      `${baseUrl}/api/calendar/export?from=2027-01-01T00%3A00%3A00.000Z&to=2027-12-31T00%3A00%3A00.000Z`,
      { headers: { Authorization: `Bearer ${token}` } },
    );
    assert.equal(response.status, 200);
    const body = await response.json();
    const ics = Buffer.from(body.fileBase64, 'base64').toString('utf8');
    assert.match(body.fileName, /\.ics$/);
    assert.match(ics, /^BEGIN:VCALENDAR/);
    assert.match(ics, /END:VCALENDAR/);
  } finally {
    server.close();
  }
});
