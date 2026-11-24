-- API-Schlüssel für Partneranwendungen (z. B. Übungsplaner) werden wie die
-- übrigen dynamischen Anwendungssammlungen in application_collections
-- persistiert. Gespeichert wird ausschließlich ein SHA-256-Prüfwert des Schlüssels.
INSERT INTO application_collections (name, data_json)
VALUES ('integrationApiKeys', '[]')
ON DUPLICATE KEY UPDATE name = VALUES(name);
