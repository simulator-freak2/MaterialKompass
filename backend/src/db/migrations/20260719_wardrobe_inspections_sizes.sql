ALTER TABLE categories
  ADD COLUMN IF NOT EXISTS sizes JSON NULL,
  ADD COLUMN IF NOT EXISTS inspection_interval_months INT NULL,
  ADD COLUMN IF NOT EXISTS requires_psage_inspection BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE clothing_items
  ADD COLUMN IF NOT EXISTS inspection_interval_months INT NULL,
  ADD COLUMN IF NOT EXISTS last_inspection_date DATE NULL,
  ADD COLUMN IF NOT EXISTS next_inspection_date DATE NULL;

ALTER TABLE procurement_request_items
  ADD COLUMN IF NOT EXISTS size VARCHAR(32) NULL;

CREATE TABLE IF NOT EXISTS clothing_inspections (
  id VARCHAR(64) PRIMARY KEY,
  clothing_id VARCHAR(64) NOT NULL,
  inspection_date DATE NOT NULL,
  inspector VARCHAR(255) NOT NULL,
  inspector_email VARCHAR(255) NOT NULL,
  result VARCHAR(32) NOT NULL,
  notes TEXT NULL,
  next_inspection_date DATE NULL,
  psage_inspection BOOLEAN NOT NULL DEFAULT FALSE,
  created_at DATETIME NOT NULL,
  FOREIGN KEY (clothing_id) REFERENCES clothing_items(id)
);

INSERT IGNORE INTO permissions (id, name)
VALUES ('clothing.inspect', 'clothing.inspect');

UPDATE roles
SET permissions = JSON_ARRAY_APPEND(permissions, '$', 'clothing.inspect')
WHERE name IN ('Kleiderwart', 'Sachkundiger PSAgE')
  AND NOT JSON_CONTAINS(permissions, JSON_QUOTE('clothing.inspect'));

UPDATE users
SET permissions = JSON_ARRAY_APPEND(permissions, '$', 'clothing.inspect')
WHERE (
    JSON_CONTAINS(roles, JSON_QUOTE('Kleiderwart'))
    OR JSON_CONTAINS(roles, JSON_QUOTE('Sachkundiger PSAgE'))
  )
  AND NOT JSON_CONTAINS(permissions, JSON_QUOTE('clothing.inspect'));
