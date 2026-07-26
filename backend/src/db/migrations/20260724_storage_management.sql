ALTER TABLE locations
  ADD COLUMN IF NOT EXISTS street VARCHAR(255) NULL,
  ADD COLUMN IF NOT EXISTS house_number VARCHAR(32) NULL,
  ADD COLUMN IF NOT EXISTS postal_code VARCHAR(32) NULL,
  ADD COLUMN IF NOT EXISTS city VARCHAR(255) NULL,
  ADD COLUMN IF NOT EXISTS country VARCHAR(100) NULL,
  ADD COLUMN IF NOT EXISTS building VARCHAR(255) NULL,
  ADD COLUMN IF NOT EXISTS address_extra VARCHAR(255) NULL,
  ADD COLUMN IF NOT EXISTS contact_name VARCHAR(255) NULL,
  ADD COLUMN IF NOT EXISTS contact_phone VARCHAR(64) NULL,
  ADD COLUMN IF NOT EXISTS notes TEXT NULL,
  ADD COLUMN IF NOT EXISTS active BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS sort_order INT NOT NULL DEFAULT 0;

ALTER TABLE material_items
  MODIFY COLUMN location_id VARCHAR(64) NULL;

ALTER TABLE clothing_items
  MODIFY COLUMN location_id VARCHAR(64) NULL;

CREATE TABLE IF NOT EXISTS storage_racks (
  id VARCHAR(64) PRIMARY KEY,
  location_id VARCHAR(64) NOT NULL,
  number INT NOT NULL,
  name VARCHAR(255) NOT NULL,
  sort_order INT NOT NULL DEFAULT 0,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at DATETIME NOT NULL,
  updated_at DATETIME NULL,
  UNIQUE KEY uq_storage_rack_number (location_id, number),
  UNIQUE KEY uq_storage_rack_name (location_id, name),
  FOREIGN KEY (location_id) REFERENCES locations(id)
);

CREATE TABLE IF NOT EXISTS storage_levels (
  id VARCHAR(64) PRIMARY KEY,
  rack_id VARCHAR(64) NOT NULL,
  number INT NOT NULL,
  name VARCHAR(255) NOT NULL,
  sort_order INT NOT NULL DEFAULT 0,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at DATETIME NOT NULL,
  updated_at DATETIME NULL,
  UNIQUE KEY uq_storage_level_number (rack_id, number),
  UNIQUE KEY uq_storage_level_name (rack_id, name),
  FOREIGN KEY (rack_id) REFERENCES storage_racks(id)
);

CREATE TABLE IF NOT EXISTS storage_places (
  id VARCHAR(64) PRIMARY KEY,
  level_id VARCHAR(64) NOT NULL,
  number INT NOT NULL,
  name VARCHAR(255) NOT NULL,
  sort_order INT NOT NULL DEFAULT 0,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at DATETIME NOT NULL,
  updated_at DATETIME NULL,
  UNIQUE KEY uq_storage_place_number (level_id, number),
  UNIQUE KEY uq_storage_place_name (level_id, name),
  FOREIGN KEY (level_id) REFERENCES storage_levels(id)
);

CREATE TABLE IF NOT EXISTS storage_boxes (
  id VARCHAR(64) PRIMARY KEY,
  inventory_number VARCHAR(64) UNIQUE NOT NULL,
  name VARCHAR(255) NOT NULL,
  type VARCHAR(100) NULL,
  storage_place_id VARCHAR(64) NOT NULL,
  status VARCHAR(32) NOT NULL,
  length_cm DECIMAL(10,2) NULL,
  width_cm DECIMAL(10,2) NULL,
  height_cm DECIMAL(10,2) NULL,
  max_load_kg DECIMAL(10,2) NULL,
  active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at DATETIME NOT NULL,
  updated_at DATETIME NULL,
  FOREIGN KEY (storage_place_id) REFERENCES storage_places(id)
);

CREATE TABLE IF NOT EXISTS storage_assignments (
  id VARCHAR(64) PRIMARY KEY,
  entity_type VARCHAR(16) NOT NULL,
  entity_id VARCHAR(64) NOT NULL,
  storage_place_id VARCHAR(64) NOT NULL,
  box_id VARCHAR(64) NULL,
  quantity DECIMAL(12,3) NOT NULL DEFAULT 1,
  created_by VARCHAR(255) NOT NULL,
  created_at DATETIME NOT NULL,
  updated_by VARCHAR(255) NULL,
  updated_at DATETIME NULL,
  INDEX idx_storage_assignment_entity (entity_type, entity_id),
  INDEX idx_storage_assignment_place (storage_place_id),
  FOREIGN KEY (storage_place_id) REFERENCES storage_places(id),
  FOREIGN KEY (box_id) REFERENCES storage_boxes(id)
);

CREATE TABLE IF NOT EXISTS stocktakes (
  id VARCHAR(64) PRIMARY KEY,
  name VARCHAR(255) NOT NULL,
  scope_type VARCHAR(32) NOT NULL,
  scope_id VARCHAR(64) NULL,
  planned_date DATE NULL,
  status VARCHAR(32) NOT NULL,
  entries_json LONGTEXT NOT NULL,
  created_by VARCHAR(255) NOT NULL,
  created_at DATETIME NOT NULL,
  started_by VARCHAR(255) NULL,
  started_at DATETIME NULL,
  completed_by VARCHAR(255) NULL,
  completed_at DATETIME NULL,
  CHECK (JSON_VALID(entries_json))
);

CREATE TABLE IF NOT EXISTS storage_history (
  id VARCHAR(64) PRIMARY KEY,
  action VARCHAR(32) NOT NULL,
  entity_type VARCHAR(64) NOT NULL,
  entity_id VARCHAR(64) NOT NULL,
  details_json LONGTEXT NOT NULL,
  actor VARCHAR(255) NOT NULL,
  created_at DATETIME NOT NULL,
  INDEX idx_storage_history_entity (entity_type, entity_id),
  CHECK (JSON_VALID(details_json))
);
