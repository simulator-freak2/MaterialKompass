-- Verknüpft eine Mängelzuweisung optional mit einem aktiven Nutzerkonto.
-- Der vorhandene Freitext bleibt als Namens-Snapshot und für externe Personen erhalten.
ALTER TABLE defect_reports
  ADD COLUMN IF NOT EXISTS assignee_user_id VARCHAR(64) NULL AFTER assignee,
  ADD INDEX IF NOT EXISTS idx_defect_reports_assignee_user (assignee_user_id);
