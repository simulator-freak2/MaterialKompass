CREATE TABLE IF NOT EXISTS user_mfa_push_devices (
  id CHAR(36) PRIMARY KEY,
  user_id VARCHAR(64) NOT NULL,
  name VARCHAR(100) NOT NULL,
  platform ENUM('android', 'web') NOT NULL,
  push_token TEXT CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
  device_secret_hash BINARY(32) NOT NULL,
  created_at DATETIME(3) NOT NULL,
  last_used_at DATETIME(3) NULL,
  updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
    ON UPDATE CURRENT_TIMESTAMP(3),
  INDEX idx_user_mfa_push_devices_user_id (user_id),
  CONSTRAINT fk_user_mfa_push_devices_user FOREIGN KEY (user_id)
    REFERENCES users(id) ON DELETE CASCADE
);
