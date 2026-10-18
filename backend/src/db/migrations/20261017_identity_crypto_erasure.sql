ALTER TABLE users
  ADD COLUMN identity_ciphertext LONGTEXT NULL AFTER email,
  ADD COLUMN identity_erased TINYINT(1) NOT NULL DEFAULT 0 AFTER identity_ciphertext;

CREATE TABLE IF NOT EXISTS identity_protection_state (
  state_key VARCHAR(64) PRIMARY KEY,
  state_value VARCHAR(255) NOT NULL,
  updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
    ON UPDATE CURRENT_TIMESTAMP(3)
);
