CREATE TABLE IF NOT EXISTS user_passkeys (
  id CHAR(36) PRIMARY KEY,
  user_id VARCHAR(64) NOT NULL,
  user_handle VARCHAR(86) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  credential_id TEXT CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  credential_id_hash BINARY(32) NOT NULL,
  public_key BLOB NOT NULL,
  signature_counter BIGINT UNSIGNED NOT NULL DEFAULT 0,
  transports JSON NOT NULL,
  device_type VARCHAR(32) NOT NULL,
  backed_up TINYINT(1) NOT NULL DEFAULT 0,
  name VARCHAR(100) NOT NULL,
  created_at DATETIME(3) NOT NULL,
  last_used_at DATETIME(3) NULL,
  updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
    ON UPDATE CURRENT_TIMESTAMP(3),
  UNIQUE KEY uq_user_passkeys_credential_hash (credential_id_hash),
  INDEX idx_user_passkeys_user_id (user_id),
  CONSTRAINT fk_user_passkeys_user FOREIGN KEY (user_id)
    REFERENCES users(id) ON DELETE CASCADE,
  CHECK (JSON_VALID(transports))
);
