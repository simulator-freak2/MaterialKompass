ALTER TABLE users
  ADD COLUMN IF NOT EXISTS department_ids JSON NULL AFTER roles;

UPDATE users
SET department_ids = JSON_ARRAY()
WHERE department_ids IS NULL;

ALTER TABLE users
  MODIFY department_ids JSON NOT NULL;
