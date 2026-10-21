ALTER TABLE user_mfa_push_devices
  MODIFY COLUMN platform ENUM('android', 'web') NOT NULL;

-- Firebase registrations cannot be migrated: their device secrets live only in
-- the former main app. Force an explicit one-time pairing with the separate app.
DELETE FROM user_mfa_push_devices;
