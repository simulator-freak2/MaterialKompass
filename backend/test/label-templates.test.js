const test = require('node:test');
const assert = require('node:assert/strict');
const express = require('express');
const { registerLabelTemplateRoutes, createLabelRenderer } = require('../src/label-templates');
const { wrapTenantCollections, runWithTenant, rawCollection } = require('../src/tenancy');

async function start(t, renderer = null) {
  const app = express(); app.use(express.json({ limit: '12mb' }));
  const units = [{ id: 'root', organizationId: 'a', parentId: null, status: 'active' }, { id: 'child', organizationId: 'a', parentId: 'root', status: 'active' }, { id: 'sibling', organizationId: 'a', parentId: 'root', status: 'active' }, { id: 'foreign', organizationId: 'b', parentId: null, status: 'active' }];
  const data = { labelTemplates: [], categories: [
    { id: 'mat', name: 'Material', organizationId: 'a', scope: 'organization', useInWardrobe: false },
    { id: 'clothes', name: 'Kleidung', organizationId: 'a', scope: 'organization', useInWardrobe: true },
    { id: 'local', name: 'Lokal', organizationId: 'a', scope: 'unit', unitId: 'child' },
    { id: 'other', name: 'Fremd', organizationId: 'b', scope: 'organization' },
  ], materials: [{ id: 'm1', organizationId: 'a', unitId: 'child', categoryCode: 'mat', name: 'Gerät', serialNumber: '', inventoryNumber: 'MK-1' }], clothingItems: [] };
  wrapTenantCollections(data);
  const users = [{ id: 'admin', name: 'Admin' }, { id: 'reader', name: 'Leser' }];
  const memberships = [{ userId: 'reader', organizationId: 'a', status: 'active', scopes: [{ unitId: 'child', roles: ['Nutzer'] }] }];
  const authMiddleware = (req, res, next) => {
    const unitId = req.headers['x-unit'] || 'child';
    const role = req.headers['x-role'] || 'Admin';
    req.user = { id: role === 'Nutzer' ? 'reader' : 'admin', username: 'test', roles: [role], permissions: ['inventory.read', 'clothing.read'] };
    req.tenant = { organizationId: unitId === 'foreign' ? 'b' : 'a', unitId, allowedUnitIds: new Set([unitId]), organizationAdmin: role === 'Admin' };
    runWithTenant(req.tenant, next);
  };
  registerLabelTemplateRoutes({ app, templates: data.labelTemplates, categories: data.categories, units, memberships, users, materials: data.materials, clothingItems: data.clothingItems, authMiddleware, logEvent() {}, renderer });
  const server = await new Promise(resolve => { const s = app.listen(0, '127.0.0.1', () => resolve(s)); });
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}/api/label-templates`;
  async function request(path = '', { method = 'GET', body, role = 'Admin', unit = 'child' } = {}) {
    const response = await fetch(base + path, { method, headers: { 'Content-Type': 'application/json', 'x-role': role, 'x-unit': unit }, ...(body ? { body: JSON.stringify(body) } : {}) });
    return { status: response.status, body: await response.json() };
  }
  return { request, data };
}
const input = (extra = {}) => ({ name: 'Gerät', type: 'inventory', manufacturer: 'Zebra', fileName: 'test.nlbl', fileBase64: Buffer.from('opaque manufacturer file').toString('base64'), categoryIds: ['mat'], scope: 'private', userIds: [], variables: [{ name: 'Serial', field: 'serialNumber' }], ...extra });

test('upload metadata excludes content; original download and optimistic update preserve bytes', async t => {
  const { request } = await start(t);
  const made = await request('', { method: 'POST', body: input() });
  assert.equal(made.status, 201); assert.equal(made.body.fileBase64, undefined);
  const id = made.body.id;
  assert.equal((await request(`/${id}/file`)).body.fileBase64, input().fileBase64);
  const update = await request(`/${id}`, { method: 'PUT', body: input({ name: 'Neu', fileBase64: undefined, updatedAt: made.body.updatedAt }) });
  assert.equal(update.status, 200); assert.equal(update.body.name, 'Neu');
  assert.equal((await request(`/${id}`, { method: 'PUT', body: input({ updatedAt: 'stale' }) })).status, 409);
});
test('cross-tenant and sibling access is denied; descendant recipients cannot edit source', async t => {
  const { request } = await start(t);
  const made = await request('', { method: 'POST', unit: 'child', body: input({ scope: 'descendants' }) });
  assert.equal(made.status, 201);
  for (const unit of ['foreign', 'sibling']) {
    assert.equal((await request('', { unit })).body.length, 0);
    for (const suffix of ['', '/file']) assert.equal((await request(`/${made.body.id}${suffix}`, { unit })).status, 404);
  }
  const root = await request('', { method: 'POST', unit: 'root', body: input({ scope: 'descendants' }) });
  const list = await request('', { role: 'Nutzer' });
  assert.equal(list.body.length, 2);
  assert.equal(list.body.find(x => x.id === root.body.id).canManage, false);
  assert.equal((await request(`/${root.body.id}`, { method: 'DELETE' })).status, 403);
});
test('Materialwart and Kleiderwart manage their own areas; readers cannot create', async t => {
  const { request } = await start(t);
  assert.equal((await request('', { method: 'POST', role: 'Materialwart', body: input() })).status, 201);
  assert.equal((await request('', { method: 'POST', role: 'Kleiderwart', body: input() })).status, 403);
  assert.equal((await request('', { method: 'POST', role: 'Nutzer', body: input() })).status, 403);
  assert.equal((await request('', { method: 'POST', role: 'Kleiderwart', body: input({ type: 'clothing', categoryIds: ['clothes'] }) })).status, 201);
  assert.equal((await request('/options', { role: 'Nutzer' })).body.users.length, 0);
});
test('reject invalid file, variables, cross-area categories and unauthorized sharing', async t => {
  const { request } = await start(t);
  const invalid = [{ manufacturer: 'Brother' }, { fileName: '../x.nlbl' }, { fileBase64: 'not base64!' }, { fileBase64: '' }, { variables: [{ name: 'A', field: '__proto__' }] }, { variables: [{ name: 'A', field: 'name' }, { name: 'A', field: 'size' }] }, { categoryIds: ['clothes'] }, { categoryIds: ['other'] }, { scope: 'users', userIds: ['foreign'] }, { categoryIds: ['local'], scope: 'organization' }];
  for (const change of invalid) assert.equal((await request('', { method: 'POST', body: input(change) })).status, 400, JSON.stringify(change));
  assert.equal((await request('', { method: 'POST', role: 'Materialwart', body: input({ scope: 'organization' }) })).status, 403);
});
test('selected users see only explicitly shared templates and no private ones', async t => {
  const { request } = await start(t);
  await request('', { method: 'POST', body: input() });
  const shared = await request('', { method: 'POST', unit: 'root', body: input({ scope: 'users', userIds: ['reader'] }) });
  assert.equal(shared.status, 201);
  const list = await request('', { role: 'Nutzer' });
  assert.deepEqual(list.body.map(x => x.id), [shared.body.id]);
});
test('render validates authoritative item access, category, quantities and missing-value acknowledgment', async t => {
  let received;
  const { request, data } = await start(t, async (_, payload) => { received = payload; return { fileBase64: Buffer.from('%PDF-1.7\nexample').toString('base64') }; });
  const made = await request('', { method: 'POST', body: input({ scope: 'descendants' }) });
  const path = `/${made.body.id}/render`;
  const body = { lines: [{ itemId: 'm1', copies: 2 }] };
  const check = await request(path, { method: 'POST', body: { ...body, checkOnly: true } });
  assert.equal(check.status, 200); assert.equal(check.body.missing[0].field, 'serialNumber');
  assert.equal((await request(path, { method: 'POST', body })).status, 422); assert.equal(received, undefined);
  const result = await request(path, { method: 'POST', body: { ...body, allowMissing: true } });
  assert.equal(result.status, 200); assert.equal(received.records[0].values.Serial, ''); assert.equal(received.useTemplatePageSize, true);
  assert.equal((await request(path, { method: 'POST', body: { lines: [{ itemId: 'm1', copies: 1001 }] } })).status, 400);
  assert.equal((await request(path, { method: 'POST', body: { lines: [{ itemId: 'unknown', copies: 1 }] } })).status, 404);
  rawCollection(data.materials)[0].categoryCode = 'clothes';
  assert.equal((await request(path, { method: 'POST', body })).status, 400);
});
test('unconfigured renderer is explicit; invalid renderer output never becomes a print job', async t => {
  const a = await start(t);
  const made = await a.request('', { method: 'POST', body: input({ variables: [] }) });
  const body = { lines: [{ itemId: 'm1', copies: 1 }] };
  assert.equal((await a.request(`/${made.body.id}/render`, { method: 'POST', body })).status, 503);
  const b = await start(t, async () => ({ fileBase64: Buffer.from('not a PDF').toString('base64') }));
  const second = await b.request('', { method: 'POST', body: input({ variables: [] }) });
  assert.equal((await b.request(`/${second.body.id}/render`, { method: 'POST', body })).status, 502);
});
test('manufacturer renderer bounds network contract and refuses redirects', async () => {
  assert.equal(createLabelRenderer({ url: '' }), null);
  assert.throws(() => createLabelRenderer({ url: 'file:///etc/passwd' }));
  let called;
  const render = createLabelRenderer({ url: 'https://renderer.example/api', token: 'test-token', fetchImpl: async (url, options) => { called = { url, options }; return new Response(JSON.stringify({ ok: true })); } });
  assert.deepEqual(await render('render', { sample: true }), { ok: true });
  assert.equal(called.url, 'https://renderer.example/api/render');
  assert.equal(called.options.redirect, 'error');
  assert.equal(called.options.headers.Authorization, 'Bearer test-token');
});
