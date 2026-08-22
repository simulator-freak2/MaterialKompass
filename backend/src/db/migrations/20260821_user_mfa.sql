ALTER TABLE users
  ADD COLUMN mfa_required TINYINT(1) NOT NULL DEFAULT 0 AFTER password_reset_expires_at,
  ADD COLUMN mfa_secret_encrypted TEXT NULL AFTER mfa_required,
  ADD COLUMN mfa_pending_secret_encrypted TEXT NULL AFTER mfa_secret_encrypted,
  ADD COLUMN mfa_pending_secret_expires_at DATETIME NULL AFTER mfa_pending_secret_encrypted,
  ADD COLUMN mfa_recovery_code_hashes JSON NULL AFTER mfa_pending_secret_expires_at,
  ADD COLUMN mfa_enabled_at DATETIME NULL AFTER mfa_recovery_code_hashes,
  ADD COLUMN mfa_last_verified_at DATETIME NULL AFTER mfa_enabled_at,
  ADD COLUMN mfa_grace_ends_at DATETIME NULL AFTER mfa_last_verified_at,
  ADD COLUMN mfa_version INT UNSIGNED NOT NULL DEFAULT 0 AFTER mfa_grace_ends_at;

UPDATE users
SET mfa_recovery_code_hashes = JSON_ARRAY()
WHERE mfa_recovery_code_hashes IS NULL;

ALTER TABLE users
  MODIFY COLUMN mfa_recovery_code_hashes JSON NOT NULL;
