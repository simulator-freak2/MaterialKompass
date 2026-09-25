const assert = require('node:assert/strict');
const test = require('node:test');
const { assessMaterialSafety, validDateOnly } = require('../src/material-safety');

test('ordinary material is not subject to the additional safety gate', () => {
  assert.deepEqual(assessMaterialSafety({ safetyCritical: false }), {
    safetyCritical: false,
    blocked: false,
    reasons: [],
  });
});

test('critical material requires a passed inspection and future due dates', () => {
  const item = {
    safetyCritical: true,
    archived: false,
    status: 'Lagernd',
    lastInspectionDate: '2026-09-01',
    lastInspectionResult: 'Bestanden',
    nextInspectionDate: '2027-09-01',
    maintenanceIntervalMonths: 12,
    nextMaintenanceDate: '2027-09-01',
  };
  assert.equal(assessMaterialSafety(item, new Date('2026-09-11T12:00:00Z')).blocked, false);

  item.nextInspectionDate = '2026-09-10';
  const expired = assessMaterialSafety(item, new Date('2026-09-11T12:00:00Z'));
  assert.equal(expired.blocked, true);
  assert.match(expired.reasons.join(' '), /Prüftermin .* überschritten/);
});

test('critical material fails closed for invalid evidence', () => {
  const result = assessMaterialSafety({
    safetyCritical: true,
    status: 'Lagernd',
    nextInspectionDate: '31.12.2027',
  }, new Date('2026-09-11T12:00:00Z'));
  assert.equal(result.blocked, true);
  assert.match(result.reasons.join(' '), /nicht nachgewiesen/);
  assert.match(result.reasons.join(' '), /fehlt oder ist ungültig/);
  assert.equal(validDateOnly('2026-02-30'), null);
});
