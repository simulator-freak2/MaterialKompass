const { randomUUID } = require('node:crypto');
const { rawCollection, DEFAULT_ORGANIZATION_ID, DEFAULT_UNIT_ID } = require('./tenancy');

const BACKUP_FORMAT = 'MaterialKompass Gesamtdatensicherung';
const BACKUP_SCHEMA_VERSION = 1;
const MAX_BACKUP_RECORDS = 500_000;

function uniqueValues(entries, field) {
  const values = entries.map((entry) => String(entry?.[field] || '').trim().toLowerCase());
  return values.every(Boolean) && new Set(values).size === values.length;
}

function uniqueRoleNames(roles) {
  const values = roles.map((role) =>
    `${String(role?.organizationId || '__global__').toLowerCase()}:${String(role?.name || '').trim().toLowerCase()}`
  );
  return values.every((value) => !value.endsWith(':'))
    && new Set(values).size === values.length;
}

function validatedBackup(input, collectionNames) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    throw Object.assign(new Error('Die Sicherungsdatei ist kein JSON-Objekt.'), { status: 400 });
  }
  if (input.format !== BACKUP_FORMAT || input.schemaVersion !== BACKUP_SCHEMA_VERSION) {
    throw Object.assign(new Error('Die Datei ist keine unterstützte MaterialKompass-Sicherung.'), { status: 400 });
  }
  if (!input.data || typeof input.data !== 'object' || Array.isArray(input.data)) {
    throw Object.assign(new Error('Die Sicherungsdatei enthält keinen gültigen Datenbestand.'), { status: 400 });
  }

  const requiredNames = ['users', 'roles', 'passkeys', ...collectionNames];
  let recordCount = 0;
  for (const name of requiredNames) {
    if (!Array.isArray(input.data[name])) {
      throw Object.assign(new Error(`Die Sammlung „${name}“ fehlt oder ist ungültig.`), { status: 400 });
    }
    recordCount += input.data[name].length;
  }
  if (recordCount > MAX_BACKUP_RECORDS) {
    throw Object.assign(new Error('Die Sicherung enthält zu viele Datensätze.'), { status: 413 });
  }

  const users = input.data.users;
  const roles = input.data.roles;
  const passkeys = input.data.passkeys;
  if (!uniqueValues(users, 'id') || !uniqueValues(users, 'username') || !uniqueValues(users, 'email')) {
    throw Object.assign(new Error('Nutzer-IDs, Nutzernamen oder E-Mail-Adressen sind ungültig oder doppelt.'), { status: 400 });
  }
  if (!uniqueValues(roles, 'id') || !uniqueRoleNames(roles)) {
    throw Object.assign(new Error('Rollen-IDs oder Rollennamen sind ungültig oder doppelt.'), { status: 400 });
  }
  const roleNames = new Set(roles.map((role) => role.name));
  const userIds = new Set(users.map((user) => user.id));
  const organizations = input.data.organizations;
  const units = input.data.organizationUnits;
  const memberships = input.data.memberships;
  if (!uniqueValues(organizations, 'id') || !uniqueValues(units, 'id')
      || !uniqueValues(memberships, 'id')) {
    throw Object.assign(new Error('Organisations-, Einheiten- oder Mitgliedschafts-IDs sind ungültig oder doppelt.'), { status: 400 });
  }
  const organizationIds = new Set(organizations.map((entry) => entry.id));
  const unitById = new Map(units.map((entry) => [entry.id, entry]));
  if (units.some((unit) => !organizationIds.has(unit.organizationId)
      || (unit.parentId && unitById.get(unit.parentId)?.organizationId !== unit.organizationId))) {
    throw Object.assign(new Error('Die Organisationshierarchie der Sicherung ist inkonsistent.'), { status: 400 });
  }
  if (memberships.some((membership) =>
    !userIds.has(membership?.userId)
      || !organizationIds.has(membership?.organizationId)
      || !Array.isArray(membership.scopes)
      || membership.scopes.some((scope) =>
        unitById.get(scope?.unitId)?.organizationId !== membership.organizationId
          || !Array.isArray(scope.roles)
          || scope.roles.some((role) => !roleNames.has(role))))) {
    throw Object.assign(new Error('Mindestens eine Mitgliedschaft der Sicherung ist inkonsistent.'), { status: 400 });
  }
  if (users.some((user) => !Array.isArray(user.roles)
      || user.roles.some((role) => !roleNames.has(role))
      || typeof user.passwordHash !== 'string'
      || user.passwordHash.length < 20)) {
    throw Object.assign(new Error('Mindestens ein Nutzer verweist auf eine unbekannte Rolle oder hat ungültige Anmeldedaten.'), { status: 400 });
  }
  const activeUserIds = new Set(users.filter((user) => user.active === true).map((user) => user.id));
  const hasActiveAdmin = memberships.some((membership) =>
    activeUserIds.has(membership?.userId)
      && membership.status === 'active'
      && Array.isArray(membership.scopes)
      && membership.scopes.some((scope) => Array.isArray(scope.roles)
        && scope.roles.includes('Admin'))
  );
  if (!hasActiveAdmin) {
    throw Object.assign(new Error('Die Sicherung enthält keinen aktiven Admin und kann nicht importiert werden.'), { status: 400 });
  }
  if (!uniqueValues(passkeys, 'id') || passkeys.some((passkey) => !userIds.has(passkey.userId))) {
    throw Object.assign(new Error('Die Passkey-Daten sind ungültig oder verweisen auf unbekannte Nutzer.'), { status: 400 });
  }

  return structuredClone(Object.fromEntries(
    requiredNames.map((name) => [name, input.data[name]]),
  ));
}

function replaceCollection(target, values) {
  const collection = rawCollection(target);
  collection.splice(0, collection.length, ...values);
}

function backupDocument(appData, collectionNames, applicationVersion) {
  return {
    format: BACKUP_FORMAT,
    schemaVersion: BACKUP_SCHEMA_VERSION,
    applicationVersion,
    createdAt: new Date().toISOString(),
    data: Object.fromEntries([
      ['users', structuredClone(rawCollection(appData.users))],
      ['roles', structuredClone(rawCollection(appData.roles))],
      ['passkeys', structuredClone(rawCollection(appData.passkeys || []))],
      ...collectionNames.map((name) => [
        name,
        structuredClone(rawCollection(appData[name] || [])),
      ]),
    ]),
  };
}

function importAuditEntry(data, username) {
  const organizationId = data.organizations[0]?.id || DEFAULT_ORGANIZATION_ID;
  const unitId = data.organizationUnits.find((entry) =>
    entry.organizationId === organizationId && entry.parentId === null)?.id
    || DEFAULT_UNIT_ID;
  return {
    id: `audit-backup-import-${randomUUID()}`,
    organizationId,
    unitId,
    timestamp: new Date().toISOString(),
    actor: username,
    action: 'import',
    entity: 'DataBackup',
    details: { schemaVersion: BACKUP_SCHEMA_VERSION },
  };
}

function validateImportBody(req, res, next) {
  if (!req.body || typeof req.body !== 'object' || Array.isArray(req.body)) {
    return res.status(400).json({ error: 'Der Request-Body muss ein JSON-Objekt sein.' });
  }
  const stack = [{ value: req.body, depth: 0 }];
  let nodes = 0;
  while (stack.length) {
    const { value, depth } = stack.pop();
    nodes += 1;
    if (nodes > 1_000_000 || depth > 20) {
      return res.status(413).json({ error: 'Die Sicherung ist zu tief oder zu komplex.' });
    }
    if (Array.isArray(value)) {
      if (value.length > 100_000) {
        return res.status(413).json({ error: 'Eine Sammlung enthält zu viele Einträge.' });
      }
      value.forEach((entry) => stack.push({ value: entry, depth: depth + 1 }));
    } else if (value && typeof value === 'object') {
      Object.values(value).forEach((entry) => {
        stack.push({ value: entry, depth: depth + 1 });
      });
    }
  }
  return next();
}

function registerDataBackupRoutes({
  app,
  appData,
  collectionNames,
  applicationVersion,
  authMiddleware,
  importBodyParser,
  verifyReauthentication,
  dataStore,
  persistData,
}) {
  function requireAdmin(req, res, next) {
    if (!req.user.roles?.includes('Admin')) {
      return res.status(403).json({ error: 'Diese Aktion ist nur für Admins verfügbar.' });
    }
    return next();
  }

  app.post('/api/system/backup/export', authMiddleware, requireAdmin, async (req, res) => {
    if (!await verifyReauthentication(req.user, req.body)) {
      return res.status(403).json({ error: 'Passwort oder 2-FA-Code ist nicht korrekt.' });
    }
    const createdAt = new Date().toISOString();
    rawCollection(appData.exportLogs).push({
      id: `export-backup-${randomUUID()}`,
      exportType: 'complete-json-backup',
      requestedBy: req.user.username,
      createdAt,
    });
    rawCollection(appData.auditLogs).push({
      id: `audit-backup-export-${randomUUID()}`,
      organizationId: req.tenant?.organizationId || DEFAULT_ORGANIZATION_ID,
      unitId: req.tenant?.unitId || DEFAULT_UNIT_ID,
      timestamp: createdAt,
      actor: req.user.username,
      action: 'export',
      entity: 'DataBackup',
      details: { schemaVersion: BACKUP_SCHEMA_VERSION },
    });
    await persistData();
    const backup = backupDocument(appData, collectionNames, applicationVersion);
    const date = createdAt.slice(0, 10);
    res.set('Content-Disposition', `attachment; filename="materialkompass-backup-${date}.json"`);
    return res.json(backup);
  });

  app.post(
    '/api/system/backup/import',
    authMiddleware,
    requireAdmin,
    importBodyParser,
    validateImportBody,
    async (req, res) => {
      if (req.body.confirmation !== 'ALLE DATEN ERSETZEN') {
        return res.status(400).json({ error: 'Die Sicherheitsbestätigung fehlt.' });
      }
      if (!await verifyReauthentication(req.user, req.body)) {
        return res.status(403).json({ error: 'Passwort oder 2-FA-Code ist nicht korrekt.' });
      }
      const data = validatedBackup(req.body.backup, collectionNames);
      data.auditLogs.push(importAuditEntry(data, req.user.username));
      const collections = Object.fromEntries(
        collectionNames.map((name) => [name, data[name]]),
      );

      if (dataStore && typeof dataStore.replaceBackupData !== 'function') {
        return res.status(503).json({
          error: 'Der konfigurierte Datenspeicher unterstützt keine vollständige Wiederherstellung.',
        });
      }
      if (dataStore?.replaceBackupData) {
        await dataStore.replaceBackupData({
          users: data.users,
          roles: data.roles,
          passkeys: data.passkeys,
          collections,
        });
      }

      replaceCollection(appData.users, data.users);
      replaceCollection(appData.roles, data.roles);
      replaceCollection(appData.passkeys, data.passkeys);
      collectionNames.forEach((name) => replaceCollection(appData[name], data[name]));
      if (!dataStore?.replaceBackupData) await persistData();

      return res.json({
        imported: Object.values(data).reduce((sum, values) => sum + values.length, 0),
        collections: Object.keys(data).length,
        reauthenticationRequired: true,
      });
    },
  );
}

module.exports = {
  BACKUP_FORMAT,
  BACKUP_SCHEMA_VERSION,
  backupDocument,
  registerDataBackupRoutes,
  validatedBackup,
};
