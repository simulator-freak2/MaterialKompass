const key = (value) => String(value || '').trim().toLowerCase();
const storageKey = (row) => JSON.stringify([row.locationId || '', row.stockStructureId || '']);
const nonEmpty = (row) => Object.fromEntries(Object.entries(row)
  .filter(([, value]) => value !== '' && value !== null && value !== undefined));
const activeItems = (...collections) => collections.flatMap((entries) => [...entries])
  .filter((entry) => !entry.archived && !entry.deletedAt && !entry.inventoryNumberReleasedAt);

// Planning never changes stored records. The same checks run again on submission.
function planImport(rows, body, own, active, locations, positions) {
  const policy = body.conflictPolicy || 'skip';
  if (!['skip', 'replace', 'renumber'].includes(policy)) {
    return { error: 'Ungültige Auswahl für doppelte Inventarnummern.' };
  }
  const seen = new Set(active.map((entry) => key(entry.inventoryNumber)).filter(Boolean));
  const conflicts = [];
  const missing = new Map();
  const prepared = rows.map((source, index) => {
    const requested = key(source.inventoryNumber);
    const existing = own.find((entry) => !entry.archived && !entry.deletedAt
      && !entry.inventoryNumberReleasedAt && key(entry.inventoryNumber) === requested && requested);
    const conflict = Boolean(requested && seen.has(requested));
    if (conflict) conflicts.push({ row: index + 2, inventoryNumber: source.inventoryNumber });
    if (requested) seen.add(requested);
    let row = policy === 'replace' && existing
      ? { ...existing, ...nonEmpty(source) } : { ...source };
    const originalKey = storageKey(row);
    const mapping = Object.hasOwn(body.storageMappings || {}, originalKey)
      ? body.storageMappings[originalKey] : null;
    if (mapping && typeof mapping === 'object') {
      row = { ...row, locationId: String(mapping.locationId || ''),
        stockStructureId: String(mapping.stockStructureId || '') };
    }
    const valid = locations.some((entry) => entry.id === row.locationId)
      && (!row.stockStructureId || positions.some((entry) =>
        entry.id === row.stockStructureId && entry.locationId === row.locationId));
    const skippedConflict = conflict && (policy === 'skip' || (policy === 'replace' && !existing));
    if (!valid && row.name && !skippedConflict) missing.set(originalKey, { key: originalKey,
      locationId: row.locationId || '', stockStructureId: row.stockStructureId || '' });
    return { row, existing, conflict };
  });
  return { policy, prepared, conflicts, missingStorage: [...missing.values()] };
}

module.exports = { activeItems, key, nonEmpty, planImport };
