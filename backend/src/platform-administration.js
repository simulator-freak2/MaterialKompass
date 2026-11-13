const PLATFORM_ORGANIZATION_ID = 'org-materialkompass-administration';
const PLATFORM_UNIT_ID = 'unit-materialkompass-administration';
const PLATFORM_SYSTEM_KIND = 'platform_administration';

function isPlatformAdministration(req) {
  return req?.user?.platformAdmin === true
    && req?.tenant?.organizationId === PLATFORM_ORGANIZATION_ID;
}

// This organization is a protected administrative control plane. Its members
// are derived from the global platform flag, never from organization grants.
function synchronizePlatformAdministration(data) {
  const organizations = (data.organizations ||= []);
  const units = (data.organizationUnits ||= []);
  const memberships = (data.memberships ||= []);
  const timestamp = new Date().toISOString();
  for (const entry of organizations) {
    if (entry.id !== PLATFORM_ORGANIZATION_ID && entry.systemKind === PLATFORM_SYSTEM_KIND) delete entry.systemKind;
  }
  for (const entry of units) {
    if (entry.id !== PLATFORM_UNIT_ID && entry.systemKind === PLATFORM_SYSTEM_KIND) delete entry.systemKind;
  }
  let organization = organizations.find((entry) => entry.id === PLATFORM_ORGANIZATION_ID);
  const occupiedNumbers = new Set([
    ...organizations.filter((entry) => entry.id !== PLATFORM_ORGANIZATION_ID),
    ...units.filter((entry) => entry.organizationId !== PLATFORM_ORGANIZATION_ID),
  ].map((entry) => String(entry.edvNumber || '')));
  let edvNumber = 'MK-PLATFORM';
  for (let suffix = 2; occupiedNumbers.has(edvNumber); suffix += 1) edvNumber = `MK-PLATFORM-${suffix}`;
  if (!organization) {
    organization = { id: PLATFORM_ORGANIZATION_ID, createdAt: timestamp, branding: {} };
    organizations.push(organization);
  }
  Object.assign(organization, { name: 'MaterialKompass – Zentrale Verwaltung', shortName: 'MK ADMIN',
    edvNumber, systemKind: PLATFORM_SYSTEM_KIND, status: 'active', archivedAt: null, purgeAfter: null });
  let unit = units.find((entry) => entry.id === PLATFORM_UNIT_ID);
  if (!unit) {
    unit = { id: PLATFORM_UNIT_ID, createdAt: timestamp };
    units.push(unit);
  }
  Object.assign(unit, { organizationId: PLATFORM_ORGANIZATION_ID, parentId: null,
    name: 'Zentrale Kontenverwaltung', type: 'Plattformverwaltung', systemKind: PLATFORM_SYSTEM_KIND,
    unitKind: 'standard', baseUnitId: null, edvNumber, status: 'active', dataIsolation: 'strict',
    archivedAt: null, purgeAfter: null, inventoryVisibleToUnitIds: [] });
  // Extra imported units must not turn the protected administrative root into
  // another domain hierarchy. Ordinary organizations are left untouched.
  for (let index = units.length - 1; index >= 0; index -= 1) {
    if (units[index].organizationId === PLATFORM_ORGANIZATION_ID && units[index].id !== PLATFORM_UNIT_ID) units.splice(index, 1);
  }
  const previous = new Map(memberships.filter((entry) => entry.organizationId === PLATFORM_ORGANIZATION_ID)
    .map((entry) => [entry.userId, entry]));
  for (let index = memberships.length - 1; index >= 0; index -= 1) {
    if (memberships[index].organizationId === PLATFORM_ORGANIZATION_ID) memberships.splice(index, 1);
  }
  for (const user of data.users || []) {
    if (user.platformAdmin !== true || user.identityErased) continue;
    const former = previous.get(user.id);
    memberships.push({ id: former?.id || `membership-mk-admin-${user.id}`,
      userId: user.id, organizationId: PLATFORM_ORGANIZATION_ID,
      // Global account activation is checked on every authentication. Keep
      // organization membership independent so reactivation needs no restart.
      status: 'active', defaultUnitId: PLATFORM_UNIT_ID,
      scopes: [{ unitId: PLATFORM_UNIT_ID, includeDescendants: false, roles: ['Admin'], departmentIds: [] }],
      createdAt: former?.createdAt || timestamp, lastSelected: former?.lastSelected === true,
      lastUnitId: PLATFORM_UNIT_ID });
  }
  return { organization, unit };
}

function administrationRouteAllowed(req) {
  if (req.path === '/api/auth/qr-credentials/me' || req.path.startsWith('/api/auth/qr-credentials/me/')) return true;
  if (req.path === '/api/system/messages/me' && req.method === 'GET') return true;
  if (/^\/api\/system\/messages\/[^/]+\/acknowledge$/.test(req.path) && req.method === 'POST') return true;
  if (req.path === '/api/users/me' || req.path.startsWith('/api/users/me/')) return true;
  if (['/api/auth/me', '/api/auth/logout', '/api/auth/context', '/api/dashboard', '/api/updater/authorization'].includes(req.path)) return true;
  if (req.path.startsWith('/api/system/backup')) return true;
  if (req.path === '/api/organizations') return ['GET', 'POST'].includes(req.method);
  if (req.path === '/api/platform/organizations') return req.method === 'GET';
  if (/^\/api\/platform\/organizations\/[^/]+$/.test(req.path)) return req.method === 'GET';
  if (/^\/api\/platform\/organizations\/[^/]+\/restore$/.test(req.path)) return req.method === 'POST';
  if (/^\/api\/platform\/organizations\/[^/]+\/admins$/.test(req.path)) return req.method === 'POST';
  if (/^\/api\/platform\/organizations\/[^/]+\/admins\/[^/]+$/.test(req.path)) return req.method === 'DELETE';
  if (/^\/api\/organizations\/[^/]+$/.test(req.path)) return ['PUT', 'DELETE'].includes(req.method);
  if (['/api/organization-units', '/api/departments', '/api/roles'].includes(req.path)) return req.method === 'GET';
  if (req.path === '/api/users') return ['GET', 'POST'].includes(req.method);
  if (['/api/users/identity-conflicts', '/api/platform/service-devices'].includes(req.path)) return req.method === 'GET';
  if (/^\/api\/users\/[^/]+$/.test(req.path)) return req.method === 'PUT';
  if (/^\/api\/platform\/users\/[^/]+$/.test(req.path)) return req.method === 'DELETE';
  if (/^\/api\/users\/[^/]+\/qr-credential$/.test(req.path)) return req.method === 'POST';
  if (/^\/api\/users\/[^/]+\/qr-credentials$/.test(req.path)) return req.method === 'GET';
  if (/^\/api\/users\/[^/]+\/qr-credentials\/[^/]+$/.test(req.path)) return req.method === 'DELETE';
  return /^\/api\/users\/[^/]+\/(mfa-policy|mfa|passkeys|password-reset|verification\/(resend|confirm))$/.test(req.path);
}

module.exports = { PLATFORM_ORGANIZATION_ID, PLATFORM_UNIT_ID, PLATFORM_SYSTEM_KIND,
  isPlatformAdministration, synchronizePlatformAdministration, administrationRouteAllowed };
