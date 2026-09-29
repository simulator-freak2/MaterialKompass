const { randomUUID } = require('node:crypto');

const { createUserStore } = require('../db/user-store');

const DEFAULT_TARGET_NAME = 'Jugend Ingelheim am Rhein';
const DEFAULT_TARGET_EDV = '10050035';

// Requested domains plus their dependent records. Keeping these references
// together prevents orphaned movements, inspections, documents, shelves,
// orders or receipts after the move.
const UNIT_COLLECTIONS = Object.freeze([
  'locations', 'shelves', 'storageLevels', 'stockStructures',
  'materials', 'deletedMaterials', 'materialMovements', 'materialInspections',
  'materialDocuments', 'reservations', 'maintenanceEvents',
  'clothingItems', 'deletedClothingItems', 'clothingInspections',
  'issueTransactions',
  'defectReports', 'notifications', 'defectEmailImports',
  'procurementRequests', 'procurementOffers', 'procurementOrders',
  'procurementReceipts', 'procurementDocuments', 'procurementEmailImports',
  'suppliers', 'documents',
  'stocktakes', 'stocktakeEmailImports',
]);
const CATEGORY_COLLECTION = 'categories';
const AUDIT_COLLECTION = 'auditLogs';

function normalized(value) {
  return String(value || '').trim().toLocaleLowerCase('de');
}

function parseArguments(args) {
  const options = {
    apply: false,
    targetName: DEFAULT_TARGET_NAME,
    targetEdv: DEFAULT_TARGET_EDV,
  };
  for (const argument of args) {
    if (argument === '--apply') options.apply = true;
    else if (argument === '--help' || argument === '-h') options.help = true;
    else if (argument.startsWith('--target-name=')) {
      options.targetName = argument.slice('--target-name='.length).trim();
    } else if (argument.startsWith('--target-edv=')) {
      options.targetEdv = argument.slice('--target-edv='.length).trim();
    } else {
      throw new Error(`Unbekanntes Argument: ${argument}`);
    }
  }
  if (!options.targetName || !options.targetEdv) {
    throw new Error('Zielname und Ziel-EDV-Nummer dürfen nicht leer sein.');
  }
  return options;
}

function findTargetUnit(collections, { targetName, targetEdv }) {
  const candidates = (collections.organizationUnits || []).filter((unit) =>
    unit.status === 'active'
      && normalized(unit.name) === normalized(targetName)
      && normalized(unit.edvNumber) === normalized(targetEdv));
  if (candidates.length !== 1) {
    throw new Error(
      `Erwartet wurde genau eine aktive Unterorganisation "${targetName}" `
      + `mit EDV-Nummer ${targetEdv}; gefunden: ${candidates.length}.`,
    );
  }
  const target = candidates[0];
  if (!target.parentId) {
    throw new Error(
      `Das gefundene Ziel ${target.id} ist eine Wurzeleinheit und keine Unterorganisation.`,
    );
  }
  const organization = (collections.organizations || []).find((entry) =>
    entry.id === target.organizationId && entry.status === 'active');
  if (!organization) {
    throw new Error(`Die übergeordnete aktive Organisation ${target.organizationId} fehlt.`);
  }
  return { target, organization };
}

function duplicateValues(entries, property) {
  const owners = new Map();
  for (const entry of entries) {
    const value = normalized(entry?.[property]);
    if (!value) continue;
    if (!owners.has(value)) owners.set(value, []);
    owners.get(value).push(entry.id || '(ohne ID)');
  }
  return [...owners.entries()]
    .filter(([, ids]) => ids.length > 1)
    .map(([value, ids]) => `${property}=${value} (${ids.join(', ')})`);
}

function validateMergedData(updated) {
  const conflicts = [];
  for (const name of [...UNIT_COLLECTIONS, CATEGORY_COLLECTION]) {
    conflicts.push(...duplicateValues(updated[name] || [], 'id').map((value) =>
      `${name}: ${value}`));
  }
  conflicts.push(...duplicateValues([
    ...(updated.materials || []),
    ...(updated.deletedMaterials || []),
    ...(updated.clothingItems || []),
    ...(updated.deletedClothingItems || []),
  ], 'inventoryNumber').map((value) => `Inventarnummer: ${value}`));
  for (const [name, property] of [
    ['locations', 'code'],
    ['defectReports', 'defectNumber'],
    ['procurementRequests', 'requestNumber'],
    ['procurementOrders', 'orderNumber'],
  ]) {
    conflicts.push(...duplicateValues(updated[name] || [], property).map((value) =>
      `${name}: ${value}`));
  }
  if (conflicts.length > 0) {
    throw new Error(
      'Die Zusammenführung würde nicht eindeutige Schlüssel erzeugen:\n- '
      + conflicts.join('\n- '),
    );
  }
}

function planMove(collections, options = {}) {
  const targetOptions = {
    targetName: options.targetName || DEFAULT_TARGET_NAME,
    targetEdv: options.targetEdv || DEFAULT_TARGET_EDV,
  };
  const { target, organization } = findTargetUnit(collections, targetOptions);
  const updated = {};
  const counts = {};

  for (const name of UNIT_COLLECTIONS) {
    const values = structuredClone(collections[name] || []);
    let changed = 0;
    for (const entry of values) {
      if (!entry || typeof entry !== 'object') continue;
      if (entry.organizationId !== organization.id || entry.unitId !== target.id) changed += 1;
      entry.organizationId = organization.id;
      entry.unitId = target.id;
    }
    updated[name] = values;
    counts[name] = { total: values.length, changed };
  }

  const categories = structuredClone(collections[CATEGORY_COLLECTION] || []);
  let changedCategories = 0;
  for (const category of categories) {
    if (!category || typeof category !== 'object') continue;
    if (category.organizationId !== organization.id
      || category.unitId !== target.id || category.scope !== 'unit') {
      changedCategories += 1;
    }
    category.organizationId = organization.id;
    category.unitId = target.id;
    category.scope = 'unit';
  }
  updated[CATEGORY_COLLECTION] = categories;
  counts[CATEGORY_COLLECTION] = {
    total: categories.length,
    changed: changedCategories,
  };

  validateMergedData(updated);
  const changed = Object.values(counts).reduce((sum, value) => sum + value.changed, 0);
  if (changed > 0) {
    const auditLogs = structuredClone(collections[AUDIT_COLLECTION] || []);
    auditLogs.push({
      id: `audit-${randomUUID()}`,
      timestamp: new Date().toISOString(),
      actor: 'move-all-data-to-organization-unit',
      action: 'transfer',
      entity: 'OrganizationUnit',
      organizationId: organization.id,
      details: {
        targetUnitId: target.id,
        targetName: target.name,
        targetEdvNumber: target.edvNumber,
        changedRecords: changed,
        collections: counts,
      },
    });
    updated[AUDIT_COLLECTION] = auditLogs;
  }

  return { target, organization, updated, counts, changed };
}

function printHelp() {
  console.log(`Verwendung:
  node src/scripts/move-all-data-to-organization-unit.js [--apply]
    [--target-name="${DEFAULT_TARGET_NAME}"] [--target-edv=${DEFAULT_TARGET_EDV}]

Ohne --apply wird nur eine Vorschau ausgegeben.`);
}

function printPlan(plan, apply) {
  console.log(`${apply ? 'Migration' : 'Vorschau'} für Ziel:`);
  console.log(`  Organisation: ${plan.organization.name} (${plan.organization.id})`);
  console.log(`  Unterorganisation: ${plan.target.name} (${plan.target.id})`);
  console.log(`  EDV-Nummer: ${plan.target.edvNumber}`);
  console.log('Betroffene Sammlungen:');
  for (const [name, count] of Object.entries(plan.counts)) {
    console.log(`  ${name}: ${count.changed} von ${count.total} zu verschieben`);
  }
  console.log(`Gesamt: ${plan.changed} Datensätze zu verschieben.`);
}

async function main(args = process.argv.slice(2)) {
  const options = parseArguments(args);
  if (options.help) return printHelp();
  const store = createUserStore();
  try {
    // This deliberately fails while the backend is running. It prevents the
    // stopped instance from overwriting migrated snapshots on shutdown.
    await store.acquireProcessLock();
    await store.initialize();
    const collections = await store.loadCollections();
    const plan = planMove(collections, options);
    printPlan(plan, options.apply);
    if (!options.apply) {
      console.log('Keine Daten geändert. Für die Ausführung --apply ergänzen.');
      return;
    }
    if (plan.changed === 0) {
      console.log('Alle ausgewählten Daten befinden sich bereits im Zielbereich.');
      return;
    }
    await store.replaceCollections(plan.updated);
    console.log('Migration wurde vollständig in einer Datenbanktransaktion gespeichert.');
  } finally {
    await store.close();
  }
}

if (require.main === module) {
  main().catch((error) => {
    console.error(`Datenmigration fehlgeschlagen: ${error.message}`);
    process.exitCode = 1;
  });
}

module.exports = {
  AUDIT_COLLECTION,
  CATEGORY_COLLECTION,
  DEFAULT_TARGET_EDV,
  DEFAULT_TARGET_NAME,
  UNIT_COLLECTIONS,
  findTargetUnit,
  parseArguments,
  planMove,
  validateMergedData,
};
