const { randomUUID } = require('node:crypto');
const { rawCollection } = require('./tenancy');
const { assessMaterialSafety, validDateOnly } = require('./material-safety');

// Kisten sind inventarisierte Einzelstücke mit dem Kennzeichen `isContainer`.
// Ihr Inhalt wird – analog zur Fahrzeugbeladung – als eigene Buchung geführt:
// Einzelstücke, Kleidung und verschachtelte Kisten wechseln physisch in die
// Kiste und werden gesperrt, Mengenartikel reservieren eine Teilmenge.

const CONTENT_ENTITY_TYPES = Object.freeze(['MaterialItem', 'ClothingItem']);
const CHECK_RESULTS = Object.freeze(['vorhanden', 'fehlt', 'beschädigt', 'abgelaufen']);
const COMPLETENESS_STATUSES = Object.freeze(['Ungeprüft', 'Vollständig', 'Unvollständig']);
const DEFECT_PRIORITIES = Object.freeze(['Niedrig', 'Normal', 'Hoch', 'Kritisch']);
const MAX_NESTING_DEPTH = 5;
const MAX_CONTENTS_PER_CONTAINER = 1_000;
const MAX_CONTENT_RECORDS = 100_000;
const MAX_CHECKS_PER_CONTAINER = 500;
const DEFAULT_EXPIRY_WARNING_DAYS = 30;
const ISSUE_BLOCKING_STATUSES = new Set(['Ausgegeben']);

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

function itemKey(entityType, entityId) {
  return `${entityType}:${entityId}`;
}

function createContainerGuard({ containerContents, materials, clothingItems }) {
  const all = (collection) => rawCollection(collection);

  function materialById(id) {
    return all(materials).find((entry) => entry.id === id) || null;
  }

  function entityFor(entityType, entityId) {
    if (entityType === 'MaterialItem') return materialById(entityId);
    if (entityType === 'ClothingItem') {
      return all(clothingItems).find((entry) => entry.id === entityId) || null;
    }
    return null;
  }

  function contentsOf(containerId) {
    return all(containerContents).filter((entry) => entry.containerId === containerId);
  }

  function packedQuantity(materialId) {
    return all(containerContents).reduce((sum, entry) =>
      entry.entityType === 'MaterialItem' && entry.entityId === materialId
        ? sum + number(entry.quantity) : sum, 0);
  }

  // Individuell geführte Artikel und Kisten können nur in genau einer Kiste liegen.
  function placementOf(entityType, entityId) {
    return all(containerContents).find((entry) => entry.entityType === entityType
      && entry.entityId === entityId && entry.individual === true) || null;
  }

  function containerOf(entityType, entityId) {
    const placement = placementOf(entityType, entityId);
    return placement ? materialById(placement.containerId) : null;
  }

  function lockedMessage(entityType, entityId) {
    const container = containerOf(entityType, entityId);
    if (!container) return null;
    return `Der Artikel liegt in der Kiste ${container.inventoryNumber} (${container.name}). `
      + 'Bitte zuerst aus der Kiste entnehmen.';
  }

  function ancestorsOf(containerId) {
    const result = [];
    let current = placementOf('MaterialItem', containerId);
    const seen = new Set([containerId]);
    while (current && !seen.has(current.containerId) && result.length < 50) {
      result.push(current.containerId);
      seen.add(current.containerId);
      current = placementOf('MaterialItem', current.containerId);
    }
    return result;
  }

  function nestingDepth(containerId) {
    return ancestorsOf(containerId).length;
  }

  function subtreeDepth(containerId, seen = new Set()) {
    if (seen.has(containerId)) return 0;
    seen.add(containerId);
    let deepest = 0;
    for (const entry of contentsOf(containerId)) {
      if (entry.entityType !== 'MaterialItem') continue;
      const child = materialById(entry.entityId);
      if (child?.isContainer) deepest = Math.max(deepest, 1 + subtreeDepth(child.id, seen));
    }
    return deepest;
  }

  function descendantEntries(containerId, seen = new Set()) {
    if (seen.has(containerId)) return [];
    seen.add(containerId);
    const result = [];
    for (const entry of contentsOf(containerId)) {
      result.push(entry);
      if (entry.entityType === 'MaterialItem') {
        const child = materialById(entry.entityId);
        if (child?.isContainer) result.push(...descendantEntries(child.id, seen));
      }
    }
    return result;
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

  // Ein Container ist sicherheitsbedingt gesperrt, wenn ein sicherheitskritischer
  // Inhalt gesperrt ist. Abgelaufene Inhalte werden gemeldet, blockieren aber nicht,
  // damit eine Einsatzkiste nicht wegen eines einzelnen Pflasters ausfällt.
  function contentSafety(containerId, at = new Date()) {
    const container = materialById(containerId);
    const warningDays = warningDaysFor(container);
    const reasons = [];
    const warnings = [];
    let expired = 0;
    let expiringSoon = 0;
    for (const entry of descendantEntries(containerId)) {
      const entity = entityFor(entry.entityType, entry.entityId);
      const label = entity?.inventoryNumber || entry.inventoryNumberSnapshot || entry.entityId;
      if (entry.entityType === 'MaterialItem' && entity && !entity.isContainer) {
        const safety = assessMaterialSafety(entity, at);
        if (safety.blocked) {
          reasons.push(`Inhalt ${label}: ${safety.reasons.join(' ')}`.trim());
        }
      }
      const expiry = expiryState(entry, warningDays, at);
      if (expiry === 'abgelaufen') {
        expired += 1;
        warnings.push(`Inhalt ${label} ist seit ${entry.expiresAt} abgelaufen.`);
      } else if (expiry) {
        expiringSoon += 1;
        warnings.push(`Inhalt ${label} läuft am ${entry.expiresAt} ab.`);
      }
    }
    return { blocked: reasons.length > 0, reasons, warnings, expired, expiringSoon };
  }

  function destinationOf(container) {
    return {
      locationId: container.locationId || null,
      stockStructureId: container.stockStructureId || null,
    };
  }

  // Bewegt den physischen Inhalt (rekursiv) an den aktuellen Ort der Kiste.
  function syncContents(containerId, { actor = 'System', movements = null, nextId = null,
    reason = 'container-follow', seen = new Set() } = {}) {
    const container = materialById(containerId);
    if (!container?.isContainer || seen.has(containerId)) return 0;
    seen.add(containerId);
    const target = destinationOf(container);
    let changed = 0;
    for (const entry of contentsOf(containerId)) {
      if (!entry.individual) continue;
      const entity = entityFor(entry.entityType, entry.entityId);
      if (!entity) continue;
      if (entity.locationId !== target.locationId
          || (entity.stockStructureId || null) !== target.stockStructureId) {
        const from = { locationId: entity.locationId || null, stockStructureId: entity.stockStructureId || null };
        entity.locationId = target.locationId;
        entity.stockStructureId = target.stockStructureId;
        changed += 1;
        if (entry.entityType === 'MaterialItem' && movements && nextId) {
          all(movements).push({
            id: nextId('movement', all(movements)), materialId: entity.id,
            action: reason, quantity: 1,
            fromLocationId: from.locationId, fromStockStructureId: from.stockStructureId,
            toLocationId: target.locationId, toStockStructureId: target.stockStructureId,
            containerId, notes: `Mit Kiste ${container.inventoryNumber} bewegt.`,
            actor, createdAt: new Date().toISOString(),
            organizationId: entity.organizationId, unitId: entity.unitId,
          });
        }
      }
      if (entry.entityType === 'MaterialItem' && entity.isContainer) {
        changed += syncContents(entity.id, { actor, movements, nextId, reason, seen });
      }
    }
    return changed;
  }

  function syncMany(ids, options = {}) {
    let changed = 0;
    for (const id of ids) {
      const material = materialById(id);
      if (material?.isContainer) changed += syncContents(id, options);
    }
    return changed;
  }

  return {
    packedQuantity,
    placementOf,
    containerOf,
    lockedMessage,
    ancestorsOf,
    nestingDepth,
    subtreeDepth,
    descendantEntries,
    contentsOf,
    contentSafety,
    expiryState,
    warningDaysFor,
    syncContents,
    syncMany,
    hasContents: (containerId) => contentsOf(containerId).length > 0,
  };
}

function registerContainerRoutes({
  app, authMiddleware, requirePermission, hasPermission,
  containerContents, containerPackLists, containerChecks,
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
    return all(materials).find((entry) => entry.id === id && entry.isContainer === true
      && !entry.archived && ownedBy(req, entry)) || null;
  }

  function locationName(id) {
    return all(locations).find((entry) => entry.id === id)?.name || null;
  }

  function stockName(id) {
    const entry = all(stockStructures).find((candidate) => candidate.id === id);
    return entry?.path || entry?.name || null;
  }

  function vehicleAssignment(materialId) {
    return all(vehicleLoadAssignments).find((entry) => entry.materialId === materialId) || null;
  }

  function entityLabel(entityType, entity, entry = {}) {
    return {
      inventoryNumber: entity?.inventoryNumber || entry.inventoryNumberSnapshot || null,
      name: entity?.name || entry.nameSnapshot || 'Gelöschter Artikel',
    };
  }

  function entityFor(entityType, entityId) {
    if (entityType === 'MaterialItem') return all(materials).find((entry) => entry.id === entityId) || null;
    if (entityType === 'ClothingItem') return all(clothingItems).find((entry) => entry.id === entityId) || null;
    return null;
  }

  function activePackList(containerId) {
    return all(containerPackLists).find((entry) => entry.containerId === containerId
      && entry.status === 'Aktiv') || null;
  }

  function actualQuantities(containerId) {
    const result = new Map();
    for (const entry of guard.contentsOf(containerId)) {
      const key = itemKey(entry.entityType, entry.entityId);
      result.set(key, (result.get(key) || 0) + number(entry.quantity));
    }
    return result;
  }

  function packListDeviation(container) {
    const list = activePackList(container.id);
    if (!list) return null;
    const actual = actualQuantities(container.id);
    const rows = list.items.map((item) => {
      const key = itemKey(item.entityType, item.entityId);
      const entity = entityFor(item.entityType, item.entityId);
      const actualQuantity = actual.get(key) || 0;
      return {
        key, entityType: item.entityType, entityId: item.entityId,
        ...entityLabel(item.entityType, entity, item),
        position: item.position || '', targetQuantity: item.targetQuantity,
        actualQuantity, deviation: actualQuantity - item.targetQuantity,
        unit: entity?.unit || 'Stück',
      };
    });
    const listed = new Set(rows.map((row) => row.key));
    const extra = [...actual.entries()].filter(([key]) => !listed.has(key)).map(([key, quantity]) => {
      const [entityType, entityId] = key.split(/:(.*)/s);
      const entity = entityFor(entityType, entityId);
      return {
        key, entityType, entityId, ...entityLabel(entityType, entity),
        position: '', targetQuantity: 0, actualQuantity: quantity, deviation: quantity,
        unit: entity?.unit || 'Stück',
      };
    });
    return {
      packListId: list.id, version: list.version, name: list.name,
      rows: [...rows, ...extra],
      missingCount: rows.filter((row) => row.deviation < 0).length,
      extraCount: extra.length,
      complete: rows.every((row) => row.deviation >= 0),
    };
  }

  function publicContent(entry, container) {
    const entity = entityFor(entry.entityType, entry.entityId);
    const warningDays = guard.warningDaysFor(container);
    return {
      ...entry,
      ...entityLabel(entry.entityType, entity, entry),
      unit: entity?.unit || 'Stück',
      itemType: entry.entityType === 'ClothingItem' ? 'individual' : entity?.itemType || 'individual',
      size: entry.entityType === 'ClothingItem' ? entity?.size || null : undefined,
      isContainer: entity?.isContainer === true,
      nestedContentCount: entity?.isContainer ? guard.contentsOf(entity.id).length : 0,
      safetyStatus: entry.entityType === 'MaterialItem' && entity && !entity.isContainer
        ? assessMaterialSafety(entity) : null,
      expiryState: guard.expiryState(entry, warningDays),
    };
  }

  function publicContainer(container, { detail = false } = {}) {
    const contents = guard.contentsOf(container.id);
    const parent = guard.containerOf('MaterialItem', container.id);
    const assignment = vehicleAssignment(container.id);
    const safety = guard.contentSafety(container.id);
    const deviation = packListDeviation(container);
    const list = activePackList(container.id);
    const checks = all(containerChecks).filter((entry) => entry.containerId === container.id);
    const lastCheck = checks.reduce((latest, entry) =>
      !latest || entry.checkedAt > latest.checkedAt ? entry : latest, null);
    const result = {
      id: container.id,
      inventoryNumber: container.inventoryNumber,
      name: container.name,
      containerType: container.containerType || '',
      compartments: container.containerCompartments || [],
      containerNotes: container.containerNotes || '',
      expiryWarningDays: guard.warningDaysFor(container),
      status: container.status,
      issued: number(container.issuedQuantity) > 0,
      locationId: container.locationId,
      locationName: locationName(container.locationId),
      stockStructureId: container.stockStructureId || null,
      stockStructureName: stockName(container.stockStructureId),
      vehicleId: assignment?.vehicleId || null,
      parentContainerId: parent?.id || null,
      parentContainerName: parent ? `${parent.inventoryNumber} ${parent.name}` : null,
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
      safetyCritical: container.safetyCritical === true,
      materialSafety: assessMaterialSafety(container),
    };
    if (detail) {
      result.contents = contents.map((entry) => publicContent(entry, container));
      result.packLists = all(containerPackLists).filter((entry) => entry.containerId === container.id)
        .sort((left, right) => Number(right.version) - Number(left.version));
      result.packListDeviation = deviation;
      result.checks = checks.slice().sort((left, right) =>
        String(right.checkedAt).localeCompare(String(left.checkedAt))).slice(0, 50);
      result.checkTemplate = checkTemplate(container);
    }
    return result;
  }

  // Prüfgrundlage: aktive Packliste, sonst der aktuelle Ist-Inhalt.
  function checkTemplate(container) {
    const list = activePackList(container.id);
    const actual = actualQuantities(container.id);
    const contents = guard.contentsOf(container.id);
    const expiryByKey = new Map();
    for (const entry of contents) {
      const key = itemKey(entry.entityType, entry.entityId);
      if (entry.expiresAt && (!expiryByKey.has(key) || entry.expiresAt < expiryByKey.get(key))) {
        expiryByKey.set(key, entry.expiresAt);
      }
    }
    const source = list ? list.items : [...actual.entries()].map(([key, quantity]) => {
      const [entityType, entityId] = key.split(/:(.*)/s);
      const entry = contents.find((candidate) => itemKey(candidate.entityType, candidate.entityId) === key);
      return { entityType, entityId, targetQuantity: quantity, position: entry?.position || '' };
    });
    return {
      packListId: list?.id || null,
      packListVersion: list?.version || null,
      items: source.map((item) => {
        const key = itemKey(item.entityType, item.entityId);
        const entity = entityFor(item.entityType, item.entityId);
        return {
          key, entityType: item.entityType, entityId: item.entityId,
          ...entityLabel(item.entityType, entity, item),
          unit: entity?.unit || 'Stück',
          position: item.position || '',
          targetQuantity: number(item.targetQuantity),
          expectedQuantity: actual.get(key) || 0,
          earliestExpiry: expiryByKey.get(key) || null,
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

  function availableMaterialQuantity(material, ignoredContentId = null) {
    const packed = all(containerContents).reduce((sum, entry) =>
      entry.entityType === 'MaterialItem' && entry.entityId === material.id
        && entry.id !== ignoredContentId ? sum + number(entry.quantity) : sum, 0);
    const loaded = all(vehicleLoadAssignments).reduce((sum, entry) =>
      entry.materialId === material.id ? sum + number(entry.quantity) : sum, 0);
    return number(material.quantity, 1) - number(material.issuedQuantity) - loaded - packed;
  }

  function packBlocker(req, container, entityType, entity, quantity) {
    if (!entity || !ownedBy(req, entity) || entity.archived) {
      return { status: 400, error: 'Der Artikel ist ungültig oder gehört nicht zu dieser Gliederung.' };
    }
    if (entityType === 'ClothingItem') {
      if (!hasPermission(req.user, 'clothing.read')) {
        return { status: 403, error: 'Für Kleiderkammer-Artikel fehlt die Berechtigung.' };
      }
      if (entity.status === 'Ausgegeben' || entity.assignedPerson) {
        return { status: 409, error: 'Ausgegebene Kleidung kann nicht in eine Kiste gepackt werden.' };
      }
      if (quantity !== 1) return { status: 400, error: 'Kleidungsstücke werden einzeln gepackt.' };
      if (guard.placementOf('ClothingItem', entity.id)) {
        return { status: 409, error: guard.lockedMessage('ClothingItem', entity.id) };
      }
      return null;
    }
    if (entity.id === container.id) return { status: 409, error: 'Eine Kiste kann nicht in sich selbst gepackt werden.' };
    if (entity.isContainer) {
      if (guard.ancestorsOf(container.id).includes(entity.id)) {
        return { status: 409, error: 'Eine übergeordnete Kiste kann nicht in eine ihrer Unterkisten gepackt werden.' };
      }
      if (guard.nestingDepth(container.id) + 1 + guard.subtreeDepth(entity.id) > MAX_NESTING_DEPTH) {
        return { status: 409, error: `Kisten dürfen höchstens ${MAX_NESTING_DEPTH} Ebenen tief verschachtelt werden.` };
      }
    }
    if (entity.itemType === 'individual' || entity.isContainer) {
      if (quantity !== 1) return { status: 400, error: 'Einzelstücke werden einzeln gepackt.' };
      if (guard.placementOf('MaterialItem', entity.id)) {
        return { status: 409, error: guard.lockedMessage('MaterialItem', entity.id) };
      }
      if (number(entity.issuedQuantity) > 0 || vehicleAssignment(entity.id)) {
        return { status: 409, error: 'Ausgegebenes oder auf Fahrzeuge geladenes Material kann nicht gepackt werden.' };
      }
    } else if (!Number.isInteger(quantity) || quantity < 1 || quantity > availableMaterialQuantity(entity)) {
      return { status: 409, error: 'Die gewünschte Menge ist nicht frei verfügbar.' };
    }
    if (['Ausgesondert', 'Verloren'].includes(entity.status)) {
      return { status: 409, error: 'Ausgesondertes oder verlorenes Material kann nicht gepackt werden.' };
    }
    return null;
  }

  function containerEditable(container) {
    if (number(container.issuedQuantity) > 0 || ISSUE_BLOCKING_STATUSES.has(container.status)) {
      return 'Der Inhalt einer ausgegebenen Kiste kann erst nach der Rückgabe geändert werden.';
    }
    return null;
  }

  function position(container, value) {
    const result = text(value, 160);
    const compartments = container.containerCompartments || [];
    if (compartments.length && result && !compartments.includes(result)) {
      return { error: 'Bitte ein definiertes Kistenfach wählen.' };
    }
    return { value: result };
  }

  // ---- Kisten-Stammdaten --------------------------------------------------

  app.get('/api/containers', authMiddleware, requirePermission('containers.read'), (req, res) => {
    const query = text(req.query.query, 120).toLowerCase();
    const limit = Math.min(Math.max(Number(req.query.limit) || 500, 1), 1000);
    const result = all(materials).filter((entry) => entry.isContainer === true && !entry.archived
      && ownedBy(req, entry)
      && (!query || [entry.inventoryNumber, entry.name, entry.containerType]
        .some((value) => String(value || '').toLowerCase().includes(query))))
      .slice(0, limit).map((entry) => publicContainer(entry));
    return res.json(result);
  });

  app.get('/api/containers/expiring', authMiddleware, requirePermission('containers.read'), (req, res) => {
    const days = Math.min(Math.max(Number.parseInt(req.query.days, 10) || DEFAULT_EXPIRY_WARNING_DAYS, 0), 365);
    const limitDate = addDays(todayIso(), days);
    const result = all(containerContents).filter((entry) => ownedBy(req, entry)
      && entry.expiresAt && entry.expiresAt <= limitDate)
      .map((entry) => {
        const container = all(materials).find((candidate) => candidate.id === entry.containerId);
        return {
          ...publicContent(entry, container),
          containerInventoryNumber: container?.inventoryNumber || null,
          containerName: container?.name || null,
          expiryState: entry.expiresAt < todayIso() ? 'abgelaufen' : 'läuft bald ab',
        };
      })
      .sort((left, right) => String(left.expiresAt).localeCompare(String(right.expiresAt)));
    return res.json(result);
  });

  // Scan einer Inventarnummer: liefert die Kiste selbst oder die Kiste, in der
  // der gescannte Artikel liegt.
  app.get('/api/containers/lookup', authMiddleware, requirePermission('containers.read'), (req, res) => {
    const code = text(req.query.code, 128).toLowerCase();
    if (!code) return res.status(400).json({ error: 'Bitte eine Inventarnummer angeben.' });
    const material = all(materials).find((entry) => ownedBy(req, entry) && !entry.archived
      && String(entry.inventoryNumber || '').toLowerCase() === code);
    const clothing = material ? null : all(clothingItems).find((entry) => ownedBy(req, entry)
      && !entry.archived && String(entry.inventoryNumber || '').toLowerCase() === code);
    if (material?.isContainer) {
      return res.json({ match: 'container', container: publicContainer(material, { detail: true }) });
    }
    const entityType = material ? 'MaterialItem' : 'ClothingItem';
    const entity = material || clothing;
    const parent = entity ? guard.containerOf(entityType, entity.id) : null;
    if (parent && ownedBy(req, parent)) {
      return res.json({
        match: 'content',
        entityType, entityId: entity.id,
        container: publicContainer(parent, { detail: true }),
      });
    }
    if (entity) {
      return res.json({ match: 'item', entityType, entityId: entity.id,
        inventoryNumber: entity.inventoryNumber, name: entity.name });
    }
    return res.status(404).json({ error: 'Zu dieser Inventarnummer wurde keine Kiste gefunden.' });
  });

  app.get('/api/containers/:id', authMiddleware, requirePermission('containers.read'), (req, res) => {
    const container = ownedContainer(req, req.params.id);
    if (!container) return res.status(404).json({ error: 'Kiste nicht gefunden.' });
    return res.json(publicContainer(container, { detail: true }));
  });

  function containerSettings(body, existing = {}) {
    const containerType = text(body.containerType ?? existing.containerType, 120);
    if (body.compartments !== undefined && (!Array.isArray(body.compartments)
      || body.compartments.length > 100 || body.compartments.some((entry) =>
        typeof entry !== 'string' || !entry.trim() || entry.trim().length > 160))) {
      return { error: 'Bitte höchstens 100 Kistenfächer mit jeweils maximal 160 Zeichen angeben.' };
    }
    const compartments = uniqueTexts(body.compartments ?? existing.containerCompartments);
    const warning = body.expiryWarningDays ?? existing.expiryWarningDays ?? DEFAULT_EXPIRY_WARNING_DAYS;
    const expiryWarningDays = Number(warning);
    if (!Number.isInteger(expiryWarningDays) || expiryWarningDays < 0 || expiryWarningDays > 365) {
      return { error: 'Die Vorwarnzeit für Ablaufdaten muss zwischen 0 und 365 Tagen liegen.' };
    }
    return {
      containerType,
      containerCompartments: compartments,
      containerNotes: text(body.notes ?? existing.containerNotes, 5000),
      expiryWarningDays,
    };
  }

  app.post('/api/containers', authMiddleware, requirePermission('containers.manage'), (req, res) => {
    const material = all(materials).find((entry) => entry.id === text(req.body.materialId, 64)
      && ownedBy(req, entry) && !entry.archived);
    if (!material) return res.status(404).json({ error: 'Material nicht gefunden.' });
    if (material.isContainer) return res.status(409).json({ error: 'Der Artikel ist bereits als Kiste gekennzeichnet.' });
    if (material.itemType !== 'individual') {
      return res.status(409).json({ error: 'Nur individuell inventarisierte Einzelstücke können Kisten sein.' });
    }
    const settings = containerSettings(req.body);
    if (settings.error) return res.status(400).json({ error: settings.error });
    Object.assign(material, settings, {
      isContainer: true, completenessStatus: 'Ungeprüft', updatedAt: nowIso(),
    });
    logEvent('create', 'Container', {
      id: material.id, inventoryNumber: material.inventoryNumber, itemName: material.name,
    }, req.user.username);
    return res.status(201).json(publicContainer(material, { detail: true }));
  });

  app.put('/api/containers/:id', authMiddleware, requirePermission('containers.manage'), (req, res) => {
    const container = ownedContainer(req, req.params.id);
    if (!container) return res.status(404).json({ error: 'Kiste nicht gefunden.' });
    const settings = containerSettings(req.body, container);
    if (settings.error) return res.status(400).json({ error: settings.error });
    const removed = (container.containerCompartments || [])
      .filter((entry) => !settings.containerCompartments.includes(entry));
    if (guard.contentsOf(container.id).some((entry) => removed.includes(entry.position))) {
      return res.status(409).json({ error: 'Belegte Kistenfächer können nicht entfernt werden.' });
    }
    Object.assign(container, settings, { updatedAt: nowIso() });
    logEvent('update', 'Container', { id: container.id }, req.user.username);
    return res.json(publicContainer(container, { detail: true }));
  });

  app.delete('/api/containers/:id', authMiddleware, requirePermission('containers.manage'), (req, res) => {
    const container = ownedContainer(req, req.params.id);
    if (!container) return res.status(404).json({ error: 'Kiste nicht gefunden.' });
    if (guard.hasContents(container.id)) {
      return res.status(409).json({ error: 'Nur leere Kisten können aufgelöst werden.' });
    }
    container.isContainer = false;
    container.updatedAt = nowIso();
    for (const list of all(containerPackLists).filter((entry) => entry.containerId === container.id)) {
      if (list.status === 'Aktiv') list.status = 'Ersetzt';
    }
    logEvent('delete', 'Container', { id: container.id }, req.user.username);
    return res.json({ success: true, id: container.id });
  });

  // ---- Packen und Entnehmen ----------------------------------------------

  app.get('/api/containers/:id/candidates', authMiddleware, requirePermission('containers.pack'), (req, res) => {
    const container = ownedContainer(req, req.params.id);
    if (!container) return res.status(404).json({ error: 'Kiste nicht gefunden.' });
    const query = text(req.query.query, 120).toLowerCase();
    const matches = (entry) => !query
      || `${entry.inventoryNumber} ${entry.name}`.toLowerCase().includes(query);
    const ancestors = new Set(guard.ancestorsOf(container.id));
    const materialCandidates = all(materials).filter((entry) => ownedBy(req, entry)
      && !entry.archived && entry.id !== container.id && !ancestors.has(entry.id) && matches(entry)
      && !['Ausgesondert', 'Verloren'].includes(entry.status))
      .filter((entry) => (entry.itemType === 'individual' || entry.isContainer)
        ? !guard.placementOf('MaterialItem', entry.id) && number(entry.issuedQuantity) === 0
          && !vehicleAssignment(entry.id)
        : availableMaterialQuantity(entry) > 0)
      .slice(0, 100)
      .map((entry) => ({
        entityType: 'MaterialItem', entityId: entry.id,
        inventoryNumber: entry.inventoryNumber, name: entry.name,
        itemType: entry.isContainer ? 'individual' : entry.itemType, unit: entry.unit || 'Stück',
        isContainer: entry.isContainer === true,
        availableQuantity: entry.itemType === 'individual' || entry.isContainer
          ? 1 : availableMaterialQuantity(entry),
        locationName: locationName(entry.locationId),
      }));
    const clothingCandidates = hasPermission(req.user, 'clothing.read')
      ? all(clothingItems).filter((entry) => ownedBy(req, entry) && !entry.archived && matches(entry)
        && entry.status !== 'Ausgegeben' && !entry.assignedPerson
        && !guard.placementOf('ClothingItem', entry.id))
        .slice(0, 100)
        .map((entry) => ({
          entityType: 'ClothingItem', entityId: entry.id,
          inventoryNumber: entry.inventoryNumber, name: entry.name, size: entry.size || null,
          itemType: 'individual', unit: 'Stück', isContainer: false, availableQuantity: 1,
          locationName: locationName(entry.locationId),
        }))
      : [];
    return res.json([...materialCandidates, ...clothingCandidates]);
  });

  app.post('/api/containers/:id/contents', authMiddleware, requirePermission('containers.pack'), (req, res) => {
    const container = ownedContainer(req, req.params.id);
    if (!container) return res.status(404).json({ error: 'Kiste nicht gefunden.' });
    const locked = containerEditable(container);
    if (locked) return res.status(409).json({ error: locked });
    if (guard.contentsOf(container.id).length >= MAX_CONTENTS_PER_CONTAINER
        || all(containerContents).length >= MAX_CONTENT_RECORDS) {
      return res.status(507).json({ error: 'Die maximale Anzahl an Kisteninhalten ist erreicht.' });
    }
    const entityType = text(req.body.entityType || 'MaterialItem', 32);
    if (!CONTENT_ENTITY_TYPES.includes(entityType)) {
      return res.status(400).json({ error: 'Die Artikelart ist ungültig.' });
    }
    const entity = entityFor(entityType, text(req.body.entityId ?? req.body.materialId, 64));
    const quantity = Number(req.body.quantity ?? 1);
    const blocker = packBlocker(req, container, entityType, entity, quantity);
    if (blocker) return res.status(blocker.status).json({ error: blocker.error });
    const expiry = validExpiry(req.body.expiresAt);
    if (expiry.error) return res.status(400).json({ error: expiry.error });
    const slot = position(container, req.body.position);
    if (slot.error) return res.status(400).json({ error: slot.error });
    const individual = entityType === 'ClothingItem' || entity.itemType === 'individual'
      || entity.isContainer === true;
    const at = nowIso();
    const entry = {
      id: `container-content-${randomUUID()}`,
      organizationId: container.organizationId, unitId: container.unitId,
      containerId: container.id, entityType, entityId: entity.id,
      individual, quantity,
      position: slot.value,
      expiresAt: expiry.value ?? null,
      batchNumber: text(req.body.batchNumber, 120),
      notes: text(req.body.notes, 1000),
      previousLocationId: entity.locationId || null,
      previousStockStructureId: entity.stockStructureId || null,
      inventoryNumberSnapshot: entity.inventoryNumber,
      nameSnapshot: entity.name,
      createdAt: at, createdBy: req.user.username,
    };
    all(containerContents).push(entry);
    if (individual) {
      entity.locationId = container.locationId;
      entity.stockStructureId = container.stockStructureId || null;
      if (entity.isContainer) {
        guard.syncContents(entity.id, { actor: req.user.username, movements: materialMovements, nextId });
      }
    }
    if (entityType === 'MaterialItem') {
      all(materialMovements).push({
        id: nextId('movement', all(materialMovements)), materialId: entity.id,
        action: 'container-pack', quantity,
        fromLocationId: entry.previousLocationId, fromStockStructureId: entry.previousStockStructureId,
        toLocationId: individual ? container.locationId : entry.previousLocationId,
        toStockStructureId: individual ? container.stockStructureId || null : entry.previousStockStructureId,
        containerId: container.id, notes: entry.notes, actor: req.user.username, createdAt: at,
        organizationId: entity.organizationId, unitId: entity.unitId,
      });
    }
    container.completenessStatus = 'Ungeprüft';
    logEvent('pack', 'Container', {
      id: entry.id, containerId: container.id, entityType, entityId: entity.id, quantity,
    }, req.user.username);
    return res.status(201).json(publicContent(entry, container));
  });

  app.put('/api/containers/:id/contents/:contentId', authMiddleware,
    requirePermission('containers.pack'), (req, res) => {
      const container = ownedContainer(req, req.params.id);
      const entry = all(containerContents).find((candidate) => candidate.id === req.params.contentId
        && candidate.containerId === container?.id);
      if (!entry) return res.status(404).json({ error: 'Kisteninhalt nicht gefunden.' });
      const expiry = validExpiry(req.body.expiresAt);
      if (expiry.error) return res.status(400).json({ error: expiry.error });
      const slot = req.body.position === undefined ? { value: entry.position } : position(container, req.body.position);
      if (slot.error) return res.status(400).json({ error: slot.error });
      if (req.body.quantity !== undefined && Number(req.body.quantity) !== number(entry.quantity)) {
        const locked = containerEditable(container);
        if (locked) return res.status(409).json({ error: locked });
        const quantity = Number(req.body.quantity);
        const material = entry.entityType === 'MaterialItem' ? entityFor('MaterialItem', entry.entityId) : null;
        if (entry.individual || !material) {
          return res.status(400).json({ error: 'Nur bei Mengenartikeln kann die Menge geändert werden.' });
        }
        if (!Number.isInteger(quantity) || quantity < 1
            || quantity > availableMaterialQuantity(material, entry.id)) {
          return res.status(409).json({ error: 'Die gewünschte Menge ist nicht frei verfügbar.' });
        }
        const difference = quantity - number(entry.quantity);
        entry.quantity = quantity;
        all(materialMovements).push({
          id: nextId('movement', all(materialMovements)), materialId: material.id,
          action: difference > 0 ? 'container-pack' : 'container-unpack',
          quantity: Math.abs(difference), containerId: container.id,
          notes: 'Menge in der Kiste angepasst.', actor: req.user.username, createdAt: nowIso(),
          organizationId: material.organizationId, unitId: material.unitId,
        });
        container.completenessStatus = 'Ungeprüft';
      }
      Object.assign(entry, {
        position: slot.value,
        expiresAt: expiry.value === undefined ? entry.expiresAt : expiry.value,
        batchNumber: text(req.body.batchNumber ?? entry.batchNumber, 120),
        notes: text(req.body.notes ?? entry.notes, 1000),
        updatedAt: nowIso(), updatedBy: req.user.username,
      });
      logEvent('update-content', 'Container', { id: entry.id, containerId: container.id }, req.user.username);
      return res.json(publicContent(entry, container));
    });

  app.post('/api/containers/:id/contents/:contentId/unpack', authMiddleware,
    requirePermission('containers.pack'), (req, res) => {
      const container = ownedContainer(req, req.params.id);
      const contents = all(containerContents);
      const index = contents.findIndex((candidate) => candidate.id === req.params.contentId
        && candidate.containerId === container?.id);
      if (index < 0) return res.status(404).json({ error: 'Kisteninhalt nicht gefunden.' });
      const locked = containerEditable(container);
      if (locked) return res.status(409).json({ error: locked });
      const entry = contents[index];
      const entity = entityFor(entry.entityType, entry.entityId);
      let destination = null;
      let destinationStockStructureId = null;
      if (entry.individual && entity) {
        const requestedLocation = text(req.body.locationId, 64);
        const candidates = requestedLocation
          ? [[requestedLocation, text(req.body.stockStructureId, 64) || null]]
          : [[entry.previousLocationId, entry.previousStockStructureId],
            [container.locationId, container.stockStructureId]];
        for (const [locationId, stockStructureId] of candidates) {
          const location = all(locations).find((candidate) => candidate.id === locationId
            && candidate.organizationId === container.organizationId && !candidate.vehicleId);
          if (!location) continue;
          const stockValid = !stockStructureId || all(stockStructures).some((candidate) =>
            candidate.id === stockStructureId && candidate.locationId === location.id);
          if (!stockValid && requestedLocation) break;
          destination = location;
          destinationStockStructureId = stockValid ? stockStructureId || null : null;
          break;
        }
        if (!destination) return res.status(400).json({ error: 'Ein gültiger Ziel-Lagerort ist erforderlich.' });
      }
      contents.splice(index, 1);
      const at = nowIso();
      if (entry.individual && entity) {
        const from = { locationId: entity.locationId || null, stockStructureId: entity.stockStructureId || null };
        entity.locationId = destination.id;
        entity.stockStructureId = destinationStockStructureId;
        if (entity.isContainer) {
          guard.syncContents(entity.id, { actor: req.user.username, movements: materialMovements, nextId });
        }
        if (entry.entityType === 'MaterialItem') {
          all(materialMovements).push({
            id: nextId('movement', all(materialMovements)), materialId: entity.id,
            action: 'container-unpack', quantity: 1,
            fromLocationId: from.locationId, fromStockStructureId: from.stockStructureId,
            toLocationId: destination.id, toStockStructureId: destinationStockStructureId,
            containerId: container.id, notes: text(req.body.notes, 1000),
            actor: req.user.username, createdAt: at,
            organizationId: entity.organizationId, unitId: entity.unitId,
          });
        }
      } else if (entity && entry.entityType === 'MaterialItem') {
        all(materialMovements).push({
          id: nextId('movement', all(materialMovements)), materialId: entity.id,
          action: 'container-unpack', quantity: entry.quantity, containerId: container.id,
          notes: text(req.body.notes, 1000), actor: req.user.username, createdAt: at,
          organizationId: entity.organizationId, unitId: entity.unitId,
        });
      }
      container.completenessStatus = 'Ungeprüft';
      logEvent('unpack', 'Container', {
        id: entry.id, containerId: container.id, entityType: entry.entityType, entityId: entry.entityId,
      }, req.user.username);
      return res.json({ success: true });
    });

  // ---- Packlisten ----------------------------------------------------------

  app.post('/api/containers/:id/pack-lists', authMiddleware,
    requirePermission('containers.packlists'), (req, res) => {
      const container = ownedContainer(req, req.params.id);
      if (!container) return res.status(404).json({ error: 'Kiste nicht gefunden.' });
      const name = text(req.body.name || 'Packliste', 160);
      let items = Array.isArray(req.body.items) ? req.body.items : [];
      if (req.body.fromContents === true) {
        const grouped = new Map();
        for (const entry of guard.contentsOf(container.id)) {
          const key = itemKey(entry.entityType, entry.entityId);
          const current = grouped.get(key) || {
            entityType: entry.entityType, entityId: entry.entityId,
            targetQuantity: 0, position: entry.position,
          };
          current.targetQuantity += number(entry.quantity);
          grouped.set(key, current);
        }
        items = [...grouped.values()];
      }
      if (!name || items.length > MAX_CONTENTS_PER_CONTAINER) {
        return res.status(400).json({ error: 'Bezeichnung oder Umfang der Packliste ist ungültig.' });
      }
      const normalized = [];
      const seen = new Set();
      for (const item of items) {
        const entityType = text(item?.entityType || 'MaterialItem', 32);
        const entity = CONTENT_ENTITY_TYPES.includes(entityType)
          ? entityFor(entityType, text(item?.entityId ?? item?.materialId, 64)) : null;
        const targetQuantity = Number(item?.targetQuantity);
        if (!entity || !ownedBy(req, entity) || entity.id === container.id
            || !Number.isInteger(targetQuantity) || targetQuantity < 1
            || ((entityType === 'ClothingItem' || entity.itemType === 'individual') && targetQuantity !== 1)) {
          return res.status(400).json({ error: 'Jede Listenposition benötigt einen gültigen Artikel und eine Sollmenge.' });
        }
        const key = itemKey(entityType, entity.id);
        if (seen.has(key)) return res.status(400).json({ error: 'Jeder Artikel darf nur einmal in der Packliste stehen.' });
        seen.add(key);
        normalized.push({
          entityType, entityId: entity.id, targetQuantity,
          position: text(item.position, 160), notes: text(item.notes, 1000),
          inventoryNumberSnapshot: entity.inventoryNumber, nameSnapshot: entity.name,
        });
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
      const template = checkTemplate(container);
      const list = activePackList(container.id);
      const { PDFDocument, StandardFonts, rgb } = pdfLib();
      const pdf = await PDFDocument.create();
      const font = await pdf.embedFont(StandardFonts.Helvetica);
      const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
      let page = pdf.addPage([595, 842]); let y = 800;
      // Standardschriften können nur WinAnsi-Zeichen kodieren.
      const safe = (value) => String(value ?? '').replace(/[^\x20-\x7E -ÿ€]/g, '?');
      const line = (value, options = {}) => {
        if (y < 55) { page = pdf.addPage([595, 842]); y = 800; }
        page.drawText(safe(value).slice(0, 110), {
          x: options.x || 42, y, size: options.size || 9,
          font: options.bold ? bold : font, color: options.color || rgb(0, 0, 0),
        });
        y -= options.gap || 15;
      };
      line('Kisten-Packliste', { size: 18, bold: true, gap: 25 });
      line(`Kiste: ${container.inventoryNumber} | ${container.name}`, { bold: true });
      line(`Kistenart: ${container.containerType || '-'} | Standort: ${locationName(container.locationId) || '-'}${container.stockStructureId ? ` / ${stockName(container.stockStructureId) || ''}` : ''}`);
      line(`Liste: ${list ? `${list.name} | Version ${list.version}` : 'Keine aktive Packliste (Ist-Inhalt)'} | Stand: ${new Date().toLocaleString('de-DE', { timeZone: 'Europe/Berlin' })}`);
      y -= 8;
      line('Inventarnummer | Bezeichnung | Fach | Soll | Ist | Abw. | Ablauf | Geprüft', { bold: true, gap: 18 });
      for (const item of template.items) {
        const deviation = item.expectedQuantity - item.targetQuantity;
        line(`${item.inventoryNumber || '-'} | ${item.name} | ${item.position || '-'} | ${item.targetQuantity} | ${item.expectedQuantity} | ${deviation >= 0 ? '+' : ''}${deviation} | ${item.earliestExpiry || '-'} | [  ]`,
          { color: deviation < 0 ? rgb(0.75, 0, 0) : rgb(0, 0, 0) });
      }
      y -= 20;
      line('Geprüft am: ____________________   durch: ______________________________');
      line('Unterschrift: ________________________________________________________');
      const bytes = await pdf.save();
      logEvent('print', 'Container', { containerId: container.id, packListId: list?.id || null }, req.user.username);
      return res.json({
        fileName: `packliste-${String(container.inventoryNumber).replace(/[^A-Za-z0-9_-]/g, '-')}${list ? `-v${list.version}` : ''}.pdf`,
        mimeType: 'application/pdf', fileBase64: Buffer.from(bytes).toString('base64'),
      });
    });

  // ---- Vollständigkeitsprüfung -------------------------------------------

  app.post('/api/containers/:id/checks', authMiddleware, requirePermission('containers.check'), (req, res) => {
    const container = ownedContainer(req, req.params.id);
    if (!container) return res.status(404).json({ error: 'Kiste nicht gefunden.' });
    if (all(containerChecks).filter((entry) => entry.containerId === container.id).length
        >= MAX_CHECKS_PER_CONTAINER) {
      // Älteste Prüfprotokolle werden rollierend ersetzt.
      const raw = all(containerChecks);
      const oldest = raw.filter((entry) => entry.containerId === container.id)
        .sort((left, right) => String(left.checkedAt).localeCompare(String(right.checkedAt)))[0];
      raw.splice(raw.indexOf(oldest), 1);
    }
    const template = checkTemplate(container);
    if (!template.items.length) {
      return res.status(409).json({ error: 'Die Kiste hat weder eine Packliste noch einen Inhalt.' });
    }
    const submitted = new Map((Array.isArray(req.body.results) ? req.body.results : [])
      .map((entry) => [text(entry?.key, 200), entry]));
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
      defectId: null,
    };
    let defect = null;
    if (!complete && req.body.createDefect && defectManagement?.createFromContainerCheck) {
      const priority = DEFECT_PRIORITIES.includes(req.body.createDefect.priority)
        ? req.body.createDefect.priority : 'Normal';
      const description = results.filter((entry) => !entry.ok).map((entry) =>
        `${entry.inventoryNumber || '-'} ${entry.name}: ${entry.result}, Soll ${entry.targetQuantity}, Ist ${entry.actualQuantity}${entry.notes ? ` (${entry.notes})` : ''}`)
        .join('\n');
      const created = defectManagement.createFromContainerCheck({
        containerId: container.id,
        title: text(req.body.createDefect.title, 160) || `Kiste ${container.inventoryNumber} unvollständig`,
        description: `${description}${check.notes ? `\n\n${check.notes}` : ''}`.slice(0, 10_000),
        priority, user: req.user, request: req, checkId: check.id,
      });
      if (created?.error) return res.status(created.status || 400).json({ error: created.error });
      defect = created?.report || null;
      check.defectId = defect?.id || null;
    }
    all(containerChecks).push(check);
    container.completenessStatus = complete ? 'Vollständig' : 'Unvollständig';
    container.lastContainerCheckAt = at;
    logEvent('check', 'Container', {
      id: check.id, containerId: container.id, complete, deviations: check.deviationCount,
    }, req.user.username);
    return res.status(201).json({
      ...check,
      defectNumber: defect?.defectNumber || null,
      container: publicContainer(container, { detail: true }),
    });
  });
}

module.exports = {
  createContainerGuard,
  registerContainerRoutes,
  CHECK_RESULTS,
  COMPLETENESS_STATUSES,
  MAX_NESTING_DEPTH,
};
