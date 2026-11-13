const { synchronizePlatformAdministration, isPlatformAdministration } = require('./platform-administration');
const { randomUUID } = require('node:crypto');
const { identityConflicts } = require('./user-identity');
const { rawCollection, DEFAULT_ORGANIZATION_ID, DEFAULT_UNIT_ID,
  youthUnitsAreLinked,
} = require('./tenancy');
const {
  LOGIN_ACCESS_MODES,
  validateLoginAccessPolicy,
} = require('./login-access-policy');

const BACKUP_FORMAT = 'MaterialKompass Gesamtdatensicherung';
const BACKUP_SCHEMA_VERSION = 3;
const LEGACY_BACKUP_SCHEMA_VERSION = 2;
const MAX_BACKUP_RECORDS = 500_000;
// Authentication, central identities and shared settings are never restored by
// an organisation administrator. New collections must be classified explicitly.
const SCOPED_BACKUP_COLLECTIONS = new Set([
  'departments', 'locations', 'shelves', 'storageLevels', 'stockStructures',
  'materials', 'deletedMaterials', 'materialMovements', 'materialInspections',
  'materialDocuments', 'reservations', 'maintenanceEvents', 'clothingItems',
  'vehicles', 'vehicleReservations', 'vehicleMaintenanceEvents',
  'vehicleLoadAssignments', 'vehicleLoadLists', 'vehicleLoadRequests',
  'containerContents', 'containerPackLists', 'containerChecks', 'clothingInspections',
  'clothingInspectionDocuments',
  'deletedClothingItems', 'issueTransactions', 'defectReports', 'notifications',
  'defectEmailImports', 'procurementRequests', 'procurementOffers',
  'procurementOrders', 'procurementReceipts', 'procurementDocuments',
  'suppliers', 'documents', 'procurementEmailImports', 'exportLogs',
  'stocktakes', 'stocktakeEmailImports', 'categories', 'auditLogs',
]);

function backupScope(appData, req) {
  const { organizationId, unitId } = req.tenant || {};
  const units = rawCollection(appData.organizationUnits);
  const current = units.find((unit) => unit.id === unitId
    && unit.organizationId === organizationId && unit.status === 'active');
  if (!current) throw Object.assign(new Error('Kein aktiver Sicherungsbereich.'), { status: 403 });
  const unitIds = [unitId];
  if (current.unitKind !== 'youth') {
    units.filter((unit) => unit.organizationId === organizationId
      && unit.status === 'active' && unit.unitKind === 'youth'
      && unit.parentId === unitId && unit.baseUnitId === unitId)
      .forEach((unit) => unitIds.push(unit.id));
  }
  return { type: 'units', organizationId, unitIds: unitIds.sort() };
}

function scopeOwns(scope, entry) {
  return entry?.organizationId === scope.organizationId
    && scope.unitIds.includes(entry.unitId);
}

function ownsBackupRecord(scope, name, entry) {
  return scopeOwns(scope, entry) && (name !== 'categories' || entry.scope === 'unit');
}

function scopedBackupData(appData, collectionNames, scope) {
  return Object.fromEntries(['users', 'roles', 'passkeys', ...collectionNames]
    .map((name) => [name, SCOPED_BACKUP_COLLECTIONS.has(name)
      ? structuredClone(rawCollection(appData[name] || []).filter((entry) =>
        ownsBackupRecord(scope, name, entry)))
      : []]));
}

function scopeError() {
  return Object.assign(new Error('Die Sicherung enthält fremde oder unzulässige Daten oder gehört zu einem anderen Organisationsbereich.'), { status: 403 });
}

async function validatedScopedBackup(input, appData, collectionNames, scope, identityProtection) {
  if (input?.format !== BACKUP_FORMAT || input.schemaVersion !== BACKUP_SCHEMA_VERSION
      || input.scope?.type !== 'units' || input.scope.organizationId !== scope.organizationId
      || !Array.isArray(input.scope.unitIds)
      || JSON.stringify([...input.scope.unitIds].sort()) !== JSON.stringify(scope.unitIds)) {
    throw scopeError();
  }
  const names = ['users', 'roles', 'passkeys', ...collectionNames];
  const protectedData = sectionData(input, names);
  function validateRecords(data) {
    let count = 0;
    const foreignIds = new Set();
    const entityIndexes = new Map();
    for (const name of [...SCOPED_BACKUP_COLLECTIONS, 'organizationUnits']) {
      for (const entry of rawCollection(appData[name] || [])) {
        const foreign = name === 'organizationUnits'
          ? entry.organizationId !== scope.organizationId || !scope.unitIds.includes(entry.id)
          : entry.unitId && !ownsBackupRecord(scope, name, entry);
        if (foreign) foreignIds.add(entry.id);
      }
    }
    function checkReferences(value, key = '', allowedEntityId = null) {
      if (Array.isArray(value)) return value.forEach((entry) => checkReferences(entry, key, allowedEntityId));
      if (value && typeof value === 'object') {
        return Object.entries(value).forEach(([field, entry]) => checkReferences(entry, field, allowedEntityId));
      }
      if (key === 'entityId' && value === allowedEntityId) return;
      if (/Ids?$/.test(key) && foreignIds.has(value)) throw scopeError();
    }
    for (const name of names) {
      const entries = data[name];
      count += entries.length;
      if (count > MAX_BACKUP_RECORDS) throw Object.assign(new Error('Zu viele Datensätze.'), { status: 413 });
      if (!SCOPED_BACKUP_COLLECTIONS.has(name) && entries.length) throw scopeError();
      const forbiddenIds = new Set(rawCollection(appData[name] || [])
        .filter((other) => !ownsBackupRecord(scope, name, other)).map((other) => other.id));
      const ids = new Set();
      for (const entry of entries) {
        if (!entry || typeof entry !== 'object' || Array.isArray(entry)
            || typeof entry.id !== 'string' || !entry.id || ids.has(entry.id)
            || !ownsBackupRecord(scope, name, entry)
            || forbiddenIds.has(entry.id)) {
          throw scopeError();
        }
        ids.add(entry.id);
        let allowedEntityId = null;
        if (name === 'defectReports') {
          const targetName = { MaterialItem: 'materials', ClothingItem: 'clothingItems', Vehicle: 'vehicles' }[entry.entityType];
          if (!['materials', 'clothingItems', 'vehicles'].includes(targetName)) throw scopeError();
          if (!entityIndexes.has(targetName)) {
            entityIndexes.set(targetName, new Map([
              ...rawCollection(appData[targetName] || []), ...(data[targetName] || []),
            ].map((value) => [value.id, value])));
          }
          const target = entityIndexes.get(targetName).get(entry.entityId);
          if (target && !scopeOwns(scope, target)) {
            if (!['MaterialItem', 'Vehicle'].includes(entry.entityType)
                || !youthUnitsAreLinked(rawCollection(appData.organizationUnits),
                  scope.organizationId, entry.unitId, target.unitId)
                || target.organizationId !== scope.organizationId) throw scopeError();
            allowedEntityId = target.id;
          }
        }
        checkReferences(entry, '', allowedEntityId);
      }
    }
  }
  validateRecords(protectedData);
  if (!identityProtection) throw Object.assign(new Error('Der Identity-Keyring ist nicht verfügbar.'), { status: 503 });
  let data;
  try { data = identityProtection.unprotectBackupData(protectedData).data; }
  catch (_) { throw Object.assign(new Error('Beschädigte geschützte Sicherungsdaten.'), { status: 400 }); }
  // Recheck ownership after decryption as well; file metadata is not authority.
  validateRecords(data);
  return data;
}
const REQUIRED_BACKUP_SECTIONS = new Set([
  'users', 'roles', 'organizations', 'organizationUnits', 'memberships',
]);

const BACKUP_SECTION_DESCRIPTIONS = Object.freeze({
  users: 'Konten und Anmeldedaten (Identitätsfelder bleiben verschlüsselt)',
  roles: 'Rollen und Berechtigungen',
  passkeys: 'Öffentliche Passkey-Anmeldedaten',
  organizations: 'Organisationen',
  organizationUnits: 'Organisationseinheiten und Hierarchie',
  memberships: 'Organisationszuordnungen der Konten',
});

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

function sectionData(input, requiredNames) {
  if (input.schemaVersion === LEGACY_BACKUP_SCHEMA_VERSION) {
    if (!input.data || typeof input.data !== 'object' || Array.isArray(input.data)) {
      throw Object.assign(new Error('Die Sicherungsdatei enthält keinen gültigen Datenbestand.'), { status: 400 });
    }
    return input.data;
  }
  if (!Array.isArray(input.sections)) {
    throw Object.assign(new Error('Die Sicherungsdatei enthält keine gültigen Sektionen.'), { status: 400 });
  }
  const allowedNames = new Set(requiredNames);
  const sections = new Map();
  for (const section of input.sections) {
    if (!section || typeof section !== 'object' || Array.isArray(section)) {
      throw Object.assign(new Error('Mindestens eine Sicherungssektion ist ungültig.'), { status: 400 });
    }
    const name = String(section.name || '');
    if (!allowedNames.has(name)) {
      throw Object.assign(new Error(`Die Sicherungssektion „${name || '?'}“ ist unbekannt.`), { status: 400 });
    }
    if (sections.has(name)) {
      throw Object.assign(new Error(`Die Sicherungssektion „${name}“ ist doppelt enthalten.`), { status: 400 });
    }
    if (section.enabled === false) {
      if (REQUIRED_BACKUP_SECTIONS.has(name)) {
        throw Object.assign(new Error(`Die Pflichtsektion „${name}“ darf nicht deaktiviert werden.`), { status: 400 });
      }
      sections.set(name, []);
      continue;
    }
    if (!Array.isArray(section.records)) {
      throw Object.assign(new Error(`Die Sicherungssektion „${name}“ enthält keine Datensatzliste.`), { status: 400 });
    }
    sections.set(name, section.records);
  }
  for (const name of REQUIRED_BACKUP_SECTIONS) {
    if (!sections.has(name)) {
      throw Object.assign(new Error(`Die Pflichtsektion „${name}“ fehlt.`), { status: 400 });
    }
  }
  return Object.fromEntries(requiredNames.map((name) => [name, sections.get(name) || []]));
}

async function validatedBackup(input, collectionNames, identityProtection) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) {
    throw Object.assign(new Error('Die Sicherungsdatei ist kein JSON-Objekt.'), { status: 400 });
  }
  if (input.format !== BACKUP_FORMAT
      || ![LEGACY_BACKUP_SCHEMA_VERSION, BACKUP_SCHEMA_VERSION].includes(input.schemaVersion)) {
    throw Object.assign(new Error('Die Datei ist keine unterstützte MaterialKompass-Sicherung.'), { status: 400 });
  }

  const requiredNames = ['users', 'roles', 'passkeys', ...collectionNames];
  const protectedData = sectionData(input, requiredNames);
  let recordCount = 0;
  for (const name of requiredNames) {
    if (!Array.isArray(protectedData[name])) {
      throw Object.assign(new Error(`Die Sammlung „${name}“ fehlt oder ist ungültig.`), { status: 400 });
    }
    recordCount += protectedData[name].length;
  }
  if (recordCount > MAX_BACKUP_RECORDS) {
    throw Object.assign(new Error('Die Sicherung enthält zu viele Datensätze.'), { status: 413 });
  }

  if (!identityProtection) {
    throw Object.assign(new Error('Der Identity-Keyring ist nicht verfügbar.'), { status: 503 });
  }
  let data;
  try {
    data = identityProtection.unprotectBackupData(protectedData).data;
  } catch (_) {
    throw Object.assign(new Error('Die Identitäten der Sicherung sind beschädigt oder nicht geschützt.'), { status: 400 });
  }

  const users = data.users;
  const roles = data.roles;
  const passkeys = data.passkeys;
  for (const user of users) {
    const policy = validateLoginAccessPolicy({
      mode: user.loginAccessMode ?? LOGIN_ACCESS_MODES.ALL_CLIENTS,
      allowedServiceDeviceIds: user.allowedServiceDeviceIds ?? [],
    }, { devices: data.serviceDevices || [] });
    if (policy.error) {
      throw Object.assign(new Error(`Ungültige Anmelderichtlinie in der Sicherung: ${policy.error}`), {
        status: 400,
      });
    }
    user.loginAccessMode = policy.mode;
    user.allowedServiceDeviceIds = policy.allowedServiceDeviceIds;
  }
  if (!uniqueValues(users, 'id') || !uniqueValues(users, 'username') || !uniqueValues(users, 'email')
      || identityConflicts(users).length > 0) {
    throw Object.assign(new Error('Nutzer-IDs, Nutzernamen oder E-Mail-Adressen sind ungültig oder doppelt.'), { status: 400 });
  }
  if (!uniqueValues(roles, 'id') || !uniqueRoleNames(roles)) {
    throw Object.assign(new Error('Rollen-IDs oder Rollennamen sind ungültig oder doppelt.'), { status: 400 });
  }
  const roleNames = new Set(roles.map((role) => role.name));
  const userIds = new Set(users.map((user) => user.id));
  const organizations = data.organizations;
  const units = data.organizationUnits;
  const memberships = data.memberships;
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
      || (!memberships.some((entry) => entry.userId === user.id)
        && user.roles.some((role) => !roleNames.has(role)))
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
  // A full backup declares its membership set, including deliberate absence.
  // Restored central identities must not receive legacy default permissions.
  users.forEach((user) => { user.membershipManaged = true; });
  if (!uniqueValues(passkeys, 'id') || passkeys.some((passkey) => !userIds.has(passkey.userId))) {
    throw Object.assign(new Error('Die Passkey-Daten sind ungültig oder verweisen auf unbekannte Nutzer.'), { status: 400 });
  }

  synchronizePlatformAdministration(data);
  return structuredClone(Object.fromEntries(
    requiredNames.map((name) => [name, data[name]]),
  ));
}

function replaceCollection(target, values) {
  const collection = rawCollection(target);
  collection.splice(0, collection.length, ...values);
}

async function backupDocument(appData, collectionNames, applicationVersion, identityProtection, scope = null) {
  if (!identityProtection) throw new Error('Der Identity-Keyring ist nicht verfügbar.');
  const data = scope ? scopedBackupData(appData, collectionNames, scope) : Object.fromEntries([
    ['users', structuredClone(rawCollection(appData.users))],
    ['roles', structuredClone(rawCollection(appData.roles))],
    ['passkeys', structuredClone(rawCollection(appData.passkeys || []))],
    ...collectionNames.map((name) => [
      name,
      structuredClone(rawCollection(appData[name] || [])),
    ]),
  ]);
  const protectedData = await identityProtection.protectBackupData(data);
  return {
    format: BACKUP_FORMAT,
    schemaVersion: BACKUP_SCHEMA_VERSION,
    applicationVersion,
    createdAt: new Date().toISOString(),
    ...(scope ? { scope } : {}),
    editInstructions: [
      'Diese UTF-8-JSON-Datei kann mit einem Texteditor bearbeitet werden.',
      'Fehlerhafte einzelne Datensätze dürfen aus records entfernt werden.',
      'Optionale Sektionen dürfen durch enabled=false deaktiviert oder vollständig entfernt werden.',
      'Pflichtsektionen für Konten, Rollen und Organisationsstruktur müssen erhalten bleiben.',
      'IDs und Verweise müssen nach einer Bearbeitung konsistent bleiben; der Import prüft dies vor dem Ersetzen.',
    ],
    sections: Object.entries(protectedData).map(([name, records]) => ({
      name,
      description: BACKUP_SECTION_DESCRIPTIONS[name] || `Datenbereich ${name}`,
      enabled: true,
      records,
    })),
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
  identityProtection,
}) {
  function requireAdmin(req, res, next) {
    if (!isPlatformAdministration(req) && !req.user.roles?.includes('Admin')) {
      return res.status(403).json({ error: 'Diese Aktion ist nur für Admins verfügbar.' });
    }
    return next();
  }

  app.post(
    '/api/system/backup/export',
    authMiddleware,
    requireAdmin,
    async (req, res) => {
      if (!await verifyReauthentication(req.user, req.body)) {
        return res.status(403).json({ error: 'Passwort oder 2-FA-Code ist nicht korrekt.' });
      }
      const createdAt = new Date().toISOString();
      const scope = isPlatformAdministration(req) ? null : backupScope(appData, req);
      rawCollection(appData.exportLogs).push({
        id: `export-backup-${randomUUID()}`,
        exportType: 'complete-json-backup',
        requestedBy: req.user.username,
        createdAt,
        organizationId: req.tenant?.organizationId || DEFAULT_ORGANIZATION_ID,
        unitId: req.tenant?.unitId || DEFAULT_UNIT_ID,
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
      const backup = await backupDocument(
        appData,
        collectionNames,
        applicationVersion,
        identityProtection,
        scope,
      );
      const date = createdAt.slice(0, 10);
      res.set('Content-Disposition', `attachment; filename="materialkompass-backup-${date}.json"`);
      return res.type('application/json').send(`${JSON.stringify(backup, null, 2)}\n`);
    },
  );

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
      const scoped = !isPlatformAdministration(req) || req.body.backup?.scope != null;
      const scope = scoped ? backupScope(appData, req) : null;
      const restored = scoped
        ? await validatedScopedBackup(req.body.backup, appData, collectionNames, scope, identityProtection)
        : await validatedBackup(req.body.backup, collectionNames, identityProtection);
      if (scoped) {
        restored.auditLogs.push({
          id: `audit-backup-import-${randomUUID()}`,
          organizationId: scope.organizationId, unitId: req.tenant.unitId,
          timestamp: new Date().toISOString(), actor: req.user.username,
          action: 'import', entity: 'DataBackup', details: { scope },
        });
        const collections = Object.fromEntries(collectionNames
          .filter((name) => SCOPED_BACKUP_COLLECTIONS.has(name))
          .map((name) => [name, restored[name]]));
        if (dataStore && typeof dataStore.replaceScopedBackupData !== 'function') {
          return res.status(503).json({ error: 'Der Datenspeicher unterstützt keine Bereichswiederherstellung.' });
        }
        if (dataStore) await dataStore.replaceScopedBackupData({ scope, collections });
        // Merge only after storage succeeds, against the current live arrays.
        // Never copy or replace central identities or unrelated records.
        for (const [name, values] of Object.entries(collections)) {
          const target = rawCollection(appData[name]);
          const retained = target.filter((entry) => !ownsBackupRecord(scope, name, entry));
          target.splice(0, target.length, ...retained, ...values);
        }
        if (!dataStore) await persistData();
        return res.json({
          imported: Object.values(collections).reduce((sum, values) => sum + values.length, 0),
          collections: Object.keys(collections).length, scope,
          reauthenticationRequired: true,
        });
      }
      const data = restored;
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
      await (dataStore?.pruneIdentityKeys?.(data.users.map((user) => user.id))
        || identityProtection.pruneUsers(data.users.map((user) => user.id)));
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
  LEGACY_BACKUP_SCHEMA_VERSION,
  backupDocument,
  registerDataBackupRoutes,
  validatedBackup,
  backupScope,
  scopedBackupData,
  validatedScopedBackup,
  SCOPED_BACKUP_COLLECTIONS,
};
