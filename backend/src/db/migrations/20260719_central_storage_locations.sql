ALTER TABLE clothing_items
  ADD COLUMN IF NOT EXISTS stock_structure_id VARCHAR(64) NULL;
