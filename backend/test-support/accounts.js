const assert = require('node:assert/strict');
const { PLATFORM_ORGANIZATION_ID } = require('../src/platform-administration');

async function centralToken(request, token) {
  const result = await request('/api/auth/context', {
    method: 'POST', token, body: { organizationId: PLATFORM_ORGANIZATION_ID },
  });
  assert.equal(result.response.status, 200, JSON.stringify(result.data));
  return result.data.token;
}

// Set up domain-test users through both public steps: global identity, then
// an explicit grant in the organization under test.
async function createOrganizationAccount(request, options) {
  const { roles = ['Nutzer'], departmentIds = [], scopes, defaultUnitId, ...identity } = options.body;
  const token = await centralToken(request, options.token);
  const created = await request('/api/users', { method: 'POST', token, body: identity });
  if (created.response.status !== 201) return created;
  const assigned = await request('/api/users/memberships', {
    method: 'POST', token: options.token,
    body: { identifier: identity.email, roles, departmentIds,
      ...(scopes ? { scopes, defaultUnitId } : {}) },
  });
  if (assigned.response.status !== 201) return assigned;
  const listed = await request(`/api/users?search=${encodeURIComponent(identity.email)}`, { token: options.token });
  assert.equal(listed.response.status, 200);
  return { response: created.response, data: { ...created.data,
    ...listed.data.find((user) => user.id === created.data.id) } };
}

async function centralRequest(request, path, options) {
  return request(path, { ...options, token: await centralToken(request, options.token) });
}

module.exports = { centralToken, centralRequest, createOrganizationAccount };
