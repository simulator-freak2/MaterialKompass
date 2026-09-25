-- Additive preparation for multi-organization operation. The existing
-- application collections are assigned to the import organization before the
-- operator exports and re-imports them into their final organization.

ALTER TABLE users
  ADD COLUMN IF NOT EXISTS platform_admin TINYINT(1) NOT NULL DEFAULT 0
    AFTER permissions;

UPDATE users
SET platform_admin = 1
WHERE id = 'user-admin';

ALTER TABLE roles
  ADD COLUMN IF NOT EXISTS organization_id VARCHAR(64) NULL AFTER id;

ALTER TABLE roles DROP INDEX IF EXISTS uq_roles_name;
ALTER TABLE roles
  ADD UNIQUE INDEX IF NOT EXISTS uq_roles_organization_name
    (organization_id, name);

ALTER TABLE application_collections
  ADD COLUMN IF NOT EXISTS organization_id VARCHAR(64) NULL FIRST;

UPDATE application_collections
SET organization_id = '__platform__'
WHERE name IN ('organizations', 'organizationUnits', 'memberships', 'permissions')
  AND organization_id IS NULL;

UPDATE application_collections
SET organization_id = 'org-default'
WHERE organization_id IS NULL;

ALTER TABLE application_collections
  MODIFY organization_id VARCHAR(64) NOT NULL;

ALTER TABLE application_collections DROP PRIMARY KEY;
ALTER TABLE application_collections
  ADD PRIMARY KEY (organization_id, name),
  ADD INDEX IF NOT EXISTS idx_application_collections_name (name);
