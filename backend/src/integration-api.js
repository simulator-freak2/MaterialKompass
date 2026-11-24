const crypto = require('node:crypto');
const { rawCollection, runWithTenant } = require('./tenancy');
const { createRateLimiter } = require('./request-rate-limiter');
const { assessMaterialSafety } = require('./material-safety');

// Read-only partner interface (`/api/v1`) for external planning tools such as
// the Übungsplaner. Access uses per-unit API keys that an administrator creates
// in MaterialKompass; only a SHA-256 digest of the key is stored.
const INTEGRATION_API_VERSION = '1.0.0';
const API_KEY_PREFIX = 'mkapi_';
const API_KEY_SCOPES = Object.freeze({
  'material:lesen': 'Material lesen',
  'fahrzeuge:lesen': 'Fahrzeuge lesen',
});
const MAX_KEYS_PER_UNIT = 20;
const MAX_PAGE_SIZE = 500;
const DEFAULT_PAGE_SIZE = 100;
const DELETED_RETENTION_MS = 90 * 24 * 60 * 60 * 1000;
const LAST_USED_PERSIST_INTERVAL_MS = 5 * 60 * 1000;
const RATE_LIMIT_WINDOW_MS = 60 * 1000;
const RATE_LIMIT_MAX_REQUESTS = 60;
const RESERVATION_TERMINAL = new Set(['Abgelehnt', 'Storniert', 'Abgeschlossen']);
const MAINTENANCE_DONE = new Set(['Abgeschlossen', 'Abgebrochen']);

function text(value, maximum = 255) {
  return String(value ?? '').trim().slice(0, maximum);
}

function hashApiKey(value) {
  return crypto.createHash('sha256').update(String(value)).digest('hex');
}

function generateApiKey() {
  return `${API_KEY_PREFIX}${crypto.randomBytes(32).toString('base64url')}`;
}

function publicApiKey(entry) {
  const { keyHash: _hash, ...safe } = entry;
  return { ...safe, active: !entry.revokedAt };
}

function validScopes(value) {
  if (!Array.isArray(value)) return null;
  const scopes = [...new Set(value.map((entry) => String(entry)))];
  if (!scopes.length || scopes.some((entry) => !Object.hasOwn(API_KEY_SCOPES, entry))) return null;
  return scopes;
}

// RFC 9457 problem details with a German message, as expected by API clients.
function problem(res, status, title, detail, extra = {}) {
  return res.status(status).type('application/problem+json').json({
    type: 'about:blank', title, status, ...(detail ? { detail } : {}), ...extra,
  });
}

function timestamp(value) {
  const parsed = Date.parse(value || '');
  return Number.isFinite(parsed) ? parsed : 0;
}

function iso(value) {
  const parsed = timestamp(value);
  return parsed ? new Date(parsed).toISOString() : null;
}

function encodeCursor(offset) {
  return Buffer.from(JSON.stringify({ o: offset })).toString('base64url');
}

function decodeCursor(value) {
  if (value === undefined || value === '') return 0;
  try {
    const offset = JSON.parse(Buffer.from(String(value), 'base64url').toString('utf8')).o;
    return Number.isInteger(offset) && offset >= 0 ? offset : null;
  } catch (_) {
    return null;
  }
}

function overlaps(leftStart, leftEnd, rightStart, rightEnd) {
  return timestamp(leftStart) < timestamp(rightEnd) && timestamp(leftEnd) > timestamp(rightStart);
}

function registerIntegrationApi({
  app,
  apiKeys,
  organizations,
  organizationUnits,
  materials,
  deletedMaterials,
  categories,
  locations,
  stockStructures,
  vehicles,
  vehicleReservations,
  vehicleMaintenanceEvents,
  vehicleLoadAssignments,
  defectReports,
  authMiddleware,
  requirePermission,
  logEvent,
  persistData = async () => {},
}) {
  const all = (collection) => rawCollection(collection);
  const nowIso = () => new Date().toISOString();

  function keysOfUnit(tenant) {
    return all(apiKeys).filter((entry) => entry.organizationId === tenant.organizationId
      && entry.unitId === tenant.unitId);
  }

  function findOwnKey(req) {
    return keysOfUnit(req.tenant).find((entry) => entry.id === req.params.id) || null;
  }

  // ----- Administration in MaterialKompass ---------------------------------

  app.get('/api/integration-keys', authMiddleware, requirePermission('users.write'), (req, res) => {
    res.json({
      scopes: Object.entries(API_KEY_SCOPES).map(([id, label]) => ({ id, label })),
      keys: keysOfUnit(req.tenant)
        .sort((left, right) => String(right.createdAt).localeCompare(String(left.createdAt)))
        .map(publicApiKey),
    });
  });

  app.post('/api/integration-keys', authMiddleware, requirePermission('users.write'), (req, res) => {
    const name = text(req.body?.name, 120);
    const scopes = validScopes(req.body?.scopes);
    if (!name) return res.status(400).json({ error: 'Bitte eine Bezeichnung für den API-Schlüssel angeben.' });
    if (!scopes) return res.status(400).json({ error: 'Bitte mindestens eine gültige Berechtigung auswählen.' });
    if (keysOfUnit(req.tenant).filter((entry) => !entry.revokedAt).length >= MAX_KEYS_PER_UNIT) {
      return res.status(409).json({ error: `Je Ebene sind höchstens ${MAX_KEYS_PER_UNIT} aktive API-Schlüssel möglich.` });
    }
    const apiKey = generateApiKey();
    const createdAt = nowIso();
    const entry = {
      id: `api-key-${crypto.randomUUID()}`,
      organizationId: req.tenant.organizationId,
      unitId: req.tenant.unitId,
      name,
      scopes,
      keyHash: hashApiKey(apiKey),
      keyHint: `${apiKey.slice(0, API_KEY_PREFIX.length + 4)}…${apiKey.slice(-4)}`,
      createdAt,
      createdBy: req.user.username,
      updatedAt: createdAt,
      rotatedAt: null,
      revokedAt: null,
      revokedBy: null,
      lastUsedAt: null,
    };
    all(apiKeys).push(entry);
    logEvent('create', 'IntegrationApiKey', { id: entry.id, name, scopes }, req.user.username);
    // The plain key is returned exactly once and never stored.
    return res.status(201).json({ ...publicApiKey(entry), apiKey });
  });

  app.put('/api/integration-keys/:id', authMiddleware, requirePermission('users.write'), (req, res) => {
    const entry = findOwnKey(req);
    if (!entry) return res.status(404).json({ error: 'API-Schlüssel nicht gefunden.' });
    const name = req.body?.name === undefined ? entry.name : text(req.body.name, 120);
    const scopes = req.body?.scopes === undefined ? entry.scopes : validScopes(req.body.scopes);
    if (!name) return res.status(400).json({ error: 'Bitte eine Bezeichnung für den API-Schlüssel angeben.' });
    if (!scopes) return res.status(400).json({ error: 'Bitte mindestens eine gültige Berechtigung auswählen.' });
    Object.assign(entry, { name, scopes, updatedAt: nowIso() });
    logEvent('update', 'IntegrationApiKey', { id: entry.id, name, scopes }, req.user.username);
    return res.json(publicApiKey(entry));
  });

  app.post('/api/integration-keys/:id/regenerate', authMiddleware, requirePermission('users.write'), (req, res) => {
    const entry = findOwnKey(req);
    if (!entry) return res.status(404).json({ error: 'API-Schlüssel nicht gefunden.' });
    const apiKey = generateApiKey();
    const at = nowIso();
    Object.assign(entry, {
      keyHash: hashApiKey(apiKey),
      keyHint: `${apiKey.slice(0, API_KEY_PREFIX.length + 4)}…${apiKey.slice(-4)}`,
      rotatedAt: at, updatedAt: at, revokedAt: null, revokedBy: null, lastUsedAt: null,
    });
    logEvent('regenerate', 'IntegrationApiKey', { id: entry.id }, req.user.username);
    return res.json({ ...publicApiKey(entry), apiKey });
  });

  app.post('/api/integration-keys/:id/revoke', authMiddleware, requirePermission('users.write'), (req, res) => {
    const entry = findOwnKey(req);
    if (!entry) return res.status(404).json({ error: 'API-Schlüssel nicht gefunden.' });
    if (!entry.revokedAt) {
      entry.revokedAt = nowIso();
      entry.revokedBy = req.user.username;
      entry.updatedAt = entry.revokedAt;
      logEvent('revoke', 'IntegrationApiKey', { id: entry.id }, req.user.username);
    }
    return res.json(publicApiKey(entry));
  });

  app.delete('/api/integration-keys/:id', authMiddleware, requirePermission('users.write'), (req, res) => {
    const entry = findOwnKey(req);
    if (!entry) return res.status(404).json({ error: 'API-Schlüssel nicht gefunden.' });
    const collection = all(apiKeys);
    collection.splice(collection.indexOf(entry), 1);
    logEvent('delete', 'IntegrationApiKey', { id: entry.id }, req.user.username);
    return res.status(204).end();
  });

  // ----- Partner interface ---------------------------------------------------

  const rateLimit = createRateLimiter({
    windowMs: RATE_LIMIT_WINDOW_MS,
    maxRequests: RATE_LIMIT_MAX_REQUESTS,
    keyFor: (req) => req.integrationKey?.id || req.ip,
    exposePolicyHeaders: true,
    errorMessage: 'Zu viele Anfragen mit diesem API-Schlüssel. Bitte später erneut versuchen.',
  });

  function activeTenantFor(entry) {
    const organization = organizations.find((candidate) => candidate.id === entry.organizationId
      && candidate.status === 'active');
    const unit = organizationUnits.find((candidate) => candidate.id === entry.unitId
      && candidate.organizationId === entry.organizationId && candidate.status === 'active');
    if (!organization || !unit) return null;
    return {
      organization,
      unit,
      context: {
        organizationId: entry.organizationId,
        unitId: entry.unitId,
        allowedUnitIds: new Set([entry.unitId]),
        storageUnitIds: new Set([entry.unitId]),
        roles: [], permissions: [], departmentIds: [],
        membershipId: null, organizationAdmin: false, system: false,
      },
    };
  }

  function apiKeyAuth(req, res, next) {
    const header = String(req.headers.authorization || '');
    const presented = header.startsWith('Bearer ') ? header.slice(7).trim() : '';
    if (!presented.startsWith(API_KEY_PREFIX)) {
      res.set('WWW-Authenticate', 'Bearer realm="materialkompass-api"');
      return problem(res, 401, 'Nicht angemeldet', 'Bitte einen gültigen API-Schlüssel im Header „Authorization: Bearer …“ senden.');
    }
    const digest = hashApiKey(presented);
    const entry = all(apiKeys).find((candidate) => candidate.keyHash === digest) || null;
    if (!entry || entry.revokedAt) {
      res.set('WWW-Authenticate', 'Bearer realm="materialkompass-api", error="invalid_token"');
      return problem(res, 401, 'Nicht angemeldet', 'Der API-Schlüssel ist ungültig oder wurde gesperrt.');
    }
    const tenant = activeTenantFor(entry);
    if (!tenant) return problem(res, 403, 'Kein Zugriff', 'Die Organisation des API-Schlüssels ist nicht aktiv.');
    req.integrationKey = entry;
    req.integrationTenant = tenant;
    const now = Date.now();
    // Last use is informational; persisting it at most every few minutes keeps
    // frequent synchronisation from turning every read into a database write.
    if (now - timestamp(entry.lastUsedAt) >= LAST_USED_PERSIST_INTERVAL_MS) {
      entry.lastUsedAt = new Date(now).toISOString();
      persistData().catch((error) => console.error('Letzte Nutzung des API-Schlüssels nicht gespeichert:', error.message));
    }
    return runWithTenant(tenant.context, next);
  }

  function requireScope(scope) {
    return (req, res, next) => {
      if (req.integrationKey.scopes?.includes(scope)) return next();
      return problem(res, 403, 'Keine Berechtigung', `Der API-Schlüssel besitzt nicht die Berechtigung „${scope}“.`);
    };
  }

  // Validates the shared list parameters (C1, C3) once for every list route.
  function listOptions(req, res) {
    const since = req.query.geaendert_seit;
    let sinceMs = null;
    if (since !== undefined) {
      sinceMs = Date.parse(String(since));
      if (!Number.isFinite(sinceMs)) {
        problem(res, 400, 'Ungültige Anfrage', '„geaendert_seit“ muss ein Zeitpunkt nach ISO 8601 sein.');
        return null;
      }
    }
    const limit = req.query.limit === undefined ? DEFAULT_PAGE_SIZE : Number(req.query.limit);
    if (!Number.isInteger(limit) || limit < 1 || limit > MAX_PAGE_SIZE) {
      problem(res, 400, 'Ungültige Anfrage', `„limit“ muss zwischen 1 und ${MAX_PAGE_SIZE} liegen.`);
      return null;
    }
    const offset = decodeCursor(req.query.cursor);
    if (offset === null) {
      problem(res, 400, 'Ungültige Anfrage', 'Der Cursor ist ungültig.');
      return null;
    }
    return { sinceMs, limit, offset };
  }

  function sendList(res, records, options, serverTime) {
    const filtered = records
      .filter((entry) => options.sinceMs === null || timestamp(entry.aktualisiert_am) > options.sinceMs)
      .sort((left, right) => String(left.id).localeCompare(String(right.id)));
    const page = filtered.slice(options.offset, options.offset + options.limit);
    const nextOffset = options.offset + page.length;
    return res.json({
      daten: page,
      naechster_cursor: nextOffset < filtered.length ? encodeCursor(nextOffset) : null,
      server_zeit: serverTime,
    });
  }

  function recentlyDeleted(value, referenceTime) {
    const deletedAt = timestamp(value);
    return deletedAt > 0 && referenceTime - deletedAt <= DELETED_RETENTION_MS;
  }

  // --- Standorte ---

  function unitLocations(tenant) {
    return all(locations).filter((entry) => entry.organizationId === tenant.organizationId
      && entry.unitId === tenant.unitId && !entry.vehicleId);
  }

  function publicLocation(entry) {
    return {
      id: entry.id,
      bezeichnung: entry.name,
      kurzzeichen: entry.code || null,
      aktualisiert_am: iso(entry.updatedAt || entry.createdAt) || iso(0),
      geloescht: false,
    };
  }

  // --- Fahrzeuge ---

  function visibleVehicles(tenant) {
    return all(vehicles).filter((entry) => entry.organizationId === tenant.organizationId
      && !entry.purgedAt
      && (entry.unitId === tenant.unitId
        || entry.viewAllowedUnitIds?.includes(tenant.unitId)
        || entry.reservationAllowedUnitIds?.includes(tenant.unitId)));
  }

  function vehicleName(vehicle) {
    return vehicle.radioCallName || vehicle.registrationNumber
      || [vehicle.manufacturer, vehicle.model].filter(Boolean).join(' ') || 'Fahrzeug';
  }

  function vehicleKind(vehicle) {
    if (vehicle.vehicleKind === 'Boot' || vehicle.type === 'Boot') return 'boot';
    if (vehicle.vehicleKind === 'Anhänger' || vehicle.type === 'Anhänger') return 'anhaenger';
    return 'fahrzeug';
  }

  function openVehicleDefects(vehicle) {
    return all(defectReports).filter((entry) => entry.organizationId === vehicle.organizationId
      && entry.entityType === 'Vehicle' && entry.entityId === vehicle.id
      && !entry.archivedAt && entry.status !== 'Geprüft/Geschlossen');
  }

  function vehicleStatus(vehicle) {
    if (vehicle.archivedAt || vehicle.status === 'Außer Dienst') {
      return { status: 'ausser_dienst', hinweis: 'Außer Dienst' };
    }
    if (vehicle.status === 'In Wartung') return { status: 'werkstatt', hinweis: 'In Wartung' };
    const defects = openVehicleDefects(vehicle);
    const critical = defects.find((entry) => entry.priority === 'Kritisch'
      || entry.operationalSafety === 'Nicht einsatzfähig');
    if (vehicle.status === 'Defekt' || critical) {
      return { status: 'ausser_dienst', hinweis: critical?.title ? `Mangel: ${critical.title}` : 'Defekt' };
    }
    if (defects.length) {
      return { status: 'bedingt_einsatzbereit', hinweis: `Offener Mangel: ${defects[0].title || defects[0].defectNumber || ''}`.trim() };
    }
    return { status: 'einsatzbereit', hinweis: null };
  }

  function publicVehicle(vehicle, referenceTime) {
    const state = vehicleStatus(vehicle);
    const deleted = Boolean(vehicle.archivedAt);
    return {
      id: vehicle.id,
      bezeichnung: vehicleName(vehicle),
      typ: vehicle.type || vehicle.vehicleKind || 'Fahrzeug',
      art: vehicleKind(vehicle),
      funkrufname: vehicle.radioCallName || null,
      kennzeichen: vehicle.registrationNumber || null,
      standort_id: vehicle.parkingLocationId || null,
      sitzplaetze: Number.isInteger(vehicle.seats) ? vehicle.seats : null,
      status: state.status,
      status_hinweis: state.hinweis,
      aktualisiert_am: iso(vehicle.archivedAt || vehicle.updatedAt || vehicle.createdAt) || iso(0),
      geloescht: deleted,
      ...(deleted && !recentlyDeleted(vehicle.archivedAt, referenceTime) ? { _expired: true } : {}),
    };
  }

  function vehicleRecords(tenant, referenceTime) {
    return visibleVehicles(tenant).map((entry) => publicVehicle(entry, referenceTime))
      .filter((entry) => !entry._expired);
  }

  function vehicleOccupancy(vehicle, from, to) {
    const reservations = all(vehicleReservations).filter((entry) => entry.vehicleId === vehicle.id
      && !RESERVATION_TERMINAL.has(entry.status) && overlaps(from, to, entry.startAt, entry.endAt))
      .map((entry) => ({
        von: iso(entry.startAt), bis: iso(entry.endAt), grund: 'Reservierung', zweck: entry.title || null,
      }));
    const maintenance = all(vehicleMaintenanceEvents).filter((entry) => entry.vehicleId === vehicle.id
      && !MAINTENANCE_DONE.has(entry.status) && entry.startAt && entry.endAt
      && overlaps(from, to, entry.startAt, entry.endAt))
      .map((entry) => ({
        von: iso(entry.startAt), bis: iso(entry.endAt), grund: 'Wartung', zweck: entry.type || null,
      }));
    return [...reservations, ...maintenance]
      .sort((left, right) => String(left.von).localeCompare(String(right.von)));
  }

  // --- Material ---

  function materialStatus(item) {
    if (item.archived || ['Ausgesondert', 'Verloren'].includes(item.status)) return 'ausgesondert';
    if (item.status === 'Defekt') return 'defekt';
    if (item.status === 'In Reparatur') return 'reparatur';
    const today = new Date().toISOString().slice(0, 10);
    if (item.status === 'In Prüfung' || (item.nextInspectionDate && item.nextInspectionDate < today)
      || assessMaterialSafety(item).blocked) return 'pruefung_faellig';
    return 'einsatzbereit';
  }

  function categoryName(id) {
    if (!id) return null;
    return all(categories).find((entry) => entry.id === id)?.name || null;
  }

  function materialPlacement(item, { locationsById, stockById, loadsByMaterial }) {
    const location = locationsById.get(item.locationId);
    if (location?.vehicleId) {
      return { vehicleId: location.vehicleId, locationId: null, place: location.name };
    }
    const loads = loadsByMaterial.get(item.id) || [];
    const fullyLoaded = loads.length === 1 && Number(loads[0].quantity) >= Number(item.quantity || 1);
    if (fullyLoaded) return { vehicleId: loads[0].vehicleId, locationId: null, place: loads[0].position || null };
    const stock = stockById.get(item.stockStructureId);
    const place = [location?.path || location?.name, stock?.path || stock?.name].filter(Boolean).join(', ');
    return { vehicleId: null, locationId: location?.id || null, place: place || null };
  }

  function publicMaterial(item, lookups) {
    const placement = materialPlacement(item, lookups);
    return {
      id: item.id,
      bezeichnung: item.name,
      kategorie: categoryName(item.categoryCode),
      unterkategorie: categoryName(item.subcategoryCode),
      inventarnummer: item.inventoryNumber || null,
      menge: Number.isFinite(Number(item.quantity)) ? Number(item.quantity) : 1,
      einheit: item.unit || null,
      verlastet_auf_fahrzeug_id: placement.vehicleId,
      standort_id: placement.locationId,
      lagerort: placement.place,
      status: materialStatus(item),
      naechste_pruefung: item.nextInspectionDate || null,
      aktualisiert_am: iso(item.archivedAt || item.updatedAt || item.createdAt) || iso(0),
      geloescht: Boolean(item.archived),
    };
  }

  function materialRecords(tenant, referenceTime) {
    const ownLocations = all(locations).filter((entry) => entry.organizationId === tenant.organizationId);
    const lookups = {
      locationsById: new Map(ownLocations.map((entry) => [entry.id, entry])),
      stockById: new Map(all(stockStructures).filter((entry) => entry.organizationId === tenant.organizationId)
        .map((entry) => [entry.id, entry])),
      loadsByMaterial: new Map(),
    };
    for (const load of all(vehicleLoadAssignments)) {
      if (load.organizationId !== tenant.organizationId) continue;
      if (!lookups.loadsByMaterial.has(load.materialId)) lookups.loadsByMaterial.set(load.materialId, []);
      lookups.loadsByMaterial.get(load.materialId).push(load);
    }
    const inUnit = (entry) => entry.organizationId === tenant.organizationId && entry.unitId === tenant.unitId;
    const current = all(materials).filter(inUnit)
      // Archived items count as removed for partners; keep them visible for 90 days.
      .filter((entry) => !entry.archived || recentlyDeleted(entry.archivedAt || entry.updatedAt, referenceTime))
      .map((entry) => publicMaterial(entry, lookups));
    const removed = all(deletedMaterials).filter(inUnit)
      .filter((entry) => recentlyDeleted(entry.deletedAt, referenceTime))
      .map((entry) => ({
        ...publicMaterial({ ...entry, archived: true }, lookups),
        status: 'ausgesondert',
        aktualisiert_am: iso(entry.deletedAt),
        geloescht: true,
      }));
    return [...current, ...removed];
  }

  // --- Routes ---

  const v1 = (path) => `/api/v1${path}`;
  const guarded = [apiKeyAuth, rateLimit];

  app.get(v1('/status'), ...guarded, (req, res) => {
    const { organization, unit } = req.integrationTenant;
    res.json({
      version: INTEGRATION_API_VERSION,
      organisation: { id: organization.id, name: organization.name },
      ebene: { id: unit.id, name: unit.name },
      berechtigungen: req.integrationKey.scopes,
      server_zeit: nowIso(),
    });
  });

  app.get(v1('/standorte'), ...guarded, requireScope('material:lesen'), (req, res) => {
    const options = listOptions(req, res);
    if (!options) return undefined;
    const serverTime = nowIso();
    return sendList(res, unitLocations(req.integrationTenant.context).map(publicLocation), options, serverTime);
  });

  app.get(v1('/fahrzeuge'), ...guarded, requireScope('fahrzeuge:lesen'), (req, res) => {
    const options = listOptions(req, res);
    if (!options) return undefined;
    const serverTime = nowIso();
    return sendList(res, vehicleRecords(req.integrationTenant.context, Date.now()), options, serverTime);
  });

  app.get(v1('/fahrzeuge/:id'), ...guarded, requireScope('fahrzeuge:lesen'), (req, res) => {
    const vehicle = visibleVehicles(req.integrationTenant.context).find((entry) => entry.id === req.params.id);
    if (!vehicle) return problem(res, 404, 'Nicht gefunden', 'Das Fahrzeug wurde nicht gefunden.');
    const { _expired, ...record } = publicVehicle(vehicle, Date.now());
    return res.json(record);
  });

  app.get(v1('/fahrzeuge/:id/verfuegbarkeit'), ...guarded, requireScope('fahrzeuge:lesen'), (req, res) => {
    const vehicle = visibleVehicles(req.integrationTenant.context).find((entry) => entry.id === req.params.id);
    if (!vehicle) return problem(res, 404, 'Nicht gefunden', 'Das Fahrzeug wurde nicht gefunden.');
    const from = Date.parse(String(req.query.von || ''));
    const to = Date.parse(String(req.query.bis || ''));
    if (!Number.isFinite(from) || !Number.isFinite(to) || to <= from) {
      return problem(res, 400, 'Ungültige Anfrage', '„von“ und „bis“ müssen Zeitpunkte nach ISO 8601 sein; „bis“ liegt nach „von“.');
    }
    const belegungen = vehicleOccupancy(vehicle, new Date(from).toISOString(), new Date(to).toISOString());
    const state = vehicleStatus(vehicle);
    return res.json({
      fahrzeug_id: vehicle.id,
      verfuegbar: belegungen.length === 0 && ['einsatzbereit', 'bedingt_einsatzbereit'].includes(state.status),
      status: state.status,
      belegungen,
    });
  });

  app.get(v1('/material'), ...guarded, requireScope('material:lesen'), (req, res) => {
    const options = listOptions(req, res);
    if (!options) return undefined;
    const serverTime = nowIso();
    const filters = {
      standort: text(req.query.standort_id, 120),
      fahrzeug: text(req.query.fahrzeug_id, 120),
      kategorie: text(req.query.kategorie, 120).toLowerCase(),
      suche: text(req.query.suche, 120).toLowerCase(),
    };
    const records = materialRecords(req.integrationTenant.context, Date.now()).filter((entry) =>
      (!filters.standort || entry.standort_id === filters.standort)
      && (!filters.fahrzeug || entry.verlastet_auf_fahrzeug_id === filters.fahrzeug)
      && (!filters.kategorie || [entry.kategorie, entry.unterkategorie]
        .some((value) => String(value || '').toLowerCase() === filters.kategorie))
      && (!filters.suche || [entry.bezeichnung, entry.inventarnummer, entry.kategorie, entry.unterkategorie]
        .some((value) => String(value || '').toLowerCase().includes(filters.suche))));
    return sendList(res, records, options, serverTime);
  });

  // Unknown paths below /api/v1 answer with problem details instead of the
  // generic 404 so partner clients get a consistent error format.
  app.use('/api/v1', (req, res) => problem(res, 404, 'Nicht gefunden', 'Dieser Endpunkt existiert nicht.'));
}

module.exports = {
  API_KEY_PREFIX,
  API_KEY_SCOPES,
  INTEGRATION_API_VERSION,
  registerIntegrationApi,
};
