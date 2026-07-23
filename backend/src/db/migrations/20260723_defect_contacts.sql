ALTER TABLE defect_reports
  ADD COLUMN IF NOT EXISTS contact_name VARCHAR(255) NULL AFTER responsible_department,
  ADD COLUMN IF NOT EXISTS contact_email VARCHAR(255) NULL AFTER contact_name,
  ADD COLUMN IF NOT EXISTS contact_phone VARCHAR(80) NULL AFTER contact_email;
