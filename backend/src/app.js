const express = require('express');
const cors = require('cors');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const XLSX = require('xlsx');
const { seedData } = require('./data/seed');
const { registerInventoryRoutes } = require('./inventory');
const { registerProcurementRoutes } = require('./procurement');
const { nextInventoryNumber } = require('./inventory-number');
const { registerUserRoutes, publicUser } = require('./user-management');
const { registerDefectManagement } = require('./defects');
const {
  createDefectEmailService,
  registerDefectEmailRoutes,
} = require('./defect-email-ingestion');
const { registerQrLoginRoutes } = require('./qr-login');
const { registerScannerEmailRoutes } = require('./scanner-email-addresses');
const { createHash, randomUUID } = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { SUPPORTED_PLATFORMS, createCorsOptions, parseTrustProxy } = require('./config');
const { version } = require('../package.json');

const API_VERSION = '1';
const JWT_ISSUER = 'materialkompass-backend';
const JWT_AUDIENCE = 'materialkompass-clients';
const DEVELOPMENT_JWT_SECRET = randomUUID() + randomUUID();
const DUMMY_PASSWORD_HASH = bcrypt.hashSync(randomUUID(), 12);
const AUTH_WINDOW_MS = 15 * 60 * 1000;
const AUTH_MAX_REQUESTS = 10;
const MAX_IMPORT_ROWS = 1000;
const PERSISTED_COLLECTIONS = Object.freeze([
  'permissions', 'departments', 'locations', 'stockStructures', 'categories', 'materials',
  'deletedMaterials', 'materialMovements', 'materialInspections', 'materialDocuments',
  'clothingItems', 'clothingInspections', 'deletedClothingItems', 'issueTransactions',
  'defectReports', 'notifications', 'defectEmailImports',
  'procurementRequests', 'procurementOffers', 'procurementOrders',
  'procurementReceipts', 'procurementDocuments', 'suppliers', 'documents',
  'auditLogs', 'exportLogs',
  'qrLoginCredentials', 'scannerEmailAddresses',
]);

function createApp(options = {}) {
  if (process.env.NODE_ENV === 'production' && (!process.env.JWT_SECRET || process.env.JWT_SECRET.length < 32)) {
    throw new Error('JWT_SECRET muss im Produktivbetrieb mindestens 32 Zeichen lang sein.');
  }
  const app = express();
  const trustProxy = parseTrustProxy(process.env.TRUST_PROXY);
  if (trustProxy !== null) app.set('trust proxy', trustProxy);
  app.disable('x-powered-by');
  app.use((req, res, next) => {
    const suppliedRequestId = String(req.get('X-Request-Id') || '');
    const requestId = /^[A-Za-z0-9._:-]{1,128}$/.test(suppliedRequestId)
      ? suppliedRequestId
      : randomUUID();
    req.requestId = requestId;
    res.set({
      'X-API-Version': API_VERSION,
      'X-Request-Id': requestId,
      'X-Content-Type-Options': 'nosniff',
      'X-Frame-Options': 'DENY',
      'Referrer-Policy': 'no-referrer',
      'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
      'Cross-Origin-Resource-Policy': 'same-site',
      'Cache-Control': 'no-store',
    });
    if (process.env.NODE_ENV === 'production') {
      res.set('Strict-Transport-Security', 'max-age=31536000; includeSubDomains');
    }
    next();
  });
  app.use(cors(createCorsOptions()));
  app.use(express.json({ limit: process.env.JSON_BODY_LIMIT || '12mb' }));
  app.use((req, res, next) => {
    if (!['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method)) return next();
    if (req.body === undefined) req.body = {};
    if (req.body === null || Array.isArray(req.body) || typeof req.body !== 'object') {
      return res.status(400).json({ error: 'Der Request-Body muss ein JSON-Objekt sein.' });
    }
    return next();
  });

  // Every app instance owns its data. Referencing the exported seed arrays
  // directly leaks mutations into later app instances (and into other tests).
  const appData = structuredClone(options.data || seedData);
  if (options.userData) {
    appData.users = structuredClone(options.userData.users);
    appData.roles = structuredClone(options.userData.roles);
  } else if (process.env.NODE_ENV === 'production') {
    // Demo accounts have documented development passwords and must never be
    // exposed by a production instance that runs without a database.
    appData.users = appData.users.filter((user) => user.roles?.includes('Admin'));
  }
  const roles = appData.roles;
  const permissions = appData.permissions;
  const users = appData.users;
  const departments = (appData.departments ||= []);
  const locations = appData.locations;
  const stockStructures = appData.stockStructures;
  const categories = appData.categories;
  const materials = appData.materials;
  const deletedMaterials = (appData.deletedMaterials ||= []);
  const materialMovements = appData.materialMovements;
  const materialInspections = appData.materialInspections;
  const materialDocuments = appData.materialDocuments;
  const clothingItems = appData.clothingItems;
  const clothingInspections = appData.clothingInspections || [];
  const deletedClothingItems = (appData.deletedClothingItems ||= []);
  const issueTransactions = appData.issueTransactions;
  const defectReports = appData.defectReports;
  const notifications = (appData.notifications ||= []);
  const defectEmailImports = (appData.defectEmailImports ||= []);
  const procurementRequests = appData.procurementRequests;
  const suppliers = appData.suppliers;
  const documents = appData.documents;
  const auditLogs = appData.auditLogs;
  const exportLogs = appData.exportLogs;
  const qrLoginCredentials = (appData.qrLoginCredentials ||= []);
  const scannerEmailAddresses = (appData.scannerEmailAddresses ||= []);
  const defaultDownloadsDirectory = path.resolve(__dirname, '..', 'downloads');
  const downloadSources = options.downloads || {
    windows: {
      filePath: process.env.DOWNLOAD_WINDOWS_PATH
        || path.join(defaultDownloadsDirectory, 'MaterialKompass-Windows.exe'),
      fileName: 'MaterialKompass-Windows.exe',
    },
    linux: {
      filePath: process.env.DOWNLOAD_LINUX_PATH
        || path.join(defaultDownloadsDirectory, 'MaterialKompass-Linux.deb'),
      fileName: 'MaterialKompass-Linux.deb',
    },
    android: {
      filePath: process.env.DOWNLOAD_ANDROID_PATH
        || path.join(defaultDownloadsDirectory, 'MaterialKompass-Android.apk'),
      fileName: 'MaterialKompass-Android.apk',
    },
  };
  const downloadHashes = new Map();

  function desktopDownload(platform) {
    const configured = downloadSources[platform];
    const filePath = typeof configured === 'string' ? configured : configured?.filePath;
    if (!filePath) return null;
    try {
      const stats = fs.statSync(filePath);
      if (!stats.isFile()) return null;
      return {
        platform,
        label: platform === 'windows' ? 'Windows' : platform === 'linux' ? 'Linux' : 'Android',
        filePath,
        fileName: configured?.fileName || path.basename(filePath),
        sizeBytes: stats.size,
        modifiedAtMs: stats.mtimeMs,
      };
    } catch (_) {
      return null;
    }
  }

  async function downloadSha256(download) {
    const cacheKey = `${download.filePath}:${download.sizeBytes}:${download.modifiedAtMs}`;
    if (downloadHashes.has(cacheKey)) return downloadHashes.get(cacheKey);
    const digest = await new Promise((resolve, reject) => {
      const hash = createHash('sha256');
      const stream = fs.createReadStream(download.filePath);
      stream.on('data', (chunk) => hash.update(chunk));
      stream.on('error', reject);
      stream.on('end', () => resolve(hash.digest('hex')));
    });
    downloadHashes.clear();
    downloadHashes.set(cacheKey, digest);
    return digest;
  }

  function compareClientVersions(left, right) {
    const parts = (value) => String(value || '0').split(/[+-]/)[0]
      .split('.').slice(0, 3).map((part) => Number.parseInt(part, 10) || 0);
    const a = parts(left);
    const b = parts(right);
    for (let index = 0; index < 3; index += 1) {
      const difference = (a[index] || 0) - (b[index] || 0);
      if (difference !== 0) return Math.sign(difference);
    }
    return 0;
  }

  if (options.dataStore) {
    let saveQueue = Promise.resolve();
    const saveState = () => {
      // Capture immediately so concurrent requests cannot change a queued
      // snapshot before its database transaction starts.
      const snapshot = Object.fromEntries(PERSISTED_COLLECTIONS.map((name) => [
        name, JSON.parse(JSON.stringify(appData[name] || [])),
      ]));
      saveQueue = saveQueue.catch(() => {}).then(() => options.dataStore.saveCollections(snapshot));
      return saveQueue;
    };
    app.locals.persistData = saveState;
    app.use((req, res, next) => {
      const stateChangingGet = req.method === 'GET'
        && ['/api/auth/verify-email', '/api/users'].includes(req.path);
      if (!stateChangingGet && !['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method)) return next();
      const originalEnd = res.end.bind(res);
      let ending = false;
      res.end = function persistentEnd(chunk, encoding, callback) {
        if (ending) return res;
        ending = true;
        saveState()
          .then(() => originalEnd(chunk, encoding, callback))
          .catch((error) => {
            console.error('MariaDB-Persistenz fehlgeschlagen:', error);
            if (res.headersSent) return res.destroy(error);
            const body = JSON.stringify({
              error: 'Die Daten konnten nicht dauerhaft gespeichert werden.',
              requestId: req.requestId,
            });
            res.statusCode = 503;
            res.setHeader('Content-Type', 'application/json; charset=utf-8');
            res.setHeader('Content-Length', Buffer.byteLength(body));
            return originalEnd(body, 'utf8', callback);
          });
        return res;
      };
      return next();
    });
  } else {
    app.locals.persistData = async () => {};
  }

  const jwtSecret = process.env.JWT_SECRET || DEVELOPMENT_JWT_SECRET;
  const authAttempts = new Map();

  function securityVersion(user) {
    return createHash('sha256').update(JSON.stringify([
      user.passwordHash, user.active, user.emailVerifiedAt, user.roles, user.permissions,
    ])).digest('base64url').slice(0, 22);
  }

  function authRateLimit(req, res, next) {
    const now = Date.now();
    const key = req.ip;
    if (!authAttempts.has(key) && authAttempts.size >= 10_000) {
      for (const [storedKey, storedEntry] of authAttempts) {
        if (storedEntry.resetAt <= now) authAttempts.delete(storedKey);
      }
      if (authAttempts.size >= 10_000) {
        return res.status(429).json({ error: 'Zu viele Anfragen. Bitte später erneut versuchen.' });
      }
    }
    let entry = authAttempts.get(key);
    if (!entry || entry.resetAt <= now) entry = { count: 0, resetAt: now + AUTH_WINDOW_MS };
    entry.count += 1;
    authAttempts.set(key, entry);
    res.set('RateLimit-Policy', `${AUTH_MAX_REQUESTS};w=${AUTH_WINDOW_MS / 1000}`);
    res.set('RateLimit-Remaining', String(Math.max(0, AUTH_MAX_REQUESTS - entry.count)));
    res.set('RateLimit-Reset', String(Math.ceil((entry.resetAt - now) / 1000)));
    if (entry.count > AUTH_MAX_REQUESTS) {
      res.set('Retry-After', String(Math.ceil((entry.resetAt - now) / 1000)));
      return res.status(429).json({ error: 'Zu viele Anfragen. Bitte später erneut versuchen.' });
    }
    return next();
  }

  function createToken(user) {
    return jwt.sign(
      { sub: user.id, sv: securityVersion(user) },
      jwtSecret,
      { algorithm: 'HS256', audience: JWT_AUDIENCE, issuer: JWT_ISSUER, expiresIn: '1h' }
    );
  }

  function authMiddleware(req, res, next) {
    const header = req.headers.authorization || '';
    const token = header.startsWith('Bearer ') ? header.slice(7) : null;
    if (!token) {
      return res.status(401).json({ error: 'Authentication required' });
    }

    try {
      const payload = jwt.verify(token, jwtSecret, {
        algorithms: ['HS256'], audience: JWT_AUDIENCE, issuer: JWT_ISSUER,
      });
      req.user = users.find((u) => u.id === payload.sub) || null;
      if (!req.user) {
        return res.status(401).json({ error: 'Unknown user' });
      }
      if (!req.user.active) return res.status(403).json({ error: 'Account deaktiviert.' });
      if (!req.user.emailVerifiedAt) return res.status(403).json({ error: 'E-Mail-Adresse noch nicht bestätigt.' });
      if (payload.sv !== securityVersion(req.user)) {
        return res.status(401).json({ error: 'Invalid token' });
      }
      next();
    } catch (error) {
      return res.status(401).json({ error: 'Invalid token' });
    }
  }

  function hasPermission(user, permission) {
    return user?.permissions?.includes(permission) || user?.roles?.includes('Admin');
  }

  const defectPermissions = [
    'defects.report', 'defects.edit', 'defects.assign', 'defects.close',
    'defects.archive', 'defects.delete', 'defects.export',
  ];
  defectPermissions.forEach((permission) => {
    if (!permissions.includes(permission)) permissions.push(permission);
  });
  const defectRolePermissions = {
    Admin: defectPermissions,
    Materialwart: defectPermissions,
    Kleiderwart: ['defects.read', ...defectPermissions],
    Vorsitz: ['defects.read'],
    'Sachkundiger PSAgE': ['defects.read'],
  };
  roles.forEach((role) => {
    (defectRolePermissions[role.name] || []).forEach((permission) => {
      if (!role.permissions.includes(permission)) role.permissions.push(permission);
    });
  });
  users.forEach((user) => {
    const inherited = user.roles.flatMap((name) => defectRolePermissions[name] || []);
    inherited.forEach((permission) => {
      if (!user.permissions.includes(permission)) user.permissions.push(permission);
    });
  });

  function requirePermission(permission) {
    return (req, res, next) => {
      if (!hasPermission(req.user, permission)) {
        return res.status(403).json({ error: 'Forbidden' });
      }
      next();
    };
  }

  function logEvent(action, entity, details, actor = 'system') {
    const matchedUser = users.find((user) =>
      [user.email, user.username].some((value) =>
        String(value || '').toLowerCase() === String(actor || '').toLowerCase()
      )
    );
    const publicActor = matchedUser?.username
      || (String(actor).includes('@') ? 'unbekannt' : actor);
    auditLogs.push({
      id: `audit-${auditLogs.length + 1}`,
      timestamp: new Date().toISOString(),
      actor: publicActor,
      action,
      entity,
      details,
    });
  }

  const activityAreas = Object.freeze({
    Location: { permission: 'locations.read', label: 'Lagerorte' },
    StockStructure: { permission: 'locations.read', label: 'Lagerorte' },
    Category: { permission: 'categories.read', label: 'Kategorien' },
    MaterialItem: { permission: 'inventory.read', label: 'Inventar' },
    MaterialMovement: { permission: 'inventory.read', label: 'Inventar' },
    ClothingItem: { permission: 'clothing.read', label: 'Kleiderkammer' },
    IssueTransaction: { permission: 'clothing.read', label: 'Kleiderkammer' },
    DefectReport: { permission: 'defects.read', label: 'Mängel' },
    ProcurementRequest: { permission: 'procurement.read', label: 'Beschaffung' },
    ExportLog: { permission: 'reports.read', label: 'Berichte' },
  });

  function categoryLabel(categoryId) {
    const category = categories.find((entry) => entry.id === categoryId);
    if (!category) return categoryId || null;
    const parent = category.parentId
      ? categories.find((entry) => entry.id === category.parentId)
      : null;
    return parent ? `${parent.name} / ${category.name}` : category.name;
  }

  function dashboardActivity(entry) {
    const area = activityAreas[entry.entity];
    const details = entry.details && typeof entry.details === 'object' ? entry.details : {};
    let item = null;
    let categoryId = details.categoryId || details.subcategoryCode || details.categoryCode || null;

    if (entry.entity === 'MaterialItem') {
      item = [...materials, ...deletedMaterials].find((candidate) => candidate.id === details.id);
      categoryId ||= item?.subcategoryCode || item?.categoryCode || null;
    } else if (entry.entity === 'ClothingItem') {
      item = [...clothingItems, ...deletedClothingItems].find((candidate) => candidate.id === details.id);
      categoryId ||= item?.categoryId || null;
    }

    const actionLabels = {
      create: 'angelegt', update: 'bearbeitet', delete: 'gelöscht', archive: 'archiviert',
      restore: 'wiederhergestellt', inspection: 'geprüft', import: 'importiert',
      export: 'exportiert', issue: 'ausgegeben', return: 'zurückgenommen',
      relocate: 'umgelagert', transaction: 'gebucht', document: 'Dokument hinzugefügt',
      'bulk-category-update': 'Kategorie geändert',
    };
    const entityLabels = {
      MaterialItem: 'Artikel', ClothingItem: 'Kleidungsartikel', Location: 'Lagerort',
      StockStructure: 'Lagerplatz', Category: 'Kategorie', MaterialMovement: 'Material',
      IssueTransaction: 'Kleidungsausgabe', DefectReport: 'Mangel',
      ProcurementRequest: 'Beschaffung', ExportLog: 'Export',
    };

    return {
      ...entry,
      actor: users.find((user) => user.email === entry.actor)?.username
        || (String(entry.actor).includes('@') ? 'unbekannt' : entry.actor),
      area: area.label,
      actionLabel: actionLabels[entry.action] || entry.action,
      entityLabel: entityLabels[entry.entity] || entry.entity,
      itemName: details.itemName || item?.name || null,
      inventoryNumber: details.inventoryNumber || item?.inventoryNumber || null,
      category: details.categoryName || categoryLabel(categoryId),
    };
  }

  function nextId(prefix, entries) {
    const highestId = entries.reduce((highest, entry) => {
      const match = String(entry.id || '').match(new RegExp(`^${prefix}-(\\d+)$`));
      return match ? Math.max(highest, Number(match[1])) : highest;
    }, 0);
    return `${prefix}-${highestId + 1}`;
  }

  function nextClothingInventoryNumber(categoryId) {
    const category = categories.find((entry) => entry.id === categoryId);
    const mainCategoryId = category?.parentId || category?.id || '00';
    const subcategoryId = category?.parentId ? category.id : '00';
    return nextInventoryNumber(
      [...materials, ...clothingItems, ...deletedClothingItems],
      mainCategoryId,
      subcategoryId,
    );
  }

  function isWardrobeCategory(categoryId) {
    const category = categories.find((entry) => entry.id === categoryId);
    if (!category) return false;
    const mainCategory = category.parentId
      ? categories.find((entry) => entry.id === category.parentId)
      : category;
    return mainCategory?.useInWardrobe === true;
  }

  function categorySizes(categoryId) {
    const category = categories.find((entry) => entry.id === categoryId);
    if (!category) return [];
    if (Array.isArray(category.sizes) && category.sizes.length) return category.sizes;
    const parent = category.parentId
      ? categories.find((entry) => entry.id === category.parentId)
      : null;
    return Array.isArray(parent?.sizes) ? parent.sizes : [];
  }

  function categoryInspectionInterval(categoryId) {
    const category = categories.find((entry) => entry.id === categoryId);
    if (!category) return null;
    const ownInterval = Number(category.inspectionIntervalMonths);
    if (Number.isInteger(ownInterval) && ownInterval > 0) return ownInterval;
    const parent = category.parentId
      ? categories.find((entry) => entry.id === category.parentId)
      : null;
    const parentInterval = Number(parent?.inspectionIntervalMonths);
    return Number.isInteger(parentInterval) && parentInterval > 0
      ? parentInterval
      : null;
  }

  function addMonths(dateValue, months) {
    if (!dateValue || !months) return null;
    const source = new Date(`${String(dateValue).slice(0, 10)}T00:00:00.000Z`);
    if (!Number.isFinite(source.getTime())) return null;
    const day = source.getUTCDate();
    const target = new Date(Date.UTC(
      source.getUTCFullYear(), source.getUTCMonth() + months, 1,
    ));
    const lastDay = new Date(Date.UTC(
      target.getUTCFullYear(), target.getUTCMonth() + 1, 0,
    )).getUTCDate();
    target.setUTCDate(Math.min(day, lastDay));
    return target.toISOString().slice(0, 10);
  }

  function normalizedCategorySizes(value, fallback = []) {
    if (value === undefined) return fallback;
    const values = Array.isArray(value) ? value : String(value || '').split(',');
    return [...new Set(values.map((entry) => String(entry).trim()).filter(Boolean))]
      .slice(0, 100);
  }

  function categorySettings(body, existing, parent, useInWardrobe) {
    const wardrobeCategory = parent ? isWardrobeCategory(parent.id) : useInWardrobe;
    const intervalValue = body.inspectionIntervalMonths === undefined
      ? existing?.inspectionIntervalMonths
      : body.inspectionIntervalMonths;
    const parsedInterval = Number(intervalValue);
    const inspectionIntervalMonths = intervalValue === null || intervalValue === ''
      ? null
      : Number.isInteger(parsedInterval) && parsedInterval > 0 && parsedInterval <= 1200
        ? parsedInterval
        : null;
    return {
      sizes: wardrobeCategory
        ? normalizedCategorySizes(body.sizes, existing?.sizes || [])
        : [],
      inspectionIntervalMonths: wardrobeCategory ? inspectionIntervalMonths : null,
      requiresPsageInspection: wardrobeCategory && Boolean(parent)
        ? body.requiresPsageInspection === undefined
          ? existing?.requiresPsageInspection === true
          : body.requiresPsageInspection === true
        : false,
    };
  }

  function responseClothing(item) {
    return {
      ...item,
      inspections: clothingInspections
        .filter((entry) => entry.clothingId === item.id)
        .slice()
        .reverse(),
    };
  }

  const clothingColumnAliases = {
    inventarnummer: 'inventoryNumber',
    inventorynumber: 'inventoryNumber',
    name: 'name',
    bezeichnung: 'name',
    kleidungsstuck: 'name',
    grosse: 'size',
    size: 'size',
    kategorie: 'category',
    category: 'category',
    kategorieid: 'categoryId',
    categoryid: 'categoryId',
    standort: 'locationId',
    location: 'locationId',
    locationid: 'locationId',
    regalfach: 'stockStructureId',
    lagerplatz: 'stockStructureId',
    stockstructureid: 'stockStructureId',
    status: 'status',
    zugewiesenan: 'assignedPerson',
    assignedperson: 'assignedPerson',
    hersteller: 'manufacturer',
    manufacturer: 'manufacturer',
    baujahr: 'manufacturingYear',
    anschaffungsdatum: 'purchaseDate',
  };

  function normalizeColumnName(value) {
    return String(value || '')
      .trim()
      .toLowerCase()
      .normalize('NFD')
      .replace(/[\u0300-\u036f]/g, '')
      .replace(/[^a-z0-9]/g, '');
  }

  function readClothingRows(fileBase64) {
    const workbook = XLSX.read(Buffer.from(fileBase64, 'base64'), {
      type: 'buffer',
      cellDates: true,
      sheetRows: MAX_IMPORT_ROWS + 2,
    });
    const firstSheetName = workbook.SheetNames[0];
    if (!firstSheetName) return [];
    const rawRows = XLSX.utils.sheet_to_json(workbook.Sheets[firstSheetName], {
      defval: '',
      raw: false,
    });
    if (rawRows.length > MAX_IMPORT_ROWS) {
      const error = new Error(`Die Tabelle darf höchstens ${MAX_IMPORT_ROWS} Datenzeilen enthalten.`);
      error.status = 413;
      throw error;
    }
    return rawRows.map((row) => Object.entries(row).reduce((result, [header, value]) => {
      const field = clothingColumnAliases[normalizeColumnName(header)];
      if (field) result[field] = String(value ?? '').trim();
      return result;
    }, {}));
  }

  function buildClothingWorkbook() {
    const headers = ['Inventarnummer', 'Name', 'Kategorie-ID', 'Kategorie', 'Größe', 'Hersteller', 'Baujahr', 'Anschaffungsdatum', 'Standort', 'Regal/Fach', 'Status', 'Zugewiesen an'];
    const rows = clothingItems.map((item) => ({
      Inventarnummer: item.inventoryNumber || '',
      Name: item.name || '',
      'Kategorie-ID': item.categoryId || '',
      Kategorie: categories.find((category) => category.id === item.categoryId)?.name || '',
      'Größe': item.size || '',
      Hersteller: item.manufacturer || '',
      Baujahr: item.manufacturingYear || '',
      Anschaffungsdatum: item.purchaseDate || '',
      Standort: item.locationId || '',
      'Regal/Fach': item.stockStructureId || '',
      Status: item.status || 'Lagernd',
      'Zugewiesen an': item.assignedPerson || '',
    }));
    const worksheet = XLSX.utils.json_to_sheet(rows, { header: headers });
    worksheet['!cols'] = [
      { wch: 22 }, { wch: 28 }, { wch: 18 }, { wch: 22 }, { wch: 12 },
      { wch: 20 }, { wch: 10 }, { wch: 18 }, { wch: 16 }, { wch: 18 },
      { wch: 14 }, { wch: 24 },
    ];
    const workbook = XLSX.utils.book_new();
    XLSX.utils.book_append_sheet(workbook, worksheet, 'Kleiderkammer');

    const helpSheet = XLSX.utils.aoa_to_sheet([
      ['Importhinweise'],
      ['Pflichtfeld', 'Name'],
      ['Optionale Felder', 'Inventarnummer, Kategorie-ID, Kategorie, Größe, Hersteller, Baujahr, Anschaffungsdatum, Standort, Regal/Fach, Status, Zugewiesen an'],
      ['Statuswerte', 'Lagernd oder Ausgegeben'],
      ['Duplikate', 'Bereits vorhandene Inventarnummern werden übersprungen.'],
    ]);
    helpSheet['!cols'] = [{ wch: 20 }, { wch: 70 }];
    XLSX.utils.book_append_sheet(workbook, helpSheet, 'Hinweise');
    return workbook;
  }

  const userManagement = registerUserRoutes({
    app, users, roles, permissions, departments, authMiddleware, requirePermission, logEvent,
    departmentReferences: procurementRequests,
    authRateLimit,
    skipEmailVerification: options.skipEmailVerification === true,
    onTokenIssued: options.onAccountToken,
    userStore: options.userStore,
    accountMailSender: options.accountMailSender,
  });

  registerScannerEmailRoutes({
    app, authMiddleware, scannerEmailAddresses, users, logEvent,
  });

  app.get('/health', (req, res) => res.json({
    status: 'ok',
    service: 'materialkompass-backend',
    version,
    apiVersion: API_VERSION,
    uptimeSeconds: Math.floor(process.uptime()),
    timestamp: new Date().toISOString(),
  }));

  app.get('/api/info', (req, res) => res.json({
    service: 'MaterialKompass API',
    version,
    apiVersion: API_VERSION,
    supportedClients: SUPPORTED_PLATFORMS,
  }));

  app.get('/api/downloads', (req, res) => res.json(['windows', 'linux', 'android'].map((platform) => {
    const download = desktopDownload(platform);
    return {
      platform,
      label: platform === 'windows' ? 'Windows' : platform === 'linux' ? 'Linux' : 'Android',
      available: download !== null,
      fileName: download?.fileName || null,
      sizeBytes: download?.sizeBytes || null,
      downloadUrl: download ? `/api/downloads/${platform}` : null,
    };
  })));

  app.get('/api/client-updates/:platform', async (req, res, next) => {
    const platform = req.params.platform;
    if (!['windows', 'linux', 'android'].includes(platform)) {
      return res.status(404).json({ error: 'Unbekannte Plattform.' });
    }
    const download = desktopDownload(platform);
    if (!download) return res.status(204).end();

    const settingName = platform.toUpperCase();
    const currentVersion = String(req.query.currentVersion || '0.0.0');
    const latestVersion = process.env[`CLIENT_${settingName}_VERSION`] || version;
    const minimumVersion = process.env[`CLIENT_${settingName}_MIN_VERSION`] || '0.0.0';
    try {
      return res.json({
        platform,
        version: latestVersion,
        minimumVersion,
        updateAvailable: compareClientVersions(latestVersion, currentVersion) > 0,
        required: compareClientVersions(minimumVersion, currentVersion) > 0,
        downloadUrl: `/api/downloads/${platform}`,
        fileName: download.fileName,
        sizeBytes: download.sizeBytes,
        sha256: await downloadSha256(download),
        notes: process.env.CLIENT_UPDATE_NOTES || null,
      });
    } catch (error) {
      return next(error);
    }
  });

  app.get('/api/downloads/:platform', (req, res, next) => {
    if (!['windows', 'linux', 'android'].includes(req.params.platform)) {
      return res.status(404).json({ error: 'Unbekannte Plattform.' });
    }
    const download = desktopDownload(req.params.platform);
    if (!download) {
      return res.status(404).json({ error: 'Für diese Plattform ist derzeit kein Download verfügbar.' });
    }
    return res.download(download.filePath, download.fileName, (error) => {
      if (!error) return;
      if (res.headersSent) return next(error);
      return res.status(500).json({ error: 'Der Download konnte nicht bereitgestellt werden.' });
    });
  });

  app.post('/api/auth/login', authRateLimit, async (req, res) => {
    await userManagement.applyRetentionPolicy();
    const { email, identifier, password } = req.body;
    const loginIdentifier = identifier || email;
    const user = userManagement.findUser(loginIdentifier);

    if (!user) {
      await bcrypt.compare(password || '', DUMMY_PASSWORD_HASH);
      return res.status(401).json({ error: 'Invalid credentials' });
    }

    const valid = await bcrypt.compare(password || '', user.passwordHash);
    if (!valid) {
      user.failedLoginAttempts = (user.failedLoginAttempts || 0) + 1;
      if (user.failedLoginAttempts >= 5) {
        user.lockedUntil = new Date(Date.now() + 15 * 60 * 1000).toISOString();
      }
      logEvent('login_failed', 'User', { id: user.id }, user.username);
      await options.userStore?.saveUser(user);
      return res.status(401).json({ error: 'Invalid credentials' });
    }

    if (user.lockedUntil && new Date(user.lockedUntil) > new Date()) {
      return res.status(423).json({ error: 'Account locked. Bitte später erneut versuchen.' });
    }

    if (!user.active) return res.status(403).json({ error: 'Account deaktiviert.' });
    if (!user.emailVerifiedAt) return res.status(403).json({ error: 'Bitte bestätigen Sie zuerst Ihre E-Mail-Adresse.' });

    user.failedLoginAttempts = 0;
    user.lockedUntil = null;
    user.lastLoginAt = new Date().toISOString();
    await options.userStore?.saveUser(user);
    const token = createToken(user);
    logEvent('login', 'User', { id: user.id }, user.username);
    res.json({ token, expiresIn: 3600, user: publicUser(user) });
  });

  registerQrLoginRoutes({
    app,
    users,
    credentials: qrLoginCredentials,
    authMiddleware,
    requirePermission,
    authRateLimit,
    createToken,
    securityVersion,
    publicUser,
    logEvent,
    saveUser: (user) => options.userStore?.saveUser(user) || Promise.resolve(),
  });

  app.get('/api/auth/me', authMiddleware, (req, res) => {
    res.json({ user: publicUser(req.user) });
  });

  app.get('/api/locations', authMiddleware, requirePermission('locations.read'), (req, res) => {
    res.json(locations);
  });

  app.post('/api/locations', authMiddleware, requirePermission('locations.write'), (req, res) => {
    const name = String(req.body.name || '').trim();
    const code = String(req.body.code || '').trim().toUpperCase();
    const type = String(req.body.type || '').trim();
    if (!name || !code || !type) return res.status(400).json({ error: 'Name, Kürzel und Typ sind Pflichtfelder.' });
    if (!/^[A-Z0-9_-]{1,16}$/.test(code)) return res.status(400).json({ error: 'Das Kürzel darf nur Buchstaben, Zahlen, _ und - enthalten.' });
    if (locations.some((entry) => entry.name.toLowerCase() === name.toLowerCase() || entry.code.toLowerCase() === code.toLowerCase())) return res.status(409).json({ error: 'Name oder Kürzel wird bereits verwendet.' });
    const location = { id: nextId('loc', locations), name, code, type };
    locations.push(location);
    logEvent('create', 'Location', { id: location.id }, req.user.username);
    res.status(201).json(location);
  });

  app.put('/api/locations/:id', authMiddleware, requirePermission('locations.write'), (req, res) => {
    const location = locations.find((entry) => entry.id === req.params.id);
    if (!location) return res.status(404).json({ error: 'Lagerort nicht gefunden.' });
    const name = String(req.body.name ?? location.name).trim();
    const code = String(req.body.code ?? location.code).trim().toUpperCase();
    const type = String(req.body.type ?? location.type).trim();
    if (!name || !code || !type) return res.status(400).json({ error: 'Name, Kürzel und Typ sind Pflichtfelder.' });
    if (!/^[A-Z0-9_-]{1,16}$/.test(code)) return res.status(400).json({ error: 'Das Kürzel ist ungültig.' });
    if (locations.some((entry) => entry.id !== location.id && (entry.name.toLowerCase() === name.toLowerCase() || entry.code.toLowerCase() === code.toLowerCase()))) return res.status(409).json({ error: 'Name oder Kürzel wird bereits verwendet.' });
    Object.assign(location, { name, code, type, updatedAt: new Date().toISOString() });
    logEvent('update', 'Location', { id: location.id }, req.user.username);
    res.json(location);
  });

  app.delete('/api/locations/:id', authMiddleware, requirePermission('locations.write'), (req, res) => {
    const index = locations.findIndex((entry) => entry.id === req.params.id);
    if (index < 0) return res.status(404).json({ error: 'Lagerort nicht gefunden.' });
    if (materials.some((entry) => entry.locationId === req.params.id) || clothingItems.some((entry) => entry.locationId === req.params.id)) return res.status(409).json({ error: 'Der Lagerort ist noch Inventar oder Kleidung zugeordnet.' });
    for (let i = stockStructures.length - 1; i >= 0; i -= 1) if (stockStructures[i].locationId === req.params.id) stockStructures.splice(i, 1);
    const [removed] = locations.splice(index, 1);
    logEvent('delete', 'Location', { id: removed.id }, req.user.username);
    res.status(204).end();
  });

  app.get('/api/stock-structures', authMiddleware, requirePermission('locations.read'), (req, res) => {
    res.json(stockStructures);
  });

  app.post('/api/stock-structures', authMiddleware, requirePermission('locations.write'), (req, res) => {
    const name = String(req.body.name || '').trim();
    const section = String(req.body.section || '').trim();
    const locationId = String(req.body.locationId || '').trim();
    if (!name || !section || !locations.some((entry) => entry.id === locationId)) return res.status(400).json({ error: 'Name, Fach/Abschnitt und ein gültiger Lagerort sind erforderlich.' });
    if (stockStructures.some((entry) => entry.locationId === locationId && (entry.name.toLowerCase() === name.toLowerCase() || entry.section.toLowerCase() === section.toLowerCase()))) return res.status(409).json({ error: 'Name oder Fach/Abschnitt existiert an diesem Lagerort bereits.' });
    const stock = { id: nextId('stock', stockStructures), name, section, locationId };
    stockStructures.push(stock);
    logEvent('create', 'StockStructure', { id: stock.id, locationId }, req.user.username);
    res.status(201).json(stock);
  });

  app.put('/api/stock-structures/:id', authMiddleware, requirePermission('locations.write'), (req, res) => {
    const stock = stockStructures.find((entry) => entry.id === req.params.id);
    if (!stock) return res.status(404).json({ error: 'Regal/Fach nicht gefunden.' });
    const name = String(req.body.name ?? stock.name).trim();
    const section = String(req.body.section ?? stock.section).trim();
    const locationId = String(req.body.locationId ?? stock.locationId).trim();
    if (!name || !section || !locations.some((entry) => entry.id === locationId)) return res.status(400).json({ error: 'Name, Fach/Abschnitt und ein gültiger Lagerort sind erforderlich.' });
    if (stockStructures.some((entry) => entry.id !== stock.id && entry.locationId === locationId && (entry.name.toLowerCase() === name.toLowerCase() || entry.section.toLowerCase() === section.toLowerCase()))) return res.status(409).json({ error: 'Name oder Fach/Abschnitt existiert an diesem Lagerort bereits.' });
    Object.assign(stock, { name, section, locationId, updatedAt: new Date().toISOString() });
    logEvent('update', 'StockStructure', { id: stock.id, locationId }, req.user.username);
    res.json(stock);
  });

  app.delete('/api/stock-structures/:id', authMiddleware, requirePermission('locations.write'), (req, res) => {
    const index = stockStructures.findIndex((entry) => entry.id === req.params.id);
    if (index < 0) return res.status(404).json({ error: 'Regal/Fach nicht gefunden.' });
    if (materials.some((entry) => entry.stockStructureId === req.params.id) || clothingItems.some((entry) => entry.stockStructureId === req.params.id)) return res.status(409).json({ error: 'Regal/Fach ist noch Inventar oder Kleidung zugeordnet.' });
    const [removed] = stockStructures.splice(index, 1);
    logEvent('delete', 'StockStructure', { id: removed.id }, req.user.username);
    res.status(204).end();
  });

  app.get('/api/categories', authMiddleware, requirePermission('categories.read'), (req, res) => {
    res.json(categories);
  });

  app.post('/api/categories', authMiddleware, requirePermission('categories.write'), (req, res) => {
    const id = String(req.body.id || '').trim();
    const name = String(req.body.name || '').trim();
    const parentId = String(req.body.parentId || '').trim() || null;
    if (!id || !name) {
      return res.status(400).json({ error: 'id and name are required' });
    }
    if (!/^[A-Za-z0-9._-]{1,64}$/.test(id)) {
      return res.status(400).json({ error: 'invalid category id' });
    }
    if (categories.some((category) => category.id.toLowerCase() === id.toLowerCase())) {
      return res.status(409).json({ error: 'category id already exists' });
    }
    const parent = parentId ? categories.find((category) => category.id === parentId) : null;
    if (parentId && (!parent || parent.parentId)) {
      return res.status(400).json({ error: 'parent must be a main category' });
    }
    if (categories.some((category) =>
      category.parentId === parentId && category.name.toLowerCase() === name.toLowerCase()
    )) {
      return res.status(409).json({ error: 'category name already exists at this level' });
    }

    const category = {
      id,
      name,
      parentId,
      useInWardrobe: parentId ? false : req.body.useInWardrobe === true,
      ...categorySettings(
        req.body,
        null,
        parent,
        parentId ? false : req.body.useInWardrobe === true,
      ),
    };
    categories.push(category);
    logEvent('create', 'Category', category, req.user.username);
    res.status(201).json(category);
  });

  app.put('/api/categories/:id', authMiddleware, requirePermission('categories.write'), (req, res) => {
    const category = categories.find((entry) => entry.id === req.params.id);
    if (!category) {
      return res.status(404).json({ error: 'Category not found' });
    }
    const name = String(req.body.name || '').trim();
    const parentId = String(req.body.parentId || '').trim() || null;
    if (!name) {
      return res.status(400).json({ error: 'name is required' });
    }
    const parent = parentId ? categories.find((entry) => entry.id === parentId) : null;
    if (parentId && (
      parentId === category.id ||
      !parent ||
      parent.parentId ||
      categories.some((entry) => entry.parentId === category.id)
    )) {
      return res.status(400).json({ error: 'invalid category hierarchy' });
    }
    if (categories.some((entry) =>
      entry.id !== category.id &&
      entry.parentId === parentId &&
      entry.name.toLowerCase() === name.toLowerCase()
    )) {
      return res.status(409).json({ error: 'category name already exists at this level' });
    }

    const useInWardrobe = req.body.useInWardrobe === undefined
      ? category.useInWardrobe === true
      : req.body.useInWardrobe === true;
    category.name = name;
    category.parentId = parentId;
    category.useInWardrobe = parentId ? false : useInWardrobe;
    Object.assign(category, categorySettings(
      req.body,
      category,
      parent,
      category.useInWardrobe,
    ));
    clothingItems.forEach((item) => {
      const itemCategory = categories.find((entry) => entry.id === item.categoryId);
      if (item.categoryId !== category.id && itemCategory?.parentId !== category.id) return;
      item.inspectionIntervalMonths = categoryInspectionInterval(item.categoryId);
      const referenceDate = item.lastInspectionDate || item.createdAt;
      item.nextInspectionDate = addMonths(referenceDate, item.inspectionIntervalMonths);
    });
    logEvent('update', 'Category', category, req.user.username);
    res.json(category);
  });

  app.delete('/api/categories/:id', authMiddleware, requirePermission('categories.write'), (req, res) => {
    const index = categories.findIndex((entry) => entry.id === req.params.id);
    if (index === -1) {
      return res.status(404).json({ error: 'Category not found' });
    }
    if (categories.some((entry) => entry.parentId === req.params.id)) {
      return res.status(409).json({ error: 'Category has subcategories' });
    }
    const usedByClothing = clothingItems
      .some((item) => item.categoryId === req.params.id);
    const usedByMaterial = materials.some((item) =>
      item.categoryId === req.params.id ||
      item.subcategoryId === req.params.id ||
      item.categoryCode === req.params.id ||
      item.subcategoryCode === req.params.id ||
      `${item.categoryCode}-${item.subcategoryCode}` === req.params.id
    );
    if (usedByClothing || usedByMaterial) {
      return res.status(409).json({ error: 'Category is in use' });
    }

    const [category] = categories.splice(index, 1);
    logEvent('delete', 'Category', category, req.user.username);
    res.json({ success: true, id: category.id });
  });

  app.get('/api/subcategories', authMiddleware, requirePermission('categories.read'), (req, res) => {
    res.json(categories.filter((category) => category.parentId));
  });

  const defectManagement = registerDefectManagement({
    app, authMiddleware, requirePermission, hasPermission, defectReports,
    materials, clothingItems, users, notifications, logEvent, nextId, XLSX,
  });
  app.locals.applyDefectRetentionPolicy = defectManagement.applyRetentionPolicy;
  const defectEmailService = createDefectEmailService({
    defectEmailImports,
    defectManagement,
    defectReports,
    materials,
    clothingItems,
    persistData: () => app.locals.persistData(),
  });
  registerDefectEmailRoutes({
    app,
    authMiddleware,
    requirePermission,
    defectEmailImports,
    defectEmailService,
    defectManagement,
    materials,
    clothingItems,
  });
  app.locals.defectEmailService = defectEmailService;
  app.locals.applyDefectEmailRetentionPolicy = defectEmailService.applyRetentionPolicy;
  app.locals.defectReports = defectReports;

  registerInventoryRoutes({
    app, authMiddleware, requirePermission, materials, deletedMaterials, materialMovements,
    materialInspections, materialDocuments, defectReports, categories, locations,
    stockStructures, logEvent, nextId, XLSX, defectManagement,
  });

  app.get('/api/clothing', authMiddleware, requirePermission('clothing.read'), (req, res) => {
    res.json(clothingItems.map(responseClothing));
  });

  app.post('/api/clothing', authMiddleware, requirePermission('clothing.write'), (req, res) => {
    const name = String(req.body.name || '').trim();
    if (!name) {
      return res.status(400).json({ error: 'name is required' });
    }

    const categoryId = String(req.body.categoryId || '').trim();
    if (categoryId && !isWardrobeCategory(categoryId)) {
      return res.status(400).json({ error: 'invalid categoryId' });
    }
    const size = String(req.body.size || '').trim();
    const allowedSizes = categorySizes(categoryId);
    if (size && allowedSizes.length && !allowedSizes.includes(size)) {
      return res.status(400).json({ error: 'Die Größe ist für diese Kategorie nicht vorgesehen.' });
    }
    const locationId = String(req.body.locationId || 'loc-2').trim() || 'loc-2';
    const stockStructureId = String(req.body.stockStructureId || '').trim();
    if (!locations.some((entry) => entry.id === locationId)) return res.status(400).json({ error: 'Der gewählte Lagerort ist ungültig.' });
    if (stockStructureId && !stockStructures.some((entry) => entry.id === stockStructureId && entry.locationId === locationId)) return res.status(400).json({ error: 'Regal/Fach gehört nicht zum gewählten Lagerort.' });
    const requestedInventoryNumber = String(req.body.inventoryNumber || '').trim();
    const inventoryNumber = requestedInventoryNumber || nextClothingInventoryNumber(categoryId);
    if ([...materials, ...clothingItems, ...deletedClothingItems].some((item) => item.inventoryNumber === inventoryNumber)) {
      return res.status(409).json({ error: 'inventoryNumber already exists' });
    }

    const item = {
      ...req.body,
      id: nextId('clothing', [...clothingItems, ...deletedClothingItems]),
      name,
      inventoryNumber,
      categoryId: categoryId || null,
      locationId,
      stockStructureId: stockStructureId || null,
      size,
      manufacturer: String(req.body.manufacturer || '').trim(),
      manufacturingYear: String(req.body.manufacturingYear || '').trim(),
      purchaseDate: req.body.purchaseDate || null,
      inspectionIntervalMonths: categoryInspectionInterval(categoryId),
      lastInspectionDate: null,
      nextInspectionDate: addMonths(
        new Date().toISOString().slice(0, 10),
        categoryInspectionInterval(categoryId),
      ),
      status: 'Lagernd',
      assignedPerson: null,
      createdAt: new Date().toISOString(),
    };
    clothingItems.push(item);
    logEvent('create', 'ClothingItem', {
      id: item.id,
      itemName: item.name,
      inventoryNumber,
      categoryId: item.categoryId,
      categoryName: categoryLabel(item.categoryId),
    }, req.user.username);
    res.status(201).json(responseClothing(item));
  });

  app.put('/api/clothing/:id', authMiddleware, requirePermission('clothing.write'), (req, res) => {
    const item = clothingItems.find((entry) => entry.id === req.params.id);
    if (!item) {
      return res.status(404).json({ error: 'Clothing item not found' });
    }

    const name = String(req.body.name ?? item.name).trim();
    if (!name) {
      return res.status(400).json({ error: 'name is required' });
    }

    const inventoryNumber = String(req.body.inventoryNumber ?? item.inventoryNumber).trim();
    if (!inventoryNumber) {
      return res.status(400).json({ error: 'inventoryNumber is required' });
    }
    if ([...clothingItems, ...deletedClothingItems].some(
      (entry) => entry.id !== item.id && entry.inventoryNumber === inventoryNumber
    )) {
      return res.status(409).json({ error: 'inventoryNumber already exists' });
    }
    const categoryId = String(req.body.categoryId ?? item.categoryId ?? '').trim();
    if (categoryId && !isWardrobeCategory(categoryId)) {
      return res.status(400).json({ error: 'invalid categoryId' });
    }
    const size = String(req.body.size ?? item.size ?? '').trim();
    const allowedSizes = categorySizes(categoryId);
    if (size && allowedSizes.length && !allowedSizes.includes(size)) {
      return res.status(400).json({ error: 'Die Größe ist für diese Kategorie nicht vorgesehen.' });
    }
    const inspectionIntervalMonths = categoryInspectionInterval(categoryId);
    const locationId = String(req.body.locationId ?? item.locationId ?? 'loc-2').trim();
    const stockStructureId = String(req.body.stockStructureId ?? item.stockStructureId ?? '').trim();
    if (!locations.some((entry) => entry.id === locationId)) return res.status(400).json({ error: 'Der gewählte Lagerort ist ungültig.' });
    if (stockStructureId && !stockStructures.some((entry) => entry.id === stockStructureId && entry.locationId === locationId)) return res.status(400).json({ error: 'Regal/Fach gehört nicht zum gewählten Lagerort.' });

    const updatedItem = {
      ...item,
      ...req.body,
      id: item.id,
      name,
      inventoryNumber,
      categoryId: categoryId || null,
      size,
      manufacturer: String(req.body.manufacturer ?? item.manufacturer ?? '').trim(),
      manufacturingYear: String(req.body.manufacturingYear ?? item.manufacturingYear ?? '').trim(),
      purchaseDate: req.body.purchaseDate ?? item.purchaseDate ?? null,
      locationId,
      stockStructureId: stockStructureId || null,
      inspectionIntervalMonths,
      nextInspectionDate: addMonths(
        item.lastInspectionDate || item.createdAt,
        inspectionIntervalMonths,
      ),
      // Ausgabezustand und Empfänger dürfen nur über Transaktionen wechseln.
      status: item.status || 'Lagernd',
      assignedPerson: item.assignedPerson || null,
      updatedAt: new Date().toISOString(),
    };

    const index = clothingItems.findIndex((entry) => entry.id === req.params.id);
    clothingItems[index] = updatedItem;

    logEvent('update', 'ClothingItem', { id: updatedItem.id, inventoryNumber: updatedItem.inventoryNumber }, req.user.username);
    res.json(responseClothing(updatedItem));
  });

  app.post('/api/clothing/bulk-category', authMiddleware, requirePermission('clothing.write'), (req, res) => {
    const clothingIds = Array.from(new Set(
      Array.isArray(req.body.clothingIds)
        ? req.body.clothingIds.map((id) => String(id || '').trim()).filter(Boolean)
        : [],
    ));
    if (clothingIds.length === 0) {
      return res.status(400).json({ error: 'clothingIds are required' });
    }

    const selectedItems = clothingIds.map((id) =>
      clothingItems.find((entry) => entry.id === id));
    if (selectedItems.some((item) => !item)) {
      return res.status(404).json({ error: 'Mindestens ein Kleidungsstück wurde nicht gefunden.' });
    }
    const sourceCategories = new Set(selectedItems.map((item) => item.categoryId || null));
    if (sourceCategories.size !== 1) {
      return res.status(400).json({ error: 'Die ausgewählten Kleidungsstücke müssen derselben Kategorie angehören.' });
    }

    const categoryId = String(req.body.categoryId || '').trim();
    if (!categoryId || !isWardrobeCategory(categoryId)) {
      return res.status(400).json({ error: 'invalid categoryId' });
    }
    if (sourceCategories.has(categoryId)) {
      return res.status(400).json({ error: 'Die neue Kategorie muss sich von der bisherigen Kategorie unterscheiden.' });
    }

    const allowedSizes = categorySizes(categoryId);
    const incompatibleItems = selectedItems.filter((item) =>
      item.size && allowedSizes.length && !allowedSizes.includes(String(item.size)));
    if (incompatibleItems.length > 0) {
      return res.status(400).json({
        error: 'Mindestens eine Größe ist für die neue Kategorie nicht vorgesehen.',
        incompatibleIds: incompatibleItems.map((item) => item.id),
      });
    }

    const reassignInventoryNumbers = req.body.reassignInventoryNumbers === true;
    const inventoryEntries = [
      ...materials,
      ...deletedMaterials,
      ...clothingItems,
      ...deletedClothingItems,
    ];
    const inventoryNumbers = new Map();
    if (reassignInventoryNumbers) {
      const category = categories.find((entry) => entry.id === categoryId);
      const mainCategoryId = category?.parentId || category?.id || '00';
      const subcategoryId = category?.parentId ? category.id : '00';
      selectedItems.forEach((item) => {
        const inventoryNumber = nextInventoryNumber(
          inventoryEntries,
          mainCategoryId,
          subcategoryId,
        );
        inventoryNumbers.set(item.id, inventoryNumber);
        inventoryEntries.push({ inventoryNumber });
      });
    }

    const inspectionIntervalMonths = categoryInspectionInterval(categoryId);
    const updatedAt = new Date().toISOString();
    const updatedItems = selectedItems.map((item) => {
      const updatedItem = {
        ...item,
        categoryId,
        inventoryNumber: inventoryNumbers.get(item.id) || item.inventoryNumber,
        inspectionIntervalMonths,
        nextInspectionDate: addMonths(
          item.lastInspectionDate || item.createdAt,
          inspectionIntervalMonths,
        ),
        updatedAt,
      };
      clothingItems[clothingItems.findIndex((entry) => entry.id === item.id)] = updatedItem;
      return updatedItem;
    });

    logEvent('bulk-category-update', 'ClothingItem', {
      ids: clothingIds,
      sourceCategoryId: [...sourceCategories][0],
      categoryId,
      reassignInventoryNumbers,
    }, req.user.username);
    res.json(updatedItems.map(responseClothing));
  });

  app.post('/api/clothing/:id/inspections', authMiddleware, requirePermission('clothing.inspect'), (req, res) => {
    const item = clothingItems.find((entry) => entry.id === req.params.id);
    if (!item) return res.status(404).json({ error: 'Kleidungsstück nicht gefunden.' });
    const category = categories.find((entry) => entry.id === item.categoryId);
    if (category?.requiresPsageInspection === true &&
        !req.user.roles?.includes('Sachkundiger PSAgE') &&
        !req.user.roles?.includes('Admin')) {
      return res.status(403).json({
        error: 'Diese Prüfung darf nur von Sachkundigen PSAgE durchgeführt werden.',
      });
    }
    const inspectionDate = String(req.body.inspectionDate || '').slice(0, 10);
    const result = String(req.body.result || '').trim();
    if (!/^\d{4}-\d{2}-\d{2}$/.test(inspectionDate) ||
        !['Bestanden', 'Mangel', 'Nicht bestanden'].includes(result)) {
      return res.status(400).json({ error: 'Prüfdatum und gültiges Ergebnis sind erforderlich.' });
    }
    const interval = categoryInspectionInterval(item.categoryId);
    const inspection = {
      id: nextId('clothing-inspection', clothingInspections),
      clothingId: item.id,
      inspectionDate,
      inspector: req.user.name || req.user.email,
      inspectorEmail: req.user.email,
      result,
      notes: String(req.body.notes || '').trim(),
      nextInspectionDate: addMonths(inspectionDate, interval),
      psageInspection: category?.requiresPsageInspection === true,
      createdAt: new Date().toISOString(),
    };
    clothingInspections.push(inspection);
    item.inspectionIntervalMonths = interval;
    item.lastInspectionDate = inspectionDate;
    item.nextInspectionDate = inspection.nextInspectionDate;
    if (result === 'Mangel' || result === 'Nicht bestanden') {
      defectManagement.createFromInspection({
        entityType: 'ClothingItem', entityId: item.id, inspectionId: inspection.id,
        notes: inspection.notes, user: req.user,
      });
    }
    logEvent('inspection', 'ClothingItem', {
      id: item.id,
      result,
      psageInspection: inspection.psageInspection,
    }, req.user.username);
    return res.status(201).json(inspection);
  });

  app.delete('/api/clothing/:id', authMiddleware, requirePermission('clothing.write'), (req, res) => {
    const index = clothingItems.findIndex((entry) => entry.id === req.params.id);
    if (index === -1) {
      return res.status(404).json({ error: 'Clothing item not found' });
    }

    if (clothingItems[index].status === 'Ausgegeben') {
      return res.status(409).json({ error: 'Issued clothing cannot be deleted' });
    }

    const removedItem = clothingItems.splice(index, 1)[0];
    deletedClothingItems.push({
      ...removedItem,
      deletedAt: new Date().toISOString(),
      deletedBy: req.user.username,
    });
    logEvent('delete', 'ClothingItem', { id: removedItem.id, inventoryNumber: removedItem.inventoryNumber }, req.user.username);
    res.json({ success: true, id: removedItem.id });
  });

  app.get('/api/clothing/history', authMiddleware, requirePermission('clothing.read'), (req, res) => {
    res.json(deletedClothingItems.slice().reverse());
  });

  app.post('/api/clothing/import', authMiddleware, requirePermission('clothing.write'), (req, res) => {
    const fileName = String(req.body.fileName || '').trim();
    const extension = fileName.split('.').pop().toLowerCase();
    const fileBase64 = String(req.body.fileBase64 || '');

    if (!['xlsx', 'ods'].includes(extension) || !fileBase64) {
      return res.status(400).json({ error: 'Eine XLSX- oder ODS-Datei ist erforderlich.' });
    }
    if (fileBase64.length > 7_000_000) {
      return res.status(413).json({ error: 'Die Datei ist zu groß. Maximal 5 MB sind erlaubt.' });
    }
    if (fileBase64.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(fileBase64)) {
      return res.status(400).json({ error: 'Die Datei ist nicht gültig Base64-kodiert.' });
    }

    let rows;
    try {
      rows = readClothingRows(fileBase64);
    } catch (error) {
      if (error.status === 413) return res.status(413).json({ error: error.message });
      return res.status(400).json({ error: 'Die Tabelle konnte nicht gelesen werden.' });
    }

    const usedInventoryNumbers = new Set(
      [...materials, ...clothingItems, ...deletedClothingItems]
        .map((item) => item.inventoryNumber)
    );
    const importedItems = [];
    const skippedRows = [];

    rows.forEach((row, index) => {
      const rowNumber = index + 2;
      const name = String(row.name || '').trim();
      let inventoryNumber = String(row.inventoryNumber || '').trim();
      if (!name) {
        skippedRows.push({ row: rowNumber, reason: 'Name fehlt' });
        return;
      }
      if (inventoryNumber && usedInventoryNumbers.has(inventoryNumber)) {
        skippedRows.push({ row: rowNumber, reason: `Inventarnummer ${inventoryNumber} existiert bereits` });
        return;
      }
      const requestedStatus = String(row.status || '').trim().toLowerCase();
      if (requestedStatus && !['lagernd', 'ausgegeben'].includes(requestedStatus)) {
        skippedRows.push({ row: rowNumber, reason: `Ungültiger Status ${row.status}` });
        return;
      }
      const status = requestedStatus === 'ausgegeben' ? 'Ausgegeben' : 'Lagernd';
      const assignedPerson = status === 'Ausgegeben'
        ? String(row.assignedPerson || '').trim() || null
        : null;
      const categoryName = String(row.category || '').trim();
      const importedCategoryId = String(row.categoryId || '').trim();
      const category = importedCategoryId
        ? categories.find((entry) =>
          entry.id === importedCategoryId && isWardrobeCategory(entry.id)
        )
        : categoryName
          ? categories.find((entry) =>
            entry.name.toLowerCase() === categoryName.toLowerCase() &&
            isWardrobeCategory(entry.id)
          )
          : null;
      if ((importedCategoryId || categoryName) && !category) {
        skippedRows.push({
          row: rowNumber,
          reason: `Unbekannte Kategorie ${importedCategoryId || categoryName}`,
        });
        return;
      }
      const size = String(row.size || '').trim();
      const allowedSizes = categorySizes(category?.id || null);
      if (allowedSizes.length && !allowedSizes.includes(size)) {
        skippedRows.push({
          row: rowNumber,
          reason: `Größe ${size || '(leer)'} ist für die Kategorie nicht vorgesehen`,
        });
        return;
      }
      const locationId = String(row.locationId || '').trim() || 'loc-2';
      const stockStructureId = String(row.stockStructureId || '').trim();
      if (!locations.some((entry) => entry.id === locationId) || (stockStructureId && !stockStructures.some((entry) => entry.id === stockStructureId && entry.locationId === locationId))) {
        skippedRows.push({ row: rowNumber, reason: 'Lagerort oder Regal/Fach ist ungültig' });
        return;
      }
      if (!inventoryNumber) {
        inventoryNumber = nextClothingInventoryNumber(category?.id || null);
      }
      const item = {
        id: nextId('clothing', [...clothingItems, ...deletedClothingItems]),
        inventoryNumber,
        name,
        categoryId: category?.id || null,
        size,
        manufacturer: String(row.manufacturer || '').trim(),
        manufacturingYear: String(row.manufacturingYear || '').trim(),
        purchaseDate: row.purchaseDate || null,
        locationId,
        stockStructureId: stockStructureId || null,
        status,
        assignedPerson,
        inspectionIntervalMonths: categoryInspectionInterval(category?.id || null),
        lastInspectionDate: null,
        nextInspectionDate: addMonths(
          new Date().toISOString().slice(0, 10),
          categoryInspectionInterval(category?.id || null),
        ),
        createdAt: new Date().toISOString(),
      };
      clothingItems.push(item);
      usedInventoryNumbers.add(inventoryNumber);
      importedItems.push(item);
    });

    logEvent('import', 'ClothingItem', {
      fileName,
      imported: importedItems.length,
      skipped: skippedRows.length,
    }, req.user.username);
    res.json({ imported: importedItems.length, skipped: skippedRows.length, skippedRows });
  });

  app.get('/api/clothing/export', authMiddleware, requirePermission('clothing.read'), (req, res) => {
    const format = String(req.query.format || 'xlsx').toLowerCase();
    if (!['xlsx', 'ods'].includes(format)) {
      return res.status(400).json({ error: 'Format muss xlsx oder ods sein.' });
    }

    const fileName = `kleiderkammer-${new Date().toISOString().slice(0, 10)}.${format}`;
    const buffer = XLSX.write(buildClothingWorkbook(), { type: 'buffer', bookType: format });
    const entry = {
      id: `export-${exportLogs.length + 1}`,
      exportType: `clothing-${format}`,
      fileName,
      itemCount: clothingItems.length,
      createdAt: new Date().toISOString(),
    };
    exportLogs.push(entry);
    logEvent('export', 'ClothingItem', { format, itemCount: clothingItems.length }, req.user.username);
    res.json({ fileName, fileBase64: buffer.toString('base64') });
  });

  app.get('/api/transactions', authMiddleware, requirePermission('transactions.read'), (req, res) => {
    res.json(issueTransactions.slice().reverse());
  });

  app.post('/api/transactions', authMiddleware, requirePermission('transactions.write'), (req, res) => {
    const clothingIds = Array.from(new Set(
      Array.isArray(req.body.clothingIds)
        ? req.body.clothingIds
        : req.body.clothingId
        ? [req.body.clothingId]
        : []
    )).map((id) => String(id || '').trim()).filter(Boolean);
    const action = req.body.action;
    const submittedPersonName = String(req.body.personName || '').trim();

    const validActions = ['ausgegeben', 'zurückgegeben'];
    if (!validActions.includes(action)) {
      return res.status(400).json({ error: 'Invalid action. Use ausgegeben or zurückgegeben.' });
    }

    if (clothingIds.length === 0) {
      return res.status(400).json({ error: 'clothingIds are required' });
    }

    if (action === 'ausgegeben' && !submittedPersonName) {
      return res.status(400).json({ error: 'personName is required when issuing clothing' });
    }

    const personName =
      action === 'zurückgegeben' ? 'nicht Ausgegeben' : submittedPersonName;

    const invalidItems = clothingIds.reduce((errors, id) => {
      const item = clothingItems.find((item) => item.id === id);
      if (!item) {
        errors.push({ id, error: 'not_found' });
      } else if (action === 'ausgegeben' && item.status === 'Defekt') {
        errors.push({ id, error: 'defective' });
      } else if (action === 'ausgegeben' && item.status === 'Ausgegeben') {
        errors.push({ id, error: 'already_issued' });
      } else if (action === 'zurückgegeben' && item.status !== 'Ausgegeben' &&
          !(item.status === 'Defekt' && item.assignedPerson)) {
        errors.push({ id, error: 'not_issued' });
      }
      return errors;
    }, []);

    if (invalidItems.length > 0) {
      return res.status(409).json({ error: 'Some items could not be processed', details: invalidItems });
    }

    const transactions = clothingIds.map((id) => {
      const transaction = {
        id: nextId('txn', issueTransactions),
        clothingId: id,
        personName,
        action,
        createdAt: new Date().toISOString(),
      };
      issueTransactions.push(transaction);
      return transaction;
    });

    clothingIds.forEach((id) => {
      const clothingItem = clothingItems.find((item) => item.id === id);
      if (!clothingItem) return;
      if (action === 'ausgegeben') {
        clothingItem.status = 'Ausgegeben';
        clothingItem.assignedPerson = personName || clothingItem.assignedPerson || null;
      } else if (action === 'zurückgegeben') {
        clothingItem.status = defectManagement.hasOpenDefect('ClothingItem', id)
          ? 'Defekt' : 'Lagernd';
        clothingItem.assignedPerson = null;
      }
    });

    logEvent('transaction', 'IssueTransaction', { ids: clothingIds, action }, req.user.username);
    res.status(201).json(transactions.length === 1 ? transactions[0] : transactions);
  });

  registerProcurementRoutes({
    app, authMiddleware, requirePermission, data: appData, categories, departments, locations,
    stockStructures, materials, deletedMaterials, clothingItems, logEvent, nextId, XLSX,
    nextClothingInventoryNumber, categorySizes, categoryInspectionInterval,
    addMonths,
  });

  app.get('/api/documents', authMiddleware, requirePermission('documents.read'), (req, res) => {
    res.json(documents);
  });

  app.get('/api/reports', authMiddleware, requirePermission('reports.read'), (req, res) => {
    res.json({
      materialCount: materials.length,
      clothingCount: clothingItems.length,
      openDefects: defectReports.filter((item) => !item.archivedAt && item.status !== 'Geprüft/Geschlossen').length,
      pendingProcurement: procurementRequests.filter((item) => item.status === 'Beantragt').length,
      auditEntries: auditLogs.length,
      exportEntries: exportLogs.length,
    });
  });

  app.get('/api/dashboard', authMiddleware, requirePermission('dashboard.read'), (req, res) => {
    const activeMaterials = materials.filter((item) => !item.archived);
    const inspectionWarning = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);
    const summary = {};

    if (hasPermission(req.user, 'inventory.read')) {
      Object.assign(summary, {
        materialCount: activeMaterials.length,
        issuedMaterialCount: activeMaterials.filter((item) => Number(item.issuedQuantity || 0) > 0).length,
        defectiveMaterialCount: activeMaterials.filter((item) => item.status === 'Defekt').length,
        dueInspectionCount: activeMaterials.filter((item) => {
          const due = item.nextInspectionDate ? new Date(item.nextInspectionDate) : null;
          return due && due <= inspectionWarning;
        }).length,
      });
    }

    if (hasPermission(req.user, 'clothing.read')) {
      summary.clothingCount = clothingItems.length;
    }

    if (hasPermission(req.user, 'defects.read')) {
      Object.assign(summary, {
        defectCount: defectReports.filter((item) => !item.archivedAt).length,
        openDefectCount: defectReports.filter((item) => !item.archivedAt && item.status !== 'Geprüft/Geschlossen').length,
        defectsInProgressCount: defectReports.filter((item) => !item.archivedAt && item.status === 'In Bearbeitung').length,
        unreadNotificationCount: notifications.filter((item) => item.userId === req.user.id && !item.readAt).length,
        pendingDefectEmailCount: defectEmailImports.filter((item) => {
          if (item.status !== 'pending') return false;
          const entityType = item.extractedData?.entityType;
          return entityType
            ? defectManagement.canScope(req.user, entityType)
            : req.user.roles?.some((role) => role === 'Admin' || role === 'Vorsitz');
        }).length,
      });
    }

    if (hasPermission(req.user, 'procurement.read')) {
      summary.procurementCount = procurementRequests.length;
    }
    if (hasPermission(req.user, 'procurement.approve')) {
      summary.pendingProcurementApprovals = procurementRequests.filter((item) => item.status === 'Beantragt').length;
    }
    if (hasPermission(req.user, 'procurement.order')) {
      summary.overdueProcurementOrders = appData.procurementOrders.filter((order) =>
        order.expectedDeliveryDate
        && new Date(order.expectedDeliveryDate) < new Date()
        && order.items.some((item) => item.deliveredQuantity < item.quantity)
      ).length;
    }
    if (hasPermission(req.user, 'procurement.receive')) {
      summary.openProcurementReceipts = appData.procurementReceipts.filter((receipt) => !receipt.inventoryTransferred).length;
    }

    res.json({
      summary,
      recentActivity: auditLogs
        .filter((entry) => {
          const area = activityAreas[entry.entity];
          return area && hasPermission(req.user, area.permission);
        })
        .slice(-10)
        .reverse()
        .map(dashboardActivity),
    });
  });

  app.post('/api/export-log', authMiddleware, requirePermission('reports.read'), (req, res) => {
    const entry = { id: `export-${exportLogs.length + 1}`, ...req.body, createdAt: new Date().toISOString() };
    exportLogs.push(entry);
    logEvent('export', 'ExportLog', { id: entry.id }, req.user.username);
    res.status(201).json(entry);
  });

  app.use((req, res) => res.status(404).json({
    error: 'Route not found',
    requestId: req.requestId,
  }));

  app.use((error, req, res, next) => {
    if (res.headersSent) return next(error);
    const status = Number.isInteger(error.status) ? error.status : 500;
    if (status >= 500) console.error(`[${req.requestId}]`, error);
    return res.status(status).json({
      error: status >= 500 ? 'Internal server error' : error.message,
      requestId: req.requestId,
    });
  });

  return app;
}

module.exports = { createApp };
