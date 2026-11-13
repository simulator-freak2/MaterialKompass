const { randomUUID } = require('node:crypto');
const { rawCollection } = require('./tenancy');
const { assessMaterialSafety, validDateOnly } = require('./material-safety');

// Kisten sind eigenständige Lagerorte, die einem Lagerplatz zugewiesen sind.
//
// Der Inhalt einer Kiste besteht aus zwei Arten von Artikeln:
// - Artikel mit Inventarnummer (Inventar und Kleidung) haben die Kiste als
//   Lagerort (`containerId`). Sie werden wie bei jedem anderen Lagerort in die
//   Kiste hinein- und aus ihr herausgebucht und folgen der Kiste, wenn diese
//   einem anderen Lagerplatz zugewiesen wird.
// - Artikel ohne Inventarnummer (z. B. Pflaster, Kompressen) sind reiner
//   Kisteninhalt (`containerContents`). Sie gehören fest zur Kiste und können
//   nicht auf andere Lagerorte umgebucht, sondern nur erfasst, geändert oder
//   ausgebucht (verbraucht/entfernt) werden.

const ITEM_ENTITY_TYPES = Object.freeze(['MaterialItem', 'ClothingItem']);
const CONTENT_ENTITY_TYPE = 'Content';
const CHECK_RESULTS = Object.freeze(['vorhanden', 'fehlt', 'beschädigt', 'abgelaufen']);
const COMPLETENESS_STATUSES = Object.freeze(['Ungeprüft', 'Vollständig', 'Unvollständig']);
const DEFECT_PRIORITIES = Object.freeze(['Niedrig', 'Normal', 'Hoch', 'Kritisch']);
const MAX_CONTAINERS = 20_000;
const MAX_CONTENTS_PER_CONTAINER = 1_000;
const MAX_CONTENT_RECORDS = 100_000;
const MAX_CHECKS_PER_CONTAINER = 500;
const DEFAULT_EXPIRY_WARNING_DAYS = 30;
const NOT_RELOCATABLE_MESSAGE = 'Artikel ohne Inventarnummer sind Teil des Kisteninhalts und können '
  + 'nicht auf andere Lagerorte umgebucht werden. Sie können nur geändert oder ausgebucht werden.';

let pdfLibModule;
function pdfLib() {
  pdfLibModule ||= require('pdf-lib');
  return pdfLibModule;
}

function text(value, maximum = 255) {
  return String(value ?? '').trim().slice(0, maximum);
}

function uniqueTexts(values, maximum = 160) {
  return [...new Set((Array.isArray(values) ? values : [])
    .map((entry) => text(entry, maximum))
    .filter((entry) => entry && !['__proto__', 'prototype', 'constructor'].includes(entry)))]
    .slice(0, 100);
}

function number(value, fallback = 0) {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : fallback;
}

function todayIso(at = new Date()) {
  return at.toISOString().slice(0, 10);
}

function addDays(dateOnly, days) {
  const date = new Date(`${dateOnly}T00:00:00.000Z`);
  date.setUTCDate(date.getUTCDate() + days);
  return date.toISOString().slice(0, 10);
}

function contentName(value) {
  return text(value, 255).toLowerCase().replace(/\s+/g, ' ');
}

function itemKey(entityType, entityId) {
  return `${entityType}:${entityId}`;
}

function contentKey(name) {
  return itemKey(CONTENT_ENTITY_TYPE, contentName(name));
}

// Freie Inhalte haben keine Artikelreferenz. Einträge des früheren Modells
// (mit `entityType`) werden bis zur Migration ignoriert.
function isFreeContent(entry) {
  return entry && !entry.entityType;
}

function createContainerGuard({ containers, containerContents, materials, clothingItems }) {
  const all = (collection) => rawCollection(collection);

  function containerById(id) {
    if (!id) return null;
    return all(containers).find((entry) => entry.id === id && !entry.archived) || null;
  }

  function entityFor(entityType, entityId, scope = null) {
    const source = entityType === 'MaterialItem' ? materials
      : entityType === 'ClothingItem' ? clothingItems : null;
    if (!source) return null;
    return all(source).find((entry) => entry.id === entityId
      && (!scope || (entry.organizationId === scope.organizationId && entry.unitId === scope.unitId)))
      || null;
  }

  // Ein Artikel liegt nur dann in der Kiste, wenn er auch physisch an deren
  // Lagerplatz gebucht ist. Wird er an anderer Stelle umgelagert, endet die
  // Zuordnung automatisch.
  function containerOfEntity(entity) {
    if (!entity?.containerId || entity.archived) return null;
    const container = containerById(entity.containerId);
    if (!container || container.organizationId !== entity.organizationId
        || container.unitId !== entity.unitId) return null;
    if ((entity.locationId || null) !== (container.locationId || null)
        || (entity.stockStructureId || null) !== (container.stockStructureId || null)) return null;
    return container;
  }

  function containerOf(entityType, entityId, scope = null) {
    return containerOfEntity(entityFor(entityType, entityId, scope));
  }

  function itemsIn(containerId) {
    const container = containerById(containerId);
    if (!container) return [];
    const result = [];
    for (const [entityType, source] of [['MaterialItem', materials], ['ClothingItem', clothingItems]]) {
      for (const entity of all(source)) {
        if (entity.containerId === containerId && containerOfEntity(entity)?.id === containerId) {
          result.push({ entityType, entity });
        }
      }
    }
    return result;
  }

  function contentsOf(containerId) {
    return all(containerContents).filter((entry) => entry.containerId === containerId
      && isFreeContent(entry));
  }

  function hasContents(containerId) {
    return contentsOf(containerId).length > 0 || itemsIn(containerId).length > 0;
  }

  function placeInto(entity, container) {
    entity.containerId = container.id;
    entity.locationId = container.locationId;
    entity.stockStructureId = container.stockStructureId || null;
  }

  function detach(entity) {
    if (entity && Object.prototype.hasOwnProperty.call(entity, 'containerId')) entity.containerId = null;
  }

  function expiryState(entry, warningDays, at = new Date()) {
    if (!entry.expiresAt) return null;
    const today = todayIso(at);
    if (entry.expiresAt < today) return 'abgelaufen';
    if (entry.expiresAt <= addDays(today, warningDays)) return 'läuft bald ab';
    return null;
  }

  function warningDaysFor(container) {
    const configured = Number(container?.expiryWarningDays);
    return Number.isInteger(configured) && configured >= 0 && configured <= 365
      ? configured : DEFAULT_EXPIRY_WARNING_DAYS;
  }

  // Sicherheitsbedingt gesperrte Inventarartikel werden gemeldet. Abgelaufene
  // Inhalte werden ebenfalls gemeldet, damit sie ersetzt werden.
  function contentSafety(containerId, at = new Date()) {
    const container = containerById(containerId);
    const warningDays = warningDaysFor(container);
    const reasons = [];
    const warnings = [];
    let expired = 0;
    let expiringSoon = 0;
    for (const { entityType, entity } of itemsIn(containerId)) {
      if (entityType !== 'MaterialItem') continue;
      const safety = assessMaterialSafety(entity, at);
      if (safety.blocked) reasons.push(`Inhalt ${entity.inventoryNumber}: ${safety.reasons.join(' ')}`.trim());
    }
    for (const entry of contentsOf(containerId)) {
      const expiry = expiryState(entry, warningDays, at);
      if (expiry === 'abgelaufen') {
        expired += 1;
        warnings.push(`${entry.name} ist seit ${entry.expiresAt} abgelaufen.`);
      } else if (expiry) {
        expiringSoon += 1;
        warnings.push(`${entry.name} läuft am ${entry.expiresAt} ab.`);
      }
    }
    return { blocked: reasons.length > 0, reasons, warnings, expired, expiringSoon };
  }

  // Bewegt alle Artikel mit Inventarnummer an den aktuellen Lagerplatz der Kiste.
  function syncItems(container, previous, { actor = 'System', movements = null, nextId = null } = {}) {
    let changed = 0;
    for (const [entityType, source] of [['MaterialItem', materials], ['ClothingItem', clothingItems]]) {
      for (const entity of all(source)) {
        if (entity.containerId !== container.id || entity.archived) continue;
        // Nur Artikel, die bis eben in der Kiste lagen, wandern mit.
        if ((entity.locationId || null) !== (previous.locationId || null)
            || (entity.stockStructureId || null) !== (previous.stockStructureId || null)) continue;
        placeInto(entity, container);
        changed += 1;
        if (entityType === 'MaterialItem' && movements && nextId) {
          all(movements).push({
            id: nextId('movement', all(movements)), materialId: entity.id,
            action: 'container-follow', quantity: number(entity.quantity, 1),
            fromLocationId: previous.locationId || null,
            fromStockStructureId: previous.stockStructureId || null,
            toLocationId: container.locationId, toStockStructureId: container.stockStructureId || null,
            containerId: container.id, notes: `Mit Kiste ${container.code} bewegt.`,
            actor, createdAt: new Date().toISOString(),
            organizationId: entity.organizationId, unitId: entity.unitId,
          });
        }
      }
    }
    return changed;
  }

  function label(container) {
    return container ? `${container.code} ${container.name}`.trim() : null;
  }

  return {
    containerById,
    containerOf,
    containerOfEntity,
    itemsIn,
    contentsOf,
    hasContents,
    placeInto,
    detach,
    contentSafety,
    expiryState,
    warningDaysFor,
    syncItems,
    label,
  };
}

// Überführt das frühere Modell (Kiste = inventarisiertes Einzelstück mit
// `isContainer`) in eigenständige Kisten-Lagerorte. Idempotent.
function migrateLegacyContainers(data) {
  const materials = data.materials || [];
  const clothing = data.clothingItems || [];
  const containers = (data.containers ||= []);
  const contents = (data.containerContents ||= []);
  const packLists = (data.containerPackLists ||= []);
  const checks = (data.containerChecks ||= []);
  const movements = (data.materialMovements ||= []);
  const scopeKey = (entry, id) => `${entry.organizationId || ''}|${entry.unitId || ''}|${id}`;
  const legacy = materials.filter((entry) => entry.isContainer === true);
  if (!legacy.length && !contents.some((entry) => entry.entityType)) return { migrated: 0 };

  const idMap = new Map();
  const at = new Date().toISOString();
  for (const material of legacy) {
    const id = `container-${randomUUID()}`;
    idMap.set(scopeKey(material, material.id), id);
    containers.push({
      id,
      organizationId: material.organizationId, unitId: material.unitId,
      code: text(material.inventoryNumber, 64) || id,
      name: text(material.name, 255) || 'Kiste',
      containerType: text(material.containerType, 120),
      locationId: material.locationId || null,
      stockStructureId: material.stockStructureId || null,
      containerCompartments: Array.isArray(material.containerCompartments) ? material.containerCompartments : [],
      containerNotes: text(material.containerNotes, 5000),
      expiryWarningDays: material.expiryWarningDays ?? DEFAULT_EXPIRY_WARNING_DAYS,
      completenessStatus: material.completenessStatus || 'Ungeprüft',
      lastContainerCheckAt: material.lastContainerCheckAt || null,
      legacyMaterialId: material.id,
      archived: material.archived === true,
      createdAt: at, createdBy: 'System',
    });
    material.isContainer = false;
    material.convertedToContainerId = id;
  }
  const newId = (entry, oldId) => idMap.get(scopeKey(entry, oldId)) || null;
  const find = (source, entry, id) => source.find((candidate) => candidate.id === id
    && candidate.organizationId === entry.organizationId && candidate.unitId === entry.unitId);

  const remaining = [];
  for (const entry of contents) {
    if (!entry.entityType) {
      remaining.push(entry);
      continue;
    }
    const containerId = newId(entry, entry.containerId);
    const container = containers.find((candidate) => candidate.id === containerId);
    if (!container) continue;
    const entity = find(entry.entityType === 'ClothingItem' ? clothing : materials, entry, entry.entityId);
    if (entry.individual) {
      // Verschachtelte Kisten werden zu eigenen Kisten am selben Lagerplatz.
      if (entity?.convertedToContainerId) {
        const child = containers.find((candidate) => candidate.id === entity.convertedToContainerId);
        if (child) {
          child.locationId = container.locationId;
          child.stockStructureId = container.stockStructureId;
        }
        continue;
      }
      if (entity) {
        entity.containerId = container.id;
        entity.locationId = container.locationId;
        entity.stockStructureId = container.stockStructureId || null;
      }
      continue;
    }
    // Teilmengen von Mengenartikeln werden zu Kisteninhalt ohne Inventarnummer.
    const quantity = Math.max(1, Math.round(number(entry.quantity, 1)));
    remaining.push({
      id: entry.id,
      organizationId: entry.organizationId, unitId: entry.unitId,
      containerId: container.id,
      name: text(entity?.name || entry.nameSnapshot, 255) || 'Inhalt',
      quantity, unit: text(entity?.unit, 32) || 'Stück',
      position: entry.position || '', expiresAt: entry.expiresAt || null,
      batchNumber: entry.batchNumber || '',
      notes: text([entry.notes, `Übernommen aus ${entity?.inventoryNumber || entry.inventoryNumberSnapshot || 'Bestand'}`]
        .filter(Boolean).join(' · '), 1000),
      createdAt: entry.createdAt || at, createdBy: entry.createdBy || 'System',
    });
    if (entity) {
      const from = number(entity.quantity);
      entity.quantity = Math.max(0, from - quantity);
      movements.push({
        id: `movement-container-migration-${randomUUID()}`, materialId: entity.id,
        action: 'container-convert', quantity, containerId: container.id,
        notes: `Als Kisteninhalt ohne Inventarnummer in Kiste ${container.code} übernommen.`,
        actor: 'System', createdAt: at,
        organizationId: entity.organizationId, unitId: entity.unitId,
      });
    }
  }
  contents.splice(0, contents.length, ...remaining);

  for (const list of packLists) {
    const containerId = newId(list, list.containerId);
    if (!containerId) continue;
    list.containerId = containerId;
    list.items = (list.items || []).flatMap((item) => {
      if (item.entityType === CONTENT_ENTITY_TYPE) return [item];
      const entity = find(item.entityType === 'ClothingItem' ? clothing : materials, list, item.entityId);
      if (entity?.convertedToContainerId) return [];
      if (item.entityType === 'MaterialItem' && entity?.itemType === 'bulk') {
        return [{
          entityType: CONTENT_ENTITY_TYPE, entityId: null,
          name: text(entity.name || item.nameSnapshot, 255), unit: entity.unit || 'Stück',
          targetQuantity: item.targetQuantity, position: item.position || '', notes: item.notes || '',
        }];
      }
      return [item];
    });
  }
  for (const check of checks) {
    const containerId = newId(check, check.containerId);
    if (containerId) check.containerId = containerId;
  }
  return { migrated: legacy.length };
}

function registerContainerRoutes({
  app, authMiddleware, requirePermission, hasPermission,
  containers, containerContents, containerPackLists, containerChecks,
  materials, materialMovements, clothingItems, locations, stockStructures,
  vehicleLoadAssignments, defectManagement, logEvent, nextId, guard,
}) {
  const all = (collection) => rawCollection(collection);
  const nowIso = () => new Date().toISOString();

  function ownedBy(req, entity) {
    return entity?.organizationId === req.tenant.organizationId
      && entity?.unitId === req.tenant.unitId;
  }

  function ownedContainer(req, id) {
    return all(containers).find((entry) => entry.id === id && !entry.archived && ownedBy(req, entry)) || null;
  }

  function ownedStock(req, id) {
    return all(stockStructures).find((entry) => entry.id === id && ownedBy(req, entry)) || null;
  }

  function locationName(id) {
    return all(locations).find((entry) => entry.id === id)?.name || null;
  }

  function stockName(id) {
    const entry = all(stockStructures).find((candidate) => candidate.id === id);
    return entry?.path || entry?.name || null;
  }

  function loadedQuantity(material) {
    return all(vehicleLoadAssignments).reduce((sum, entry) => entry.materialId === material.id
      && entry.organizationId === material.organizationId && entry.unitId === material.unitId
      ? sum + number(entry.quantity) : sum, 0);
  }

  function entityFor(req, entityType, entityId) {
    const source = entityType === 'MaterialItem' ? materials
      : entityType === 'ClothingItem' ? clothingItems : null;
    if (!source) return null;
    return all(source).find((entry) => entry.id === entityId && ownedBy(req, entry)) || null;
  }

  function activePackList(containerId) {
    return all(containerPackLists).find((entry) => entry.containerId === containerId
      && entry.status === 'Aktiv') || null;
  }

  function itemQuantity(entityType, entity) {
    return entityType === 'MaterialItem' && entity.itemType === 'bulk' ? number(entity.quantity, 1) : 1;
  }

  // Ist-Bestand der Kiste je Schlüssel, inklusive Anzeigeinformationen.
  function actualPositions(containerId) {
    const result = new Map();
    for (const { entityType, entity } of guard.itemsIn(containerId)) {
      result.set(itemKey(entityType, entity.id), {
        entityType, entityId: entity.id, inventoryNumber: entity.inventoryNumber,
        name: entity.name, unit: entity.unit || 'Stück', quantity: itemQuantity(entityType, entity),
        position: '', earliestExpiry: null,
      });
    }
    for (const entry of guard.contentsOf(containerId)) {
      const key = contentKey(entry.name);
      const current = result.get(key) || {
        entityType: CONTENT_ENTITY_TYPE, entityId: null, inventoryNumber: null,
        name: entry.name, unit: entry.unit || 'Stück', quantity: 0,
        position: entry.position || '', earliestExpiry: null,
      };
      current.quantity += number(entry.quantity);
      if (entry.expiresAt && (!current.earliestExpiry || entry.expiresAt < current.earliestExpiry)) {
        current.earliestExpiry = entry.expiresAt;
      }
      result.set(key, current);
    }
    return result;
  }

  function listItemKey(item) {
    return item.entityType === CONTENT_ENTITY_TYPE
      ? contentKey(item.name) : itemKey(item.entityType, item.entityId);
  }

  function listItemLabel(req, item) {
    if (item.entityType === CONTENT_ENTITY_TYPE) {
      return { inventoryNumber: null, name: item.name, unit: item.unit || 'Stück' };
    }
    const entity = all(item.entityType === 'MaterialItem' ? materials : clothingItems)
      .find((entry) => entry.id === item.entityId && entry.organizationId === item.organizationId
        && entry.unitId === item.unitId)
      || all(item.entityType === 'MaterialItem' ? materials : clothingItems)
        .find((entry) => entry.id === item.entityId && (!req || ownedBy(req, entry)));
    return {
      inventoryNumber: entity?.inventoryNumber || item.inventoryNumberSnapshot || null,
      name: entity?.name || item.nameSnapshot || 'Gelöschter Artikel',
      unit: entity?.unit || 'Stück',
    };
  }

  function packListDeviation(req, container) {
    const list = activePackList(container.id);
    if (!list) return null;
    const actual = actualPositions(container.id);
    const rows = list.items.map((item) => {
      const key = listItemKey(item);
      const actualQuantity = actual.get(key)?.quantity || 0;
      return {
        key, entityType: item.entityType, entityId: item.entityId || null,
        ...listItemLabel(req, { ...item, organizationId: list.organizationId, unitId: list.unitId }),
        position: item.position || '', targetQuantity: item.targetQuantity,
        actualQuantity, deviation: actualQuantity - item.targetQuantity,
      };
    });
    const listed = new Set(rows.map((row) => row.key));
    const extra = [...actual.entries()].filter(([key]) => !listed.has(key)).map(([key, entry]) => ({
      key, entityType: entry.entityType, entityId: entry.entityId,
      inventoryNumber: entry.inventoryNumber, name: entry.name, unit: entry.unit,
      position: entry.position, targetQuantity: 0, actualQuantity: entry.quantity, deviation: entry.quantity,
    }));
    return {
      packListId: list.id, version: list.version, name: list.name,
      rows: [...rows, ...extra],
      missingCount: rows.filter((row) => row.deviation < 0).length,
      extraCount: extra.length,
      complete: rows.every((row) => row.deviation >= 0),
    };
  }

  function publicItem(entityType, entity) {
    return {
      entityType, entityId: entity.id,
      inventoryNumber: entity.inventoryNumber, name: entity.name,
      itemType: entityType === 'ClothingItem' ? 'individual' : entity.itemType || 'individual',
      quantity: itemQuantity(entityType, entity), unit: entity.unit || 'Stück',
      size: entityType === 'ClothingItem' ? entity.size || null : undefined,
      status: entity.status || null,
      issued: entityType === 'MaterialItem' ? number(entity.issuedQuantity) > 0 : entity.status === 'Ausgegeben',
      safetyStatus: entityType === 'MaterialItem' ? assessMaterialSafety(entity) : null,
      relocatable: true,
    };
  }

  function publicContent(entry, container) {
    return {
      ...entry,
      entityType: CONTENT_ENTITY_TYPE,
      inventoryNumber: null,
      relocatable: false,
      expiryState: guard.expiryState(entry, guard.warningDaysFor(container)),
    };
  }

  function publicContainer(req, container, { detail = false } = {}) {
    const items = guard.itemsIn(container.id);
    const contents = guard.contentsOf(container.id);
    const safety = guard.contentSafety(container.id);
    const deviation = packListDeviation(req, container);
    const list = activePackList(container.id);
    const checks = all(containerChecks).filter((entry) => entry.containerId === container.id);
    const lastCheck = checks.reduce((latest, entry) =>
      !latest || entry.checkedAt > latest.checkedAt ? entry : latest, null);
    const stock = all(stockStructures).find((entry) => entry.id === container.stockStructureId);
    const result = {
      id: container.id,
      code: container.code,
      name: container.name,
      label: guard.label(container),
      containerType: container.containerType || '',
      compartments: container.containerCompartments || [],
      containerNotes: container.containerNotes || '',
      expiryWarningDays: guard.warningDaysFor(container),
      locationId: container.locationId,
      locationName: locationName(container.locationId),
      stockStructureId: container.stockStructureId || null,
      stockStructureName: stockName(container.stockStructureId),
      storagePath: [stockName(container.stockStructureId) || locationName(container.locationId), container.name]
        .filter(Boolean).join(' / '),
      fullCode: [stock?.fullCode, container.code].filter(Boolean).join('-'),
      needsStorageAssignment: !container.stockStructureId,
      itemCount: items.length,
      contentCount: contents.length,
      completenessStatus: COMPLETENESS_STATUSES.includes(container.completenessStatus)
        ? container.completenessStatus : 'Ungeprüft',
      lastCheckAt: lastCheck?.checkedAt || null,
      lastCheckBy: lastCheck?.checkedByName || null,
      activePackListVersion: list?.version || null,
      packListMissingCount: deviation?.missingCount ?? null,
      expiredCount: safety.expired,
      expiringSoonCount: safety.expiringSoon,
      safetyStatus: { blocked: safety.blocked, reasons: safety.reasons, warnings: safety.warnings },
    };
    if (detail) {
      result.items = items.map(({ entityType, entity }) => publicItem(entityType, entity))
        .sort((left, right) => String(left.inventoryNumber).localeCompare(String(right.inventoryNumber)));
      result.contents = contents.map((entry) => publicContent(entry, container));
      result.packLists = all(containerPackLists).filter((entry) => entry.containerId === container.id)
        .sort((left, right) => Number(right.version) - Number(left.version));
      result.packListDeviation = deviation;
      result.checks = checks.slice().sort((left, right) =>
        String(right.checkedAt).localeCompare(String(left.checkedAt))).slice(0, 50);
      result.checkTemplate = checkTemplate(req, container);
    }
    return result;
  }

  // Prüfgrundlage: aktive Packliste, sonst der aktuelle Ist-Inhalt.
  function checkTemplate(req, container) {
    const list = activePackList(container.id);
    const actual = actualPositions(container.id);
    const source = list
      ? list.items.map((item) => ({ ...item, organizationId: list.organizationId, unitId: list.unitId }))
      : [...actual.values()].map((entry) => ({ ...entry, targetQuantity: entry.quantity }));
    return {
      packListId: list?.id || null,
      packListVersion: list?.version || null,
      items: source.map((item) => {
        const key = listItemKey(item);
        const current = actual.get(key);
        return {
          key, entityType: item.entityType, entityId: item.entityId || null,
          ...listItemLabel(req, item),
          position: item.position || current?.position || '',
          targetQuantity: number(item.targetQuantity),
          expectedQuantity: current?.quantity || 0,
          earliestExpiry: current?.earliestExpiry || null,
        };
      }),
    };
  }

  function validExpiry(value) {
    if (value === undefined) return { value: undefined };
    if (value === null || value === '') return { value: null };
    const parsed = validDateOnly(value);
    return parsed ? { value: parsed } : { error: 'Das Ablaufdatum ist ungültig.' };
  }

  function position(container, value) {
    const result = text(value, 160);
    const compartments = container.containerCompartments || [];
    if (compartments.length && result && !compartments.includes(result)) {
      return { error: 'Bitte ein definiertes Kistenfach wählen.' };
    }
    return { value: result };
  }

  function codeInUse(req, code, exceptId = null) {
    const normalized = code.toLowerCase();
    return all(containers).some((entry) => entry.id !== exceptId && !entry.archived
      && ownedBy(req, entry) && String(entry.code || '').toLowerCase() === normalized);
  }

  function nextCode(req) {
    const used = new Set(all(containers).filter((entry) => ownedBy(req, entry) && !entry.archived)
      .map((entry) => String(entry.code || '').toUpperCase()));
    let index = 1;
    while (used.has(`K-${String(index).padStart(3, '0')}`)) index += 1;
    return `K-${String(index).padStart(3, '0')}`;
  }

  // Ziel einer Umbuchung: Lagerplatz, Gebäude oder eine andere Kiste.
  function relocationTarget(req, body) {
    const containerId = text(body.containerId, 64);
    if (containerId) {
      const target = ownedContainer(req, containerId);
      if (!target) return { error: 'Die Ziel-Kiste ist ungültig.' };
      if (!target.stockStructureId) return { error: 'Die Ziel-Kiste ist keinem Lagerplatz zugewiesen.' };
      return { container: target, locationId: target.locationId, stockStructureId: target.stockStructureId };
    }
    const locationId = text(body.locationId, 64);
    const stockStructureId = text(body.stockStructureId, 64) || null;
    const location = all(locations).find((entry) => entry.id === locationId
      && entry.organizationId === req.tenant.organizationId);
    if (!location) return { error: 'Ein gültiger Ziel-Lagerort ist erforderlich.' };
    if (stockStructureId && !all(stockStructures).some((entry) => entry.id === stockStructureId
      && entry.locationId === location.id)) {
      return { error: 'Der Lagerplatz gehört nicht zum gewählten Gebäude.' };
    }
    return { container: null, locationId: location.id, stockStructureId };
  }

  function itemBlocker(req, entityType, entity) {
    if (!entity || entity.archived) {
      return { status: 400, error: 'Der Artikel ist ungültig oder gehört nicht zu dieser Gliederung.' };
    }
    if (entityType === 'ClothingItem') {
      if (!hasPermission(req.user, 'clothing.read')) {
        return { status: 403, error: 'Für Kleiderkammer-Artikel fehlt die Berechtigung.' };
      }
      if (entity.status === 'Ausgegeben' || entity.assignedPerson) {
        return { status: 409, error: 'Ausgegebene Kleidung kann nicht umgebucht werden.' };
      }
      return null;
    }
    if (number(entity.issuedQuantity) > 0 || loadedQuantity(entity) > 0) {
      return { status: 409, error: 'Ausgegebenes oder auf Fahrzeuge geladenes Material kann nicht umgebucht werden.' };
    }
    return null;
  }

  function bookItem(req, entityType, entity, target, { action, containerId, notes }) {
    const from = {
      locationId: entity.locationId || null,
      stockStructureId: entity.stockStructureId || null,
      containerId: guard.containerOfEntity(entity)?.id || null,
    };
    if (target.container) guard.placeInto(entity, target.container);
    else {
      guard.detach(entity);
      entity.locationId = target.locationId;
      entity.stockStructureId = target.stockStructureId;
    }
    entity.updatedAt = nowIso();
    if (entityType === 'MaterialItem') {
      all(materialMovements).push({
        id: nextId('movement', all(materialMovements)), materialId: entity.id,
        action, quantity: itemQuantity(entityType, entity),
        fromLocationId: from.locationId, fromStockStructureId: from.stockStructureId,
        fromContainerId: from.containerId,
        toLocationId: entity.locationId, toStockStructureId: entity.stockStructureId || null,
        toContainerId: target.container?.id || null,
        containerId, notes: text(notes, 1000), actor: req.user.username, createdAt: nowIso(),
        organizationId: entity.organizationId, unitId: entity.unitId,
      });
    }
    return from;
  }

  // ---- Kisten-Stammdaten --------------------------------------------------

  app.get('/api/containers', authMiddleware, requirePermission('containers.read'), (req, res) => {
    const query = text(req.query.query, 120).toLowerCase();
    const stockStructureId = text(req.query.stockStructureId, 64);
    const limit = Math.min(Math.max(Number(req.query.limit) || 500, 1), 1000);
    const result = all(containers).filter((entry) => !entry.archived && ownedBy(req, entry)
      && (!stockStructureId || entry.stockStructureId === stockStructureId)
      && (!query || [entry.code, entry.name, entry.containerType]
        .some((value) => String(value || '').toLowerCase().includes(query))))
      .sort((left, right) => String(left.code).localeCompare(String(right.code), 'de', { numeric: true }))
      .slice(0, limit).map((entry) => publicContainer(req, entry));
    return res.json(result);
  });

  app.get('/api/containers/expiring', authMiddleware, requirePermission('containers.read'), (req, res) => {
    const days = Math.min(Math.max(Number.parseInt(req.query.days, 10) || DEFAULT_EXPIRY_WARNING_DAYS, 0), 365);
    const limitDate = addDays(todayIso(), days);
    const result = all(containerContents).filter((entry) => isFreeContent(entry) && ownedBy(req, entry)
      && entry.expiresAt && entry.expiresAt <= limitDate)
      .flatMap((entry) => {
        const container = ownedContainer(req, entry.containerId);
        if (!container) return [];
        return [{
          ...publicContent(entry, container),
          containerCode: container.code,
          containerName: container.name,
          expiryState: entry.expiresAt < todayIso() ? 'abgelaufen' : 'läuft bald ab',
        }];
      })
      .sort((left, right) => String(left.expiresAt).localeCompare(String(right.expiresAt)));
    return res.json(result);
  });

  // Scan: Kistennummer öffnet die Kiste, eine Inventarnummer die Kiste, in der
  // der Artikel liegt.
  app.get('/api/containers/lookup', authMiddleware, requirePermission('containers.read'), (req, res) => {
    const code = text(req.query.code, 128).toLowerCase();
    if (!code) return res.status(400).json({ error: 'Bitte eine Kisten- oder Inventarnummer angeben.' });
    const container = all(containers).find((entry) => !entry.archived && ownedBy(req, entry)
      && String(entry.code || '').toLowerCase() === code);
    if (container) {
      return res.json({ match: 'container', container: publicContainer(req, container, { detail: true }) });
    }
    for (const [entityType, source] of [['MaterialItem', materials], ['ClothingItem', clothingItems]]) {
      const entity = all(source).find((entry) => ownedBy(req, entry) && !entry.archived
        && String(entry.inventoryNumber || '').toLowerCase() === code);
      if (!entity) continue;
      const parent = guard.containerOfEntity(entity);
      if (parent) {
        return res.json({
          match: 'content', entityType, entityId: entity.id,
          container: publicContainer(req, parent, { detail: true }),
        });
      }
      return res.json({ match: 'item', entityType, entityId: entity.id,
        inventoryNumber: entity.inventoryNumber, name: entity.name });
    }
    return res.status(404).json({ error: 'Zu dieser Nummer wurde keine Kiste gefunden.' });
  });

  // Auswahlliste für Kisten-Lagerplätze und Umbuchungsziele, unabhängig vom
  // Recht zur Lagerortverwaltung.
  app.get('/api/containers/storage-targets', authMiddleware, requirePermission('containers.read'), (req, res) => {
    const byPath = (left, right) => String(left.path).localeCompare(String(right.path), 'de', { numeric: true });
    return res.json({
      locations: all(locations).filter((entry) => ownedBy(req, entry) && !entry.vehicleId)
        .map((entry) => ({ id: entry.id, path: entry.path || entry.name })).sort(byPath),
      stockStructures: all(stockStructures).filter((entry) => ownedBy(req, entry))
        .map((entry) => ({
          id: entry.id, locationId: entry.locationId, path: entry.path || entry.name, fullCode: entry.fullCode || null,
        })).sort(byPath),
      containers: all(containers).filter((entry) => ownedBy(req, entry) && !entry.archived && entry.stockStructureId)
        .map((entry) => ({ id: entry.id, code: entry.code, name: entry.name, path: stockName(entry.stockStructureId) }))
        .sort((left, right) => String(left.code).localeCompare(String(right.code), 'de', { numeric: true })),
    });
  });

  app.get('/api/containers/:id', authMiddleware, requirePermission('containers.read'), (req, res) => {
    const container = ownedContainer(req, req.params.id);
    if (!container) return res.status(404).json({ error: 'Kiste nicht gefunden.' });
    return res.json(publicContainer(req, container, { detail: true }));
  });

  function containerSettings(req, body, existing = null) {
    const name = text(body.name ?? existing?.name, 255);
    if (!name) return { error: 'Die Bezeichnung der Kiste ist ein Pflichtfeld.' };
    const code = text(body.code ?? existing?.code, 64) || (existing ? '' : nextCode(req));
    if (!code || (code !== existing?.code && !/^[\p{L}\p{N} ._/-]+$/u.test(code))) {
      return { error: 'Die Kistennummer darf nur Buchstaben, Zahlen, Leerzeichen sowie . _ / - enthalten.' };
    }
    if (codeInUse(req, code, existing?.id)) return { status: 409, error: 'Die Kistennummer ist bereits vergeben.' };
    const stockStructureId = text(body.stockStructureId ?? existing?.stockStructureId, 64);
    const stock = stockStructureId ? ownedStock(req, stockStructureId) : null;
    if (!stock) return { error: 'Bitte einen gültigen Lagerplatz für die Kiste wählen.' };
    if (body.compartments !== undefined && (!Array.isArray(body.compartments)
      || body.compartments.length > 100 || body.compartments.some((entry) =>
        typeof entry !== 'string' || !entry.trim() || entry.trim().length > 160))) {
      return { error: 'Bitte höchstens 100 Kistenfächer mit jeweils maximal 160 Zeichen angeben.' };
    }
    const compartments = uniqueTexts(body.compartments ?? existing?.containerCompartments);
    const warning = body.expiryWarningDays ?? existing?.expiryWarningDays ?? DEFAULT_EXPIRY_WARNING_DAYS;
    const expiryWarningDays = Number(warning);
    if (!Number.isInteger(expiryWarningDays) || expiryWarningDays < 0 || expiryWarningDays > 365) {
      return { error: 'Die Vorwarnzeit für Ablaufdaten muss zwischen 0 und 365 Tagen liegen.' };
    }
    return {
      code, name,
      containerType: text(body.containerType ?? existing?.containerType, 120),
      locationId: stock.locationId,
      stockStructureId: stock.id,
      containerCompartments: compartments,
      containerNotes: text(body.notes ?? existing?.containerNotes, 5000),
      expiryWarningDays,
    };
  }

  app.post('/api/containers', authMiddleware, requirePermission('containers.manage'), (req, res) => {
    if (all(containers).length >= MAX_CONTAINERS) {
      return res.status(507).json({ error: 'Die maximale Anzahl an Kisten ist erreicht.' });
    }
    const settings = containerSettings(req, req.body);
    if (settings.error) return res.status(settings.status || 400).json({ error: settings.error });
    const container = {
      id: `container-${randomUUID()}`,
      organizationId: req.tenant.organizationId, unitId: req.tenant.unitId,
      ...settings,
      completenessStatus: 'Ungeprüft', lastContainerCheckAt: null, archived: false,
      createdAt: nowIso(), createdBy: req.user.username,
    };
    all(containers).push(container);
    logEvent('create', 'Container', {
      id: container.id, code: container.code, itemName: container.name,
      stockStructureId: container.stockStructureId,
    }, req.user.username);
    return res.status(201).json(publicContainer(req, container, { detail: true }));
  });

  app.put('/api/containers/:id', authMiddleware, requirePermission('containers.manage'), (req, res) => {
    const container = ownedContainer(req, req.params.id);
    if (!container) return res.status(404).json({ error: 'Kiste nicht gefunden.' });
    const settings = containerSettings(req, req.body, container);
    if (settings.error) return res.status(settings.status || 400).json({ error: settings.error });
    const removed = (container.containerCompartments || [])
      .filter((entry) => !settings.containerCompartments.includes(entry));
    if (guard.contentsOf(container.id).some((entry) => removed.includes(entry.position))) {
      return res.status(409).json({ error: 'Belegte Kistenfächer können nicht entfernt werden.' });
    }
    const previous = { locationId: container.locationId, stockStructureId: container.stockStructureId };
    const moved = previous.stockStructureId !== settings.stockStructureId;
    Object.assign(container, settings, { updatedAt: nowIso(), updatedBy: req.user.username });
    let followed = 0;
    if (moved) {
      followed = guard.syncItems(container, previous, {
        actor: req.user.username, movements: materialMovements, nextId,
      });
    }
    logEvent(moved ? 'relocate' : 'update', 'Container', {
      id: container.id, ...(moved ? {
        fromStockStructureId: previous.stockStructureId, toStockStructureId: container.stockStructureId, followed,
      } : {}),
    }, req.user.username);
    return res.json(publicContainer(req, container, { detail: true }));
  });

  app.delete('/api/containers/:id', authMiddleware, requirePermission('containers.manage'), (req, res) => {
    const container = ownedContainer(req, req.params.id);
    if (!container) return res.status(404).json({ error: 'Kiste nicht gefunden.' });
    if (guard.hasContents(container.id)) {
      return res.status(409).json({ error: 'Nur leere Kisten können aufgelöst werden.' });
    }
    container.archived = true;
    container.archivedAt = nowIso();
    container.archivedBy = req.user.username;
    for (const list of all(containerPackLists).filter((entry) => entry.containerId === container.id)) {
      if (list.status === 'Aktiv') list.status = 'Ersetzt';
    }
    logEvent('delete', 'Container', { id: container.id, code: container.code }, req.user.username);
    return res.json({ success: true, id: container.id });
  });

  // ---- Artikel mit Inventarnummer ------------------------------------------

  app.get('/api/containers/:id/candidates', authMiddleware, requirePermission('containers.pack'), (req, res) => {
    const container = ownedContainer(req, req.params.id);
    if (!container) return res.status(404).json({ error: 'Kiste nicht gefunden.' });
    const query = text(req.query.query, 120).toLowerCase();
    const matches = (entry) => !query
      || `${entry.inventoryNumber} ${entry.name}`.toLowerCase().includes(query);
    const describe = (entityType, entry) => {
      const current = guard.containerOfEntity(entry);
      return {
        entityType, entityId: entry.id,
        inventoryNumber: entry.inventoryNumber, name: entry.name,
        size: entityType === 'ClothingItem' ? entry.size || null : undefined,
        itemType: entityType === 'ClothingItem' ? 'individual' : entry.itemType,
        unit: entry.unit || 'Stück',
        quantity: itemQuantity(entityType, entry),
        locationName: current ? `Kiste ${guard.label(current)}`
          : [locationName(entry.locationId), stockName(entry.stockStructureId)].filter(Boolean).join(' / '),
      };
    };
    const materialCandidates = all(materials).filter((entry) => ownedBy(req, entry)
      && !entry.archived && matches(entry) && !['Ausgesondert', 'Verloren'].includes(entry.status)
      && guard.containerOfEntity(entry)?.id !== container.id
      && number(entry.issuedQuantity) === 0 && loadedQuantity(entry) === 0)
      .slice(0, 100).map((entry) => describe('MaterialItem', entry));
    const clothingCandidates = hasPermission(req.user, 'clothing.read')
      ? all(clothingItems).filter((entry) => ownedBy(req, entry) && !entry.archived && matches(entry)
        && entry.status !== 'Ausgegeben' && !entry.assignedPerson
        && guard.containerOfEntity(entry)?.id !== container.id)
        .slice(0, 100).map((entry) => describe('ClothingItem', entry))
      : [];
    return res.json([...materialCandidates, ...clothingCandidates]);
  });

  // Bucht einen Artikel mit Inventarnummer in die Kiste (Lagerort = Kiste).
  app.post('/api/containers/:id/items', authMiddleware, requirePermission('containers.pack'), (req, res) => {
    const container = ownedContainer(req, req.params.id);
    if (!container) return res.status(404).json({ error: 'Kiste nicht gefunden.' });
    if (!container.stockStructureId) {
      return res.status(409).json({ error: 'Die Kiste ist keinem Lagerplatz zugewiesen.' });
    }
    const entityType = text(req.body.entityType || 'MaterialItem', 32);
    if (!ITEM_ENTITY_TYPES.includes(entityType)) {
      return res.status(400).json({ error: 'Nur Artikel mit Inventarnummer können in eine Kiste gebucht werden.' });
    }
    const entity = entityFor(req, entityType, text(req.body.entityId ?? req.body.materialId, 64));
    const blocker = itemBlocker(req, entityType, entity);
    if (blocker) return res.status(blocker.status).json({ error: blocker.error });
    if (['Ausgesondert', 'Verloren'].includes(entity.status)) {
      return res.status(409).json({ error: 'Ausgesondertes oder verlorenes Material kann nicht eingelagert werden.' });
    }
    if (guard.containerOfEntity(entity)?.id === container.id) {
      return res.status(409).json({ error: 'Der Artikel liegt bereits in dieser Kiste.' });
    }
    bookItem(req, entityType, entity, {
      container, locationId: container.locationId, stockStructureId: container.stockStructureId,
    }, { action: 'container-pack', containerId: container.id, notes: req.body.notes });
    container.completenessStatus = 'Ungeprüft';
    logEvent('pack', 'Container', {
      containerId: container.id, entityType, entityId: entity.id,
    }, req.user.username);
    return res.status(201).json(publicItem(entityType, entity));
  });

  // Bucht einen Artikel mit Inventarnummer aus der Kiste auf einen anderen
  // Lagerort (Lagerplatz, Gebäude oder andere Kiste).
  app.post('/api/containers/:id/items/:entityType/:entityId/relocate', authMiddleware,
    requirePermission('containers.pack'), (req, res) => {
      const container = ownedContainer(req, req.params.id);
      if (!container) return res.status(404).json({ error: 'Kiste nicht gefunden.' });
      const entityType = text(req.params.entityType, 32);
      if (!ITEM_ENTITY_TYPES.includes(entityType)) {
        return res.status(409).json({ error: NOT_RELOCATABLE_MESSAGE });
      }
      const entity = entityFor(req, entityType, req.params.entityId);
      if (!entity || guard.containerOfEntity(entity)?.id !== container.id) {
        return res.status(404).json({ error: 'Der Artikel liegt nicht in dieser Kiste.' });
      }
      const blocker = itemBlocker(req, entityType, entity);
      if (blocker) return res.status(blocker.status).json({ error: blocker.error });
      const target = relocationTarget(req, req.body);
      if (target.error) return res.status(400).json({ error: target.error });
      if (target.container?.id === container.id) {
        return res.status(409).json({ error: 'Der Artikel liegt bereits in dieser Kiste.' });
      }
      bookItem(req, entityType, entity, target, {
        action: target.container ? 'container-pack' : 'container-unpack',
        containerId: container.id, notes: req.body.notes,
      });
      container.completenessStatus = 'Ungeprüft';
      if (target.container) target.container.completenessStatus = 'Ungeprüft';
      logEvent('unpack', 'Container', {
        containerId: container.id, entityType, entityId: entity.id,
        toContainerId: target.container?.id || null, toStockStructureId: entity.stockStructureId || null,
      }, req.user.username);
      return res.json(publicItem(entityType, entity));
    });

  // ---- Inhalt ohne Inventarnummer ------------------------------------------

  function contentInput(container, body, existing = null) {
    const name = text(body.name ?? existing?.name, 255);
    if (!name) return { error: 'Die Bezeichnung des Inhalts ist ein Pflichtfeld.' };
    const quantity = Number(body.quantity ?? existing?.quantity ?? 1);
    if (!Number.isInteger(quantity) || quantity < 1 || quantity > 1_000_000) {
      return { error: 'Die Menge muss eine positive ganze Zahl sein.' };
    }
    const expiry = validExpiry(body.expiresAt);
    if (expiry.error) return { error: expiry.error };
    const slot = body.position === undefined && existing
      ? { value: existing.position } : position(container, body.position);
    if (slot.error) return { error: slot.error };
    return {
      name, quantity,
      unit: text(body.unit ?? existing?.unit, 32) || 'Stück',
      position: slot.value,
      expiresAt: expiry.value === undefined ? existing?.expiresAt ?? null : expiry.value,
      batchNumber: text(body.batchNumber ?? existing?.batchNumber, 120),
      notes: text(body.notes ?? existing?.notes, 1000),
    };
  }

  function findContent(req, res) {
    const container = ownedContainer(req, req.params.id);
    const entry = container && guard.contentsOf(container.id)
      .find((candidate) => candidate.id === req.params.contentId);
    if (!entry) {
      res.status(404).json({ error: 'Kisteninhalt nicht gefunden.' });
      return {};
    }
    return { container, entry };
  }

  app.post('/api/containers/:id/contents', authMiddleware, requirePermission('containers.pack'), (req, res) => {
    const container = ownedContainer(req, req.params.id);
    if (!container) return res.status(404).json({ error: 'Kiste nicht gefunden.' });
    if (req.body.entityId || req.body.materialId) {
      return res.status(400).json({
        error: 'Artikel mit Inventarnummer werden in die Kiste umgebucht, nicht als Inhalt erfasst.',
      });
    }
    if (guard.contentsOf(container.id).length >= MAX_CONTENTS_PER_CONTAINER
        || all(containerContents).length >= MAX_CONTENT_RECORDS) {
      return res.status(507).json({ error: 'Die maximale Anzahl an Kisteninhalten ist erreicht.' });
    }
    const values = contentInput(container, req.body);
    if (values.error) return res.status(400).json({ error: values.error });
    const entry = {
      id: `container-content-${randomUUID()}`,
      organizationId: container.organizationId, unitId: container.unitId,
      containerId: container.id, ...values,
      createdAt: nowIso(), createdBy: req.user.username,
    };
    all(containerContents).push(entry);
    container.completenessStatus = 'Ungeprüft';
    logEvent('add-content', 'Container', {
      id: entry.id, containerId: container.id, itemName: entry.name, quantity: entry.quantity,
    }, req.user.username);
    return res.status(201).json(publicContent(entry, container));
  });

  app.put('/api/containers/:id/contents/:contentId', authMiddleware,
    requirePermission('containers.pack'), (req, res) => {
      const { container, entry } = findContent(req, res);
      if (!entry) return undefined;
      if (req.body.containerId !== undefined && req.body.containerId !== entry.containerId) {
        return res.status(409).json({ error: NOT_RELOCATABLE_MESSAGE });
      }
      const values = contentInput(container, req.body, entry);
      if (values.error) return res.status(400).json({ error: values.error });
      if (values.quantity !== entry.quantity || values.name !== entry.name) {
        container.completenessStatus = 'Ungeprüft';
      }
      Object.assign(entry, values, { updatedAt: nowIso(), updatedBy: req.user.username });
      logEvent('update-content', 'Container', { id: entry.id, containerId: container.id }, req.user.username);
      return res.json(publicContent(entry, container));
    });

  // Ausbuchen (verbraucht, entsorgt, verloren). Ein Umbuchen auf einen anderen
  // Lagerort ist für Inhalte ohne Inventarnummer nicht möglich.
  app.delete('/api/containers/:id/contents/:contentId', authMiddleware,
    requirePermission('containers.pack'), (req, res) => {
      const { container, entry } = findContent(req, res);
      if (!entry) return undefined;
      const raw = all(containerContents);
      raw.splice(raw.indexOf(entry), 1);
      container.completenessStatus = 'Ungeprüft';
      logEvent('remove-content', 'Container', {
        id: entry.id, containerId: container.id, itemName: entry.name, quantity: entry.quantity,
        reason: text(req.body?.reason ?? req.query.reason, 160) || 'Ausgebucht',
      }, req.user.username);
      return res.json({ success: true });
    });

  for (const suffix of ['unpack', 'relocate']) {
    app.post(`/api/containers/:id/contents/:contentId/${suffix}`, authMiddleware,
      requirePermission('containers.pack'), (req, res) => {
        const { entry } = findContent(req, res);
        if (!entry) return undefined;
        return res.status(409).json({ error: NOT_RELOCATABLE_MESSAGE });
      });
  }

  // ---- Packlisten ----------------------------------------------------------

  app.post('/api/containers/:id/pack-lists', authMiddleware,
    requirePermission('containers.packlists'), (req, res) => {
      const container = ownedContainer(req, req.params.id);
      if (!container) return res.status(404).json({ error: 'Kiste nicht gefunden.' });
      const name = text(req.body.name || 'Packliste', 160);
      let items = Array.isArray(req.body.items) ? req.body.items : [];
      if (req.body.fromContents === true) {
        items = [...actualPositions(container.id).values()].map((entry) => ({
          entityType: entry.entityType, entityId: entry.entityId, name: entry.name, unit: entry.unit,
          targetQuantity: entry.quantity, position: entry.position,
        }));
      }
      if (!name || items.length > MAX_CONTENTS_PER_CONTAINER) {
        return res.status(400).json({ error: 'Bezeichnung oder Umfang der Packliste ist ungültig.' });
      }
      const normalized = [];
      const seen = new Set();
      for (const item of items) {
        const entityType = text(item?.entityType || (item?.entityId ? 'MaterialItem' : CONTENT_ENTITY_TYPE), 32);
        const targetQuantity = Number(item?.targetQuantity);
        if (!Number.isInteger(targetQuantity) || targetQuantity < 1 || targetQuantity > 1_000_000) {
          return res.status(400).json({ error: 'Jede Listenposition benötigt eine gültige Sollmenge.' });
        }
        let entry;
        if (entityType === CONTENT_ENTITY_TYPE) {
          const contentLabel = text(item?.name, 255);
          if (!contentLabel) return res.status(400).json({ error: 'Jede Listenposition benötigt eine Bezeichnung.' });
          entry = {
            entityType, entityId: null, name: contentLabel, unit: text(item.unit, 32) || 'Stück',
            targetQuantity,
          };
        } else {
          const entity = ITEM_ENTITY_TYPES.includes(entityType)
            ? entityFor(req, entityType, text(item?.entityId ?? item?.materialId, 64)) : null;
          if (!entity) {
            return res.status(400).json({ error: 'Jede Listenposition benötigt einen gültigen Artikel und eine Sollmenge.' });
          }
          if (targetQuantity !== itemQuantity(entityType, entity)
              && (entityType === 'ClothingItem' || entity.itemType === 'individual')) {
            return res.status(400).json({ error: 'Einzelstücke stehen mit der Sollmenge 1 in der Packliste.' });
          }
          entry = {
            entityType, entityId: entity.id, targetQuantity,
            inventoryNumberSnapshot: entity.inventoryNumber, nameSnapshot: entity.name,
          };
        }
        const key = listItemKey(entry);
        if (seen.has(key)) return res.status(400).json({ error: 'Jeder Artikel darf nur einmal in der Packliste stehen.' });
        seen.add(key);
        normalized.push({ ...entry, position: text(item.position, 160), notes: text(item.notes, 1000) });
      }
      const version = all(containerPackLists).filter((entry) => entry.containerId === container.id)
        .reduce((highest, entry) => Math.max(highest, Number(entry.version || 0)), 0) + 1;
      const activate = req.body.activate !== false;
      if (activate) {
        all(containerPackLists).filter((entry) => entry.containerId === container.id && entry.status === 'Aktiv')
          .forEach((entry) => { entry.status = 'Ersetzt'; });
        container.completenessStatus = 'Ungeprüft';
      }
      const list = {
        id: `container-pack-list-${randomUUID()}`,
        organizationId: container.organizationId, unitId: container.unitId,
        containerId: container.id, name, version, status: activate ? 'Aktiv' : 'Entwurf',
        items: normalized, createdAt: nowIso(), createdBy: req.user.username,
      };
      all(containerPackLists).push(list);
      logEvent('pack-list', 'Container', { id: list.id, containerId: container.id, version }, req.user.username);
      return res.status(201).json(list);
    });

  app.post('/api/containers/:id/pack-lists/:listId/activate', authMiddleware,
    requirePermission('containers.packlists'), (req, res) => {
      const container = ownedContainer(req, req.params.id);
      const list = all(containerPackLists).find((entry) => entry.id === req.params.listId
        && entry.containerId === container?.id);
      if (!list) return res.status(404).json({ error: 'Packliste nicht gefunden.' });
      if (list.status !== 'Entwurf') return res.status(409).json({ error: 'Nur Entwürfe können aktiviert werden.' });
      all(containerPackLists).filter((entry) => entry.containerId === container.id && entry.status === 'Aktiv')
        .forEach((entry) => { entry.status = 'Ersetzt'; });
      list.status = 'Aktiv';
      list.activatedAt = nowIso();
      list.activatedBy = req.user.username;
      container.completenessStatus = 'Ungeprüft';
      logEvent('pack-list-activate', 'Container', { id: list.id, containerId: container.id }, req.user.username);
      return res.json(list);
    });

  app.get('/api/containers/:id/pack-list/print', authMiddleware,
    requirePermission('containers.print'), async (req, res) => {
      const container = ownedContainer(req, req.params.id);
      if (!container) return res.status(404).json({ error: 'Kiste nicht gefunden.' });
      const template = checkTemplate(req, container);
      const list = activePackList(container.id);
      const { PDFDocument, StandardFonts, rgb } = pdfLib();
      const pdf = await PDFDocument.create();
      const font = await pdf.embedFont(StandardFonts.Helvetica);
      const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
      let page = pdf.addPage([595, 842]); let y = 800;
      // Standardschriften können nur WinAnsi-Zeichen kodieren.
      const safe = (value) => String(value ?? '').replace(/[^\x20-\x7E\xA0-\xFF€]/g, '?');
      const line = (value, options = {}) => {
        if (y < 55) { page = pdf.addPage([595, 842]); y = 800; }
        page.drawText(safe(value).slice(0, 110), {
          x: options.x || 42, y, size: options.size || 9,
          font: options.bold ? bold : font, color: options.color || rgb(0, 0, 0),
        });
        y -= options.gap || 15;
      };
      line('Kisten-Packliste', { size: 18, bold: true, gap: 25 });
      line(`Kiste: ${container.code} | ${container.name}`, { bold: true });
      line(`Kistenart: ${container.containerType || '-'} | Lagerplatz: ${stockName(container.stockStructureId) || locationName(container.locationId) || '-'}`);
      line(`Liste: ${list ? `${list.name} | Version ${list.version}` : 'Keine aktive Packliste (Ist-Inhalt)'} | Stand: ${new Date().toLocaleString('de-DE', { timeZone: 'Europe/Berlin' })}`);
      y -= 8;
      line('Inventarnummer | Bezeichnung | Fach | Soll | Ist | Abw. | Ablauf | Geprüft', { bold: true, gap: 18 });
      for (const item of template.items) {
        const deviation = item.expectedQuantity - item.targetQuantity;
        line(`${item.inventoryNumber || 'ohne'} | ${item.name} | ${item.position || '-'} | ${item.targetQuantity} | ${item.expectedQuantity} | ${deviation >= 0 ? '+' : ''}${deviation} | ${item.earliestExpiry || '-'} | [  ]`,
          { color: deviation < 0 ? rgb(0.75, 0, 0) : rgb(0, 0, 0) });
      }
      y -= 20;
      line('Geprüft am: ____________________   durch: ______________________________');
      line('Unterschrift: ________________________________________________________');
      const bytes = await pdf.save();
      logEvent('print', 'Container', { containerId: container.id, packListId: list?.id || null }, req.user.username);
      return res.json({
        fileName: `packliste-${String(container.code).replace(/[^A-Za-z0-9_-]/g, '-')}${list ? `-v${list.version}` : ''}.pdf`,
        mimeType: 'application/pdf', fileBase64: Buffer.from(bytes).toString('base64'),
      });
    });

  // ---- Vollständigkeitsprüfung -------------------------------------------

  app.post('/api/containers/:id/checks', authMiddleware, requirePermission('containers.check'), (req, res) => {
    const container = ownedContainer(req, req.params.id);
    if (!container) return res.status(404).json({ error: 'Kiste nicht gefunden.' });
    const template = checkTemplate(req, container);
    if (!template.items.length) {
      return res.status(409).json({ error: 'Die Kiste hat weder eine Packliste noch einen Inhalt.' });
    }
    const submitted = new Map((Array.isArray(req.body.results) ? req.body.results : [])
      .map((entry) => [text(entry?.key, 300), entry]));
    const results = [];
    for (const item of template.items) {
      const input = submitted.get(item.key);
      if (!input) return res.status(400).json({ error: `Für ${item.inventoryNumber || item.name} fehlt ein Prüfergebnis.` });
      const result = text(input.result, 32).toLowerCase();
      if (!CHECK_RESULTS.includes(result)) return res.status(400).json({ error: 'Das Prüfergebnis ist ungültig.' });
      const actualQuantity = input.actualQuantity === undefined || input.actualQuantity === null
        ? (result === 'fehlt' ? 0 : item.targetQuantity) : Number(input.actualQuantity);
      if (!Number.isInteger(actualQuantity) || actualQuantity < 0 || actualQuantity > 1_000_000) {
        return res.status(400).json({ error: 'Die Ist-Menge ist ungültig.' });
      }
      results.push({
        key: item.key, entityType: item.entityType, entityId: item.entityId,
        inventoryNumber: item.inventoryNumber, name: item.name, position: item.position,
        targetQuantity: item.targetQuantity, actualQuantity, result,
        notes: text(input.notes, 1000),
        ok: result === 'vorhanden' && actualQuantity >= item.targetQuantity,
      });
    }
    if (all(containerChecks).filter((entry) => entry.containerId === container.id).length
        >= MAX_CHECKS_PER_CONTAINER) {
      // Älteste Prüfprotokolle werden rollierend ersetzt.
      const raw = all(containerChecks);
      const oldest = raw.filter((entry) => entry.containerId === container.id)
        .sort((left, right) => String(left.checkedAt).localeCompare(String(right.checkedAt)))[0];
      raw.splice(raw.indexOf(oldest), 1);
    }
    const complete = results.every((entry) => entry.ok);
    const at = nowIso();
    const check = {
      id: `container-check-${randomUUID()}`,
      organizationId: container.organizationId, unitId: container.unitId,
      containerId: container.id,
      packListId: template.packListId, packListVersion: template.packListVersion,
      results, complete,
      deviationCount: results.filter((entry) => !entry.ok).length,
      notes: text(req.body.notes, 5000),
      checkedAt: at, checkedBy: req.user.username, checkedByName: req.user.name || req.user.username,
      defectIds: [],
    };
    // Mängel werden für die betroffenen Artikel mit Inventarnummer angelegt.
    // Fehlender Inhalt ohne Inventarnummer wird über den Status „Unvollständig“
    // und das Prüfprotokoll nachverfolgt.
    const defects = [];
    if (!complete && req.body.createDefect && defectManagement?.createFromContainerCheck) {
      const priority = DEFECT_PRIORITIES.includes(req.body.createDefect.priority)
        ? req.body.createDefect.priority : 'Normal';
      for (const entry of results.filter((candidate) => !candidate.ok
        && ITEM_ENTITY_TYPES.includes(candidate.entityType))) {
        if (!entityFor(req, entry.entityType, entry.entityId)) continue;
        const created = defectManagement.createFromContainerCheck({
          entityType: entry.entityType, entityId: entry.entityId,
          title: text(req.body.createDefect.title, 160)
            || `${entry.inventoryNumber} in Kiste ${container.code}: ${entry.result}`,
          description: [`Kistenprüfung ${container.code} ${container.name}: ${entry.result}, Soll ${entry.targetQuantity}, Ist ${entry.actualQuantity}${entry.notes ? ` (${entry.notes})` : ''}`,
            check.notes].filter(Boolean).join('\n\n').slice(0, 10_000),
          priority, user: req.user, request: req, checkId: check.id,
        });
        if (created?.error) continue;
        if (created?.report) defects.push(created.report);
      }
      check.defectIds = defects.map((entry) => entry.id);
    }
    all(containerChecks).push(check);
    container.completenessStatus = complete ? 'Vollständig' : 'Unvollständig';
    container.lastContainerCheckAt = at;
    logEvent('check', 'Container', {
      id: check.id, containerId: container.id, complete, deviations: check.deviationCount,
    }, req.user.username);
    return res.status(201).json({
      ...check,
      defectNumbers: defects.map((entry) => entry.defectNumber).filter(Boolean),
      container: publicContainer(req, container, { detail: true }),
    });
  });
}

module.exports = {
  createContainerGuard,
  registerContainerRoutes,
  migrateLegacyContainers,
  CHECK_RESULTS,
  COMPLETENESS_STATUSES,
  NOT_RELOCATABLE_MESSAGE,
};
