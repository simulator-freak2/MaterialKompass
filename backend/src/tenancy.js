const { AsyncLocalStorage } = require('node:async_hooks');
const { randomUUID } = require('node:crypto');

const DEFAULT_ORGANIZATION_ID = 'org-default';
const DEFAULT_UNIT_ID = 'unit-default-root';
const ORGANIZATION_RETENTION_DAYS = 730;
const RAW_COLLECTION = Symbol('materialkompass.rawTenantCollection');
const tenantStorage = new AsyncLocalStorage();

const UNIT_SCOPED_COLLECTIONS = new Set([
  'departments', 'locations', 'shelves', 'storageLevels', 'stockStructures',
  'materials', 'deletedMaterials', 'materialMovements', 'materialInspections',
  'materialDocuments', 'reservations', 'maintenanceEvents', 'clothingItems',
  'clothingInspections', 'deletedClothingItems', 'issueTransactions',
  'defectReports', 'notifications', 'defectEmailImports', 'procurementRequests',
  'procurementOffers', 'procurementOrders', 'procurementReceipts',
  'procurementDocuments', 'suppliers', 'documents', 'procurementEmailImports',
  'exportLogs', 'stocktakes', 'stocktakeEmailImports',
]);

const ORGANIZATION_SCOPED_COLLECTIONS = new Set([
  ...UNIT_SCOPED_COLLECTIONS,
  'categories', 'auditLogs', 'qrLoginCredentials', 'scannerEmailAddresses',
  'mailTemplates', 'serviceDevices', 'offlineClients', 'offlineCommandResults',
  'offlineSyncState',
]);
const PUBLIC_LOOKUP_COLLECTIONS = new Set([
  'qrLoginCredentials', 'serviceDevices', 'offlineClients', 'offlineCommandResults',
]);

function nowIso() {
  return new Date().toISOString();
}

function normalizeTenancyData(data) {
  const organizations = (data.organizations ||= []);
  const organizationUnits = (data.organizationUnits ||= []);
  const memberships = (data.memberships ||= []);
  if (organizations.length === 0) {
    organizations.push({
      id: DEFAULT_ORGANIZATION_ID,
      name: 'Organisation',
      shortName: 'ORG',
      status: 'active',
      branding: {},
      createdAt: nowIso(),
      archivedAt: null,
      purgeAfter: null,
    });
  }
  if (organizationUnits.length === 0) {
    organizationUnits.push({
      id: DEFAULT_UNIT_ID,
      organizationId: organizations[0].id,
      parentId: null,
      name: organizations[0].name,
      type: 'Organisation',
      status: 'active',
      createdAt: nowIso(),
      archivedAt: null,
      purgeAfter: null,
    });
  }
  const defaultOrganization = organizations[0];
  const defaultUnit = organizationUnits.find((unit) =>
    unit.organizationId === defaultOrganization.id && unit.parentId === null
  ) || organizationUnits[0];
  for (const user of data.users || []) {
    if (!memberships.some((entry) =>
      entry.userId === user.id && entry.organizationId === defaultOrganization.id
    )) {
      memberships.push({
        id: `membership-${user.id}-${defaultOrganization.id}`,
        userId: user.id,
        organizationId: defaultOrganization.id,
        status: 'active',
        defaultUnitId: defaultUnit.id,
        scopes: [{
          unitId: defaultUnit.id,
          includeDescendants: true,
          roles: [...(user.roles || ['Nutzer'])],
          departmentIds: [...(user.departmentIds || [])],
        }],
        createdAt: user.createdAt || nowIso(),
      });
    }
  }
  for (const name of ORGANIZATION_SCOPED_COLLECTIONS) {
    for (const entry of data[name] || []) {
      if (!entry || typeof entry !== 'object') continue;
      entry.organizationId ||= defaultOrganization.id;
      if (UNIT_SCOPED_COLLECTIONS.has(name)) entry.unitId ||= defaultUnit.id;
      if (name === 'categories') {
        entry.scope ||= 'organization';
        if (entry.scope === 'unit') entry.unitId ||= defaultUnit.id;
      }
    }
  }
  return { organizations, organizationUnits, memberships };
}

function descendantsOf(units, organizationId, unitId) {
  const result = new Set([unitId]);
  let changed = true;
  while (changed) {
    changed = false;
    for (const unit of units) {
      if (unit.organizationId !== organizationId || result.has(unit.id)) continue;
      if (unit.parentId && result.has(unit.parentId)) {
        result.add(unit.id);
        changed = true;
      }
    }
  }
  return result;
}

function rolePermissions(roles, organizationId, roleNames) {
  const names = new Set(roleNames || []);
  return [...new Set(roles
    .filter((role) => names.has(role.name)
      && (!role.organizationId || role.organizationId === organizationId))
    .flatMap((role) => role.permissions || []))];
}

function contextForMembership({ membership, units, roles, activeUnitId }) {
  if (!membership || membership.status !== 'active') return null;
  const organizationUnits = units.filter((unit) =>
    unit.organizationId === membership.organizationId && unit.status !== 'purged'
  );
  const requestedUnit = organizationUnits.find((unit) => unit.id === activeUnitId)
    || organizationUnits.find((unit) => unit.id === membership.defaultUnitId)
    || organizationUnits.find((unit) => unit.parentId === null);
  if (!requestedUnit) return null;
  const allowedUnitIds = new Set();
  const effectiveRoleNames = new Set();
  const departmentIds = new Set();
  for (const scope of membership.scopes || []) {
    const covered = scope.includeDescendants
      ? descendantsOf(organizationUnits, membership.organizationId, scope.unitId)
      : new Set([scope.unitId]);
    covered.forEach((id) => allowedUnitIds.add(id));
    if (covered.has(requestedUnit.id)) {
      (scope.roles || []).forEach((role) => effectiveRoleNames.add(role));
      (scope.departmentIds || []).forEach((id) => departmentIds.add(id));
    }
  }
  if (!allowedUnitIds.has(requestedUnit.id)) return null;
  const roleNames = [...effectiveRoleNames];
  return {
    organizationId: membership.organizationId,
    unitId: requestedUnit.id,
    allowedUnitIds,
    roles: roleNames,
    permissions: rolePermissions(roles, membership.organizationId, roleNames),
    departmentIds: [...departmentIds],
    membershipId: membership.id,
    organizationAdmin: roleNames.includes('Admin'),
    system: false,
  };
}

function currentTenant() {
  return tenantStorage.getStore() || null;
}

function runWithTenant(context, callback) {
  return tenantStorage.run(context, callback);
}

function runAsSystem(callback) {
  return tenantStorage.run({ system: true }, callback);
}

function rawCollection(collection) {
  return collection?.[RAW_COLLECTION] || collection;
}

function isVisible(entry, context, unitScoped, categoryScoped = false) {
  if (context?.system) return true;
  // Internal startup, migration and retention code runs without an HTTP
  // context and must be able to inspect the complete collection. Mutations
  // still require either an explicit tenant or system context in stampEntry.
  if (!context) return true;
  if (!entry || typeof entry !== 'object') return false;
  if (entry.organizationId !== context.organizationId) return false;
  if (categoryScoped && entry.scope === 'unit') {
    return context.allowedUnitIds?.has(entry.unitId) === true;
  }
  if (!unitScoped || !entry.unitId) return true;
  return context.allowedUnitIds?.has(entry.unitId) === true;
}

function stampEntry(entry, context, unitScoped) {
  if (!entry || typeof entry !== 'object') return entry;
  if (!context || context.system) {
    if (!entry.organizationId) {
      throw new Error('Mandantendaten dürfen außerhalb eines Organisationskontexts nicht angelegt werden.');
    }
    return entry;
  }
  if (entry.organizationId && entry.organizationId !== context.organizationId) {
    throw new Error('Ein Datensatz darf nicht in einen fremden Mandanten geschrieben werden.');
  }
  entry.organizationId = context.organizationId;
  if (unitScoped) {
    if (entry.unitId && !context.allowedUnitIds?.has(entry.unitId)) {
      throw new Error('Ein Datensatz darf nicht in eine unberechtigte Organisationseinheit geschrieben werden.');
    }
    entry.unitId ||= context.unitId;
  }
  return entry;
}

function createTenantCollection(entries, { unitScoped = false, categoryScoped = false } = {}) {
  if (entries?.[RAW_COLLECTION]) return entries;
  const target = Array.isArray(entries) ? entries : [];
  const view = () => target.filter((entry) =>
    isVisible(entry, currentTenant(), unitScoped, categoryScoped)
  );
  const replaceViewOrder = (ordered) => {
    const visible = new Set(view());
    let next = 0;
    for (let index = 0; index < target.length; index += 1) {
      if (visible.has(target[index])) target[index] = ordered[next++];
    }
  };
  let proxy;
  proxy = new Proxy(target, {
    get(_target, property) {
      if (property === RAW_COLLECTION) return target;
      if (property === Symbol.iterator) return view()[Symbol.iterator].bind(view());
      if (property === 'length') return view().length;
      if (property === 'toJSON') return () => view();
      if (/^(0|[1-9]\d*)$/.test(String(property))) return view()[Number(property)];
      if (property === 'push' || property === 'unshift') {
        return (...items) => {
          const context = currentTenant();
          const stamped = items.map((item) => stampEntry(item, context, unitScoped));
          if (property === 'push') target.push(...stamped);
          else target.unshift(...stamped);
          return view().length;
        };
      }
      if (property === 'pop' || property === 'shift') {
        return () => {
          const scoped = view();
          const item = property === 'pop' ? scoped.at(-1) : scoped[0];
          if (item === undefined) return undefined;
          target.splice(target.indexOf(item), 1);
          return item;
        };
      }
      if (property === 'splice') {
        return (start, deleteCount, ...items) => {
          const scoped = view();
          const normalizedStart = start < 0
            ? Math.max(scoped.length + start, 0) : Math.min(start, scoped.length);
          const count = deleteCount === undefined
            ? scoped.length - normalizedStart
            : Math.max(0, Math.min(deleteCount, scoped.length - normalizedStart));
          const removed = scoped.slice(normalizedStart, normalizedStart + count);
          const rawInsertAt = scoped[normalizedStart]
            ? target.indexOf(scoped[normalizedStart])
            : target.length;
          for (const entry of removed) target.splice(target.indexOf(entry), 1);
          const stamped = items.map((item) => stampEntry(item, currentTenant(), unitScoped));
          target.splice(Math.min(rawInsertAt, target.length), 0, ...stamped);
          return removed;
        };
      }
      if (property === 'sort' || property === 'reverse') {
        return (...args) => {
          const scoped = view();
          scoped[property](...args);
          replaceViewOrder(scoped);
          return proxy;
        };
      }
      const value = Array.prototype[property];
      if (typeof value === 'function') return value.bind(view());
      return Reflect.get(target, property);
    },
    set(_target, property, value) {
      if (property === 'length') {
        const scoped = view();
        const desired = Number(value);
        if (!Number.isInteger(desired) || desired < 0) return false;
        scoped.slice(desired).forEach((entry) => target.splice(target.indexOf(entry), 1));
        return true;
      }
      if (/^(0|[1-9]\d*)$/.test(String(property))) {
        const scoped = view();
        const index = Number(property);
        const stamped = stampEntry(value, currentTenant(), unitScoped);
        if (index < scoped.length) target[target.indexOf(scoped[index])] = stamped;
        else if (index === scoped.length) target.push(stamped);
        else return false;
        return true;
      }
      return Reflect.set(target, property, value);
    },
  });
  return proxy;
}

// createTenantCollection returns from the Proxy expression above. This helper
// assigns a stable self-reference needed by mutating Array methods.
function tenantCollection(entries, options) {
  const target = Array.isArray(entries) ? entries : [];
  return createTenantCollection(target, options);
}

function wrapTenantCollections(data) {
  for (const name of ORGANIZATION_SCOPED_COLLECTIONS) {
    if (PUBLIC_LOOKUP_COLLECTIONS.has(name)) continue;
    data[name] = tenantCollection(data[name] || [], {
      unitScoped: UNIT_SCOPED_COLLECTIONS.has(name),
      categoryScoped: name === 'categories',
    });
  }
}

function validateUnitTree(units, organizationId, parentId, movingId = null) {
  if (parentId === null) return true;
  const parent = units.find((entry) =>
    entry.id === parentId && entry.organizationId === organizationId && entry.status === 'active'
  );
  if (!parent || parent.id === movingId) return false;
  if (!movingId) return true;
  return !descendantsOf(units, organizationId, movingId).has(parentId);
}

function publicOrganization(organization) {
  return {
    id: organization.id,
    name: organization.name,
    shortName: organization.shortName,
    status: organization.status,
    branding: organization.branding || {},
    archivedAt: organization.archivedAt || null,
    purgeAfter: organization.purgeAfter || null,
  };
}

function registerTenancyRoutes({
  app, organizations, units, memberships, users, roles, authMiddleware,
  requirePermission, logEvent, persistOrganization = async () => {},
  persistUnit = async () => {}, persistMembership = async () => {},
  deleteUnit = async () => {}, deleteOrganizationData = async () => {},
}) {
  const text = (value, maximum = 160) => String(value || '').trim().slice(0, maximum);
  const membershipFor = (userId, organizationId) => memberships.find((entry) =>
    entry.userId === userId && entry.organizationId === organizationId && entry.status === 'active'
  );
  const canCreateOrganizationStructure = (req) =>
    req.user?.roles?.includes('Admin')
      && req.user?.permissions?.includes('organizations.write');

  app.get('/api/organizations', authMiddleware, (req, res) => {
    const allowed = new Set(memberships
      .filter((entry) => entry.userId === req.user.id && entry.status === 'active')
      .map((entry) => entry.organizationId));
    res.json(organizations.filter((entry) => allowed.has(entry.id)).map(publicOrganization));
  });

  app.post('/api/organizations', authMiddleware, async (req, res) => {
    if (!req.identity?.platformAdmin || !canCreateOrganizationStructure(req)) {
      return res.status(403).json({
        error: 'Nur Plattformadministratoren mit der Berechtigung organizations.write dürfen Organisationen anlegen.',
      });
    }
    const name = text(req.body.name);
    const shortName = text(req.body.shortName, 24).toUpperCase();
    if (!name || !shortName) return res.status(400).json({ error: 'Name und Kurzname sind erforderlich.' });
    if (organizations.some((entry) => entry.status !== 'purged'
      && (entry.name.toLocaleLowerCase('de') === name.toLocaleLowerCase('de')
        || entry.shortName.toLocaleLowerCase('de') === shortName.toLocaleLowerCase('de')))) {
      return res.status(409).json({ error: 'Name oder Kurzname wird bereits verwendet.' });
    }
    const organization = {
      id: randomUUID(), name, shortName, status: 'active',
      branding: req.body.branding && typeof req.body.branding === 'object' ? req.body.branding : {},
      createdAt: nowIso(), archivedAt: null, purgeAfter: null,
    };
    const root = {
      id: randomUUID(), organizationId: organization.id, parentId: null,
      name, type: 'Organisation', status: 'active', createdAt: nowIso(),
      archivedAt: null, purgeAfter: null,
    };
    organizations.push(organization);
    units.push(root);
    memberships.push({
      id: randomUUID(), userId: req.user.id, organizationId: organization.id,
      status: 'active', defaultUnitId: root.id,
      scopes: [{ unitId: root.id, includeDescendants: true, roles: ['Admin'], departmentIds: [] }],
      createdAt: nowIso(),
    });
    await persistOrganization(organization);
    await persistUnit(root);
    await persistMembership(memberships.at(-1));
    logEvent('create', 'Organization', { id: organization.id, name }, req.user.username);
    return res.status(201).json({ ...publicOrganization(organization), rootUnitId: root.id });
  });

  app.get('/api/organization-units', authMiddleware, (req, res) => {
    const allowed = req.tenant.allowedUnitIds || new Set();
    return res.json(units.filter((entry) =>
      entry.organizationId === req.tenant.organizationId && allowed.has(entry.id)
    ));
  });

  app.post('/api/organization-units', authMiddleware, async (req, res) => {
    if (!canCreateOrganizationStructure(req)) {
      return res.status(403).json({
        error: 'Nur Organisationsadministratoren mit der Berechtigung organizations.write dürfen Unterorganisationen anlegen.',
      });
    }
    const name = text(req.body.name);
    const type = text(req.body.type, 80);
    const parentId = text(req.body.parentId, 64) || req.tenant.unitId;
    if (!name || !type) return res.status(400).json({ error: 'Name und Einheitstyp sind erforderlich.' });
    if (!validateUnitTree(units, req.tenant.organizationId, parentId)) {
      return res.status(400).json({ error: 'Die übergeordnete Einheit ist ungültig.' });
    }
    if (!req.tenant.allowedUnitIds.has(parentId)) return res.status(403).json({ error: 'Forbidden' });
    const unit = {
      id: randomUUID(), organizationId: req.tenant.organizationId, parentId,
      name, type, status: 'active', createdAt: nowIso(), archivedAt: null, purgeAfter: null,
    };
    units.push(unit);
    await persistUnit(unit);
    logEvent('create', 'OrganizationUnit', { id: unit.id, parentId }, req.user.username);
    return res.status(201).json(unit);
  });

  app.put('/api/organization-units/:id', authMiddleware, requirePermission('users.write'), async (req, res) => {
    const unit = units.find((entry) => entry.id === req.params.id
      && entry.organizationId === req.tenant.organizationId
      && req.tenant.allowedUnitIds.has(entry.id));
    if (!unit) return res.status(404).json({ error: 'Organisationseinheit nicht gefunden.' });
    const parentId = req.body.parentId === undefined ? unit.parentId : text(req.body.parentId, 64) || null;
    if (unit.parentId === null && parentId !== null) {
      return res.status(409).json({ error: 'Die Wurzeleinheit kann nicht verschoben werden.' });
    }
    if (!validateUnitTree(units, unit.organizationId, parentId, unit.id)) {
      return res.status(400).json({ error: 'Die Hierarchie würde ungültig oder zyklisch.' });
    }
    Object.assign(unit, {
      name: text(req.body.name ?? unit.name),
      type: text(req.body.type ?? unit.type, 80),
      parentId,
    });
    await persistUnit(unit);
    logEvent('update', 'OrganizationUnit', { id: unit.id }, req.user.username);
    return res.json(unit);
  });

  app.post('/api/organization-units/:id/archive', authMiddleware, requirePermission('users.write'), async (req, res) => {
    const unit = units.find((entry) => entry.id === req.params.id
      && entry.organizationId === req.tenant.organizationId
      && req.tenant.allowedUnitIds.has(entry.id));
    if (!unit) return res.status(404).json({ error: 'Organisationseinheit nicht gefunden.' });
    if (unit.parentId === null) return res.status(409).json({ error: 'Die Wurzeleinheit kann nicht archiviert werden.' });
    const descendants = descendantsOf(units, unit.organizationId, unit.id);
    const activeChildren = units.some((entry) =>
      entry.organizationId === unit.organizationId && entry.parentId === unit.id && entry.status === 'active'
    );
    if (activeChildren) return res.status(409).json({ error: 'Untergeordnete Einheiten müssen zuerst übertragen oder archiviert werden.' });
    const hasOwnedData = [...UNIT_SCOPED_COLLECTIONS].some((name) => {
      const collection = rawCollection(app.locals.appData?.[name] || []);
      return collection.some((entry) => entry.organizationId === unit.organizationId
        && descendants.has(entry.unitId));
    });
    if (hasOwnedData) {
      return res.status(409).json({ error: 'Alle Daten müssen vor der Archivierung in eine aktive Einheit übertragen werden.' });
    }
    unit.status = 'archived';
    unit.archivedAt = nowIso();
    unit.purgeAfter = new Date(Date.now() + ORGANIZATION_RETENTION_DAYS * 86_400_000).toISOString();
    await persistUnit(unit);
    logEvent('archive', 'OrganizationUnit', { id: unit.id, purgeAfter: unit.purgeAfter }, req.user.username);
    return res.json(unit);
  });

  app.post('/api/organization-units/:id/transfer', authMiddleware, requirePermission('users.write'), async (req, res) => {
    const source = units.find((entry) => entry.id === req.params.id
      && entry.organizationId === req.tenant.organizationId
      && req.tenant.allowedUnitIds.has(entry.id));
    const targetId = text(req.body.targetUnitId, 64);
    const target = units.find((entry) => entry.id === targetId
      && entry.organizationId === req.tenant.organizationId
      && entry.status === 'active' && req.tenant.allowedUnitIds.has(entry.id));
    if (!source || !target) {
      return res.status(404).json({ error: 'Quell- oder Zieleinheit nicht gefunden.' });
    }
    if (source.id === target.id) {
      return res.status(400).json({ error: 'Quell- und Zieleinheit müssen verschieden sein.' });
    }
    let transferred = 0;
    for (const name of UNIT_SCOPED_COLLECTIONS) {
      const collection = rawCollection(app.locals.appData?.[name] || []);
      for (const entry of collection) {
        if (entry.organizationId === source.organizationId && entry.unitId === source.id) {
          entry.unitId = target.id;
          transferred += 1;
        }
      }
    }
    logEvent('transfer', 'OrganizationUnit', {
      sourceUnitId: source.id, targetUnitId: target.id, recordCount: transferred,
    }, req.user.username);
    return res.json({ sourceUnitId: source.id, targetUnitId: target.id, transferred });
  });

  async function purgeExpiredUnits(referenceTime = Date.now()) {
    const expired = units.filter((entry) => entry.status === 'archived'
      && Date.parse(entry.purgeAfter || '') <= referenceTime);
    for (const unit of expired) {
      unit.status = 'purged';
      unit.purgedAt = new Date(referenceTime).toISOString();
      await deleteOrganizationData(unit.organizationId, unit.id);
      await deleteUnit(unit.id);
    }
    return expired.length;
  }

  app.locals.purgeExpiredOrganizationUnits = purgeExpiredUnits;
  return { membershipFor, purgeExpiredUnits };
}

module.exports = {
  DEFAULT_ORGANIZATION_ID,
  DEFAULT_UNIT_ID,
  ORGANIZATION_RETENTION_DAYS,
  ORGANIZATION_SCOPED_COLLECTIONS,
  UNIT_SCOPED_COLLECTIONS,
  normalizeTenancyData,
  wrapTenantCollections,
  rawCollection,
  currentTenant,
  runWithTenant,
  runAsSystem,
  descendantsOf,
  contextForMembership,
  rolePermissions,
  registerTenancyRoutes,
};
