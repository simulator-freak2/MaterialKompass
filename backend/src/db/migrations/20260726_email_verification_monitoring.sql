ALTER TABLE users
  ADD COLUMN IF NOT EXISTS created_by_user_id VARCHAR(64) NULL AFTER created_at,
  ADD COLUMN IF NOT EXISTS email_verification_managed TINYINT(1) DEFAULT 0 AFTER email_verified_at,
  ADD COLUMN IF NOT EXISTS email_verification_requested_at DATETIME NULL AFTER email_verification_managed,
  ADD INDEX IF NOT EXISTS idx_users_created_by (created_by_user_id);

CREATE TABLE IF NOT EXISTS account_mail_deliveries (
  id VARCHAR(64) PRIMARY KEY,
  type VARCHAR(64) NOT NULL,
  user_id VARCHAR(64) NOT NULL,
  created_by_user_id VARCHAR(64) NULL,
  recipient_email VARCHAR(255) NOT NULL,
  message_id VARCHAR(255) NULL,
  sent_at DATETIME NOT NULL,
  bounce_forwarded_at DATETIME NULL,
  INDEX idx_account_mail_message_id (message_id),
  INDEX idx_account_mail_recipient (recipient_email),
  INDEX idx_account_mail_user (user_id)
);

CREATE TABLE IF NOT EXISTS mailbox_processing_state (
  mailbox VARCHAR(255) PRIMARY KEY,
  uid_validity VARCHAR(64) NOT NULL,
  last_uid BIGINT UNSIGNED NOT NULL,
  initialized_at DATETIME NOT NULL,
  updated_at DATETIME NOT NULL
);
