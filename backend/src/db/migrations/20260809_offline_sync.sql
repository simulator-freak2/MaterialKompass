-- Offline-Metadaten werden transaktional mit den übrigen dynamischen
-- Anwendungssammlungen gespeichert.
INSERT INTO application_collections (name, data_json) VALUES
  ('offlineClients', '[]'),
  ('offlineCommandResults', '[]'),
  ('offlineSyncState', '[{"revision":0,"updatedAt":null}]')
ON DUPLICATE KEY UPDATE name = VALUES(name);
