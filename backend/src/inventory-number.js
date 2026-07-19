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

function nextInventoryNumber(entries, mainCategoryId, subcategoryId) {
  const prefix = inventoryPrefix(mainCategoryId, subcategoryId);
  const pattern = new RegExp(`^${escapeRegExp(prefix)}(\\d+)$`, 'i');
  const highest = entries.reduce((result, entry) => {
    const match = String(entry.inventoryNumber || '').match(pattern);
    return match ? Math.max(result, Number(match[1])) : result;
  }, 0);
  return `${prefix}${String(highest + 1).padStart(4, '0')}`;
}

module.exports = { inventoryPrefix, nextInventoryNumber, organizationNumber };
