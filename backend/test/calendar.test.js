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
  return { app, server, baseUrl, token: (await login.json()).token };
}

function reservationBody(materialId, purpose = 'Termin') {
  return {
    purpose,
    startAt: '2027-10-01T08:00:00.000Z',
    endAt: '2027-10-01T12:00:00.000Z',
    items: [{ materialId, quantity: 1 }],
  };
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

test('only individual inventory can be reserved and concurrent requests cannot double book', async () => {
  const { server, baseUrl, token } = await serverAndToken();
  const headers = { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` };
  try {
    const bulk = await fetch(`${baseUrl}/api/material`, {
      method: 'POST', headers, body: JSON.stringify({
        name: 'Verbrauchsmaterial', categoryCode: '02', subcategoryCode: '02-02',
        locationId: 'loc-1', status: 'Lagernd', itemType: 'bulk', quantity: 25,
      }),
    });
    assert.equal(bulk.status, 201);
    const bulkItem = await bulk.json();
    const rejected = await fetch(`${baseUrl}/api/reservations`, {
      method: 'POST', headers, body: JSON.stringify(reservationBody(bulkItem.id)),
    });
    assert.equal(rejected.status, 400);
    assert.match((await rejected.json()).error, /Mengenartikel/);

    const requests = await Promise.all([
      fetch(`${baseUrl}/api/reservations`, {
        method: 'POST', headers, body: JSON.stringify(reservationBody('material-1', 'Parallel A')),
      }),
      fetch(`${baseUrl}/api/reservations`, {
        method: 'POST', headers, body: JSON.stringify(reservationBody('material-1', 'Parallel B')),
      }),
    ]);
    assert.deepEqual(requests.map((response) => response.status).sort(), [201, 409]);
  } finally {
    server.close();
  }
});

test('calendar retention inherits organization settings and keeps active entries', async () => {
  const { app, server, baseUrl, token } = await serverAndToken();
  const headers = { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` };
  try {
    const settings = await fetch(`${baseUrl}/api/calendar/settings`, {
      method: 'PUT', headers, body: JSON.stringify({
        scope: 'organization', retentionMonths: 1,
      }),
    });
    assert.equal(settings.status, 200);
    assert.equal((await settings.json()).effectiveRetentionMonths, 1);

    await app.locals.runAsSystem(() => {
      app.locals.appData.reservations.push({
        id: 'reservation-old-terminal', organizationId: 'org-default',
        unitId: 'unit-default-root', status: 'Abgeschlossen',
        endAt: '2026-01-01T12:00:00.000Z', updatedAt: '2026-01-02T12:00:00.000Z',
        items: [],
      });
      app.locals.appData.reservations.push({
        id: 'reservation-old-active', organizationId: 'org-default',
        unitId: 'unit-default-root', status: 'Freigegeben',
        startAt: '2026-01-01T08:00:00.000Z', endAt: '2026-01-01T12:00:00.000Z',
        updatedAt: '2026-01-02T12:00:00.000Z', items: [],
      });
    });
    const result = await app.locals.applyCalendarRetentionPolicy(
      Date.parse('2026-03-15T00:00:00.000Z'),
    );
    assert.equal(result.removedReservations, 1);
    const ids = await app.locals.runAsSystem(() =>
      app.locals.appData.reservations.map((entry) => entry.id));
    assert.ok(!ids.includes('reservation-old-terminal'));
    assert.ok(ids.includes('reservation-old-active'));
  } finally {
    server.close();
  }
});

test('calendar includes visible vehicle reservations and maintenance', async () => {
  const { server, baseUrl, token } = await serverAndToken();
  const headers = { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` };
  try {
    const vehicleResponse = await fetch(`${baseUrl}/api/vehicles`, {
      method: 'POST', headers, body: JSON.stringify({
        registrationNumber: 'MK-KAL 1',
        vin: 'WVWZZZ1JZXWKAL001',
        radioCallName: 'Pelikan Kalender 1',
        type: 'Einsatzfahrzeug',
      }),
    });
    assert.equal(vehicleResponse.status, 201);
    const vehicle = await vehicleResponse.json();

    const reservation = await fetch(`${baseUrl}/api/vehicle-reservations`, {
      method: 'POST', headers, body: JSON.stringify({
        vehicleId: vehicle.id,
        startAt: '2027-09-10T08:00:00.000Z',
        endAt: '2027-09-10T12:00:00.000Z',
        title: 'Fahrdienst Kalender',
        purpose: 'Kalenderübung',
        destination: 'Badesee',
        contact: 'Leitstelle',
      }),
    });
    assert.equal(reservation.status, 201);

    const maintenance = await fetch(`${baseUrl}/api/vehicles/${vehicle.id}/maintenance`, {
      method: 'POST', headers, body: JSON.stringify({
        type: 'Jahreswartung',
        status: 'Geplant',
        dueDate: '2027-09-12',
        provider: 'Werkstatt Musterstadt',
      }),
    });
    assert.equal(maintenance.status, 201);

    const calendar = await fetch(
      `${baseUrl}/api/calendar?from=2027-09-01T00%3A00%3A00.000Z&to=2027-10-01T00%3A00%3A00.000Z`,
      { headers },
    );
    assert.equal(calendar.status, 200);
    const events = (await calendar.json()).events;
    const vehicleReservation = events.find((entry) => entry.kind === 'vehicle-reservation');
    const vehicleMaintenance = events.find((entry) => entry.kind === 'vehicle-maintenance');
    assert.equal(vehicleReservation.title, 'Fahrdienst Kalender');
    assert.deepEqual(vehicleReservation.inventoryNumbers, ['MK-KAL 1']);
    assert.equal(vehicleMaintenance.title, 'Jahreswartung');
    assert.equal(vehicleMaintenance.allDay, true);
  } finally {
    server.close();
  }
});
