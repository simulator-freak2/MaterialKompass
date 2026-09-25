-- Organisationsstrukturen besitzen eine eigene, explizite Berechtigung.
-- Sie wird bestehenden Admin-Rollen zugewiesen; die API verlangt zusaetzlich
-- weiterhin die Admin-Rolle und fuer neue Hauptorganisationen platform_admin.

INSERT IGNORE INTO permissions (id, name)
VALUES ('organizations.write', 'organizations.write');

UPDATE roles
SET permissions = JSON_ARRAY_APPEND(permissions, '$', 'organizations.write')
WHERE name = 'Admin'
  AND NOT JSON_CONTAINS(permissions, JSON_QUOTE('organizations.write'));

UPDATE application_collections
SET data_json = JSON_ARRAY_APPEND(data_json, '$', 'organizations.write')
WHERE organization_id = '__platform__'
  AND name = 'permissions'
  AND NOT JSON_CONTAINS(data_json, JSON_QUOTE('organizations.write'));
