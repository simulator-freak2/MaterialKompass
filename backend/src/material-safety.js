const ISSUE_COMPATIBLE_STATUSES = new Set(['Lagernd', 'Reserviert']);

function validDateOnly(value) {
  const raw = String(value || '').trim();
  if (!/^\d{4}-\d{2}-\d{2}$/.test(raw)) return null;
  const parsed = new Date(`${raw}T00:00:00.000Z`);
  return Number.isFinite(parsed.getTime()) && parsed.toISOString().slice(0, 10) === raw
    ? raw
    : null;
}

function utcDateOnly(now = new Date()) {
  const parsed = now instanceof Date ? now : new Date(now);
  return Number.isFinite(parsed.getTime()) ? parsed.toISOString().slice(0, 10) : null;
}

/**
 * Computes, but never persists, the operational safety state of a material item.
 * The API remains the enforcement point so outdated and manipulated clients
 * cannot issue equipment whose safety prerequisites are no longer satisfied.
 */
function assessMaterialSafety(item, now = new Date()) {
  if (item?.safetyCritical !== true) {
    return { safetyCritical: false, blocked: false, reasons: [] };
  }

  const reasons = [];
  const today = utcDateOnly(now);
  const inspectionDate = validDateOnly(item.nextInspectionDate);
  const maintenanceDate = validDateOnly(item.nextMaintenanceDate);

  if (item.archived === true) reasons.push('Das Material ist archiviert.');
  if (!ISSUE_COMPATIBLE_STATUSES.has(String(item.status || ''))) {
    reasons.push(`Der Status „${String(item.status || 'Unbekannt')}“ erlaubt keine Ausgabe.`);
  }
  if (!item.lastInspectionDate || item.lastInspectionResult !== 'Bestanden') {
    reasons.push('Eine bestandene Erst- oder Folgeprüfung ist nicht nachgewiesen.');
  }
  if (!inspectionDate) {
    reasons.push('Der nächste Prüftermin fehlt oder ist ungültig.');
  } else if (today && inspectionDate < today) {
    reasons.push(`Der Prüftermin ${inspectionDate} ist überschritten.`);
  }

  if (Number(item.maintenanceIntervalMonths) > 0) {
    if (!maintenanceDate) {
      reasons.push('Der nächste Wartungstermin fehlt oder ist ungültig.');
    } else if (today && maintenanceDate < today) {
      reasons.push(`Der Wartungstermin ${maintenanceDate} ist überschritten.`);
    }
  }

  return { safetyCritical: true, blocked: reasons.length > 0, reasons };
}

module.exports = { assessMaterialSafety, validDateOnly };
