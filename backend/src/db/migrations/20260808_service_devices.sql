-- Dienstgeräte werden wie die übrigen dynamischen Anwendungssammlungen in
-- application_collections persistiert. Dieser Eintrag sorgt bei bestehenden
-- Installationen für eine explizite, leere Ausgangssammlung.
INSERT INTO application_collections (name, data_json)
VALUES ('serviceDevices', '[]')
ON DUPLICATE KEY UPDATE name = VALUES(name);
