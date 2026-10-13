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
  return {
    app, server, baseUrl,
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
  };
}

function vehicleBody(overrides = {}) {
  return {
    registrationNumber: 'DLRG 1',
    vin: 'WVWZZZ1JZXW000001',
    radioCallName: 'Pelikan Musterstadt 1/11-1',
    vehicleKind: 'Kraftfahrzeug',
    usage: 'Einsatzfahrt',
    type: 'Einsatzfahrzeug',
    manufacturer: 'Volkswagen',
    model: 'Transporter',
    year: 2024,
    status: 'Verfügbar',
    primaryResponseVehicle: true,
    ...overrides,
  };
}

test('vehicle master data is validated and creates a protected inventory location', async () => {
  const { app, server, baseUrl, headers } = await setup();
  try {
    const vehicleWarden = app.locals.appData.roles.find((entry) => entry.name === 'Fahrzeugwart');
    assert.ok(vehicleWarden);
    assert.equal(
      vehicleWarden.permissions.includes('vehicle_reservations.operational_approve'),
      false,
    );
    const missing = await fetch(`${baseUrl}/api/vehicles`, {
      method: 'POST', headers, body: JSON.stringify({
        vehicleKind: 'Kraftfahrzeug', usage: 'Einsatzfahrt', type: 'Einsatzfahrzeug',
      }),
    });
    assert.equal(missing.status, 400);

    const createdResponse = await fetch(`${baseUrl}/api/vehicles`, {
      method: 'POST', headers, body: JSON.stringify(vehicleBody()),
    });
    assert.equal(createdResponse.status, 201);
    const vehicle = await createdResponse.json();
    assert.equal(vehicle.registrationNumber, 'DLRG 1');
    assert.equal(vehicle.ownerUnitName, 'Organisation');
    assert.ok(vehicle.loadLocationId);

    const duplicate = await fetch(`${baseUrl}/api/vehicles`, {
      method: 'POST', headers,
      body: JSON.stringify(vehicleBody({ registrationNumber: 'DLRG 2' })),
    });
    assert.equal(duplicate.status, 409);

    const protectedDelete = await fetch(`${baseUrl}/api/locations/${vehicle.loadLocationId}`, {
      method: 'DELETE', headers,
    });
    assert.equal(protectedDelete.status, 409);

    const stored = app.locals.appData.locations.find((entry) => entry.id === vehicle.loadLocationId);
    assert.equal(stored.type, 'Fahrzeug');
    assert.equal(stored.vehicleId, vehicle.id);
  } finally {
    server.close();
  }
});

test('vehicle classification uses managed dependent options and conditional identifiers', async () => {
  const { app, server, baseUrl, headers } = await setup();
  try {
    const options = await fetch(`${baseUrl}/api/vehicles/options`, { headers })
      .then((response) => response.json());
    assert.deepEqual(options.vehicleKinds, [
      'Kraftfahrzeug', 'Boot', 'Anhänger', 'Sonstige Fahrzeugart',
    ]);
    assert.deepEqual(options.usages, ['Einsatzfahrt', 'sonstige Verwendung']);
    assert.deepEqual(options.vehicleTypesByUsage.Einsatzfahrt, ['Einsatzfahrzeug']);

    const settingsResponse = await fetch(`${baseUrl}/api/vehicle-settings`, {
      method: 'PUT', headers, body: JSON.stringify({
        usages: ['Einsatzfahrt', 'sonstige Verwendung', 'Ausbildung'],
        vehicleTypesByUsage: {
          Einsatzfahrt: ['Kommandowagen'],
          'sonstige Verwendung': ['Vereinsbus'],
          Ausbildung: ['Schulungsboot'],
        },
      }),
    });
    assert.equal(settingsResponse.status, 200);
    const settings = await settingsResponse.json();
    assert.ok(settings.usages.includes('Ausbildung'));
    assert.deepEqual(settings.vehicleTypesByUsage.Ausbildung, ['Schulungsboot']);

    const boatResponse = await fetch(`${baseUrl}/api/vehicles`, {
      method: 'POST', headers, body: JSON.stringify(vehicleBody({
        registrationNumber: '', vin: '', radioCallName: 'Adler Rhein',
        vehicleKind: 'Boot', usage: 'Ausbildung', type: 'Schulungsboot',
      })),
    });
    assert.equal(boatResponse.status, 201);
    const boat = await boatResponse.json();
    assert.equal(boat.vehicleKind, 'Boot');
    assert.equal(boat.usage, 'Ausbildung');
    assert.equal(boat.type, 'Schulungsboot');
    assert.equal(boat.registrationNumber, '');
    assert.equal(boat.vin, '');

    for (const vehicleKind of ['Kraftfahrzeug', 'Anhänger']) {
      const missingIdentifiers = await fetch(`${baseUrl}/api/vehicles`, {
        method: 'POST', headers, body: JSON.stringify(vehicleBody({
          registrationNumber: '', vin: '', vehicleKind,
          usage: 'Einsatzfahrt', type: 'Kommandowagen',
        })),
      });
      assert.equal(missingIdentifiers.status, 400);
    }

    const mismatchedType = await fetch(`${baseUrl}/api/vehicles`, {
      method: 'POST', headers, body: JSON.stringify(vehicleBody({
        registrationNumber: 'DLRG 3', vin: 'WVWZZZ1JZXW000003',
        usage: 'sonstige Verwendung', type: 'Kommandowagen',
      })),
    });
    assert.equal(mismatchedType.status, 400);

    const admin = app.locals.appData.users.find((entry) => entry.id === 'user-admin');
    admin.roles = ['Fahrzeugwart'];
    admin.permissions = ['vehicles.read', 'vehicles.write'];
    const membership = app.locals.appData.memberships.find(
      (entry) => entry.userId === admin.id,
    );
    membership.scopes.forEach((scope) => { scope.roles = ['Fahrzeugwart']; });
    const wardenLogin = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        email: 'admin@materialkompass.org', password: 'MaterialKompass2026!',
      }),
    });
    const wardenHeaders = {
      ...headers,
      Authorization: `Bearer ${(await wardenLogin.json()).token}`,
    };
    const wardenTypes = await fetch(`${baseUrl}/api/vehicle-settings`, {
      method: 'PUT', headers: wardenHeaders, body: JSON.stringify({
        vehicleTypesByUsage: {
          Einsatzfahrt: ['Gerätewagen'],
          'sonstige Verwendung': ['Vereinsbus'],
          Ausbildung: ['Schulungsboot'],
        },
      }),
    });
    assert.equal(wardenTypes.status, 200);
    const forbiddenUsage = await fetch(`${baseUrl}/api/vehicle-settings`, {
      method: 'PUT', headers: wardenHeaders,
      body: JSON.stringify({ usages: ['Einsatzfahrt'] }),
    });
    assert.equal(forbiddenUsage.status, 403);
  } finally {
    server.close();
  }
});

test('primary response vehicle requires vehicle and operational approval', async () => {
  const { server, baseUrl, headers } = await setup();
  try {
    await fetch(`${baseUrl}/api/vehicle-settings`, {
      method: 'PUT', headers,
      body: JSON.stringify({ primaryVehicleApprovalRequired: true }),
    });
    const vehicle = await fetch(`${baseUrl}/api/vehicles`, {
      method: 'POST', headers, body: JSON.stringify(vehicleBody()),
    }).then((response) => response.json());
    const reservationResponse = await fetch(`${baseUrl}/api/vehicle-reservations`, {
      method: 'POST', headers, body: JSON.stringify({
        vehicleId: vehicle.id,
        startAt: '2027-06-01T08:00:00.000Z', endAt: '2027-06-01T18:00:00.000Z',
        title: 'Dienst am Badesee',
        purpose: 'Wasserrettungsdienst', destination: 'Badesee',
        contact: 'Max Muster, 01234 5678', note: 'Primärfahrzeug',
      }),
    });
    assert.equal(reservationResponse.status, 201);
    const reservation = await reservationResponse.json();
    assert.equal(reservation.status, 'Ausstehend');
    assert.equal(reservation.title, 'Dienst am Badesee');
    assert.equal(reservation.operationalApprovalRequired, true);

    const vehicleApproval = await fetch(
      `${baseUrl}/api/vehicle-reservations/${reservation.id}/decision`,
      { method: 'POST', headers, body: JSON.stringify({ approved: true }) },
    );
    assert.equal((await vehicleApproval.json()).status, 'TLE-Freigabe ausstehend');

    const operationalApproval = await fetch(
      `${baseUrl}/api/vehicle-reservations/${reservation.id}/operational-decision`,
      { method: 'POST', headers, body: JSON.stringify({ approved: true }) },
    );
    assert.equal((await operationalApproval.json()).status, 'Freigegeben');

    const conflict = await fetch(`${baseUrl}/api/vehicle-reservations`, {
      method: 'POST', headers, body: JSON.stringify({
        vehicleId: vehicle.id,
        startAt: '2027-06-01T09:00:00.000Z', endAt: '2027-06-01T10:00:00.000Z',
        purpose: 'Parallel', destination: 'Halle', contact: 'Leitstelle',
      }),
    });
    assert.equal(conflict.status, 409);

    const issued = await fetch(`${baseUrl}/api/vehicle-reservations/${reservation.id}/issue`, {
      method: 'POST', headers, body: JSON.stringify({ mileage: 12000, fuelLevel: 'voll' }),
    });
    assert.equal((await issued.json()).status, 'Ausgegeben');
    const returned = await fetch(`${baseUrl}/api/vehicle-reservations/${reservation.id}/return`, {
      method: 'POST', headers,
      body: JSON.stringify({ mileage: 12042, fuelLevel: '3/4', damageReported: false }),
    });
    assert.equal((await returned.json()).status, 'Abgeschlossen');
  } finally {
    server.close();
  }
});

test('maintenance blocks reservations unless a permitted non-critical override is justified', async () => {
  const { server, baseUrl, headers } = await setup();
  try {
    const vehicle = await fetch(`${baseUrl}/api/vehicles`, {
      method: 'POST', headers, body: JSON.stringify(vehicleBody()),
    }).then((response) => response.json());
    const maintenance = await fetch(`${baseUrl}/api/vehicles/${vehicle.id}/maintenance`, {
      method: 'POST', headers, body: JSON.stringify({
        type: 'Inspektion', status: 'Geplant',
        startAt: '2027-07-01T08:00:00.000Z', endAt: '2027-07-01T16:00:00.000Z',
        dueDate: '2027-07-01', provider: 'Werkstatt', safetyCritical: false,
      }),
    });
    assert.equal(maintenance.status, 201);

    const body = {
      vehicleId: vehicle.id,
      startAt: '2027-07-01T10:00:00.000Z', endAt: '2027-07-01T12:00:00.000Z',
      purpose: 'Termin', destination: 'Stadt', contact: 'Max Muster',
    };
    const blocked = await fetch(`${baseUrl}/api/vehicle-reservations`, {
      method: 'POST', headers, body: JSON.stringify(body),
    });
    assert.equal(blocked.status, 409);

    const overridden = await fetch(`${baseUrl}/api/vehicle-reservations`, {
      method: 'POST', headers,
      body: JSON.stringify({ ...body, overrideReason: 'Werkstatttermin wird verlegt.' }),
    });
    assert.equal(overridden.status, 201);
  } finally {
    server.close();
  }
});

test('vehicle load is atomic, reduces available inventory and produces a printable target list', async () => {
  const { server, baseUrl, headers } = await setup();
  try {
    const vehicle = await fetch(`${baseUrl}/api/vehicles`, {
      method: 'POST', headers, body: JSON.stringify(vehicleBody()),
    }).then((response) => response.json());
    const material = await fetch(`${baseUrl}/api/material`, {
      method: 'POST', headers, body: JSON.stringify({
        name: 'Rettungsweste', categoryCode: '02', subcategoryCode: '02-02',
        locationId: 'loc-1', status: 'Lagernd', itemType: 'bulk', quantity: 10,
      }),
    }).then((response) => response.json());

    const load = await fetch(`${baseUrl}/api/vehicles/${vehicle.id}/load`, {
      method: 'POST', headers,
      body: JSON.stringify({ materialId: material.id, quantity: 4, position: 'Geräteraum 1' }),
    });
    assert.equal(load.status, 201);
    const assignment = await load.json();
    const detail = await fetch(`${baseUrl}/api/material/${material.id}`, { headers })
      .then((response) => response.json());
    assert.equal(detail.vehicleLoadedQuantity, 4);
    assert.equal(detail.availableQuantity, 6);

    const issueTooMany = await fetch(`${baseUrl}/api/material/transactions/bulk`, {
      method: 'POST', headers, body: JSON.stringify({
        action: 'issue', recipient: 'Einsatz', items: [{ materialId: material.id, quantity: 7 }],
      }),
    });
    assert.equal(issueTooMany.status, 409);

    const list = await fetch(`${baseUrl}/api/vehicles/${vehicle.id}/load-lists`, {
      method: 'POST', headers, body: JSON.stringify({
        name: 'Standardbeladung', activate: true,
        items: [{ materialId: material.id, targetQuantity: 5, position: 'Geräteraum 1' }],
      }),
    });
    assert.equal(list.status, 201);
    const printable = await fetch(`${baseUrl}/api/vehicles/${vehicle.id}/load-list/print`, {
      headers,
    }).then((response) => response.json());
    assert.match(printable.fileName, /beladungsliste/);
    assert.equal(Buffer.from(printable.fileBase64, 'base64').subarray(0, 5).toString(), '%PDF-');

    const unloaded = await fetch(
      `${baseUrl}/api/vehicles/${vehicle.id}/load/${assignment.id}/unload`,
      { method: 'POST', headers, body: JSON.stringify({ locationId: 'loc-1' }) },
    );
    assert.equal(unloaded.status, 200);
    const after = await fetch(`${baseUrl}/api/material/${material.id}`, { headers })
      .then((response) => response.json());
    assert.equal(after.vehicleLoadedQuantity, 0);
  } finally {
    server.close();
  }
});

test('off-duty vehicles are purged after ten years only without open defects or load', async () => {
  const { app, server, baseUrl, headers } = await setup();
  try {
    const vehicle = await fetch(`${baseUrl}/api/vehicles`, {
      method: 'POST', headers, body: JSON.stringify(vehicleBody({ status: 'Außer Dienst' })),
    }).then((response) => response.json());
    const loadedVehicle = await fetch(`${baseUrl}/api/vehicles`, {
      method: 'POST', headers, body: JSON.stringify(vehicleBody({
        registrationNumber: 'DLRG LOAD', vin: 'WVWZZZ1JZXW000099',
        primaryResponseVehicle: false,
      })),
    }).then((response) => response.json());
    assert.equal((await fetch(`${baseUrl}/api/vehicles/${loadedVehicle.id}/load`, {
      method: 'POST', headers,
      body: JSON.stringify({ materialId: 'material-1', quantity: 1 }),
    })).status, 201);
    assert.equal((await fetch(`${baseUrl}/api/vehicles/${loadedVehicle.id}`, {
      method: 'PUT', headers, body: JSON.stringify(vehicleBody({
        registrationNumber: loadedVehicle.registrationNumber,
        vin: loadedVehicle.vin,
        status: 'Außer Dienst', primaryResponseVehicle: false,
      })),
    })).status, 200);
    await app.locals.runAsSystem(() => {
      const stored = app.locals.appData.vehicles.find((entry) => entry.id === vehicle.id);
      stored.offDutyAt = '2016-01-02T00:00:00.000Z';
      app.locals.appData.vehicles.find((entry) => entry.id === loadedVehicle.id).offDutyAt =
        '2010-01-01T00:00:00.000Z';
      app.locals.appData.defectReports.push({
        id: 'vehicle-retention-defect', organizationId: stored.organizationId,
        unitId: stored.unitId, entityType: 'Vehicle', entityId: stored.id,
        status: 'Neu', archivedAt: null,
      });
    });
    const blocked = await app.locals.applyVehicleRetentionPolicy(
      Date.parse('2026-01-02T00:00:00.000Z'),
    );
    assert.equal(blocked.removedVehicles, 0);

    await app.locals.runAsSystem(() => {
      app.locals.appData.defectReports.splice(
        app.locals.appData.defectReports.findIndex((entry) =>
          entry.id === 'vehicle-retention-defect'),
        1,
      );
    });
    const tooEarly = await app.locals.applyVehicleRetentionPolicy(
      Date.parse('2026-01-01T23:59:59.999Z'),
    );
    assert.equal(tooEarly.removedVehicles, 0);
    const result = await app.locals.applyVehicleRetentionPolicy(
      Date.parse('2026-01-02T00:00:00.000Z'),
    );
    assert.equal(result.removedVehicles, 1);
    assert.equal(app.locals.appData.vehicles.some((entry) => entry.id === vehicle.id), false);
    assert.equal(
      app.locals.appData.vehicles.some((entry) => entry.id === loadedVehicle.id),
      true,
    );
  } finally {
    server.close();
  }
});
