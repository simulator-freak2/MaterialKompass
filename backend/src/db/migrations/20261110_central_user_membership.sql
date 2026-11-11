-- New central accounts must never be mistaken for legacy single-org users
-- after a crash between identity and collection persistence.
ALTER TABLE users ADD COLUMN IF NOT EXISTS membership_managed TINYINT(1) NOT NULL DEFAULT 0;
