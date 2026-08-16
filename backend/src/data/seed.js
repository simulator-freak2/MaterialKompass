const permissions = [
  'users.read', 'users.write',
  'roles.read',
  'locations.read', 'locations.write',
  'categories.read', 'categories.write',
  'material.read', 'material.write',
  'inventory.read', 'inventory.write', 'inventory.transactions',
  'inventory.relocate', 'inventory.archive', 'inventory.import', 'inventory.export',
  'clothing.read', 'clothing.write', 'clothing.inspect',
  'transactions.read', 'transactions.write',
  'defects.read', 'defects.write',
  'defects.report', 'defects.edit', 'defects.assign', 'defects.close',
  'defects.archive', 'defects.delete', 'defects.export',
  'procurement.read', 'procurement.write', 'procurement.request',
  'procurement.approve', 'procurement.order', 'procurement.receive',
  'procurement.export', 'suppliers.write',
  'documents.read',
  'reports.read', 'reports.write',
  'dashboard.read',
  'stocktakes.read', 'stocktakes.create', 'stocktakes.count',
  'stocktakes.evaluate', 'stocktakes.export', 'stocktakes.email.import',
];

const roles = [
  { id: 'role-admin', name: 'Admin', permissions },
  { id: 'role-user', name: 'Nutzer', permissions: ['categories.read', 'locations.read', 'material.read', 'inventory.read', 'dashboard.read'] },
  { id: 'role-materialwart', name: 'Materialwart', permissions: ['categories.read', 'categories.write', 'locations.read', 'locations.write', 'material.read', 'material.write', 'inventory.read', 'inventory.write', 'inventory.transactions', 'inventory.relocate', 'inventory.archive', 'inventory.import', 'inventory.export', 'transactions.read', 'transactions.write', 'defects.read', 'defects.write', 'defects.report', 'defects.edit', 'defects.assign', 'defects.close', 'defects.archive', 'defects.delete', 'defects.export', 'documents.read', 'procurement.read', 'procurement.request', 'procurement.order', 'procurement.receive', 'procurement.export', 'suppliers.write', 'dashboard.read'] },
  { id: 'role-kleiderwart', name: 'Kleiderwart', permissions: ['categories.read', 'locations.read', 'clothing.read', 'clothing.write', 'clothing.inspect', 'inventory.read', 'inventory.transactions', 'inventory.relocate', 'inventory.export', 'transactions.read', 'transactions.write', 'defects.read', 'defects.report', 'defects.edit', 'defects.assign', 'defects.close', 'defects.archive', 'defects.delete', 'defects.export', 'procurement.read', 'procurement.request', 'procurement.order', 'procurement.receive', 'procurement.export', 'suppliers.write', 'dashboard.read'] },
  { id: 'role-fachbereichsleiter', name: 'Fachbereichsleiter', permissions: ['categories.read', 'locations.read', 'material.read', 'inventory.read', 'inventory.transactions', 'inventory.relocate', 'inventory.export', 'procurement.read', 'procurement.request', 'procurement.export', 'reports.read', 'dashboard.read'] },
  { id: 'role-vorsitz', name: 'Vorsitz', permissions: ['categories.read', 'categories.write', 'locations.read', 'locations.write', 'material.read', 'material.write', 'inventory.read', 'inventory.write', 'inventory.transactions', 'inventory.relocate', 'inventory.archive', 'inventory.import', 'inventory.export', 'defects.read', 'procurement.read', 'procurement.request', 'procurement.approve', 'procurement.export', 'suppliers.write', 'reports.read', 'dashboard.read'] },
  { id: 'role-schatzmeister', name: 'Schatzmeister', permissions: ['categories.read', 'locations.read', 'material.read', 'inventory.read', 'procurement.read', 'procurement.request', 'procurement.approve', 'procurement.export', 'suppliers.write', 'reports.read', 'dashboard.read'] },
  { id: 'role-jugendvorsitzender', name: 'Jugendvorsitzender', permissions: ['material.read', 'dashboard.read'] },
  { id: 'role-sachkundiger', name: 'Sachkundiger PSAgE', permissions: ['material.read', 'clothing.read', 'clothing.inspect', 'defects.read'] },
];

const users = [
  {
    id: 'user-admin',
    name: 'Admin User',
    username: 'admin',
    email: 'admin@materialkompass.org',
    // Hash of the documented local-development password. Production replaces
    // it when the first database user is created (see server.js).
    passwordHash: '$2a$12$7nR.kNwGpXK1APgVoIKTU.uCtrzO8CXZ.ECmSIWYpJ7tthBB75qOu',
    roles: ['Admin'],
    departmentIds: [],
    permissions,
    active: true,
    failedLoginAttempts: 0,
    createdAt: '2026-01-01T00:00:00.000Z',
    lastLoginAt: null,
    emailVerifiedAt: '2026-01-01T00:00:00.000Z',
  },
  {
    id: 'user-materialwart',
    name: 'Miriam Material',
    username: 'materialwart',
    email: 'materialwart@materialkompass.local',
    passwordHash: '$2a$10$BLFjpHTdxbS9fHNO70twwu1mH1cq42P45wvLlcdnvetS6D/ZqtpcC',
    roles: ['Materialwart'],
    departmentIds: [],
    permissions: ['categories.read', 'categories.write', 'locations.read', 'locations.write', 'material.read', 'material.write', 'inventory.read', 'inventory.write', 'inventory.transactions', 'inventory.relocate', 'inventory.archive', 'inventory.import', 'inventory.export', 'transactions.read', 'transactions.write', 'defects.read', 'defects.write', 'documents.read', 'procurement.read', 'procurement.request', 'procurement.order', 'procurement.receive', 'procurement.export', 'suppliers.write', 'dashboard.read'],
    active: true,
    failedLoginAttempts: 0,
    createdAt: '2026-01-02T00:00:00.000Z',
    lastLoginAt: null,
    emailVerifiedAt: '2026-01-02T00:00:00.000Z',
  },
];

const departments = [
  { id: 'department-technik', name: 'Technik', code: 'TECH', active: true },
];

const locations = [
  { id: 'loc-1', name: 'Hauptlager', code: 'HL', type: 'Lager' },
  { id: 'loc-2', name: 'Kleiderkammer', code: 'KK', type: 'Kleidung' },
  { id: 'loc-3', name: 'Nebenlager', code: 'NL', type: 'Lager' },
];

const stockStructures = [
  { id: 'stock-1', name: 'Regal A', locationId: 'loc-1', section: 'A1' },
  { id: 'stock-2', name: 'Kleiderregal', locationId: 'loc-2', section: 'K1' },
];

const categories = [
  { id: '02', name: 'Werkzeug', parentId: null, useInWardrobe: false },
  { id: '02-02', name: 'Handwerk', parentId: '02', useInWardrobe: false },
  { id: '04', name: 'Kleidung', parentId: null, useInWardrobe: true, sizes: ['XS', 'S', 'M', 'L', 'XL', 'XXL'], inspectionIntervalMonths: null, requiresPsageInspection: false },
  { id: '04-01', name: 'Einsatzkleidung', parentId: '04', useInWardrobe: false, sizes: ['XS', 'S', 'M', 'L', 'XL', 'XXL'], inspectionIntervalMonths: 12, requiresPsageInspection: false },
  { id: '04-04', name: 'Schutzkleidung', parentId: '04', useInWardrobe: false, sizes: ['S', 'M', 'L', 'XL'], inspectionIntervalMonths: 12, requiresPsageInspection: true },
  { id: '04-05', name: 'Zubehör', parentId: '04', useInWardrobe: false, sizes: ['Einheitsgröße'], inspectionIntervalMonths: null, requiresPsageInspection: false },
];

const materials = [
  {
    id: 'material-1',
    inventoryNumber: '10050035-02-02-001',
    name: 'Kettensäge',
    categoryCode: '02',
    subcategoryCode: '02-02',
    locationId: 'loc-1',
    status: 'Lagernd',
    description: 'Für Einsätze im Lager',
    notes: '',
    itemType: 'individual',
    quantity: 1,
    unit: 'Stück',
    issuedQuantity: 0,
    stockStructureId: 'stock-1',
    manufacturer: 'Stihl',
    model: '',
    serialNumber: '',
    purchaseDate: null,
    purchasePrice: null,
    department: 'Technik',
    inspectionIntervalMonths: 12,
    lastInspectionDate: null,
    nextInspectionDate: '2027-01-01',
    archived: false,
    createdAt: '2026-01-01T00:00:00.000Z',
  },
];

const materialMovements = [];
const materialInspections = [];
const materialDocuments = [];
const clothingInspections = [];

const clothingItems = [
  {
    id: 'clothing-1',
    inventoryNumber: '10050035-04-01-0001',
    name: 'Wetterjacke',
    categoryId: '04-01',
    size: 'M',
    locationId: 'loc-2',
    stockStructureId: 'stock-2',
    status: 'Lagernd',
    assignedPerson: null,
    inspectionIntervalMonths: 12,
    lastInspectionDate: null,
    nextInspectionDate: '2027-01-01',
  },
];

const issueTransactions = [];
const defectReports = [];
const notifications = [];
const defectEmailImports = [];
const procurementRequests = [];
const procurementOffers = [];
const procurementOrders = [];
const procurementReceipts = [];
const procurementDocuments = [];
const procurementEmailImports = [];
const suppliers = [{
  id: 'supplier-1',
  name: 'DLRG Fachhandel',
  contact: 'Vertrieb',
  address: 'Musterstraße 1, 12345 Musterstadt, Deutschland',
  street: 'Musterstraße',
  houseNumber: '1',
  postalCode: '12345',
  city: 'Musterstadt',
  country: 'Deutschland',
  customerNumber: '',
  email: 'info@fachhandel.example',
  phone: '',
  website: '',
  paymentTerms: '14 Tage netto',
  active: true,
}];
const documents = [];
const auditLogs = [{ id: 'audit-1', timestamp: new Date().toISOString(), actor: 'system', action: 'seed', entity: 'System', details: 'Initial seed complete' }];
const exportLogs = [];
const scannerEmailAddresses = [];
const stocktakes = [];
const stocktakeEmailImports = [];

module.exports = {
  seedData: {
    permissions,
    roles,
    users,
    departments,
    locations,
    stockStructures,
    categories,
    materials,
    materialMovements,
    materialInspections,
    materialDocuments,
    clothingItems,
    clothingInspections,
    issueTransactions,
    defectReports,
    notifications,
    defectEmailImports,
    procurementRequests,
    procurementOffers,
    procurementOrders,
    procurementReceipts,
    procurementDocuments,
    procurementEmailImports,
    suppliers,
    documents,
    auditLogs,
    exportLogs,
    scannerEmailAddresses,
    stocktakes,
    stocktakeEmailImports,
  },
};
