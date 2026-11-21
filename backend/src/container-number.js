const { rawCollection } = require('./tenancy');

// Kistennummern sind eine eigene, je Gliederung eindeutige Kennung für Kisten –
// zusätzlich zur Inventarnummer des Einzelstücks. Das Präfix für automatische
// Vorschläge kann je Organisation (Wurzeleinheit) und je Verwaltungsebene
// festgelegt werden und wird an untergeordnete Ebenen vererbt. Ohne Festlegung
// gilt „<EDV-Nummer der Gliederung>-K-“.

const EDV_PLACEHOLDER = '{EDV}';
const DEFAULT_CONTAINER_NUMBER_PREFIX = `${EDV_PLACEHOLDER}-K-`;
const MAX_PREFIX_LENGTH = 32;
const MAX_CONTAINER_NUMBER_LENGTH = 64;
const SEQUENCE_DIGITS = 4;
const PREFIX_PATTERN = /^[A-Za-z0-9._/-]*$/;
const CONTAINER_NUMBER_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._/-]*$/;

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function normalizedKey(value) {
  return String(value ?? '').trim().toLowerCase();
}

// Prüft eine Präfix-Vorlage. Leer bedeutet: von der übergeordneten Ebene erben.
function validateContainerNumberPrefix(value) {
  if (value === null || value === undefined) return { value: null };
  if (typeof value !== 'string') return { error: 'Das Kistennummern-Präfix muss ein Text sein.' };
  const prefix = value.trim();
  if (!prefix) return { value: null };
  if (prefix.length > MAX_PREFIX_LENGTH) {
    return { error: `Das Kistennummern-Präfix darf höchstens ${MAX_PREFIX_LENGTH} Zeichen lang sein.` };
  }
  if (!PREFIX_PATTERN.test(prefix.split(EDV_PLACEHOLDER).join(''))) {
    return {
      error: 'Das Kistennummern-Präfix darf nur Buchstaben, Ziffern, Punkt, Schrägstrich, '
        + `Unterstrich, Bindestrich und den Platzhalter ${EDV_PLACEHOLDER} enthalten.`,
    };
  }
  return { value: prefix };
}

function validateContainerNumberFormat(value) {
  const containerNumber = String(value ?? '').trim();
  if (!containerNumber) return { error: 'Bitte eine Kistennummer angeben.' };
  if (containerNumber.length > MAX_CONTAINER_NUMBER_LENGTH) {
    return { error: `Die Kistennummer darf höchstens ${MAX_CONTAINER_NUMBER_LENGTH} Zeichen lang sein.` };
  }
  if (!CONTAINER_NUMBER_PATTERN.test(containerNumber)) {
    return {
      error: 'Die Kistennummer muss mit einem Buchstaben oder einer Ziffer beginnen und darf nur '
        + 'Buchstaben, Ziffern, Punkt, Schrägstrich, Unterstrich und Bindestrich enthalten.',
    };
  }
  return { value: containerNumber };
}

function createContainerNumbering({ units, materials, clothingItems }) {
  const all = (collection) => rawCollection(collection);

  function unitById(unitId) {
    return all(units).find((entry) => entry.id === unitId) || null;
  }

  // Liefert die wirksame Präfix-Vorlage einer Einheit und woher sie stammt.
  function prefixSetting(unitId) {
    const seen = new Set();
    let current = unitById(unitId);
    while (current && !seen.has(current.id)) {
      seen.add(current.id);
      if (current.containerNumberPrefix) {
        return {
          template: current.containerNumberPrefix,
          sourceUnitId: current.id,
          sourceUnitName: current.name || null,
          inherited: current.id !== unitId,
          isDefault: false,
        };
      }
      current = current.parentId ? unitById(current.parentId) : null;
    }
    return {
      template: DEFAULT_CONTAINER_NUMBER_PREFIX,
      sourceUnitId: null,
      sourceUnitName: null,
      inherited: false,
      isDefault: true,
    };
  }

  function resolvePrefix(template, unitId) {
    const edvNumber = String(unitById(unitId)?.edvNumber || '').trim();
    return String(template).split(EDV_PLACEHOLDER).join(edvNumber);
  }

  function effectivePrefix(unitId) {
    const setting = prefixSetting(unitId);
    return { ...setting, prefix: resolvePrefix(setting.template, unitId) };
  }

  const sameUnit = (entry, organizationId, unitId) =>
    entry?.organizationId === organizationId && entry?.unitId === unitId;

  function containersOf(organizationId, unitId) {
    return all(materials).filter((entry) => sameUnit(entry, organizationId, unitId)
      && entry.isContainer === true && entry.containerNumber);
  }

  // Eine Kistennummer muss innerhalb der Gliederung eindeutig sein und darf
  // keiner Inventarnummer gleichen, damit ein Scan eindeutig bleibt.
  function conflict(containerNumber, { organizationId, unitId, excludeId = null }) {
    const key = normalizedKey(containerNumber);
    if (!key) return null;
    const otherContainer = containersOf(organizationId, unitId).find((entry) =>
      entry.id !== excludeId && normalizedKey(entry.containerNumber) === key);
    if (otherContainer) return 'Die Kistennummer ist in dieser Gliederung bereits vergeben.';
    const inventoryMatch = [...all(materials), ...all(clothingItems)].some((entry) =>
      sameUnit(entry, organizationId, unitId)
      && !(entry.id === excludeId && entry.isContainer === true)
      && normalizedKey(entry.inventoryNumber) === key);
    if (inventoryMatch) return 'Die Kistennummer entspricht einer Inventarnummer dieser Gliederung.';
    return null;
  }

  function validate(value, scope) {
    const format = validateContainerNumberFormat(value);
    if (format.error) return { error: format.error, status: 400 };
    const message = conflict(format.value, scope);
    if (message) return { error: message, status: 409 };
    return { value: format.value };
  }

  function suggest({ organizationId, unitId, reserved = [] }) {
    const { prefix } = effectivePrefix(unitId);
    const pattern = new RegExp(`^${escapeRegExp(prefix)}(\\d+)$`, 'i');
    const used = [
      ...containersOf(organizationId, unitId).map((entry) => entry.containerNumber),
      ...reserved,
    ];
    let sequence = used.reduce((highest, value) => {
      const match = String(value || '').match(pattern);
      return match ? Math.max(highest, Number(match[1])) : highest;
    }, 0);
    let candidate;
    do {
      sequence += 1;
      candidate = `${prefix}${String(sequence).padStart(SEQUENCE_DIGITS, '0')}`;
    } while (conflict(candidate, { organizationId, unitId })
      || reserved.some((entry) => normalizedKey(entry) === normalizedKey(candidate)));
    return candidate;
  }

  // Stellt sicher, dass eine Kiste eine Kistennummer besitzt.
  function ensure(container) {
    if (!container?.isContainer || container.containerNumber) return false;
    container.containerNumber = suggest({
      organizationId: container.organizationId, unitId: container.unitId,
    });
    return true;
  }

  // Vergibt beim Start allen bestehenden Kisten ohne Nummer eine Kistennummer.
  function backfill() {
    let assigned = 0;
    const pending = all(materials).filter((entry) => entry.isContainer === true
      && !entry.containerNumber)
      .sort((left, right) => String(left.createdAt || '').localeCompare(String(right.createdAt || ''))
        || String(left.id).localeCompare(String(right.id)));
    for (const container of pending) {
      if (ensure(container)) assigned += 1;
    }
    return assigned;
  }

  return { prefixSetting, effectivePrefix, conflict, validate, suggest, ensure, backfill };
}

module.exports = {
  DEFAULT_CONTAINER_NUMBER_PREFIX,
  EDV_PLACEHOLDER,
  createContainerNumbering,
  validateContainerNumberFormat,
  validateContainerNumberPrefix,
};
