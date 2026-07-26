const bcrypt = require('bcryptjs');

const CONFIRMATION_PHRASE = 'DATEN LÖSCHEN';

const AREAS = Object.freeze([
  {
    id: 'inventory',
    label: 'Inventar',
    description: 'Material, Archiv, Bewegungen, Prüfungen und Materialdokumente',
    collections: ['materials', 'deletedMaterials', 'materialMovements', 'materialInspections', 'materialDocuments'],
  },
  {
    id: 'wardrobe',
    label: 'Kleiderkammer',
    description: 'Kleidungsstücke, Archiv, Prüfungen und Ausgaben',
    collections: ['clothingItems', 'clothingInspections', 'deletedClothingItems', 'issueTransactions'],
  },
  {
    id: 'defects',
    label: 'Mängel',
    description: 'Alle aktiven und archivierten Mängelmeldungen',
    collections: ['defectReports'],
  },
  {
    id: 'procurement',
    label: 'Beschaffung',
    description: 'Anträge, Angebote, Bestellungen, Wareneingänge, Dokumente und Lieferanten',
    collections: ['procurementRequests', 'procurementOffers', 'procurementOrders', 'procurementReceipts', 'procurementDocuments', 'suppliers'],
  },
  {
    id: 'storage',
    label: 'Lagerverwaltung',
    description: 'Standorte, Lagerstrukturen, Zuordnungen, Inventuren und Lagerhistorie',
    collections: ['locations', 'stockStructures', 'storageRacks', 'storageLevels', 'storagePlaces', 'storageBoxes', 'storageAssignments', 'stocktakes', 'storageHistory'],
  },
  {
    id: 'masterData',
    label: 'Stammdaten',
    description: 'Kategorien und Fachbereiche',
    collections: ['categories', 'departments'],
  },
  {
    id: 'accounts',
    label: 'Benutzerkonten',
    description: 'Alle Benutzerkonten außer dem ausführenden Admin',
    collections: [],
  },
  {
    id: 'systemData',
    label: 'Protokolle & Systemdaten',
    description: 'Benachrichtigungen, Dokumente, Exportprotokolle und QR-Anmeldungen',
    collections: ['notifications', 'documents', 'auditLogs', 'exportLogs', 'qrLoginCredentials'],
  },
]);

function registerAdminDataManagement({
  app,
  data,
  users,
  authMiddleware,
  userStore,
  logEvent,
}) {
  const isAdmin = (req, res, next) => {
    if (!req.user?.roles?.includes('Admin')) {
      return res.status(403).json({ error: 'Diese Funktion ist ausschließlich für Admins verfügbar.' });
    }
    return next();
  };

  const collection = (name) => (data[name] ||= []);
  const retain = (name, predicate) => {
    const values = collection(name);
    const kept = values.filter(predicate);
    values.splice(0, values.length, ...kept);
  };
  const countArea = (area, currentUser) => area.id === 'accounts'
    ? users.filter((user) => user.id !== currentUser.id).length
    : area.collections.reduce((total, name) => total + collection(name).length, 0);

  app.get('/api/admin/data-management', authMiddleware, isAdmin, (req, res) => {
    res.json({
      confirmationPhrase: CONFIRMATION_PHRASE,
      preserved: 'Der ausführende Admin, Rollen und Berechtigungen bleiben erhalten.',
      areas: AREAS.map((area) => ({
        id: area.id,
        label: area.label,
        description: area.description,
        count: countArea(area, req.user),
      })),
    });
  });

  app.delete('/api/admin/data-management', authMiddleware, isAdmin, async (req, res) => {
    const requestedScopes = Array.isArray(req.body.scopes)
      ? [...new Set(req.body.scopes.map(String))]
      : [];
    const knownScopes = new Set(AREAS.map((area) => area.id));
    if (requestedScopes.length === 0 || requestedScopes.some((scope) => !knownScopes.has(scope))) {
      return res.status(400).json({ error: 'Mindestens ein gültiger Datenbereich muss ausgewählt werden.' });
    }
    if (req.body.confirmation !== CONFIRMATION_PHRASE) {
      return res.status(400).json({ error: `Zur Bestätigung muss „${CONFIRMATION_PHRASE}“ eingegeben werden.` });
    }
    if (!await bcrypt.compare(String(req.body.currentPassword || ''), req.user.passwordHash)) {
      return res.status(403).json({ error: 'Das aktuelle Passwort ist nicht korrekt.' });
    }

    const selectedAreas = AREAS.filter((area) => requestedScopes.includes(area.id));
    const names = new Set(selectedAreas.flatMap((area) => area.collections));
    const deletedByArea = Object.fromEntries(
      selectedAreas.map((area) => [area.id, countArea(area, req.user)]),
    );

    // Keep the same array objects because all route modules hold references to them.
    for (const name of names) collection(name).splice(0);

    // Removing a fachlicher Bereich also removes dependent cross-area references.
    if (requestedScopes.includes('inventory') && !names.has('storageAssignments')) {
      retain('storageAssignments', (entry) => entry.entityType !== 'material');
    }
    if (requestedScopes.includes('inventory') && !names.has('defectReports')) {
      retain('defectReports', (entry) => entry.entityType !== 'MaterialItem');
    }
    if (requestedScopes.includes('wardrobe') && !names.has('storageAssignments')) {
      retain('storageAssignments', (entry) => entry.entityType !== 'clothing');
    }
    if (requestedScopes.includes('wardrobe') && !names.has('defectReports')) {
      retain('defectReports', (entry) => entry.entityType !== 'ClothingItem');
    }
    if (requestedScopes.includes('masterData')) {
      await Promise.all(users.map(async (user) => {
        user.departmentIds = [];
        await userStore?.saveUser(user);
      }));
    }
    if (requestedScopes.includes('accounts')) {
      const removedUserIds = new Set(
        users.filter((user) => user.id !== req.user.id).map((user) => user.id),
      );
      await Promise.all([...removedUserIds].map(
        (id) => userStore?.deleteUser(id) || Promise.resolve(),
      ));
      retain('qrLoginCredentials', (credential) => !removedUserIds.has(credential.userId));
      const currentAdmin = users.find((user) => user.id === req.user.id);
      users.splice(0, users.length, currentAdmin);
    }

    // A single security entry intentionally survives so the destructive action remains attributable.
    logEvent('purge', 'System', { scopes: requestedScopes, deletedByArea }, req.user.username);
    return res.json({
      message: 'Die ausgewählten Datenbereiche wurden dauerhaft gelöscht.',
      scopes: requestedScopes,
      deletedByArea,
    });
  });
}

module.exports = { registerAdminDataManagement, AREAS, CONFIRMATION_PHRASE };
