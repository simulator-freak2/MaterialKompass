ALTER TABLE locations
  MODIFY COLUMN type VARCHAR(64) NULL,
  ADD COLUMN IF NOT EXISTS street VARCHAR(255) NULL AFTER type,
  ADD COLUMN IF NOT EXISTS house_number VARCHAR(64) NULL AFTER street,
  ADD COLUMN IF NOT EXISTS postal_code VARCHAR(32) NULL AFTER house_number,
  ADD COLUMN IF NOT EXISTS city VARCHAR(255) NULL AFTER postal_code,
  ADD COLUMN IF NOT EXISTS country VARCHAR(128) NULL AFTER city;

CREATE TABLE IF NOT EXISTS shelves (
  id VARCHAR(64) PRIMARY KEY,
  location_id VARCHAR(64) NOT NULL,
  name VARCHAR(255) NOT NULL,
  code VARCHAR(32) NOT NULL,
  UNIQUE KEY uq_shelves_location_code (location_id, code),
  FOREIGN KEY (location_id) REFERENCES locations(id)
);

CREATE TABLE IF NOT EXISTS storage_levels (
  id VARCHAR(64) PRIMARY KEY,
  shelf_id VARCHAR(64) NOT NULL,
  name VARCHAR(255) NOT NULL,
  code VARCHAR(32) NOT NULL,
  UNIQUE KEY uq_storage_levels_shelf_code (shelf_id, code),
  FOREIGN KEY (shelf_id) REFERENCES shelves(id)
);

ALTER TABLE stock_structures
  ADD COLUMN IF NOT EXISTS shelf_id VARCHAR(64) NULL AFTER location_id,
  ADD COLUMN IF NOT EXISTS level_id VARCHAR(64) NULL AFTER shelf_id,
  ADD COLUMN IF NOT EXISTS code VARCHAR(32) NULL AFTER level_id;

-- Die Anwendung migriert die bisherige JSON-Sammlung idempotent und erhält
-- dabei die IDs der Lagerplätze. Fremdschlüssel werden erst nach dieser
-- Datenmigration in einer späteren Normalisierung verpflichtend.
