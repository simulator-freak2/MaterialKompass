const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');

async function setup() {
  const app = createApp();
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  const login = await fetch(`${baseUrl}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      email: 'admin@materialkompass.org', password: 'MaterialKompass2026!',
    }),
  });
  const token = (await login.json()).token;
  const headers = { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` };
  const send = async (path, method = 'GET', body = undefined) => {
    const response = await fetch(baseUrl + path, {
      method, headers, body: body === undefined ? undefined : JSON.stringify(body),
    });
    return { status: response.status, data: await response.json() };
  };
  return { app, server, send };
}

let counter = 0;
function vehicleBody(overrides = {}) {
  counter += 1;
  return {
    registrationNumber: `DLRG W${counter}`,
    vin: `WVWZZZ1JZXW1000${counter}`,
    radioCallName: `Pelikan ${counter}`,
    vehicleKind: 'Kraftfahrzeug', usage: 'Einsatzfahrt', type: 'Einsatzfahrzeug',
    status: 'Verfügbar', primaryResponseVehicle: false,
    ...overrides,
  };
}

function reservationBody(vehicleId, overrides = {}) {
  return {
    vehicleId, title: 'Fahrt', purpose: 'Übung', destination: 'See', contact: 'Max',
    startAt: '2030-05-01T08:00:00.000Z', endAt: '2030-05-01T12:00:00.000Z',
    ...overrides,
  };
}

test('reservation changes are checked against maintenance and the past', async () => {
  const { server, send } = await setup();
  try {
    const vehicle = (await send('/api/vehicles', 'POST', vehicleBody())).data;
    const past = await send('/api/vehicle-reservations', 'POST', reservationBody(vehicle.id, {
      startAt: '2020-01-01T08:00:00.000Z', endAt: '2020-01-01T10:00:00.000Z',
    }));
    assert.equal(past.status, 400);

    const reservation = await send('/api/vehicle-reservations', 'POST', reservationBody(vehicle.id));
    assert.equal(reservation.status, 201);
    const maintenance = await send(`/api/vehicles/${vehicle.id}/maintenance`, 'POST', {
      type: 'HU', startAt: '2030-06-01T08:00:00.000Z', endAt: '2030-06-01T16:00:00.000Z',
      safetyCritical: true,
    });
    assert.equal(maintenance.status, 201);

    // Moving the reservation into a safety critical maintenance window is refused.
    const moved = await send(`/api/vehicle-reservations/${reservation.data.id}`, 'PUT', {
      startAt: '2030-06-01T09:00:00.000Z', endAt: '2030-06-01T10:00:00.000Z',
      overrideReason: 'Versuch',
    });
    assert.equal(moved.status, 409);
    assert.match(moved.data.error, /sicherheitskritisch/);
  } finally { server.close(); }
});

test('issuing respects overrides, mileage and parallel handovers', async () => {
  const { app, server, send } = await setup();
  try {
    const vehicle = (await send('/api/vehicles', 'POST', vehicleBody({ mileage: 5000 }))).data;
    const first = (await send('/api/vehicle-reservations', 'POST', reservationBody(vehicle.id, {
      startAt: new Date(Date.now() + 60_000).toISOString(),
      endAt: new Date(Date.now() + 3_600_000).toISOString(),
    }))).data;
    const second = (await send('/api/vehicle-reservations', 'POST', reservationBody(vehicle.id, {
      startAt: new Date(Date.now() + 7_200_000).toISOString(),
      endAt: new Date(Date.now() + 10_800_000).toISOString(),
    }))).data;
    for (const entry of [first, second]) {
      assert.equal((await send(`/api/vehicle-reservations/${entry.id}/decision`, 'POST', { approved: true })).data.status, 'Freigegeben');
    }

    assert.equal((await send(`/api/vehicle-reservations/${first.id}/issue`, 'POST', { mileage: 4000 })).status, 400);

    // Non-critical block (status "In Wartung") requires a justified override.
    await app.locals.runAsSystem(() => {
      app.locals.appData.vehicles.find((entry) => entry.id === vehicle.id).status = 'In Wartung';
    });
    const blocked = await send(`/api/vehicle-reservations/${first.id}/issue`, 'POST', { mileage: 5100 });
    assert.equal(blocked.status, 409);
    assert.equal(blocked.data.overridable, true);
    const issued = await send(`/api/vehicle-reservations/${first.id}/issue`, 'POST', {
      mileage: 5100, overrideReason: 'Nur Sichtprüfung offen.',
    });
    assert.equal(issued.status, 200);
    assert.equal(issued.data.issueOverrideReason, 'Nur Sichtprüfung offen.');

    const parallel = await send(`/api/vehicle-reservations/${second.id}/issue`, 'POST', {
      mileage: 5100, overrideReason: 'Test',
    });
    assert.equal(parallel.status, 409);
    assert.match(parallel.data.error, /anderen Reservierung/);

    // A vehicle that is out cannot be retired.
    const retire = await send(`/api/vehicles/${vehicle.id}`, 'PUT', { status: 'Außer Dienst' });
    assert.equal(retire.status, 409);

    const returned = await send(`/api/vehicle-reservations/${first.id}/return`, 'POST', { mileage: 5180 });
    assert.equal(returned.data.status, 'Abgeschlossen');

    const retired = await send(`/api/vehicles/${vehicle.id}`, 'PUT', { status: 'Außer Dienst' });
    assert.equal(retired.status, 200);
    const detail = await send(`/api/vehicles/${vehicle.id}`);
    assert.equal(detail.data.mileage, 5180);
    const open = detail.data.reservations.find((entry) => entry.id === second.id);
    assert.equal(open.status, 'Storniert');
    assert.match(open.decisionReason, /außer Dienst/);
  } finally { server.close(); }
});

test('operational decisions cannot reopen finished reservations', async () => {
  const { server, send } = await setup();
  try {
    await send('/api/vehicle-settings', 'PUT', { primaryVehicleApprovalRequired: true });
    const vehicle = (await send('/api/vehicles', 'POST', vehicleBody({ primaryResponseVehicle: true }))).data;
    const reservation = (await send('/api/vehicle-reservations', 'POST', reservationBody(vehicle.id))).data;
    assert.equal((await send(`/api/vehicle-reservations/${reservation.id}/cancel`, 'POST', {})).data.status, 'Storniert');
    const decision = await send(`/api/vehicle-reservations/${reservation.id}/operational-decision`, 'POST', {
      approved: false, reason: 'zu spät',
    });
    assert.equal(decision.status, 409);
  } finally { server.close(); }
});

test('maintenance updates validate first and schedule the follow-up once', async () => {
  const { server, send } = await setup();
  try {
    const vehicle = (await send('/api/vehicles', 'POST', vehicleBody())).data;
    assert.equal((await send(`/api/vehicles/${vehicle.id}/maintenance`, 'POST', {
      type: 'Ohne Termin',
    })).status, 400);
    assert.equal((await send(`/api/vehicles/${vehicle.id}/maintenance`, 'POST', {
      type: 'Halber Termin', startAt: '2030-01-01T08:00:00.000Z',
    })).status, 400);
    const created = await send(`/api/vehicles/${vehicle.id}/maintenance`, 'POST', {
      type: 'Inspektion', dueDate: '2030-01-31', intervalMonths: 12, cost: 100,
    });
    assert.equal(created.status, 201);

    const invalid = await send(`/api/vehicles/${vehicle.id}/maintenance/${created.data.id}`, 'PUT', {
      cost: -5, status: 'Abgeschlossen',
    });
    assert.equal(invalid.status, 400);
    let detail = await send(`/api/vehicles/${vehicle.id}`);
    let stored = detail.data.maintenance.find((entry) => entry.id === created.data.id);
    assert.equal(stored.cost, 100);
    assert.equal(stored.status, 'Geplant');

    const done = await send(`/api/vehicles/${vehicle.id}/maintenance/${created.data.id}`, 'PUT', {
      status: 'Abgeschlossen', result: 'ohne Befund', mileage: 1234,
    });
    assert.equal(done.status, 200);
    assert.ok(done.data.followUpId);
    detail = await send(`/api/vehicles/${vehicle.id}`);
    const followUp = detail.data.maintenance.find((entry) => entry.id === done.data.followUpId);
    assert.equal(followUp.status, 'Geplant');
    assert.equal(followUp.dueDate, done.data.nextDueDate);
    assert.equal(detail.data.mileage, 1234);
    assert.equal(detail.data.maintenance.length, 2);

    assert.equal((await send(`/api/vehicles/${vehicle.id}/maintenance/${created.data.id}`, 'PUT', {
      status: 'Geplant',
    })).status, 409);
    stored = (await send(`/api/vehicles/${vehicle.id}/maintenance/${created.data.id}`, 'PUT', {
      status: 'Abgeschlossen', result: 'nachgetragen',
    })).data;
    assert.equal(stored.result, 'nachgetragen');
    detail = await send(`/api/vehicles/${vehicle.id}`);
    assert.equal(detail.data.maintenance.length, 2);
  } finally { server.close(); }
});

test('load lists merge duplicates, can be activated and printed per version', async () => {
  const { server, send } = await setup();
  try {
    const vehicle = (await send('/api/vehicles', 'POST', vehicleBody())).data;
    const material = (await send('/api/material', 'POST', {
      name: 'Leine „Rot“ → 30 m', categoryCode: '02', subcategoryCode: '02-02',
      locationId: 'loc-1', status: 'Lagernd', itemType: 'bulk', quantity: 10,
    })).data;
    assert.equal((await send(`/api/vehicles/${vehicle.id}/load`, 'POST', {
      materialId: material.id, quantity: 2, position: 'G1',
    })).status, 201);
    assert.equal((await send(`/api/vehicles/${vehicle.id}/load`, 'POST', {
      materialId: material.id, quantity: 1, position: 'G2',
    })).status, 201);

    assert.equal((await send(`/api/vehicles/${vehicle.id}/load-lists`, 'POST', { items: [] })).status, 400);
    const draft = await send(`/api/vehicles/${vehicle.id}/load-lists`, 'POST', {
      name: 'Entwurf', activate: false,
      items: [
        { materialId: material.id, targetQuantity: 2, position: 'G1' },
        { materialId: material.id, targetQuantity: 1, position: 'G2' },
      ],
    });
    assert.equal(draft.status, 201);
    assert.equal(draft.data.status, 'Entwurf');
    assert.equal(draft.data.items.length, 1);
    assert.equal(draft.data.items[0].targetQuantity, 3);
    assert.equal(draft.data.items[0].position, 'G1, G2');

    assert.equal((await send(`/api/vehicles/${vehicle.id}/load-list/print`)).status, 404);
    const draftPrint = await send(`/api/vehicles/${vehicle.id}/load-lists/${draft.data.id}/print`);
    assert.equal(draftPrint.status, 200);
    assert.equal(Buffer.from(draftPrint.data.fileBase64, 'base64').subarray(0, 5).toString(), '%PDF-');

    const activated = await send(`/api/vehicles/${vehicle.id}/load-lists/${draft.data.id}/activate`, 'POST', {});
    assert.equal(activated.data.status, 'Aktiv');
    assert.equal((await send(`/api/vehicles/${vehicle.id}/load-list/print`)).status, 200);

    // Unloading to another location must not keep the old storage structure.
    const detail = await send(`/api/vehicles/${vehicle.id}`);
    const assignment = detail.data.loadAssignments[0];
    assert.equal((await send(`/api/vehicles/${vehicle.id}/load/${assignment.id}/unload`, 'POST', {
      locationId: 'loc-1',
    })).status, 200);
  } finally { server.close(); }
});
