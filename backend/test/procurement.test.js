const assert = require('node:assert/strict');
const test = require('node:test');
const { createApp } = require('../src/app');

async function start(options = {}) {
  const app = createApp({ skipEmailVerification: true, ...options });
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
  return { server, baseUrl, login, admin };
}

const headers = (token) => ({ Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' });
async function jsonRequest(url, token, method = 'GET', body) {
  const response = await fetch(url, { method, headers: headers(token), body: body === undefined ? undefined : JSON.stringify(body) });
  return { response, data: response.headers.get('content-type')?.includes('json') ? await response.json() : null };
}

function offerInput(request, totals, { shipping = 0, discount = 0, custom = [] } = {}) {
  const items = request.items.map((item, index) => ({
    requestItemId: item.id,
    offered: totals[index] != null,
    grossTotal: totals[index] ?? 0,
  }));
  const components = [
    { kind: 'shipping', label: 'Versandkosten', operation: 'add', grossAmount: shipping },
    { kind: 'discount', label: 'Rabatt', operation: 'subtract', grossAmount: discount },
    ...custom,
  ];
  const positionTotal = totals.reduce((sum, value) => sum + (value ?? 0), 0);
  const componentTotal = components.reduce((sum, entry) => (
    sum + (entry.operation === 'subtract' ? -entry.grossAmount : entry.grossAmount)
  ), 0);
  return { items, components, documentGrossTotal: positionTotal + componentTotal };
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

test('suppliers require structured addresses and expose address suggestions', async () => {
  const calls = [];
  const addressLookup = {
    async suggestions(input) {
      calls.push(['suggestions', input]);
      return {
        configured: true,
        supported: true,
        suggestions: [{
          id: 'address-1',
          label: 'Hauptstraße, 31535 Neustadt, Deutschland',
          street: 'Hauptstraße',
          postalCode: '31535',
          city: 'Neustadt',
          country: 'Deutschland',
          countryCode: 'de',
        }],
      };
    },
    async localities(input) {
      calls.push(['localities', input]);
      return { supported: true, suggestions: ['Neustadt', 'Neustadt am Rübenberge'] };
    },
    async streets(input) {
      calls.push(['streets', input]);
      return { supported: true, suggestions: ['Hauptstraße', 'Hauptweg'] };
    },
  };
  const { server, baseUrl, admin } = await start({ addressLookup });
  try {
    const incomplete = await jsonRequest(`${baseUrl}/api/suppliers`, admin, 'POST', {
      name: 'Ohne Anschrift',
    });
    assert.equal(incomplete.response.status, 400);
    assert.match(incomplete.data.error, /Straße.*Hausnummer.*Postleitzahl.*Ort.*Land/);

    const created = await jsonRequest(`${baseUrl}/api/suppliers`, admin, 'POST', {
      name: 'Adresshandel', street: 'Hauptstraße', houseNumber: '12 / Hinterhaus',
      postalCode: '31535', city: 'Neustadt', country: 'Deutschland', active: true,
    });
    assert.equal(created.response.status, 201);
    assert.equal(created.data.street, 'Hauptstraße');
    assert.equal(created.data.address,
      'Hauptstraße 12 / Hinterhaus, 31535 Neustadt, Deutschland');

    const invalidPostalCode = await jsonRequest(
      `${baseUrl}/api/suppliers/${created.data.id}`, admin, 'PUT',
      { ...created.data, postalCode: '1234' },
    );
    assert.equal(invalidPostalCode.response.status, 400);
    assert.match(invalidPostalCode.data.error, /fünf Ziffern/);

    const suggestions = await jsonRequest(
      `${baseUrl}/api/address-suggestions?country=Deutschland&query=Hauptstra%C3%9Fe`,
      admin,
    );
    assert.equal(suggestions.response.status, 200);
    assert.equal(suggestions.data.suggestions[0].postalCode, '31535');

    const localities = await jsonRequest(
      `${baseUrl}/api/address-suggestions/localities?country=Deutschland&postalCode=31535`,
      admin,
    );
    assert.equal(localities.response.status, 200);
    assert.deepEqual(localities.data.suggestions, ['Neustadt', 'Neustadt am Rübenberge']);
    const streets = await jsonRequest(
      `${baseUrl}/api/address-suggestions/streets?country=Deutschland&postalCode=31535&city=Neustadt&query=Hau`,
      admin,
    );
    assert.equal(streets.response.status, 200);
    assert.deepEqual(streets.data.suggestions, ['Hauptstraße', 'Hauptweg']);
    assert.deepEqual(calls, [
      ['suggestions', { query: 'Hauptstraße', country: 'Deutschland' }],
      ['localities', { country: 'Deutschland', postalCode: '31535' }],
      ['streets', {
        country: 'Deutschland', postalCode: '31535', city: 'Neustadt', query: 'Hau',
      }],
    ]);
  } finally { server.close(); }
});

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
  const { server, baseUrl, login, admin } = await start();
  try {
    const material = await login('materialwart@materialkompass.local', 'Material123!');
    const created = await jsonRequest(`${baseUrl}/api/procurement`, material, 'POST', {
      title: 'Werkzeugnachkauf', reason: 'Verbrauch', department: 'Technik',
      requestedBudgetGross: 60, items: [{ name: 'Karabiner', categoryId: '02', subcategoryId: '02-02', quantity: 10, unit: 'Stück', taxRate: 19 }],
    });
    await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/submit`, material, 'POST', {});
    const approved = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/approval`, admin, 'POST', { decision: 'approve', role: 'Vorsitz', approvedBudgetGross: 60 });
    assert.equal(approved.data.status, 'Genehmigt');

    const supplier = await jsonRequest(`${baseUrl}/api/suppliers`, admin, 'POST', {
      name: 'Testhandel', email: 'test@example.org', active: true,
      street: 'Handelsweg', houseNumber: '12a', postalCode: '30159',
      city: 'Hannover', country: 'Deutschland',
    });
    assert.equal(supplier.response.status, 201);
    const cheap = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/offers`, material, 'POST', {
      supplierId: 'supplier-1', ...offerInput(created.data, [48]),
    });
    const expensive = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/offers`, material, 'POST', {
      supplierId: supplier.data.id, ...offerInput(created.data, [50], { shipping: 5 }),
    });
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
    await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/receipts/${finalReceipt.data.id}/transfer`, material, 'POST', { items: [{ requestItemId: created.data.items[0].id, locationId: 'loc-1', itemType: 'bulk' }] });
    detail = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}`, material);
    assert.equal(detail.data.status, 'Abgeschlossen');

    const inventory = await jsonRequest(`${baseUrl}/api/material`, material);
    assert.ok(inventory.data.some((item) => item.name === 'Karabiner' && item.quantity === 4));
    assert.ok(inventory.data.some((item) => item.name === 'Karabiner' && item.quantity === 6));
    const exported = await jsonRequest(`${baseUrl}/api/procurement/export/xlsx`, material);
    assert.equal(exported.response.status, 200);
    assert.match(exported.data.fileName, /\.xlsx$/);
    const document = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/documents`, material, 'POST', {
      fileName: 'Rechnung.pdf', documentType: 'Rechnung',
      fileBase64: Buffer.from('%PDF-1.4\n%%EOF').toString('base64'),
    });
    assert.equal(document.response.status, 201);
    const downloaded = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/documents/${document.data.id}`, material);
    assert.equal(Buffer.from(downloaded.data.fileBase64, 'base64').toString(), '%PDF-1.4\n%%EOF');
    for (const type of ['orders', 'offers', 'receipts']) {
      const printed = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/print/${type}`, material);
      assert.equal(printed.response.status, 200);
      assert.match(Buffer.from(printed.data.fileBase64, 'base64').toString('ascii', 0, 8), /^%PDF-1.4/);
    }
  } finally { server.close(); }
});

test('offers require reconciled line totals and can be safely corrected before ordering', async () => {
  const { server, baseUrl, login, admin } = await start();
  try {
    const material = await login('materialwart@materialkompass.local', 'Material123!');
    const created = await jsonRequest(`${baseUrl}/api/procurement`, material, 'POST', {
      title: 'Mehrteiliges Angebot', reason: 'Ersatzbedarf', requestedBudgetGross: 200,
      items: [
        { name: 'Position A', categoryId: '02', quantity: 2, unit: 'Stück' },
        { name: 'Position B', categoryId: '02', quantity: 1, unit: 'Stück' },
      ],
    });
    await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/submit`, material, 'POST', {});

    const input = offerInput(created.data, [100, null], {
      shipping: 10,
      discount: 5,
      custom: [{ kind: 'custom', label: 'Verpackung', operation: 'add', grossAmount: 2 }],
    });
    const mismatch = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/offers`, material, 'POST', {
      supplierId: 'supplier-1', ...input, documentGrossTotal: 108,
    });
    assert.equal(mismatch.response.status, 400);
    assert.match(mismatch.data.error, /weicht/);

    const createdOffer = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/offers`, material, 'POST', {
      supplierId: 'supplier-1', offerNumber: 'K-100', ...input,
    });
    assert.equal(createdOffer.response.status, 201);
    assert.equal(createdOffer.data.positionsGrossTotal, 100);
    assert.equal(createdOffer.data.calculatedGrossTotal, 107);
    assert.equal(createdOffer.data.items[1].offered, false);
    await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/select-offer`, material, 'POST', {
      offerId: createdOffer.data.id,
    });

    const correctedInput = offerInput(created.data, [100, null], {
      shipping: 10,
      discount: -5,
      custom: [{ kind: 'custom', label: 'Verpackung', operation: 'add', grossAmount: 2 }],
    });
    const corrected = await jsonRequest(
      `${baseUrl}/api/procurement/${created.data.id}/offers/${createdOffer.data.id}`,
      material,
      'PUT',
      {
        supplierId: 'supplier-1', offerNumber: 'K-100-korrigiert',
        expectedUpdatedAt: createdOffer.data.updatedAt, ...correctedInput,
      },
    );
    assert.equal(corrected.response.status, 200);
    assert.equal(corrected.data.selectedOfferId, null);
    assert.equal(corrected.data.offers[0].calculatedGrossTotal, 117);
    assert.equal(corrected.data.history.at(-1).action, 'Angebot bearbeitet');
    assert.equal(corrected.data.history.at(-1).details.selectionCleared, true);

    const stale = await jsonRequest(
      `${baseUrl}/api/procurement/${created.data.id}/offers/${createdOffer.data.id}`,
      material,
      'PUT',
      { supplierId: 'supplier-1', expectedUpdatedAt: createdOffer.data.updatedAt, ...correctedInput },
    );
    assert.equal(stale.response.status, 409);
    assert.match(stale.data.error, /zwischenzeitlich/);

    await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/select-offer`, material, 'POST', {
      offerId: createdOffer.data.id,
    });
    await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/approval`, admin, 'POST', {
      decision: 'approve', role: 'Vorsitz', approvedBudgetGross: 200,
    });
    const order = await jsonRequest(`${baseUrl}/api/procurement/${created.data.id}/orders`, material, 'POST', {
      supplierId: 'supplier-1', shippingGross: 10,
      items: [{ requestItemId: created.data.items[0].id, quantity: 2, grossTotal: 100 }],
    });
    assert.equal(order.response.status, 201);
    assert.equal(order.data.offerId, createdOffer.data.id);

    const locked = await jsonRequest(
      `${baseUrl}/api/procurement/${created.data.id}/offers/${createdOffer.data.id}`,
      material,
      'PUT',
      { supplierId: 'supplier-1', expectedUpdatedAt: corrected.data.offers[0].updatedAt, ...correctedInput },
    );
    assert.equal(locked.response.status, 409);
    assert.match(locked.data.error, /Bestellung verwendet/);
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
      supplierId: 'supplier-1', ...offerInput(created.data, [432.50]),
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
