ALTER TABLE users
  ADD COLUMN login_access_mode VARCHAR(32) NOT NULL DEFAULT 'all_clients' AFTER active,
  ADD COLUMN allowed_service_device_ids JSON NULL AFTER login_access_mode;

UPDATE users SET allowed_service_device_ids = JSON_ARRAY()
WHERE allowed_service_device_ids IS NULL;

ALTER TABLE users
  MODIFY COLUMN allowed_service_device_ids JSON NOT NULL;
