const express = require('express');
const cors = require('cors');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const { seedData } = require('./data/seed');

function createApp() {
  const app = express();
  app.use(cors());
  app.use(express.json());

  const roles = seedData.roles;
  const permissions = seedData.permissions;
  const users = seedData.users;
  const locations = seedData.locations;
  const stockStructures = seedData.stockStructures;
  const categories = seedData.categories;
  const subcategories = seedData.subcategories;
  const materials = seedData.materials;
  const clothingItems = seedData.clothingItems;
  const issueTransactions = seedData.issueTransactions;
  const defectReports = seedData.defectReports;
  const procurementRequests = seedData.procurementRequests;
  const suppliers = seedData.suppliers;
  const documents = seedData.documents;
  const auditLogs = seedData.auditLogs;
  const exportLogs = seedData.exportLogs;

  function createToken(user) {
    return jwt.sign(
      { sub: user.id, email: user.email, roles: user.roles },
      process.env.JWT_SECRET || 'dev-secret',
      { expiresIn: '30m' }
    );
  }

  function getUserByEmail(email) {
    return users.find((user) => user.email === email);
  }

  function authMiddleware(req, res, next) {
    const header = req.headers.authorization || '';
    const token = header.startsWith('Bearer ') ? header.slice(7) : null;
    if (!token) {
      return res.status(401).json({ error: 'Authentication required' });
    }

    try {
      const payload = jwt.verify(token, process.env.JWT_SECRET || 'dev-secret');
      req.user = users.find((u) => u.id === payload.sub) || null;
      if (!req.user) {
        return res.status(401).json({ error: 'Unknown user' });
      }
      next();
    } catch (error) {
      return res.status(401).json({ error: 'Invalid token' });
    }
  }

  function hasPermission(user, permission) {
    return user?.permissions?.includes(permission) || user?.roles?.includes('Admin');
  }

  function requirePermission(permission) {
    return (req, res, next) => {
      if (!hasPermission(req.user, permission)) {
        return res.status(403).json({ error: 'Forbidden' });
      }
      next();
    };
  }

  function logEvent(action, entity, details, actor = 'system') {
    auditLogs.push({
      id: `audit-${auditLogs.length + 1}`,
      timestamp: new Date().toISOString(),
      actor,
      action,
      entity,
      details,
    });
  }

  function generateInventoryNumber(categoryCode, subcategoryCode) {
    const categoryKey = categoryCode || '00';
    const subcategoryKey = subcategoryCode || '00';
    const counter = materials.filter((item) => item.categoryCode === categoryKey && item.subcategoryCode === subcategoryKey).length + 1;
    return `10050035-${categoryKey}-${subcategoryKey}-${String(counter).padStart(4, '0')}`;
  }

  app.get('/health', (req, res) => res.json({ status: 'ok' }));

  app.post('/api/auth/login', async (req, res) => {
    const { email, password } = req.body;
    const user = getUserByEmail(email);

    if (!user) {
      return res.status(401).json({ error: 'Invalid credentials' });
    }

    const valid = await bcrypt.compare(password || '', user.passwordHash);
    if (!valid) {
      user.failedLoginAttempts = (user.failedLoginAttempts || 0) + 1;
      if (user.failedLoginAttempts >= 5) {
        user.lockedUntil = new Date(Date.now() + 15 * 60 * 1000).toISOString();
      }
      logEvent('login_failed', 'User', { email }, email);
      return res.status(401).json({ error: 'Invalid credentials' });
    }

    user.failedLoginAttempts = 0;
    user.lockedUntil = null;
    const token = createToken(user);
    logEvent('login', 'User', { email }, email);
    res.json({ token, user: { ...user, passwordHash: undefined } });
  });

  app.post('/api/auth/password-reset', (req, res) => {
    const { email } = req.body;
    const user = getUserByEmail(email);
    if (!user) {
      return res.status(404).json({ error: 'User not found' });
    }
    logEvent('password_reset_requested', 'User', { email }, email);
    res.json({ message: 'Password reset request accepted' });
  });

  app.get('/api/auth/me', authMiddleware, (req, res) => {
    res.json({ user: { ...req.user, passwordHash: undefined } });
  });

  app.get('/api/roles', authMiddleware, requirePermission('roles.read'), (req, res) => {
    res.json(roles);
  });

  app.get('/api/users', authMiddleware, requirePermission('users.read'), (req, res) => {
    res.json(users.map((user) => ({ ...user, passwordHash: undefined })));
  });

  app.post('/api/users', authMiddleware, requirePermission('users.write'), (req, res) => {
    const newUser = {
      id: `user-${users.length + 1}`,
      ...req.body,
      passwordHash: bcrypt.hashSync(req.body.password || 'ChangeMe123!', 10),
      roles: req.body.roles || ['Nutzer'],
      permissions: req.body.permissions || ['material.read'],
      failedLoginAttempts: 0,
      createdAt: new Date().toISOString(),
    };
    users.push(newUser);
    logEvent('create', 'User', { id: newUser.id }, req.user.email);
    res.status(201).json({ ...newUser, passwordHash: undefined });
  });

  app.get('/api/locations', authMiddleware, requirePermission('locations.read'), (req, res) => {
    res.json(locations);
  });

  app.post('/api/locations', authMiddleware, requirePermission('locations.write'), (req, res) => {
    const location = { id: `loc-${locations.length + 1}`, ...req.body };
    locations.push(location);
    logEvent('create', 'Location', { id: location.id }, req.user.email);
    res.status(201).json(location);
  });

  app.get('/api/stock-structures', authMiddleware, requirePermission('locations.read'), (req, res) => {
    res.json(stockStructures);
  });

  app.get('/api/categories', authMiddleware, requirePermission('categories.read'), (req, res) => {
    res.json(categories);
  });

  app.get('/api/subcategories', authMiddleware, requirePermission('categories.read'), (req, res) => {
    res.json(subcategories);
  });

  app.get('/api/material', authMiddleware, requirePermission('material.read'), (req, res) => {
    res.json(materials);
  });

  app.post('/api/material', authMiddleware, requirePermission('material.write'), (req, res) => {
    const item = {
      id: `material-${materials.length + 1}`,
      inventoryNumber: generateInventoryNumber(req.body.categoryCode, req.body.subcategoryCode),
      ...req.body,
      createdAt: new Date().toISOString(),
      status: req.body.status || 'Lagernd',
    };
    materials.push(item);
    logEvent('create', 'MaterialItem', { id: item.id, inventoryNumber: item.inventoryNumber }, req.user.email);
    res.status(201).json(item);
  });

  app.get('/api/material/:id', authMiddleware, requirePermission('material.read'), (req, res) => {
    const item = materials.find((material) => material.id === req.params.id);
    if (!item) return res.status(404).json({ error: 'Material not found' });
    res.json(item);
  });

  app.get('/api/clothing', authMiddleware, requirePermission('clothing.read'), (req, res) => {
    res.json(clothingItems);
  });

  app.post('/api/clothing', authMiddleware, requirePermission('clothing.write'), (req, res) => {
    const item = { id: `clothing-${clothingItems.length + 1}`, ...req.body, createdAt: new Date().toISOString() };
    clothingItems.push(item);
    logEvent('create', 'ClothingItem', { id: item.id }, req.user.email);
    res.status(201).json(item);
  });

  app.post('/api/transactions', authMiddleware, requirePermission('transactions.write'), (req, res) => {
    const transaction = { id: `txn-${issueTransactions.length + 1}`, ...req.body, createdAt: new Date().toISOString() };
    issueTransactions.push(transaction);
    logEvent('transaction', 'IssueTransaction', { id: transaction.id }, req.user.email);
    res.status(201).json(transaction);
  });

  app.get('/api/defects', authMiddleware, requirePermission('defects.read'), (req, res) => {
    res.json(defectReports);
  });

  app.post('/api/defects', authMiddleware, requirePermission('defects.write'), (req, res) => {
    const report = { id: `defect-${defectReports.length + 1}`, ...req.body, createdAt: new Date().toISOString() };
    defectReports.push(report);
    logEvent('create', 'DefectReport', { id: report.id }, req.user.email);
    res.status(201).json(report);
  });

  app.get('/api/procurement', authMiddleware, requirePermission('procurement.read'), (req, res) => {
    res.json(procurementRequests);
  });

  app.post('/api/procurement', authMiddleware, requirePermission('procurement.write'), (req, res) => {
    const request = { id: `proc-${procurementRequests.length + 1}`, status: 'Entwurf', ...req.body, createdAt: new Date().toISOString() };
    procurementRequests.push(request);
    logEvent('create', 'ProcurementRequest', { id: request.id }, req.user.email);
    res.status(201).json(request);
  });

  app.get('/api/documents', authMiddleware, requirePermission('documents.read'), (req, res) => {
    res.json(documents);
  });

  app.get('/api/reports', authMiddleware, requirePermission('reports.read'), (req, res) => {
    res.json({
      materialCount: materials.length,
      clothingCount: clothingItems.length,
      openDefects: defectReports.filter((item) => item.status !== 'Behoben').length,
      pendingProcurement: procurementRequests.filter((item) => item.status === 'Beantragt').length,
      auditEntries: auditLogs.length,
      exportEntries: exportLogs.length,
    });
  });

  app.get('/api/dashboard', authMiddleware, requirePermission('dashboard.read'), (req, res) => {
    res.json({
      summary: {
        materialCount: materials.length,
        clothingCount: clothingItems.length,
        defectCount: defectReports.length,
        procurementCount: procurementRequests.length,
      },
      recentActivity: auditLogs.slice(-5).reverse(),
    });
  });

  app.post('/api/export-log', authMiddleware, requirePermission('reports.read'), (req, res) => {
    const entry = { id: `export-${exportLogs.length + 1}`, ...req.body, createdAt: new Date().toISOString() };
    exportLogs.push(entry);
    logEvent('export', 'ExportLog', { id: entry.id }, req.user.email);
    res.status(201).json(entry);
  });

  return app;
}

module.exports = { createApp };
