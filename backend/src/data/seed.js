const bcrypt = require('bcryptjs');

const permissions = [
  'users.read', 'users.write',
  'roles.read',
  'locations.read', 'locations.write',
  'categories.read',
  'material.read', 'material.write',
  'clothing.read', 'clothing.write',
  'transactions.write',
  'defects.read', 'defects.write',
  'procurement.read', 'procurement.write',
  'documents.read',
  'reports.read',
  'dashboard.read',
];

const roles = [
  { id: 'role-admin', name: 'Admin', permissions },
  { id: 'role-user', name: 'Nutzer', permissions: ['material.read', 'dashboard.read'] },
  { id: 'role-materialwart', name: 'Materialwart', permissions: ['material.read', 'material.write', 'transactions.write', 'defects.write'] },
  { id: 'role-kleiderwart', name: 'Kleiderwart', permissions: ['clothing.read', 'clothing.write', 'transactions.write'] },
  { id: 'role-fachbereichsleiter', name: 'Fachbereichsleiter', permissions: ['material.read', 'reports.read'] },
  { id: 'role-vorsitzender', name: 'Vorsitzender', permissions: ['procurement.read', 'procurement.write', 'reports.read'] },
  { id: 'role-kassenwart', name: 'Kassenwart', permissions: ['procurement.read', 'procurement.write', 'reports.read'] },
  { id: 'role-jugendvorsitzender', name: 'Jugendvorsitzender', permissions: ['material.read', 'dashboard.read'] },
  { id: 'role-sachkundiger', name: 'Sachkundiger PSAgE', permissions: ['material.read', 'defects.read'] },
];

const users = [
  {
    id: 'user-admin',
    name: 'Admin User',
    email: 'admin@materialkompass.local',
    passwordHash: bcrypt.hashSync('Admin123!', 10),
    roles: ['Admin'],
    permissions,
    active: true,
    failedLoginAttempts: 0,
    createdAt: '2026-01-01T00:00:00.000Z',
  },
  {
    id: 'user-materialwart',
    name: 'Miriam Material',
    email: 'materialwart@materialkompass.local',
    passwordHash: bcrypt.hashSync('Material123!', 10),
    roles: ['Materialwart'],
    permissions: ['material.read', 'material.write', 'transactions.write', 'defects.write', 'dashboard.read'],
    active: true,
    failedLoginAttempts: 0,
    createdAt: '2026-01-02T00:00:00.000Z',
  },
];

const locations = [
  { id: 'loc-1', name: 'Hauptlager', code: 'HL', type: 'Lager' },
  { id: 'loc-2', name: 'Kleiderkammer', code: 'KK', type: 'Kleidung' },
];

const stockStructures = [
  { id: 'stock-1', name: 'Regal A', locationId: 'loc-1', section: 'A1' },
  { id: 'stock-2', name: 'Kleiderregal', locationId: 'loc-2', section: 'K1' },
];

const categories = [
  { id: 'cat-1', name: 'Werkzeug', code: '02' },
  { id: 'cat-2', name: 'Kleidung', code: '04' },
];

const subcategories = [
  { id: 'sub-1', name: 'Handwerk', categoryId: 'cat-1', code: '02' },
  { id: 'sub-2', name: 'Schutzkleidung', categoryId: 'cat-2', code: '04' },
];

const materials = [
  {
    id: 'material-1',
    inventoryNumber: '10050035-02-02-0001',
    name: 'Kettensäge',
    categoryCode: '02',
    subcategoryCode: '02',
    locationId: 'loc-1',
    status: 'Lagernd',
    description: 'Für Einsätze im Lager',
  },
];

const clothingItems = [
  {
    id: 'clothing-1',
    name: 'Wetterjacke',
    size: 'M',
    locationId: 'loc-2',
    status: 'Lagernd',
    assignedPerson: null,
  },
];

const issueTransactions = [];
const defectReports = [];
const procurementRequests = [];
const suppliers = [{ id: 'supplier-1', name: 'DLRG Fachhandel', contact: 'info@fachhandel.example' }];
const documents = [];
const auditLogs = [{ id: 'audit-1', timestamp: new Date().toISOString(), actor: 'system', action: 'seed', entity: 'System', details: 'Initial seed complete' }];
const exportLogs = [];

module.exports = {
  seedData: {
    permissions,
    roles,
    users,
    locations,
    stockStructures,
    categories,
    subcategories,
    materials,
    clothingItems,
    issueTransactions,
    defectReports,
    procurementRequests,
    suppliers,
    documents,
    auditLogs,
    exportLogs,
  },
};
