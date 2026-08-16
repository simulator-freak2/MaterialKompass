ALTER TABLE suppliers
  ADD COLUMN IF NOT EXISTS street VARCHAR(255) NULL AFTER address,
  ADD COLUMN IF NOT EXISTS house_number VARCHAR(64) NULL AFTER street,
  ADD COLUMN IF NOT EXISTS postal_code VARCHAR(32) NULL AFTER house_number,
  ADD COLUMN IF NOT EXISTS city VARCHAR(255) NULL AFTER postal_code,
  ADD COLUMN IF NOT EXISTS country VARCHAR(128) NULL AFTER city;

-- Bestehende Freitextanschriften bleiben bewusst in address erhalten. Sie werden
-- beim nächsten Bearbeiten kontrolliert in die strukturierten Pflichtfelder übernommen.
