function organizationNumber() {
  return String(process.env.GLIEDERUNGSNUMMER || '10050035').trim() || '10050035';
}

function idSegment(value) {
  const parts = String(value || '00').trim().split('-').filter(Boolean);
  return parts.at(-1) || '00';
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function inventoryPrefix(mainCategoryId, subcategoryId) {
  return `${organizationNumber()}-${idSegment(mainCategoryId)}-${idSegment(subcategoryId)}-`;
}

function reservesInventoryNumber(entry) {
  return Boolean(entry?.inventoryNumber) && !entry.inventoryNumberReleasedAt;
}

function inventoryNumberInUse(entries, inventoryNumber, excludingEntry = null) {
  const normalized = String(inventoryNumber || '').trim().toLowerCase();
  if (!normalized) return false;
  return entries.some((entry) => entry !== excludingEntry
    && reservesInventoryNumber(entry)
    && String(entry.inventoryNumber).trim().toLowerCase() === normalized);
}

function nextInventoryNumber(entries, mainCategoryId, subcategoryId) {
  const prefix = inventoryPrefix(mainCategoryId, subcategoryId);
  const pattern = new RegExp(`^${escapeRegExp(prefix)}(\\d+)$`, 'i');
  const matching = entries.flatMap((entry) => {
    const match = String(entry.inventoryNumber || '').match(pattern);
    return match ? [{ entry, sequence: Number(match[1]) }] : [];
  });
  const used = new Set(matching
    .filter(({ entry }) => reservesInventoryNumber(entry))
    .map(({ sequence }) => sequence));
  const reusable = matching
    .filter(({ entry, sequence }) => !reservesInventoryNumber(entry) && !used.has(sequence))
    .sort((left, right) => left.sequence - right.sequence);
  if (reusable.length) return String(reusable[0].entry.inventoryNumber);
  const highest = matching.reduce(
    (result, { sequence }) => Math.max(result, sequence),
    0,
  );
  const sequence = highest + 1;
  return `${prefix}${String(sequence).padStart(4, '0')}`;
}

module.exports = {
  inventoryPrefix,
  inventoryNumberInUse,
  nextInventoryNumber,
  organizationNumber,
  reservesInventoryNumber,
};
