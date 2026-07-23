-- Das produktive Backend speichert fachliche Sammlungen transaktional in
-- application_collections. Diese Migration hält zusätzlich das normalisierte
-- Referenzschema und bestehende Rollen auf dem aktuellen Stand.
ALTER TABLE defect_reports
  ADD COLUMN IF NOT EXISTS defect_number VARCHAR(32) NULL AFTER id,
  ADD COLUMN IF NOT EXISTS affected_quantity DECIMAL(12,3) NOT NULL DEFAULT 1 AFTER entity_id,
  ADD COLUMN IF NOT EXISTS title VARCHAR(160) NULL AFTER affected_quantity,
  ADD COLUMN IF NOT EXISTS priority VARCHAR(32) NOT NULL DEFAULT 'Normal' AFTER description,
  ADD COLUMN IF NOT EXISTS damage_type VARCHAR(120) NULL AFTER status,
  ADD COLUMN IF NOT EXISTS cause TEXT NULL AFTER damage_type,
  ADD COLUMN IF NOT EXISTS risk_level VARCHAR(80) NULL AFTER cause,
  ADD COLUMN IF NOT EXISTS operational_safety VARCHAR(80) NULL AFTER risk_level,
  ADD COLUMN IF NOT EXISTS assignee VARCHAR(255) NULL AFTER operational_safety,
  ADD COLUMN IF NOT EXISTS responsible_department VARCHAR(255) NULL AFTER assignee,
  ADD COLUMN IF NOT EXISTS due_date DATE NULL AFTER responsible_department,
  ADD COLUMN IF NOT EXISTS estimated_cost DECIMAL(12,2) NULL AFTER due_date,
  ADD COLUMN IF NOT EXISTS actual_cost DECIMAL(12,2) NULL AFTER estimated_cost,
  ADD COLUMN IF NOT EXISTS resolution TEXT NULL AFTER actual_cost,
  ADD COLUMN IF NOT EXISTS reported_by VARCHAR(64) NULL AFTER resolution,
  ADD COLUMN IF NOT EXISTS reported_at DATETIME NULL AFTER reported_by,
  ADD COLUMN IF NOT EXISTS details_json LONGTEXT NULL AFTER reported_at,
  ADD COLUMN IF NOT EXISTS archived_at DATETIME NULL AFTER details_json,
  ADD COLUMN IF NOT EXISTS archived_by VARCHAR(255) NULL AFTER archived_at;

INSERT IGNORE INTO permissions (id, name) VALUES
  ('defects-report', 'defects.report'), ('defects-edit', 'defects.edit'),
  ('defects-assign', 'defects.assign'), ('defects-close', 'defects.close'),
  ('defects-archive', 'defects.archive'), ('defects-delete', 'defects.delete'),
  ('defects-export', 'defects.export');

UPDATE roles SET permissions = JSON_ARRAY_APPEND(
  permissions, '$', 'defects.report', '$', 'defects.edit', '$', 'defects.assign',
  '$', 'defects.close', '$', 'defects.archive', '$', 'defects.delete', '$', 'defects.export'
) WHERE name IN ('Admin', 'Materialwart') AND NOT JSON_CONTAINS(permissions, JSON_QUOTE('defects.report'));

UPDATE roles SET permissions = JSON_ARRAY_APPEND(
  permissions, '$', 'defects.read', '$', 'defects.report', '$', 'defects.edit',
  '$', 'defects.assign', '$', 'defects.close', '$', 'defects.archive', '$', 'defects.delete', '$', 'defects.export'
) WHERE name = 'Kleiderwart' AND NOT JSON_CONTAINS(permissions, JSON_QUOTE('defects.report'));

UPDATE roles SET permissions = JSON_ARRAY_APPEND(permissions, '$', 'defects.read')
WHERE name = 'Vorsitz' AND NOT JSON_CONTAINS(permissions, JSON_QUOTE('defects.read'));
