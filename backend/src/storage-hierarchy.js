const { randomUUID } = require('node:crypto');

class StorageValidationError extends Error {}

const CODE_PATTERN = /^[A-Z0-9_-]{1,32}$/;
const BULK_LIMITS = Object.freeze({
  shelves: 20,
  levelsPerShelf: 50,
  positionsPerLevel: 200,
  totalPositions: 1000,
});

function requiredText(value, label, maxLength = 255) {
  const result = String(value ?? '').trim();
  if (!result) throw new StorageValidationError(`${label} ist ein Pflichtfeld.`);
  if (result.length > maxLength) {
    throw new StorageValidationError(`${label} darf höchstens ${maxLength} Zeichen enthalten.`);
  }
  return result;
}

function storageCode(value, label = 'Kürzel') {
  const result = requiredText(value, label, 32).toUpperCase();
  if (!CODE_PATTERN.test(result)) {
    throw new StorageValidationError(
      `${label} darf nur Buchstaben, Zahlen, _ und - enthalten.`,
    );
  }
  return result;
}

function buildingInput(body, existing = {}) {
  const requested = body.parkingSpaces ?? existing.parkingSpaces ?? [];
  if (!Array.isArray(requested) || requested.length > 100) {
    throw new StorageValidationError('Bitte höchstens 100 Fahrzeugstellplätze angeben.');
  }
  const parkingSpaces = requested.map(entry => {
    if (!entry || typeof entry !== 'object') throw new StorageValidationError('Ungültiger Fahrzeugstellplatz.');
    if (entry.id && !(existing.parkingSpaces || []).some(space => space.id === entry.id)) {
      throw new StorageValidationError('Unbekannter Fahrzeugstellplatz.');
    }
    return { id: entry.id || randomUUID(), name: requiredText(entry.name, 'Stellplatz', 120) };
  });
  if (new Set(parkingSpaces.map(entry => entry.id)).size !== parkingSpaces.length
    || new Set(parkingSpaces.map(entry => entry.name.toLowerCase())).size !== parkingSpaces.length) {
    throw new StorageValidationError('Fahrzeugstellplätze müssen innerhalb eines Gebäudes eindeutig sein.');
  }
  return {
    parkingSpaces,
    name: requiredText(body.name ?? existing.name, 'Name'),
    code: storageCode(body.code ?? existing.code),
    street: requiredText(body.street ?? existing.street, 'Straße'),
    houseNumber: requiredText(
      body.houseNumber ?? existing.houseNumber,
      'Hausnummer',
      64,
    ),
    postalCode: requiredText(
      body.postalCode ?? existing.postalCode,
      'Postleitzahl',
      32,
    ),
    city: requiredText(body.city ?? existing.city, 'Ort'),
    country: requiredText(body.country ?? existing.country, 'Land', 128),
  };
}

function hierarchyNodeInput(body, existing = {}) {
  return {
    name: requiredText(body.name ?? existing.name, 'Bezeichnung'),
    code: storageCode(body.code ?? body.section ?? existing.code ?? existing.section),
  };
}

function nextLegacyId(prefix, sourceId, entries) {
  const safeSource = String(sourceId || 'bestand').replace(/[^A-Za-z0-9_-]/g, '-');
  const base = `${prefix}-legacy-${safeSource}`.slice(0, 64);
  if (!entries.some((entry) => entry.id === base)) return base;
  let suffix = 2;
  while (entries.some((entry) => entry.id === `${base}-${suffix}`)) suffix += 1;
  return `${base}-${suffix}`;
}

function nextScopedCode(prefix, entries, parentKey, parentId) {
  const existing = new Set(entries
    .filter((entry) => entry[parentKey] === parentId)
    .map((entry) => String(entry.code || '').toUpperCase()));
  let number = 1;
  while (existing.has(`${prefix}${number}`)) number += 1;
  return `${prefix}${number}`;
}

/**
 * Upgrades the former building -> flat storage-place model in memory.
 * Position IDs are retained because inventory and stocktakes reference them.
 * The operation is idempotent and the persistence coordinator stores the
 * upgraded collections with the next successful mutation.
 */
function ensureStorageHierarchy(data) {
  const locations = (data.locations ||= []);
  const shelves = (data.shelves ||= []);
  const storageLevels = (data.storageLevels ||= []);
  const positions = (data.stockStructures ||= []);

  for (const location of locations) {
    location.street ??= '';
    location.houseNumber ??= '';
    location.postalCode ??= '';
    location.city ??= '';
    location.country ??= '';
  }

  for (const position of positions) {
    if (position.levelId
        && storageLevels.some((level) => level.id === position.levelId)) {
      continue;
    }
    const shelfId = nextLegacyId('shelf', position.id, shelves);
    const levelId = nextLegacyId('level', position.id, storageLevels);
    const shelfCode = nextScopedCode('R', shelves, 'locationId', position.locationId);
    shelves.push({
      id: shelfId,
      locationId: position.locationId,
      name: requiredText(position.name || 'Regal', 'Bezeichnung'),
      code: shelfCode,
      organizationId: position.organizationId,
      unitId: position.unitId,
    });
    storageLevels.push({
      id: levelId,
      locationId: position.locationId,
      shelfId,
      name: 'Ebene 1',
      code: 'E1',
      organizationId: position.organizationId,
      unitId: position.unitId,
    });
    const legacyCode = String(position.code || position.section || '').trim();
    position.shelfId = shelfId;
    position.levelId = levelId;
    position.code = CODE_PATTERN.test(legacyCode.toUpperCase())
      ? legacyCode.toUpperCase()
      : 'P1';
    position.section = position.code;
    position.name = `Lagerplatz ${position.code}`;
  }

  refreshStoragePaths(data);
  return { locations, shelves, storageLevels, positions };
}

/** Rebuilds denormalized parent IDs and display paths after moves or renames. */
function refreshStoragePaths(data) {
  const locations = data.locations || [];
  const shelves = data.shelves || [];
  const storageLevels = data.storageLevels || [];
  const positions = data.stockStructures || [];
  const locationById = new Map(locations.map((entry) => [entry.id, entry]));
  const shelfById = new Map(shelves.map((entry) => [entry.id, entry]));
  const levelById = new Map(storageLevels.map((entry) => [entry.id, entry]));

  for (const location of locations) {
    location.path = location.name;
    location.fullCode = location.code;
  }
  for (const shelf of shelves) {
    const location = locationById.get(shelf.locationId);
    shelf.path = [location?.name, shelf.name].filter(Boolean).join(' / ');
    shelf.fullCode = [location?.code, shelf.code].filter(Boolean).join('-');
  }
  for (const level of storageLevels) {
    const shelf = shelfById.get(level.shelfId);
    if (shelf) level.locationId = shelf.locationId;
    const location = locationById.get(level.locationId);
    level.path = [location?.name, shelf?.name, level.name]
      .filter(Boolean).join(' / ');
    level.fullCode = [location?.code, shelf?.code, level.code]
      .filter(Boolean).join('-');
  }
  for (const position of positions) {
    const level = levelById.get(position.levelId);
    const shelf = shelfById.get(level?.shelfId || position.shelfId);
    if (level) position.shelfId = level.shelfId;
    if (shelf) position.locationId = shelf.locationId;
    const location = locationById.get(position.locationId);
    position.section = position.code || position.section;
    position.path = [location?.name, shelf?.name, level?.name, position.name]
      .filter(Boolean).join(' / ');
    position.fullCode = [location?.code, shelf?.code, level?.code,
      position.code || position.section].filter(Boolean).join('-');
  }
}

function duplicateInScope(entries, candidate, {
  parentKey,
  parentId,
  excludingId,
}) {
  const name = candidate.name.toLowerCase();
  const code = candidate.code.toLowerCase();
  return entries.some((entry) => entry.id !== excludingId
    && entry[parentKey] === parentId
    && (String(entry.name).toLowerCase() === name
      || String(entry.code || entry.section).toLowerCase() === code));
}

function positiveInteger(value, label, maximum) {
  const number = Number(value);
  if (!Number.isInteger(number) || number < 1 || number > maximum) {
    throw new StorageValidationError(
      `${label} muss zwischen 1 und ${maximum} liegen.`,
    );
  }
  return number;
}

function bulkInput(body) {
  const shelfCount = positiveInteger(body.shelfCount, 'Anzahl der Regale', BULK_LIMITS.shelves);
  const levelsPerShelf = positiveInteger(
    body.levelsPerShelf,
    'Ebenen je Regal',
    BULK_LIMITS.levelsPerShelf,
  );
  const positionsPerLevel = positiveInteger(
    body.positionsPerLevel,
    'Lagerplätze je Ebene',
    BULK_LIMITS.positionsPerLevel,
  );
  if (shelfCount * levelsPerShelf * positionsPerLevel > BULK_LIMITS.totalPositions) {
    throw new StorageValidationError(
      `Pro Vorgang können höchstens ${BULK_LIMITS.totalPositions} Lagerplätze erzeugt werden.`,
    );
  }
  const prefix = (value, fallback, label) => {
    const result = storageCode(value ?? fallback, label);
    if (result.length > 16) {
      throw new StorageValidationError(`${label} darf höchstens 16 Zeichen enthalten.`);
    }
    return result;
  };
  return {
    shelfCount,
    levelsPerShelf,
    positionsPerLevel,
    startNumber: positiveInteger(body.startNumber ?? 1, 'Startnummer', 999999),
    shelfPrefix: prefix(body.shelfPrefix, 'R', 'Regalpräfix'),
    levelPrefix: prefix(body.levelPrefix, 'E', 'Ebenenpräfix'),
    positionPrefix: prefix(body.positionPrefix, 'P', 'Lagerplatzpräfix'),
  };
}

const STORAGE_ID_COLLECTIONS = Object.freeze([
  ['locations', 'loc', /^(?:[a-z]+)?locationIds?$/i],
  ['shelves', 'shelf', /^(?:[a-z]+)?shelfIds?$/i],
  ['storageLevels', 'level', /^(?:[a-z]+)?levelIds?$/i],
  ['stockStructures', 'stock', /^(?:[a-z]+)?(?:stockStructure|storagePosition|position)Ids?$/i],
]);

function nextNumericId(prefix, entries) {
  const pattern = new RegExp(`^${prefix}-(\\d+)$`);
  const highest = entries.reduce((max, entry) => {
    const match = String(entry?.id || '').match(pattern);
    return match ? Math.max(max, Number(match[1])) : max;
  }, 0);
  return `${prefix}-${highest + 1}`;
}

function replaceReferences(value, keyPattern, oldId, newId, key = '') {
  if (Array.isArray(value)) {
    if (keyPattern.test(key)) {
      return value.map((entry) => (entry === oldId ? newId : entry));
    }
    return value.map((entry) => replaceReferences(entry, keyPattern, oldId, newId));
  }
  if (value && typeof value === 'object') {
    for (const [field, entry] of Object.entries(value)) {
      if (field === 'id') continue;
      if (entry === oldId && keyPattern.test(field)) value[field] = newId;
      else if (entry && typeof entry === 'object') {
        value[field] = replaceReferences(entry, keyPattern, oldId, newId, field);
      }
    }
  }
  return value;
}

/**
 * Repairs storage records that share an ID with another record. Duplicate IDs
 * make the UI select the wrong building and let tenant checks hit the record
 * of another unit. The first record keeps its ID; every further record gets a
 * fresh one and the references of its own organisation unit are moved along.
 * Exact copies of the same record (same unit and code) are dropped instead.
 */
function repairDuplicateStorageIds(data, { log = () => {} } = {}) {
  const repairs = [];
  for (const [name, prefix, keyPattern] of STORAGE_ID_COLLECTIONS) {
    const entries = data[name] || [];
    const firstById = new Map();
    for (let index = 0; index < entries.length; index += 1) {
      const entry = entries[index];
      if (!entry || typeof entry !== 'object' || !entry.id) continue;
      const first = firstById.get(entry.id);
      if (!first) {
        firstById.set(entry.id, entry);
        continue;
      }
      if (first.organizationId === entry.organizationId && first.unitId === entry.unitId
          && String(first.code || '') === String(entry.code || '')
          && String(first.name || '') === String(entry.name || '')) {
        entries.splice(index, 1);
        index -= 1;
        repairs.push({ collection: name, id: entry.id, action: 'removed-copy' });
        continue;
      }
      const oldId = entry.id;
      const newId = nextNumericId(prefix, entries);
      entry.id = newId;
      firstById.set(newId, entry);
      for (const values of Object.values(data)) {
        if (!Array.isArray(values)) continue;
        for (const candidate of values) {
          if (!candidate || typeof candidate !== 'object' || candidate === first) continue;
          if (candidate.organizationId !== entry.organizationId
              || candidate.unitId !== entry.unitId) continue;
          replaceReferences(candidate, keyPattern, oldId, newId);
        }
      }
      repairs.push({ collection: name, id: oldId, newId, unitId: entry.unitId,
        organizationId: entry.organizationId, action: 'renumbered' });
    }
  }
  repairs.forEach((repair) => log(repair));
  if (repairs.length) refreshStoragePaths(data);
  return repairs;
}

module.exports = {
  StorageValidationError,
  buildingInput,
  hierarchyNodeInput,
  duplicateInScope,
  ensureStorageHierarchy,
  repairDuplicateStorageIds,
  refreshStoragePaths,
  bulkInput,
};
