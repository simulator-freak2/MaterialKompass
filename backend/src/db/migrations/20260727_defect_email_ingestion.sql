CREATE TABLE IF NOT EXISTS mailbox_processing_state (
  mailbox VARCHAR(255) PRIMARY KEY,
  uid_validity VARCHAR(64) NOT NULL,
  last_uid BIGINT UNSIGNED NOT NULL,
  initialized_at DATETIME NOT NULL,
  updated_at DATETIME NOT NULL
);
