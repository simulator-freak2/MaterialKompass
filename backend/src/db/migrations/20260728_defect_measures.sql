ALTER TABLE defect_reports
  ADD COLUMN IF NOT EXISTS measures_taken TEXT NULL AFTER cause;
