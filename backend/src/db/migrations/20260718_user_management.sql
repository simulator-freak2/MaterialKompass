ALTER TABLE users
  ADD COLUMN username VARCHAR(100) NULL AFTER name,
  ADD COLUMN last_login_at DATETIME NULL AFTER locked_until,
  ADD COLUMN email_verified_at DATETIME NULL AFTER last_login_at,
  ADD COLUMN verification_token_hash CHAR(64) NULL AFTER email_verified_at,
  ADD COLUMN verification_expires_at DATETIME NULL AFTER verification_token_hash,
  ADD COLUMN password_reset_token_hash CHAR(64) NULL AFTER verification_expires_at,
  ADD COLUMN password_reset_expires_at DATETIME NULL AFTER password_reset_token_hash,
  ADD COLUMN deactivated_at DATETIME NULL AFTER password_reset_expires_at,
  ADD COLUMN deactivation_reason VARCHAR(64) NULL AFTER deactivated_at,
  ADD COLUMN scheduled_deletion_at DATETIME NULL AFTER deactivation_reason;

UPDATE users SET username = LOWER(SUBSTRING_INDEX(email, '@', 1)) WHERE username IS NULL;
UPDATE users SET email_verified_at = created_at WHERE email_verified_at IS NULL;

ALTER TABLE users
  MODIFY username VARCHAR(100) NOT NULL,
  ADD UNIQUE INDEX uq_users_username (username),
  ADD INDEX idx_users_last_login (last_login_at),
  ADD INDEX idx_users_scheduled_deletion (scheduled_deletion_at);

ALTER TABLE roles ADD UNIQUE INDEX uq_roles_name (name);
