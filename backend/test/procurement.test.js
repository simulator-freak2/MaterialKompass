const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');

async function start() {
  const app = createApp({ skipEmailVerification: true });
  const server = await new Promise((resolve) => {
    const instance = app.listen(0, '127.0.0.1', () => resolve(instance));
  });
  const baseUrl = `http://127.0.0.1:${server.address().port}`;
  const login = async (email, password) => {
    const response = await fetch(`${baseUrl}/api/auth/login`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password }),
    });
    assert.equal(response.status, 200);
    return (await response.json()).token;
  };
  const admin = await login('admin@materialkompass.org', 'MaterialKompass2026!');
  return { app, server, baseUrl, login, admin };
}

const headers = (token) => ({ Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' });
async function jsonRequest(url, token, method = 'GET', body) {
  const response = await fetch(url, { method, headers: headers(token), body: body === undefined ? undefined : JSON.stringify(body) });
  return { response, data: response.headers.get('content-type')?.includes('json') ? await response.json() : null };
}

async function createApprovers(baseUrl, admin, login) {
  for (const user of [
    { name: 'Vera Vorsitz', username: 'vorsitz', email: 'vorsitz@test.local', password: 'Testpasswort123!', roles: ['Vorsitz'] },
    { name: 'Theo Schatz', username: 'schatz', email: 'schatz@test.local', password: 'Testpasswort123!', roles: ['Schatzmeister'] },
  ]) {
    const created = await jsonRequest(`${baseUrl}/api/users`, admin, 'POST', user);
    assert.equal(created.response.status, 201);
  }
  return {
    chair: await login('vorsitz@test.local', 'Testpasswort123!'),
    treasurer: await login('schatz@test.local', 'Testpasswort123!'),
  };
}

test('procurement persists requested budget and needs one approval', async () => {
  const { server, baseUrl, login, admin } = await start();
  try {
    const { chair, treasurer } = await createApprovers(baseUrl, admin, login);
    const material = await login('materialwart@materialkompass.local', 'Material123!');
    const created = await jsonRequest(`${baseUrl}/api/procurement`, material, 'POST', {
      title: 'Neue Helme', reason: 'Austausch', department: 'Technik', costCenter: '4711',
      priority: 'Hoch', requestedBudgetGross: 150, items: [{ name: 'Helm', categoryId: '02', subcategoryId: '02-02', quantity: 2, unit: 'Stück', taxRate: 19 }],
    });
    assert.equal(created.response.status, 201);
    assert.match(created.data.number, /^BA-\d{4}-0001$/);
    assert.equal(created.data.requestedBudgetGross, 150);
    assert.equal(created.data.items[0].grossUnitPrice, undefined);

    const listed = await jsonRequest(`${baseUrl}/api/procurement`, material);
    assert.equal(listed.data.find((entry) => entry.id === created.data.id).requestedBudgetGross, 150);
    const updated = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}`, material, 'PUT', {
      ...created.data, requestedBudgetGross: '175,00',
    });
    assert.equal(updated.response.status, 200);
    assert.equal(updated.data.requestedBudgetGross, 175);
    const reloaded = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}`, material);
    assert.equal(reloaded.data.requestedBudgetGross, 175);

    const submitted = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/submit`, material, 'POST', {});
    assert.equal(submitted.data.status, 'Beantragt');
    const first = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/approval`, treasurer, 'POST', { decision: 'approve' });
    assert.equal(first.data.status, 'Genehmigt');
    assert.equal(first.data.approvedBudgetGross, 175);
    const duplicate = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/approval`, treasurer, 'POST', { decision: 'approve' });
    assert.equal(duplicate.response.status, 409);

    const small = await jsonRequest(`${baseUrl}/api/procurement`, material, 'POST', {
      title: 'Kleinbeschaffung', reason: 'Verbrauch', requestedBudgetGross: 80,
      items: [{ name: 'Handschuhe', categoryId: '02', quantity: 4, unit: 'Paar' }],
    });
    await jsonRequest(`${baseUrl}/api/procurement/${small.data.id}/submit`, material, 'POST', {});
    const missingBudget = await jsonRequest(`${baseUrl}/api/procurement/${small.data.id}/approval`, chair, 'POST', { decision: 'approve' });
    assert.equal(missingBudget.response.status, 400);
    const smallApproved = await jsonRequest(`${baseUrl}/api/procurement/${small.data.id}/approval`, chair, 'POST', { decision: 'approve', approvedBudgetGross: 70 });
    assert.equal(smallApproved.data.status, 'Genehmigt');
    assert.equal(smallApproved.data.approvedBudgetGross, 70);
    assert.equal(smallApproved.data.approvals.length, 1);
  } finally { server.close(); }
});

test('department heads can only request and see their assigned departments', async () => {
  const { server, baseUrl, login, admin } = await start();
  try {
    const department = await jsonRequest(`${baseUrl}/api/departments`, admin, 'POST', {
      name: 'Ausbildung', code: 'AUSB', active: true,
    });
    const otherDepartment = await jsonRequest(`${baseUrl}/api/departments`, admin, 'POST', {
      name: 'Öffentlichkeitsarbeit', code: 'OEFF', active: true,
    });
    const leader = await jsonRequest(`${baseUrl}/api/users`, admin, 'POST', {
      name: 'Fiona Fachbereich',
      username: 'fachbereich',
      email: 'fachbereich@test.local',
      password: 'Testpasswort123!',
      roles: ['Fachbereichsleiter'],
      departmentIds: [department.data.id],
    });
    assert.equal(leader.response.status, 201);
    const leaderToken = await login('fachbereich@test.local', 'Testpasswort123!');
    const requestBody = {
      title: 'Übungsmaterial',
      reason: 'Ausbildungsbetrieb',
      requestedBudgetGross: 100,
      items: [{ name: 'Leinen', categoryId: '02', quantity: 2, unit: 'Stück' }],
    };

    const forbidden = await jsonRequest(`${baseUrl}/api/procurement`, leaderToken, 'POST', {
      ...requestBody, departmentId: otherDepartment.data.id,
    });
    assert.equal(forbidden.response.status, 403);
    const created = await jsonRequest(`${baseUrl}/api/procurement`, leaderToken, 'POST', {
      ...requestBody, departmentId: department.data.id,
    });
    assert.equal(created.response.status, 201);
    assert.equal(created.data.department, 'Ausbildung');
    assert.equal(created.data.departmentId, department.data.id);
  } finally { server.close(); }
});

test('procurement supports offer selection, split workflow, receipts and inventory transfer', async () => {
  const { app, server, baseUrl, login, admin } = await start();
  try {
    const material = await login('materialwart@materialkompass.local', 'Material123!');
    const created = await jsonRequest(`${baseUrl}/api/procurement`, material, 'POST', {
      title: 'Werkzeugnachkauf', reason: 'Verbrauch', department: 'Technik',
      requestedBudgetGross: 60, items: [{ name: 'Karabiner', categoryId: '02', subcategoryId: '02-02', quantity: 10, unit: 'Stück', taxRate: 19 }],
    });
    await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/submit`, material, 'POST', {});
    const approved = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/approval`, admin, 'POST', { decision: 'approve', role: 'Vorsitz', approvedBudgetGross: 60 });
    assert.equal(approved.data.status, 'Genehmigt');

    const supplier = await jsonRequest(`${baseUrl}/api/suppliers`, admin, 'POST', { name: 'Testhandel', email: 'test@example.org', active: true });
    assert.equal(supplier.response.status, 201);
    const cheap = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/offers`, material, 'POST', { supplierId: 'supplier-1', grossTotal: 48, shippingGross: 0 });
    const expensive = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/offers`, material, 'POST', { supplierId: supplier.data.id, grossTotal: 50, shippingGross: 5 });
    assert.equal(cheap.response.status, 201);
    const noReason = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/select-offer`, material, 'POST', { offerId: expensive.data.id });
    assert.equal(noReason.response.status, 400);
    assert.equal((await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/select-offer`, material, 'POST', { offerId: expensive.data.id, justification: 'Schnellere Lieferung' })).response.status, 200);

    const budgetBlocked = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/orders`, material, 'POST', {
      supplierId: supplier.data.id, shippingGross: 20,
      items: [{ requestItemId: created.data.items[0].id, quantity: 10, grossUnitPrice: 5 }],
    });
    assert.equal(budgetBlocked.response.status, 409);
    assert.match(budgetBlocked.data.error, /freigegebene Budget/);
    const order = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/orders`, material, 'POST', {
      supplierId: supplier.data.id, shippingGross: 5,
      items: [{ requestItemId: created.data.items[0].id, quantity: 10, grossUnitPrice: 5 }],
    });
    assert.equal(order.response.status, 201);
    assert.match(order.data.number, /^BE-/);
    const overBudget = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/orders`, material, 'POST', { supplierId: supplier.data.id, items: [{ requestItemId: created.data.items[0].id, quantity: 1, grossUnitPrice: 5 }] });
    assert.equal(overBudget.response.status, 409);

    const partial = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/orders/${order.data.id}/receipts`, material, 'POST', { deliveryNoteNumber: 'LS-1', items: [{ requestItemId: created.data.items[0].id, quantity: 4 }] });
    assert.equal(partial.response.status, 201);
    let detail = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}`, material);
    assert.equal(detail.data.status, 'Teilweise geliefert');
    const transfer = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/receipts/${partial.data.id}/transfer`, material, 'POST', { items: [{ requestItemId: created.data.items[0].id, locationId: 'loc-1', stockStructureId: 'stock-1', itemType: 'bulk' }] });
    assert.equal(transfer.response.status, 200);
    assert.equal(transfer.data.created.length, 1);

    const finalReceipt = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/orders/${order.data.id}/receipts`, material, 'POST', { deliveryNoteNumber: 'LS-2', items: [{ requestItemId: created.data.items[0].id, quantity: 6 }] });
    assert.equal(finalReceipt.response.status, 201);
    const emailImport = {
      id: 'procurement-email-test', requestId: created.data.id,
      emailSource: { messageId: '<procurement-test@example.org>' },
    };
    app.locals.procurementEmailImports.push(emailImport);
    await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/receipts/${finalReceipt.data.id}/transfer`, material, 'POST', { items: [{ requestItemId: created.data.items[0].id, locationId: 'loc-1', itemType: 'bulk' }] });
    detail = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}`, material);
    assert.equal(detail.data.status, 'Abgeschlossen');
    assert.ok(emailImport.emailSource.deleteRequestedAt);
    assert.equal(emailImport.emailSource.deletedAt, undefined);

    const inventory = await jsonRequest(`${baseUrl}/api/material`, material);
    assert.ok(inventory.data.some((item) => item.name === 'Karabiner' && item.quantity === 4));
    assert.ok(inventory.data.some((item) => item.name === 'Karabiner' && item.quantity === 6));
    const exported = await jsonRequest(`${baseUrl}/api/procurement/export/xlsx`, material);
    assert.equal(exported.response.status, 200);
    assert.match(exported.data.fileName, /\.xlsx$/);
    const document = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/documents`, material, 'POST', {
      fileName: 'Rechnung.pdf', documentType: 'Rechnung',
      fileBase64: Buffer.from('%PDF test').toString('base64'),
    });
    assert.equal(document.response.status, 201);
    const downloaded = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/documents/${document.data.id}`, material);
    assert.equal(Buffer.from(downloaded.data.fileBase64, 'base64').toString(), '%PDF test');
    for (const type of ['orders', 'offers', 'receipts']) {
      const printed = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/print/${type}`, material);
      assert.equal(printed.response.status, 200);
      assert.match(Buffer.from(printed.data.fileBase64, 'base64').toString('ascii', 0, 8), /^%PDF-1.4/);
    }
  } finally { server.close(); }
});

test('order uses the gross line total without multiplying it by quantity', async () => {
  const { server, baseUrl, login, admin } = await start();
  try {
    const material = await login('materialwart@materialkompass.local', 'Material123!');
    const created = await jsonRequest(`${baseUrl}/api/procurement`, material, 'POST', {
      title: 'Feststoffwesten', reason: 'UVV', requestedBudgetGross: 450,
      items: [{ name: 'Feststoffweste', categoryId: '04', subcategoryId: '04-04', size: 'M', quantity: 20, unit: 'Stück' }],
    });
    await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/submit`, material, 'POST', {});
    const approved = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/approval`, admin, 'POST', {
      decision: 'approve', role: 'Vorsitz', approvedBudgetGross: 450,
    });
    assert.equal(approved.data.status, 'Genehmigt');
    await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/offers`, material, 'POST', {
      supplierId: 'supplier-1', grossTotal: 432.50, shippingGross: 0,
    });

    const ordered = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/orders`, material, 'POST', {
      supplierId: 'supplier-1', shippingGross: 0,
      items: [{ requestItemId: created.data.items[0].id, quantity: 20, grossUnitPrice: 432.50 }],
    });
    assert.equal(ordered.response.status, 201);
    assert.equal(ordered.data.grossTotal, 432.50);
    assert.equal(ordered.data.items[0].grossTotal, 432.50);
    assert.equal(ordered.data.items[0].grossUnitPrice, 21.63);
  } finally { server.close(); }
});

test('contested receipts require resolution before inventory transfer', async () => {
  const { server, baseUrl, login, admin } = await start();
  try {
    const material = await login('materialwart@materialkompass.local', 'Material123!');
    const created = await jsonRequest(`${baseUrl}/api/procurement`, material, 'POST', { title: 'Kleinmaterial', reason: 'Bedarf', requestedBudgetGross: 25, items: [{ name: 'Seil', categoryId: '02', quantity: 1, unit: 'Stück' }] });
    await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/submit`, material, 'POST', {});
    await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/approval`, admin, 'POST', { decision: 'approve', role: 'Vorsitz', approvedBudgetGross: 25 });
    const order = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/orders`, material, 'POST', { supplierId: 'supplier-1', items: [{ requestItemId: created.data.items[0].id, quantity: 1, grossUnitPrice: 20 }] });
    const receipt = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/orders/${order.data.id}/receipts`, material, 'POST', { deliveryNoteNumber: 'LS-X', contested: true, complaint: 'Verpackung und Ware beschädigt', items: [{ requestItemId: created.data.items[0].id, quantity: 1 }] });
    assert.equal(receipt.data.status, 'Beanstandet');
    const blocked = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/receipts/${receipt.data.id}/transfer`, material, 'POST', { items: [{ requestItemId: created.data.items[0].id, locationId: 'loc-1' }] });
    assert.equal(blocked.response.status, 409);
  } finally { server.close(); }
});

test('procurement creates category-based clothing inventory numbers', async () => {
  const { server, baseUrl, login, admin } = await start();
  try {
    const material = await login('materialwart@materialkompass.local', 'Material123!');
    const created = await jsonRequest(`${baseUrl}/api/procurement`, material, 'POST', {
      title: 'Einsatzkleidung', reason: 'Ersatzbedarf', requestedBudgetGross: 50,
      items: [{ name: 'Schutzjacke', categoryId: '04', subcategoryId: '04-04', size: 'M', quantity: 2, unit: 'Stück' }],
    });
    assert.equal(created.data.items[0].size, 'M');
    await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/submit`, material, 'POST', {});
    await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/approval`, admin, 'POST', {
      decision: 'approve', role: 'Vorsitz', approvedBudgetGross: 50,
    });
    const order = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/orders`, material, 'POST', {
      supplierId: 'supplier-1', items: [{ requestItemId: created.data.items[0].id, quantity: 2, grossTotal: 40 }],
    });
    const receipt = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/orders/${order.data.id}/receipts`, material, 'POST', {
      deliveryNoteNumber: 'LS-KLEIDUNG', items: [{ requestItemId: created.data.items[0].id, quantity: 2 }],
    });
    const transfer = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/receipts/${receipt.data.id}/transfer`, material, 'POST', {
      items: [{ requestItemId: created.data.items[0].id, locationId: 'loc-2', stockStructureId: 'stock-2' }],
    });
    assert.equal(transfer.response.status, 200);
    assert.deepEqual(transfer.data.created.map((entry) => entry.inventoryNumber), [
      '10050035-04-04-0001',
      '10050035-04-04-0002',
    ]);
  } finally { server.close(); }
});
