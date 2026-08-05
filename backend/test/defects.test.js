const assert = require('node:assert/strict');
const test = require('node:test');
const bcrypt = require('bcryptjs');
const { PDFDocument } = require('pdf-lib');

const { createApp } = require('../src/app');
const { seedData } = require('../src/data/seed');

async function start() {
  const roles = structuredClone(seedData.roles);
  const roleUser = (roleName, password) => {
    const role = roles.find((entry) => entry.name === roleName);
    return {
      id: `user-${roleName.toLowerCase()}`, name: roleName,
      username: roleName.toLowerCase(), email: `${roleName.toLowerCase()}@example.org`,
      passwordHash: bcrypt.hashSync(password, 10), roles: [roleName],
      permissions: [...role.permissions], active: true, failedLoginAttempts: 0,
      createdAt: '2026-01-01T00:00:00.000Z', lastLoginAt: null,
      emailVerifiedAt: '2026-01-01T00:00:00.000Z',
    };
  };
  const data = structuredClone(seedData);
  data.materials[0].itemType = 'bulk';
  data.materials[0].quantity = 5;
  const app = createApp({
    data,
    userData: {
      roles,
      users: [
        structuredClone(seedData.users[0]),
        roleUser('Materialwart', 'Material123!'),
        roleUser('Kleiderwart', 'Kleider123!'),
        roleUser('Vorsitz', 'Vorsitz123!'),
      ],
    },
  });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  return { app, server, baseUrl: `http://127.0.0.1:${server.address().port}` };
}

async function token(baseUrl, identifier, password) {
  const response = await fetch(`${baseUrl}/api/auth/login`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ identifier, password }),
  });
  assert.equal(response.status, 200);
  return (await response.json()).token;
}

function headers(value) {
  return { Authorization: `Bearer ${value}`, 'Content-Type': 'application/json' };
}

test('defect workflow blocks issue, permits return and restores the item on closing', async () => {
  const { server, baseUrl } = await start();
  try {
    const materialToken = await token(baseUrl, 'materialwart', 'Material123!');
    const auth = headers(materialToken);
    const issue = await fetch(`${baseUrl}/api/material/transactions/bulk`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({ action: 'issue', recipient: 'Einsatz', items: [{ materialId: 'material-1', quantity: 2 }] }),
    });
    assert.equal(issue.status, 201);

    const create = await fetch(`${baseUrl}/api/defects`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({
        entityType: 'MaterialItem', entityId: 'material-1', affectedQuantity: 2,
        title: 'Kettenschutz gebrochen', description: 'Schutz kann nicht verriegelt werden.',
        priority: 'Kritisch', damageType: 'Mechanisch', cause: 'Verschleiß',
        measuresTaken: 'Gerät außer Betrieb genommen und gekennzeichnet.',
        riskLevel: 'Hoch', operationalSafety: 'Nicht einsatzfähig',
        contactName: 'Max Mustermann', contactEmail: 'max@example.org',
        contactPhone: '+49 123 456789',
      }),
    });
    assert.equal(create.status, 201);
    let defect = await create.json();
    assert.match(defect.defectNumber, /^M-\d{4}-\d{4}$/);
    assert.equal(defect.affectedQuantity, 2);
    assert.equal(defect.measuresTaken, 'Gerät außer Betrieb genommen und gekennzeichnet.');
    assert.equal(defect.contactName, 'Max Mustermann');
    assert.equal(defect.contactEmail, 'max@example.org');
    assert.equal(defect.contactPhone, '+49 123 456789');

    let item = await fetch(`${baseUrl}/api/material/material-1`, { headers: auth }).then((response) => response.json());
    assert.equal(item.status, 'Defekt');
    assert.equal((await fetch(`${baseUrl}/api/material/transactions/bulk`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({ action: 'issue', recipient: 'Test', items: [{ materialId: 'material-1', quantity: 1 }] }),
    })).status, 409);
    assert.equal((await fetch(`${baseUrl}/api/material/transactions/bulk`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({ action: 'return', items: [{ materialId: 'material-1', quantity: 2 }] }),
    })).status, 201);
    item = await fetch(`${baseUrl}/api/material/material-1`, { headers: auth }).then((response) => response.json());
    assert.equal(item.status, 'Defekt');

    for (const status of ['In Prüfung']) {
      const response = await fetch(`${baseUrl}/api/defects/${defect.id}/transition`, {
        method: 'POST', headers: auth, body: JSON.stringify({ status }),
      });
      assert.equal(response.status, 200);
      defect = await response.json();
    }
    assert.equal((await fetch(`${baseUrl}/api/defects/${defect.id}/assign`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({ assignee: 'Werkstatt', responsibleDepartment: 'Technik', dueDate: '2026-08-01' }),
    })).status, 200);
    for (const status of ['Zugewiesen', 'In Bearbeitung', 'Behoben']) {
      const response = await fetch(`${baseUrl}/api/defects/${defect.id}/transition`, {
        method: 'POST', headers: auth, body: JSON.stringify({ status }),
      });
      assert.equal(response.status, 200);
      defect = await response.json();
    }
    assert.equal((await fetch(`${baseUrl}/api/defects/${defect.id}/transition`, {
      method: 'POST', headers: auth, body: JSON.stringify({ status: 'Geprüft/Geschlossen' }),
    })).status, 409);
    assert.equal((await fetch(`${baseUrl}/api/defects/${defect.id}`, {
      method: 'PUT', headers: auth,
      body: JSON.stringify({ resolution: 'Schutz ersetzt und Funktion geprüft.', actualCost: 29.9 }),
    })).status, 200);
    assert.equal((await fetch(`${baseUrl}/api/defects/${defect.id}/transition`, {
      method: 'POST', headers: auth, body: JSON.stringify({ status: 'Geprüft/Geschlossen' }),
    })).status, 200);
    item = await fetch(`${baseUrl}/api/material/material-1`, { headers: auth }).then((response) => response.json());
    assert.equal(item.status, 'Lagernd');
  } finally {
    server.close();
  }
});

test('defects enforce role scope, create notifications and support every export', async () => {
  const { server, baseUrl } = await start();
  try {
    const adminToken = await token(baseUrl, 'admin', 'MaterialKompass2026!');
    const materialToken = await token(baseUrl, 'materialwart', 'Material123!');
    const wardrobeToken = await token(baseUrl, 'kleiderwart', 'Kleider123!');
    const create = await fetch(`${baseUrl}/api/defects`, {
      method: 'POST', headers: headers(materialToken),
      body: JSON.stringify({ entityType: 'MaterialItem', entityId: 'material-1', affectedQuantity: 1, title: 'Ölaustritt', description: 'Öl tritt aus.', priority: 'Normal' }),
    });
    assert.equal(create.status, 201);
    const defect = await create.json();
    assert.equal((await fetch(`${baseUrl}/api/defects/${defect.id}/comments`, {
      method: 'POST', headers: headers(materialToken), body: JSON.stringify({ text: 'Werkstatt informiert.' }),
    })).status, 201);
    assert.equal((await fetch(`${baseUrl}/api/defects/${defect.id}/checklist`, {
      method: 'POST', headers: headers(materialToken), body: JSON.stringify({ label: 'Dichtung prüfen' }),
    })).status, 201);
    assert.equal((await fetch(`${baseUrl}/api/defects/${defect.id}/related-actions`, {
      method: 'POST', headers: headers(materialToken), body: JSON.stringify({ type: 'Reparatur', label: 'Werkstattauftrag', referenceId: 'REP-1' }),
    })).status, 201);
    assert.equal((await fetch(`${baseUrl}/api/defects/${defect.id}/follow-up-tasks`, {
      method: 'POST', headers: headers(materialToken), body: JSON.stringify({ label: 'Nachkontrolle', assignee: 'Materialwart' }),
    })).status, 201);
    const onePixelPng = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=';
    assert.equal((await fetch(`${baseUrl}/api/defects/${defect.id}/images`, {
      method: 'POST', headers: headers(materialToken),
      body: JSON.stringify({ fileName: 'schaden.png', mimeType: 'image/png', fileBase64: onePixelPng }),
    })).status, 201);
    const duplicateResponse = await fetch(`${baseUrl}/api/defects`, {
      method: 'POST', headers: headers(materialToken),
      body: JSON.stringify({ entityType: 'MaterialItem', entityId: 'material-1', affectedQuantity: 1, title: 'Ölaustritt', description: 'Erneut tritt Öl aus.', priority: 'Normal' }),
    });
    assert.equal(duplicateResponse.status, 201);
    assert.equal((await duplicateResponse.json()).duplicateOfId, defect.id);
    const wardrobeList = await fetch(`${baseUrl}/api/defects`, { headers: headers(wardrobeToken) }).then((response) => response.json());
    assert.equal(wardrobeList.length, 0);
    assert.equal((await fetch(`${baseUrl}/api/defects/${defect.id}`, { headers: headers(wardrobeToken) })).status, 404);

    const clothingCreate = await fetch(`${baseUrl}/api/defects`, {
      method: 'POST', headers: headers(wardrobeToken),
      body: JSON.stringify({
        entityType: 'ClothingItem', entityId: 'clothing-1', affectedQuantity: 1,
        title: 'Naht gerissen', description: 'Die Schulterpartie ist beschädigt.', priority: 'Hoch',
      }),
    });
    assert.equal(clothingCreate.status, 201);
    const clothingDefect = await clothingCreate.json();
    const clothing = await fetch(`${baseUrl}/api/clothing`, { headers: headers(wardrobeToken) })
      .then((response) => response.json());
    assert.ok(clothing.find((item) => item.id === 'clothing-1').defects
      .some((entry) => entry.id === clothingDefect.id));
    assert.equal((await fetch(`${baseUrl}/api/defects/${clothingDefect.id}/print`, {
      headers: headers(wardrobeToken),
    })).status, 200);
    assert.equal((await fetch(`${baseUrl}/api/defects/${clothingDefect.id}/print`, {
      headers: headers(materialToken),
    })).status, 404);

    const notifications = await fetch(`${baseUrl}/api/notifications`, { headers: headers(adminToken) }).then((response) => response.json());
    assert.ok(notifications.some((entry) => entry.defectId === defect.id));
    for (const format of ['xlsx', 'ods', 'csv', 'pdf', 'print']) {
      const response = await fetch(`${baseUrl}/api/defects/export?format=${format}`, { headers: headers(adminToken) });
      assert.equal(response.status, 200, format);
      const exported = await response.json();
      assert.ok(Buffer.from(exported.fileBase64, 'base64').length > 20, format);
    }
    const printResponse = await fetch(`${baseUrl}/api/defects/${defect.id}/print`, {
      headers: headers(materialToken),
    });
    assert.equal(printResponse.status, 200);
    const printed = await printResponse.json();
    assert.equal(printed.fileName, `maengelmeldung-${defect.defectNumber}.pdf`);
    const printedPdf = await PDFDocument.load(Buffer.from(printed.fileBase64, 'base64'));
    assert.ok(printedPdf.getPageCount() >= 2);
    assert.equal(printedPdf.getForm().getTextField('Inventarnummer').getText(), '10050035-02-02-001');
    assert.match(printedPdf.getForm().getTextField('Beschreibung_des_Mangels').getText(), /Ölaustritt/);
    assert.equal((await fetch(`${baseUrl}/api/defects/${defect.id}/print`, {
      headers: headers(wardrobeToken),
    })).status, 404);
  } finally {
    server.close();
  }
});

test('defect disposal reduces stock and creates a linked procurement draft', async () => {
  const { server, baseUrl } = await start();
  try {
    const materialToken = await token(baseUrl, 'materialwart', 'Material123!');
    const auth = headers(materialToken);
    const create = await fetch(`${baseUrl}/api/defects`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({
        entityType: 'MaterialItem', entityId: 'material-1', affectedQuantity: 2,
        title: 'Irreparabler Schaden', description: 'Zwei Geräte sind wirtschaftlich nicht reparierbar.',
        priority: 'Hoch', responsibleDepartment: 'Technik',
      }),
    });
    assert.equal(create.status, 201);
    const defect = await create.json();

    const disposal = await fetch(`${baseUrl}/api/defects/${defect.id}/dispose-and-procure`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({
        disposalQuantity: 2, replacementQuantity: 2, requestedBudgetGross: 1190,
        reason: 'Ersatz für die irreparabel beschädigten Geräte.', department: 'Technik',
        costCenter: 'TECH-01', desiredDeliveryDate: '2026-09-01',
      }),
    });
    assert.equal(disposal.status, 201);
    const result = await disposal.json();
    assert.equal(result.defect.disposal.quantity, 2);
    assert.equal(result.defect.disposal.procurementRequestId, result.procurementRequest.id);
    assert.equal(result.procurementRequest.status, 'Entwurf');
    assert.equal(result.procurementRequest.sourceDefectId, defect.id);
    assert.equal(result.procurementRequest.items[0].name, 'Kettensäge');
    assert.equal(result.procurementRequest.items[0].quantity, 2);
    assert.equal(result.procurementRequest.items[0].categoryId, '02');
    assert.equal(result.procurementRequest.items[0].subcategoryId, '02-02');
    assert.equal(result.procurementRequest.requestedBudgetGross, 1190);

    const item = await fetch(`${baseUrl}/api/material/material-1`, { headers: auth })
      .then((response) => response.json());
    assert.equal(item.quantity, 3);
    assert.equal(item.status, 'Lagernd');
    const procurement = await fetch(`${baseUrl}/api/procurement`, { headers: auth })
      .then((response) => response.json());
    assert.equal(procurement.length, 1);
    assert.equal(procurement[0].id, result.procurementRequest.id);
    assert.equal((await fetch(`${baseUrl}/api/defects/${defect.id}/dispose-and-procure`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({
        disposalQuantity: 1, replacementQuantity: 1, requestedBudgetGross: 500,
        reason: 'Doppelte Aussonderung darf nicht möglich sein.',
      }),
    })).status, 409);
  } finally {
    server.close();
  }
});

test('failed inspections create a linked defect and archived defects expire after two years', async () => {
  const { app, server, baseUrl } = await start();
  try {
    const adminToken = await token(baseUrl, 'admin', 'MaterialKompass2026!');
    const auth = headers(adminToken);
    const inspection = await fetch(`${baseUrl}/api/material/material-1/inspections`, {
      method: 'POST', headers: auth,
      body: JSON.stringify({ inspectionDate: '2026-07-23', inspector: 'Prüfer', result: 'Nicht bestanden', notes: 'Sicherheitsbügel defekt' }),
    });
    assert.equal(inspection.status, 201);
    const inspectionData = await inspection.json();
    const defects = await fetch(`${baseUrl}/api/defects`, { headers: auth }).then((response) => response.json());
    assert.equal(defects.length, 1);
    assert.equal(defects[0].linkedInspectionId, inspectionData.id);

    assert.equal(typeof app.locals.applyDefectRetentionPolicy, 'function');
    await fetch(`${baseUrl}/api/defects/${defects[0].id}/transition`, { method: 'POST', headers: auth, body: JSON.stringify({ status: 'In Prüfung' }) });
    await fetch(`${baseUrl}/api/defects/${defects[0].id}/assign`, { method: 'POST', headers: auth, body: JSON.stringify({ assignee: 'Werkstatt' }) });
    for (const status of ['Zugewiesen', 'In Bearbeitung', 'Behoben']) {
      assert.equal((await fetch(`${baseUrl}/api/defects/${defects[0].id}/transition`, { method: 'POST', headers: auth, body: JSON.stringify({ status }) })).status, 200);
    }
    await fetch(`${baseUrl}/api/defects/${defects[0].id}`, { method: 'PUT', headers: auth, body: JSON.stringify({ resolution: 'Repariert' }) });
    assert.equal((await fetch(`${baseUrl}/api/defects/${defects[0].id}/transition`, { method: 'POST', headers: auth, body: JSON.stringify({ status: 'Geprüft/Geschlossen' }) })).status, 200);
    assert.equal((await fetch(`${baseUrl}/api/defects/${defects[0].id}/archive`, { method: 'POST', headers: auth })).status, 200);
    await app.locals.applyDefectRetentionPolicy(new Date('2029-08-01T00:00:00.000Z'));
    const afterRetention = await fetch(`${baseUrl}/api/defects?archived=all`, { headers: auth }).then((response) => response.json());
    assert.equal(afterRetention.length, 0);
  } finally {
    server.close();
  }
});
