const ALLOWED_STATUSES = [
  'Entwurf', 'Beantragt', 'Genehmigt', 'Abgelehnt', 'Bestellt',
  'Teilweise geliefert', 'Geliefert', 'Abgeschlossen', 'Storniert',
];
const REQUEST_ROLES = ['Fachbereichsleiter', 'Materialwart', 'Kleiderwart', 'Vorsitz'];
const APPROVAL_ROLES = ['Vorsitz', 'Schatzmeister'];
const ORDER_ROLES = ['Materialwart', 'Kleiderwart'];
const REQUEST_PRIORITIES = ['Niedrig', 'Normal', 'Hoch', 'Kritisch'];
const FILE_EXTENSIONS = ['pdf', 'png', 'jpg', 'jpeg', 'docx', 'xlsx', 'ods'];
const { nextInventoryNumber } = require('./inventory-number');
const {
  fileMagic,
  inspectZipArchive,
  neutralizeSpreadsheetCell,
  validBase64,
} = require('./security-utils');
const { countryCode, createAddressLookupService } = require('./address-lookup');
const MAX_REQUEST_ITEMS = 100;
const MAX_DOCUMENTS_PER_REQUEST = 20;
const MAX_INVENTORY_ITEMS_PER_TRANSFER = 500;
const MAX_QUANTITY = 10_000;
const MAX_MONEY = 1_000_000_000;
const MAX_REQUEST_RECORDS = 50_000;
const MAX_DOCUMENTS_TOTAL = 5_000;
const MAX_OFFERS_PER_REQUEST = 20;
const MAX_ORDERS_PER_REQUEST = 20;
const MAX_RECEIPTS_PER_ORDER = 100;
const MAX_SUPPLIER_RECORDS = 10_000;
const MAX_INVENTORY_RECORDS = 200_000;
const MAX_DOCUMENT_STORAGE_BYTES = 256 * 1024 * 1024;

function registerProcurementRoutes({
  app, authMiddleware, requirePermission, data, categories, departments = [], locations,
  stockStructures, materials, deletedMaterials, clothingItems, logEvent, nextId, XLSX,
  nextClothingInventoryNumber, categorySizes, categoryInspectionInterval,
  addMonths, addressLookup = createAddressLookupService(),
}) {
  const requests = data.procurementRequests;
  const offers = data.procurementOffers;
  const orders = data.procurementOrders;
  const receipts = data.procurementReceipts;
  const procurementDocuments = data.procurementDocuments;
  const suppliers = data.suppliers;

  const roles = (user) => new Set(user?.roles || []);
  const isAdmin = (user) => roles(user).has('Admin');
  const hasRole = (user, allowed) => isAdmin(user) || allowed.some((role) => roles(user).has(role));
  const assignedDepartments = (user) => new Set(user?.departmentIds || []);
  const departmentFor = (value) => {
    const normalized = String(value || '').trim().toLowerCase();
    return departments.find((entry) => entry.id === value
      || entry.name.toLowerCase() === normalized || entry.code.toLowerCase() === normalized);
  };
  const number = (value) => {
    let parsed;
    if (typeof value === 'string' && value.includes(',')) {
      parsed = Number(value.trim().replace(/\./g, '').replace(',', '.'));
    } else {
      parsed = Number(value);
    }
    return Number.isFinite(parsed) ? parsed : 0;
  };
  const money = (value) => Math.round(number(value) * 100) / 100;
  const now = () => new Date().toISOString();
  const yearSequence = (prefix, entries) => {
    const year = new Date().getFullYear();
    const count = entries.filter((entry) => String(entry.number || '').startsWith(`${prefix}-${year}-`)).length + 1;
    return `${prefix}-${year}-${String(count).padStart(4, '0')}`;
  };
  const event = (request, action, actor, details = {}) => {
    request.history.push({ id: `history-${request.history.length + 1}`, action, actor, details, createdAt: now() });
    request.updatedAt = now();
    logEvent(action, 'ProcurementRequest', { id: request.id, ...details }, actor);
  };
  const categoryExists = (id) => categories.some((entry) => entry.id === id);
  const normalizeItems = (input = []) => (Array.isArray(input) ? input : []).slice(0, MAX_REQUEST_ITEMS + 1).map((item, index) => ({
    id: item.id || `item-${index + 1}`,
    name: String(item.name || '').trim(),
    categoryId: String(item.categoryId || '').trim(),
    subcategoryId: String(item.subcategoryId || '').trim() || null,
    size: String(item.size || '').trim(),
    quantity: money(item.quantity),
    unit: String(item.unit || 'Stück').trim(),
    taxRate: Number.isFinite(Number(item.taxRate)) ? Number(item.taxRate) : 19,
    notes: String(item.notes || '').trim(),
  }));
  const validateItems = (items) => {
    if (!items.length) return 'Mindestens eine Position ist erforderlich.';
    for (const item of items) {
      if (!item.name || item.quantity <= 0) return 'Positionen benötigen Bezeichnung und eine positive Menge.';
      if (item.name.length > 255 || item.categoryId.length > 64
        || String(item.subcategoryId || '').length > 64 || item.size.length > 32
        || item.unit.length > 32 || item.notes.length > 5000) {
        return 'Mindestens ein Feld einer Position überschreitet die zulässige Länge.';
      }
      if (item.quantity > MAX_QUANTITY) return `Eine Positionsmenge darf ${MAX_QUANTITY} nicht überschreiten.`;
      if (!item.categoryId || !categoryExists(item.categoryId)) return 'Jede Position benötigt eine gültige Hauptkategorie.';
      if (item.subcategoryId) {
        const child = categories.find((entry) => entry.id === item.subcategoryId);
        if (!child || child.parentId !== item.categoryId) return 'Die Unterkategorie gehört nicht zur Hauptkategorie.';
      }
      const main = categories.find((entry) => entry.id === item.categoryId);
      if (main?.useInWardrobe === true) {
        const allowedSizes = categorySizes(item.subcategoryId || item.categoryId);
        if (allowedSizes.length && !allowedSizes.includes(item.size)) {
          return `Für ${item.name} muss eine vordefinierte Größe ausgewählt werden.`;
        }
      }
      if (![0, 7, 19].includes(item.taxRate)) return 'Der Steuersatz muss 0, 7 oder 19 Prozent betragen.';
    }
    return null;
  };
  const canSee = (user, request) => {
    if (isAdmin(user) || hasRole(user, ['Vorsitz', 'Schatzmeister'])) return true;
    return request.requestedByUserId === user.id
      || (!request.requestedByUserId && request.requestedByEmail === user.email)
      || (roles(user).has('Fachbereichsleiter')
        && request.departmentId && assignedDepartments(user).has(request.departmentId));
  };
  const isOwner = (user, request) => isAdmin(user)
    || request.requestedByUserId === user.id
    || (!request.requestedByUserId && request.requestedByEmail === user.email);
  const findVisible = (req, res) => {
    const request = requests.find((entry) => entry.id === req.params.id);
    if (!request) { res.status(404).json({ error: 'Beschaffungsantrag nicht gefunden.' }); return null; }
    if (!canSee(req.user, request)) { res.status(403).json({ error: 'Keine Berechtigung für diesen Fachbereich.' }); return null; }
    return request;
  };
  const supplierAddressFields = ['street', 'houseNumber', 'postalCode', 'city', 'country'];
  const supplierTextFields = [
    'contact', 'customerNumber', 'email', 'phone', 'website', 'paymentTerms',
    ...supplierAddressFields,
  ];
  const supplierAddress = (source, fallback = {}) => Object.fromEntries(
    supplierAddressFields.map((field) => [
      field,
      String(source[field] ?? fallback[field] ?? '').trim(),
    ]),
  );
  const validateSupplierAddress = (address) => {
    if (supplierAddressFields.some((field) => !address[field])) {
      return 'Straße, Hausnummer, Postleitzahl, Ort und Land sind erforderlich.';
    }
    if (address.street.length > 255 || address.houseNumber.length > 64
      || address.postalCode.length > 32 || address.city.length > 255
      || address.country.length > 128) {
      return 'Mindestens ein Adressfeld überschreitet die zulässige Länge.';
    }
    if (countryCode(address.country) === 'de' && !/^\d{5}$/.test(address.postalCode)) {
      return 'Eine deutsche Postleitzahl muss aus genau fünf Ziffern bestehen.';
    }
    return null;
  };
  const formatSupplierAddress = (address) => (
    `${address.street} ${address.houseNumber}, ${address.postalCode} ${address.city}, ${address.country}`
  );
  const detail = (request) => ({
    ...request,
    offers: offers.filter((entry) => entry.requestId === request.id),
    orders: orders.filter((entry) => entry.requestId === request.id).map((order) => ({
      ...order,
      receipts: receipts.filter((entry) => entry.orderId === order.id),
    })),
    documents: procurementDocuments.filter((entry) => entry.requestId === request.id).map(({ fileBase64, ...metadata }) => metadata),
  });

  app.get('/api/procurement', authMiddleware, requirePermission('procurement.read'), (req, res) => {
    const status = String(req.query.status || '');
    const query = String(req.query.q || '').toLowerCase();
    const limit = Math.min(Math.max(Number(req.query.limit) || 500, 1), 1000);
    const offset = Math.max(Number(req.query.offset) || 0, 0);
    const visible = requests.filter((entry) => canSee(req.user, entry)).filter((entry) =>
      (!status || entry.status === status) && (!query || [entry.number, entry.title, entry.department, entry.costCenter, entry.requestedBy].join(' ').toLowerCase().includes(query))
    );
    res.json(visible.slice(offset, offset + limit).map(detail));
  });

  app.get('/api/procurement/:id', authMiddleware, requirePermission('procurement.read'), (req, res) => {
    const request = findVisible(req, res); if (request) res.json(detail(request));
  });

  app.post('/api/procurement', authMiddleware, requirePermission('procurement.request'), (req, res) => {
    if (requests.length >= MAX_REQUEST_RECORDS) {
      return res.status(507).json({ error: 'Die maximale Anzahl an Beschaffungsvorgängen ist erreicht.' });
    }
    if (!hasRole(req.user, REQUEST_ROLES)) return res.status(403).json({ error: 'Diese Rolle darf keine Beschaffung beantragen.' });
    const items = normalizeItems(req.body.items);
    const itemError = validateItems(items);
    if (items.length > MAX_REQUEST_ITEMS) {
      return res.status(413).json({ error: `Maximal ${MAX_REQUEST_ITEMS} Positionen sind erlaubt.` });
    }
    const requestedBudgetGross = money(req.body.requestedBudgetGross);
    const department = departmentFor(req.body.departmentId || req.body.department);
    if (roles(req.user).has('Fachbereichsleiter')
      && (!department || department.active === false || !assignedDepartments(req.user).has(department.id))) {
      return res.status(403).json({ error: 'Fachbereichsleiter dürfen nur für einen zugewiesenen aktiven Fachbereich beantragen.' });
    }
    if (!String(req.body.title || '').trim() || !String(req.body.reason || '').trim() || requestedBudgetGross <= 0 || itemError) {
      return res.status(400).json({ error: itemError || 'Titel, Begründung und ein beantragtes Budget größer als null sind erforderlich.' });
    }
    if (String(req.body.title).trim().length > 255 || String(req.body.reason).trim().length > 5000
      || String(req.body.department || '').length > 255 || String(req.body.costCenter || '').length > 255
      || String(req.body.desiredDeliveryDate || '').length > 32
      || !REQUEST_PRIORITIES.includes(String(req.body.priority || 'Normal'))
      || String(req.body.notes || '').length > 5000
      || String(req.body.preferredSupplierId || '').length > 64 || requestedBudgetGross > MAX_MONEY) {
      return res.status(400).json({ error: 'Ein Textfeld oder Budget überschreitet den zulässigen Wert.' });
    }
    const request = {
      id: nextId('proc', requests), number: yearSequence('BA', requests), status: 'Entwurf',
      title: String(req.body.title).trim(), reason: String(req.body.reason).trim(),
      requestedBy: req.user.name, requestedByEmail: req.user.email,
      requestedByUserId: req.user.id,
      departmentId: department?.id || null,
      department: department?.name || String(req.body.department || '').trim(),
      costCenter: String(req.body.costCenter || '').trim(),
      desiredDeliveryDate: req.body.desiredDeliveryDate || null,
      priority: String(req.body.priority || 'Normal'), notes: String(req.body.notes || '').trim(),
      preferredSupplierId: req.body.preferredSupplierId || null, items,
      requestedBudgetGross, approvedBudgetGross: null,
      approvals: [], selectedOfferId: null,
      history: [], createdAt: now(), updatedAt: now(),
    };
    requests.push(request); event(request, 'Entwurf angelegt', req.user.username, { requestedBudgetGross });
    res.status(201).json(detail(request));
  });

  app.put('/api/procurement/:id', authMiddleware, requirePermission('procurement.request'), (req, res) => {
    const request = findVisible(req, res); if (!request) return;
    if (request.status !== 'Entwurf') return res.status(409).json({ error: 'Nur Entwürfe können bearbeitet werden.' });
    if (!isOwner(req.user, request)) return res.status(403).json({ error: 'Nur der Antragsteller darf den Entwurf bearbeiten.' });
    const items = normalizeItems(req.body.items ?? request.items);
    if (items.length > MAX_REQUEST_ITEMS) {
      return res.status(413).json({ error: `Maximal ${MAX_REQUEST_ITEMS} Positionen sind erlaubt.` });
    }
    const itemError = validateItems(items); if (itemError) return res.status(400).json({ error: itemError });
    let nextDepartmentId = request.departmentId;
    let nextDepartmentName = request.department;
    if (Object.hasOwn(req.body, 'department') || Object.hasOwn(req.body, 'departmentId')) {
      const department = departmentFor(req.body.departmentId || req.body.department);
      if (roles(req.user).has('Fachbereichsleiter')
        && (!department || department.active === false || !assignedDepartments(req.user).has(department.id))) {
        return res.status(403).json({ error: 'Fachbereichsleiter dürfen nur einen zugewiesenen aktiven Fachbereich verwenden.' });
      }
      nextDepartmentId = department?.id || null;
      nextDepartmentName = department?.name || String(req.body.department || '').trim();
    }
    const updates = {};
    for (const field of ['title', 'reason', 'costCenter', 'desiredDeliveryDate', 'priority', 'notes', 'preferredSupplierId']) {
      if (Object.hasOwn(req.body, field)) updates[field] = typeof req.body[field] === 'string' ? req.body[field].trim() : req.body[field];
    }
    const requestedBudgetGross = money(req.body.requestedBudgetGross ?? request.requestedBudgetGross);
    if (requestedBudgetGross <= 0 || requestedBudgetGross > MAX_MONEY) return res.status(400).json({ error: 'Das beantragte Budget ist ungültig.' });
    const candidate = { ...request, ...updates };
    if (!String(candidate.title || '').trim() || !String(candidate.reason || '').trim()
      || String(candidate.title).length > 255 || String(candidate.reason).length > 5000
      || String(candidate.costCenter || '').length > 255
      || String(candidate.desiredDeliveryDate || '').length > 32
      || !REQUEST_PRIORITIES.includes(String(candidate.priority || 'Normal'))
      || String(candidate.notes || '').length > 5000
      || String(candidate.preferredSupplierId || '').length > 64) {
      return res.status(400).json({ error: 'Mindestens ein Textfeld überschreitet die zulässige Länge.' });
    }
    Object.assign(request, updates, {
      departmentId: nextDepartmentId,
      department: nextDepartmentName,
    });
    request.items = items; request.requestedBudgetGross = requestedBudgetGross;
    event(request, 'Entwurf bearbeitet', req.user.username, { requestedBudgetGross }); res.json(detail(request));
  });

  app.delete('/api/procurement/:id', authMiddleware, requirePermission('procurement.request'), (req, res) => {
    const request = findVisible(req, res); if (!request) return;
    if (request.status !== 'Entwurf') return res.status(409).json({ error: 'Nur Entwürfe können gelöscht werden.' });
    if (!isOwner(req.user, request)) return res.status(403).json({ error: 'Nur der Antragsteller darf den Entwurf löschen.' });
    requests.splice(requests.indexOf(request), 1); logEvent('Entwurf gelöscht', 'ProcurementRequest', { id: request.id }, req.user.username); res.json({ success: true });
  });

  app.post('/api/procurement/:id/submit', authMiddleware, requirePermission('procurement.request'), (req, res) => {
    const request = findVisible(req, res); if (!request) return;
    if (!isOwner(req.user, request)) return res.status(403).json({ error: 'Nur der Antragsteller darf den Entwurf einreichen.' });
    if (request.status !== 'Entwurf') return res.status(409).json({ error: 'Nur Entwürfe können beantragt werden.' });
    request.status = 'Beantragt'; event(request, 'Freigabe beantragt', req.user.username); res.json(detail(request));
  });

  app.post('/api/procurement/:id/approval', authMiddleware, requirePermission('procurement.approve'), (req, res) => {
    const request = findVisible(req, res); if (!request) return;
    if (!hasRole(req.user, APPROVAL_ROLES)) return res.status(403).json({ error: 'Nur Vorsitz oder Schatzmeister dürfen freigeben.' });
    if (request.status !== 'Beantragt') return res.status(409).json({ error: 'Der Antrag wartet nicht auf eine Freigabe.' });
    if (request.approvals.some((entry) => entry.email === req.user.email)) return res.status(409).json({ error: 'Diese Person hat bereits entschieden.' });
    const decision = req.body.decision === 'reject' ? 'Abgelehnt' : 'Genehmigt';
    const approverRole = isAdmin(req.user) ? String(req.body.role || 'Vorsitz') : [...roles(req.user)].find((role) => APPROVAL_ROLES.includes(role));
    const approvedBudgetGross = approverRole === 'Vorsitz' && decision === 'Genehmigt' ? money(req.body.approvedBudgetGross) : null;
    if (approverRole === 'Vorsitz' && decision === 'Genehmigt' && approvedBudgetGross <= 0) return res.status(400).json({ error: 'Der Vorsitz muss ein freigegebenes Budget größer als null festlegen.' });
    request.approvals.push({ decision, role: approverRole, email: req.user.email, name: req.user.name, notes: String(req.body.notes || '').trim(), boardResolution: String(req.body.boardResolution || '').trim(), approvedBudgetGross, createdAt: now() });
    if (approvedBudgetGross) request.approvedBudgetGross = approvedBudgetGross;
    if (decision === 'Abgelehnt') request.status = 'Abgelehnt';
    else {
      request.status = 'Genehmigt';
      if (!request.approvedBudgetGross) request.approvedBudgetGross = request.requestedBudgetGross;
    }
    event(request, decision === 'Abgelehnt' ? 'Antrag abgelehnt' : 'Freigabe erteilt', req.user.username, { status: request.status });
    res.json(detail(request));
  });

  app.post('/api/procurement/:id/cancel', authMiddleware, requirePermission('procurement.request'), (req, res) => {
    const request = findVisible(req, res); if (!request) return;
    if (!isOwner(req.user, request)) return res.status(403).json({ error: 'Nur der Antragsteller darf den Vorgang stornieren.' });
    if (['Abgeschlossen', 'Storniert'].includes(request.status)) return res.status(409).json({ error: 'Der Vorgang kann nicht storniert werden.' });
    const reason = String(req.body.reason || '').trim(); if (!reason) return res.status(400).json({ error: 'Eine Stornierungsbegründung ist erforderlich.' });
    request.status = 'Storniert'; event(request, 'Vorgang storniert', req.user.username, { reason }); res.json(detail(request));
  });

  app.post('/api/procurement/:id/offers', authMiddleware, requirePermission('procurement.request'), (req, res) => {
    const request = findVisible(req, res); if (!request) return;
    if (!isOwner(req.user, request)) return res.status(403).json({ error: 'Nur der Antragsteller darf Angebote erfassen.' });
    if (offers.filter((entry) => entry.requestId === request.id).length >= MAX_OFFERS_PER_REQUEST) {
      return res.status(409).json({ error: `Pro Vorgang sind maximal ${MAX_OFFERS_PER_REQUEST} Angebote erlaubt.` });
    }
    if (!['Beantragt', 'Genehmigt'].includes(request.status)) return res.status(409).json({ error: 'In diesem Status können keine Angebote erfasst werden.' });
    const supplier = suppliers.find((entry) => entry.id === req.body.supplierId && entry.active !== false);
    if (!supplier) return res.status(400).json({ error: 'Ein aktiver Lieferant ist erforderlich.' });
    const offer = { id: nextId('offer', offers), requestId: request.id, supplierId: supplier.id, offerNumber: String(req.body.offerNumber || '').trim(), offerDate: req.body.offerDate || null, validUntil: req.body.validUntil || null, deliveryDays: Number(req.body.deliveryDays) || null, grossTotal: money(req.body.grossTotal), shippingGross: money(req.body.shippingGross), notes: String(req.body.notes || '').trim(), createdAt: now() };
    if (offer.grossTotal <= 0) return res.status(400).json({ error: 'Die Angebotssumme muss größer als null sein.' });
    offers.push(offer); event(request, 'Angebot erfasst', req.user.username, { offerId: offer.id, supplierId: supplier.id }); res.status(201).json(offer);
  });

  app.post('/api/procurement/:id/select-offer', authMiddleware, requirePermission('procurement.order'), (req, res) => {
    const request = findVisible(req, res); if (!request) return;
    const offer = offers.find((entry) => entry.id === req.body.offerId && entry.requestId === request.id);
    if (!offer) return res.status(404).json({ error: 'Angebot nicht gefunden.' });
    const cheapest = Math.min(...offers.filter((entry) => entry.requestId === request.id).map((entry) => entry.grossTotal + entry.shippingGross));
    const justification = String(req.body.justification || '').trim();
    if (offer.grossTotal + offer.shippingGross > cheapest && !justification) return res.status(400).json({ error: 'Die Auswahl eines teureren Angebots muss begründet werden.' });
    request.selectedOfferId = offer.id; request.offerSelectionJustification = justification;
    event(request, 'Angebot ausgewählt', req.user.username, { offerId: offer.id, justification }); res.json(detail(request));
  });

  app.post('/api/procurement/:id/orders', authMiddleware, requirePermission('procurement.order'), (req, res) => {
    const request = findVisible(req, res); if (!request) return;
    if (orders.filter((entry) => entry.requestId === request.id).length >= MAX_ORDERS_PER_REQUEST) {
      return res.status(409).json({ error: `Pro Vorgang sind maximal ${MAX_ORDERS_PER_REQUEST} Bestellungen erlaubt.` });
    }
    if (!hasRole(req.user, ORDER_ROLES)) return res.status(403).json({ error: 'Nur Materialwart oder Kleiderwart dürfen bestellen.' });
    if (!['Genehmigt', 'Bestellt'].includes(request.status)) return res.status(409).json({ error: 'Der Antrag ist nicht zur Bestellung freigegeben.' });
    const supplier = suppliers.find((entry) => entry.id === req.body.supplierId && entry.active !== false);
    if (!supplier) return res.status(400).json({ error: 'Ein aktiver Lieferant ist erforderlich.' });
    if (!Array.isArray(req.body.items) || req.body.items.length > MAX_REQUEST_ITEMS) {
      return res.status(413).json({ error: `Maximal ${MAX_REQUEST_ITEMS} Bestellpositionen sind erlaubt.` });
    }
    const orderItems = req.body.items.map((item) => {
      const quantity = money(item.quantity);
      const submittedPrice = money(item.grossUnitPrice);
      const requestOffers = offers.filter((entry) => entry.requestId === request.id);
      const referenceOffer = requestOffers.find((entry) => entry.id === request.selectedOfferId)
        || (requestOffers.length === 1 ? requestOffers[0] : null);
      const legacyLineTotal = item.grossTotal == null
        && request.items.length === 1
        && referenceOffer
        && Math.abs(submittedPrice - referenceOffer.grossTotal) < 0.01;
      const grossTotal = item.grossTotal != null
        ? money(item.grossTotal)
        : legacyLineTotal
          ? submittedPrice
          : money(quantity * submittedPrice);
      return {
        requestItemId: item.requestItemId,
        quantity,
        grossTotal,
        grossUnitPrice: quantity > 0 ? money(grossTotal / quantity) : 0,
        deliveredQuantity: 0,
      };
    });
    if (!orderItems.length || orderItems.some((item) => !request.items.some((entry) => entry.id === item.requestItemId) || item.quantity <= 0 || item.grossTotal <= 0)) return res.status(400).json({ error: 'Gültige Bestellpositionen mit positiver Positionssumme sind erforderlich.' });
    for (const item of orderItems) {
      const alreadyOrdered = orders.filter((entry) => entry.requestId === request.id).flatMap((entry) => entry.items).filter((entry) => entry.requestItemId === item.requestItemId).reduce((sum, entry) => sum + entry.quantity, 0);
      const requested = request.items.find((entry) => entry.id === item.requestItemId).quantity;
      if (alreadyOrdered + item.quantity > requested) return res.status(409).json({ error: 'Die bestellte Menge überschreitet die Antragsmenge.' });
    }
    const shippingGross = money(req.body.shippingGross);
    const grossTotal = money(orderItems.reduce((sum, item) => sum + item.grossTotal, 0) + shippingGross);
    const approvedBudgetGross = money(request.approvedBudgetGross);
    const alreadyOrderedGross = orders.filter((entry) => entry.requestId === request.id).reduce((sum, entry) => sum + entry.grossTotal, 0);
    if (approvedBudgetGross <= 0 || alreadyOrderedGross + grossTotal > approvedBudgetGross) return res.status(409).json({ error: 'Die Bestellung überschreitet das freigegebene Budget.' });
    const order = { id: nextId('order', orders), number: yearSequence('BE', orders), requestId: request.id, supplierId: supplier.id, orderDate: req.body.orderDate || new Date().toISOString().slice(0, 10), expectedDeliveryDate: req.body.expectedDeliveryDate || null, items: orderItems, shippingGross, grossTotal, netTotal: money(req.body.netTotal), notes: String(req.body.notes || '').trim(), createdBy: req.user.username, createdAt: now() };
    orders.push(order); request.status = 'Bestellt';
    if (!supplier.customerNumber && req.body.customerNumber) supplier.customerNumber = String(req.body.customerNumber).trim();
    event(request, 'Bestellung angelegt', req.user.username, { orderId: order.id, number: order.number }); res.status(201).json(order);
  });

  app.post('/api/procurement/:id/orders/:orderId/receipts', authMiddleware, requirePermission('procurement.receive'), (req, res) => {
    const request = findVisible(req, res); if (!request) return;
    if (!hasRole(req.user, ORDER_ROLES)) return res.status(403).json({ error: 'Nur Materialwart oder Kleiderwart dürfen Wareneingänge buchen.' });
    const order = orders.find((entry) => entry.id === req.params.orderId && entry.requestId === request.id);
    if (!order) return res.status(404).json({ error: 'Bestellung nicht gefunden.' });
    if (receipts.filter((entry) => entry.orderId === order.id).length >= MAX_RECEIPTS_PER_ORDER) {
      return res.status(409).json({ error: `Pro Bestellung sind maximal ${MAX_RECEIPTS_PER_ORDER} Wareneingänge erlaubt.` });
    }
    if (!Array.isArray(req.body.items) || req.body.items.length > MAX_REQUEST_ITEMS) {
      return res.status(413).json({ error: `Maximal ${MAX_REQUEST_ITEMS} Lieferpositionen sind erlaubt.` });
    }
    const receiptItems = req.body.items.map((item) => ({ requestItemId: item.requestItemId, quantity: money(item.quantity) }));
    if (!receiptItems.length || receiptItems.some((item) => item.quantity <= 0)) return res.status(400).json({ error: 'Gelieferte Mengen sind erforderlich.' });
    for (const item of receiptItems) {
      const orderItem = order.items.find((entry) => entry.requestItemId === item.requestItemId);
      if (!orderItem || orderItem.deliveredQuantity + item.quantity > orderItem.quantity) return res.status(409).json({ error: 'Die Lieferung überschreitet die offene Bestellmenge.' });
    }
    const contested = req.body.contested === true;
    const receipt = { id: nextId('receipt', receipts), number: yearSequence('WE', receipts), requestId: request.id, orderId: order.id, deliveryNoteNumber: String(req.body.deliveryNoteNumber || '').trim(), receivedAt: req.body.receivedAt || new Date().toISOString().slice(0, 10), items: receiptItems, status: contested ? 'Beanstandet' : 'Zu prüfen', complaint: contested ? String(req.body.complaint || '').trim() : '', inventoryTransferred: false, createdBy: req.user.username, createdAt: now() };
    if (contested && !receipt.complaint) return res.status(400).json({ error: 'Eine Beanstandung benötigt eine Beschreibung.' });
    receipts.push(receipt); receiptItems.forEach((item) => { order.items.find((entry) => entry.requestItemId === item.requestItemId).deliveredQuantity += item.quantity; });
    const allDelivered = orders.filter((entry) => entry.requestId === request.id).every((entry) => entry.items.every((item) => item.deliveredQuantity >= item.quantity));
    request.status = allDelivered ? 'Geliefert' : 'Teilweise geliefert';
    event(request, contested ? 'Lieferung beanstandet' : 'Wareneingang gebucht', req.user.username, { receiptId: receipt.id }); res.status(201).json(receipt);
  });

  function nextMaterialNumber(categoryId, subcategoryId) {
    return nextInventoryNumber([...materials, ...deletedMaterials, ...clothingItems], categoryId, subcategoryId);
  }

  app.post('/api/procurement/:id/receipts/:receiptId/transfer', authMiddleware, requirePermission('procurement.receive'), (req, res) => {
    const request = findVisible(req, res); if (!request) return;
    const receipt = receipts.find((entry) => entry.id === req.params.receiptId && entry.requestId === request.id);
    if (!receipt) return res.status(404).json({ error: 'Wareneingang nicht gefunden.' });
    if (receipt.inventoryTransferred) return res.status(409).json({ error: 'Der Wareneingang wurde bereits übernommen.' });
    if (receipt.status === 'Beanstandet' && req.body.complaintResolved !== true) return res.status(409).json({ error: 'Die Beanstandung muss vor der Übernahme geklärt werden.' });
    const mappings = Array.isArray(req.body.items) ? req.body.items : [];
    if (mappings.length > MAX_REQUEST_ITEMS) {
      return res.status(413).json({ error: `Maximal ${MAX_REQUEST_ITEMS} Zuordnungen sind erlaubt.` });
    }
    let inventoryItemsToCreate = 0;
    for (const receiptItem of receipt.items) {
      const source = request.items.find((entry) => entry.id === receiptItem.requestItemId);
      const mapping = mappings.find((entry) => entry.requestItemId === receiptItem.requestItemId) || {};
      const wardrobe = categories.find((entry) => entry.id === source?.categoryId)?.useInWardrobe === true;
      if (wardrobe || mapping.itemType !== 'bulk') inventoryItemsToCreate += Math.max(1, Math.floor(receiptItem.quantity));
    }
    if (inventoryItemsToCreate > MAX_INVENTORY_ITEMS_PER_TRANSFER) {
      return res.status(413).json({ error: `Pro Übernahme dürfen maximal ${MAX_INVENTORY_ITEMS_PER_TRANSFER} Einzelartikel erzeugt werden.` });
    }
    if (materials.length + deletedMaterials.length + clothingItems.length
      + inventoryItemsToCreate + receipt.items.length > MAX_INVENTORY_RECORDS) {
      return res.status(507).json({ error: 'Die maximale Gesamtzahl an Inventardatensätzen ist erreicht.' });
    }
    const created = [];
    for (const receiptItem of receipt.items) {
      const source = request.items.find((entry) => entry.id === receiptItem.requestItemId);
      const sourceOrder = orders.find((entry) => entry.id === receipt.orderId);
      const purchaseUnitPrice = sourceOrder?.items.find((entry) => entry.requestItemId === receiptItem.requestItemId)?.grossUnitPrice || null;
      const mapping = mappings.find((entry) => entry.requestItemId === receiptItem.requestItemId) || {};
      if (!source || !locations.some((entry) => entry.id === mapping.locationId)) return res.status(400).json({ error: 'Für jede Position ist ein gültiger Standort erforderlich.' });
      if (mapping.stockStructureId && !stockStructures.some((entry) => entry.id === mapping.stockStructureId && entry.locationId === mapping.locationId)) return res.status(400).json({ error: 'Der Lagerplatz gehört nicht zum Standort.' });
      const mainCategory = categories.find((entry) => entry.id === source.categoryId);
      const wardrobe = mainCategory?.useInWardrobe === true;
      if (wardrobe) {
        const clothingCategoryId = source.subcategoryId || source.categoryId;
        const allowedSizes = categorySizes(clothingCategoryId);
        const size = String(mapping.size || source.size || '').trim();
        if (allowedSizes.length && !allowedSizes.includes(size)) {
          return res.status(400).json({
            error: `Für ${source.name} muss eine vordefinierte Größe ausgewählt werden.`,
          });
        }
        const inspectionIntervalMonths = categoryInspectionInterval(clothingCategoryId);
        const count = Math.max(1, Math.floor(receiptItem.quantity));
        for (let index = 0; index < count; index += 1) {
          const item = { id: nextId('clothing', clothingItems), inventoryNumber: nextClothingInventoryNumber(clothingCategoryId), name: source.name, categoryId: clothingCategoryId, size, locationId: mapping.locationId, stockStructureId: mapping.stockStructureId || null, status: 'Lagernd', assignedPerson: null, manufacturer: String(mapping.manufacturer || ''), manufacturingYear: String(mapping.manufacturingYear || ''), purchaseDate: receipt.receivedAt, purchasePrice: purchaseUnitPrice, inspectionIntervalMonths, lastInspectionDate: null, nextInspectionDate: addMonths(receipt.receivedAt, inspectionIntervalMonths), createdAt: now() };
          clothingItems.push(item); created.push({ entity: 'clothing', ...item });
        }
      } else if (mapping.itemType === 'bulk') {
        const item = { id: nextId('material', [...materials, ...deletedMaterials]), inventoryNumber: nextMaterialNumber(source.categoryId, source.subcategoryId), name: source.name, categoryCode: source.categoryId, subcategoryCode: source.subcategoryId || '', locationId: mapping.locationId, stockStructureId: mapping.stockStructureId || null, status: 'Lagernd', itemType: 'bulk', quantity: receiptItem.quantity, issuedQuantity: 0, unit: source.unit, manufacturer: String(mapping.manufacturer || ''), model: String(mapping.model || ''), serialNumber: '', purchaseDate: receipt.receivedAt, purchasePrice: purchaseUnitPrice, department: request.department, inspectionIntervalMonths: Number(mapping.inspectionIntervalMonths) || null, archived: false, createdAt: now() };
        item.manufacturingYear = String(mapping.manufacturingYear || '');
        materials.push(item); created.push({ entity: 'material', ...item });
      } else {
        const count = Math.max(1, Math.floor(receiptItem.quantity));
        for (let index = 0; index < count; index += 1) {
          const item = { id: nextId('material', [...materials, ...deletedMaterials]), inventoryNumber: nextMaterialNumber(source.categoryId, source.subcategoryId), name: source.name, categoryCode: source.categoryId, subcategoryCode: source.subcategoryId || '', locationId: mapping.locationId, stockStructureId: mapping.stockStructureId || null, status: 'Lagernd', itemType: 'individual', quantity: 1, issuedQuantity: 0, unit: source.unit, manufacturer: String(mapping.manufacturer || ''), model: String(mapping.model || ''), serialNumber: String((mapping.serialNumbers || [])[index] || ''), purchaseDate: receipt.receivedAt, purchasePrice: purchaseUnitPrice, department: request.department, inspectionIntervalMonths: Number(mapping.inspectionIntervalMonths) || null, archived: false, createdAt: now() };
          item.manufacturingYear = String(mapping.manufacturingYear || '');
          materials.push(item); created.push({ entity: 'material', ...item });
        }
      }
    }
    receipt.inventoryTransferred = true; receipt.status = 'Übernommen'; receipt.transferredAt = now(); receipt.createdInventory = created;
    const requestReceipts = receipts.filter((entry) => entry.requestId === request.id);
    if (request.status === 'Geliefert' && requestReceipts.length && requestReceipts.every((entry) => entry.inventoryTransferred)) request.status = 'Abgeschlossen';
    event(request, 'Wareneingang ins Inventar übernommen', req.user.username, { receiptId: receipt.id, created: created.length }); res.json({ receipt, created });
  });

  app.get('/api/address-suggestions/localities', authMiddleware,
    requirePermission('procurement.read'), async (req, res) => {
      const country = String(req.query.country || '').trim();
      const postalCode = String(req.query.postalCode || '').trim();
      if (!country || country.length > 128 || !postalCode || postalCode.length > 32) {
        return res.status(400).json({ error: 'Land und Postleitzahl sind erforderlich.' });
      }
      try {
        return res.json(await addressLookup.localities({ country, postalCode }));
      } catch (_) {
        return res.status(503).json({
          error: 'Die automatische Ortssuche ist momentan nicht verfügbar. Der Ort kann manuell eingegeben werden.',
        });
      }
    });
  app.get('/api/address-suggestions/streets', authMiddleware,
    requirePermission('procurement.read'), async (req, res) => {
      const country = String(req.query.country || '').trim();
      const postalCode = String(req.query.postalCode || '').trim();
      const city = String(req.query.city || '').trim();
      const query = String(req.query.query || '').trim();
      if (!country || country.length > 128 || !postalCode || postalCode.length > 32
        || !city || city.length > 255 || query.length < 3 || query.length > 255) {
        return res.status(400).json({
          error: 'Land, Postleitzahl, Ort und mindestens drei Zeichen der Straße sind erforderlich.',
        });
      }
      try {
        return res.json(await addressLookup.streets({ country, postalCode, city, query }));
      } catch (_) {
        return res.status(503).json({
          error: 'Die automatische Straßensuche ist momentan nicht verfügbar. Die Straße kann manuell eingegeben werden.',
        });
      }
    });

  app.get('/api/suppliers', authMiddleware, requirePermission('procurement.read'), (req, res) => res.json(suppliers));
  app.post('/api/suppliers', authMiddleware, requirePermission('suppliers.write'), (req, res) => {
    if (suppliers.length >= MAX_SUPPLIER_RECORDS) {
      return res.status(507).json({ error: 'Die maximale Anzahl an Lieferanten ist erreicht.' });
    }
    const name = String(req.body.name || '').trim(); if (!name || name.length > 255) return res.status(400).json({ error: 'Name ist erforderlich und darf höchstens 255 Zeichen enthalten.' });
    const address = supplierAddress(req.body);
    const addressError = validateSupplierAddress(address);
    if (addressError) return res.status(400).json({ error: addressError });
    if (['contact', 'customerNumber', 'email', 'phone'].some((field) => String(req.body[field] || '').length > 255)
      || String(req.body.website || '').length > 512
      || String(req.body.paymentTerms || '').length > 2000) {
      return res.status(400).json({ error: 'Mindestens ein Lieferantenfeld überschreitet die zulässige Länge.' });
    }
    const supplier = {
      id: nextId('supplier', suppliers), name,
      ...Object.fromEntries(supplierTextFields.map((field) => [field, String(req.body[field] || '').trim()])),
      ...address,
      address: formatSupplierAddress(address),
      active: req.body.active !== false, createdAt: now(),
    };
    suppliers.push(supplier); res.status(201).json(supplier);
  });
  app.put('/api/suppliers/:id', authMiddleware, requirePermission('suppliers.write'), (req, res) => {
    const supplier = suppliers.find((entry) => entry.id === req.params.id); if (!supplier) return res.status(404).json({ error: 'Lieferant nicht gefunden.' });
    const name = String(req.body.name ?? supplier.name).trim();
    if (!name || name.length > 255) return res.status(400).json({ error: 'Name ist erforderlich und darf höchstens 255 Zeichen enthalten.' });
    const address = supplierAddress(req.body, supplier);
    const addressError = validateSupplierAddress(address);
    if (addressError) return res.status(400).json({ error: addressError });
    if (['contact', 'customerNumber', 'email', 'phone'].some((field) => String(req.body[field] ?? supplier[field] ?? '').length > 255)
      || String(req.body.website ?? supplier.website ?? '').length > 512
      || String(req.body.paymentTerms ?? supplier.paymentTerms ?? '').length > 2000) {
      return res.status(400).json({ error: 'Mindestens ein Lieferantenfeld überschreitet die zulässige Länge.' });
    }
    supplier.name = name;
    for (const field of supplierTextFields) {
      supplier[field] = String(req.body[field] ?? supplier[field] ?? '').trim();
    }
    Object.assign(supplier, address, { address: formatSupplierAddress(address) });
    if (Object.hasOwn(req.body, 'active')) supplier.active = req.body.active !== false;
    res.json(supplier);
  });

  app.post('/api/procurement/:id/documents', authMiddleware, requirePermission('procurement.request'), (req, res) => {
    const request = findVisible(req, res); if (!request) return;
    if (!isOwner(req.user, request)) return res.status(403).json({ error: 'Nur der Antragsteller darf Dokumente hinzufügen.' });
    const fileName = String(req.body.fileName || '').trim(); const extension = fileName.split('.').pop().toLowerCase(); const fileBase64 = String(req.body.fileBase64 || '');
    if (!fileName || !FILE_EXTENSIONS.includes(extension) || !fileBase64) return res.status(400).json({ error: 'Erlaubt sind PDF, Bilder, DOCX, XLSX und ODS.' });
    if (fileBase64.length > 7_000_000) return res.status(413).json({ error: 'Dateien dürfen maximal 5 MB groß sein.' });
    if (!validBase64(fileBase64)) return res.status(400).json({ error: 'Die Datei ist nicht gültig Base64-kodiert.' });
    if (procurementDocuments.filter((entry) => entry.requestId === request.id).length >= MAX_DOCUMENTS_PER_REQUEST) {
      return res.status(409).json({ error: `Pro Vorgang sind maximal ${MAX_DOCUMENTS_PER_REQUEST} Dokumente erlaubt.` });
    }
    if (procurementDocuments.length >= MAX_DOCUMENTS_TOTAL) {
      return res.status(507).json({ error: 'Die maximale Gesamtzahl an Beschaffungsdokumenten ist erreicht.' });
    }
    const bytes = Buffer.from(fileBase64, 'base64');
    const storedDocumentBytes = procurementDocuments.reduce((sum, entry) =>
      sum + Buffer.byteLength(entry.fileBase64 || '', 'base64'), 0);
    if (storedDocumentBytes + bytes.length > MAX_DOCUMENT_STORAGE_BYTES) {
      return res.status(507).json({ error: 'Das Speicherlimit für Beschaffungsdokumente ist erreicht.' });
    }
    const magic = fileMagic(bytes);
    const allowed = { pdf: 'pdf', png: 'png', jpg: 'jpeg', jpeg: 'jpeg', docx: 'zip', xlsx: 'zip', ods: 'zip' };
    if (allowed[extension] !== magic) return res.status(400).json({ error: 'Dateiendung und tatsächlicher Dateityp stimmen nicht überein.' });
    if (magic === 'zip') {
      const archive = inspectZipArchive(bytes);
      if (archive.error) return res.status(400).json({ error: archive.error });
    }
    const document = { id: nextId('proc-document', procurementDocuments), requestId: request.id, entityType: String(req.body.entityType || 'Antrag'), entityId: req.body.entityId || request.id, documentType: String(req.body.documentType || 'Sonstiges'), fileName, mimeType: req.body.mimeType || null, fileBase64, createdBy: req.user.username, createdAt: now() };
    procurementDocuments.push(document); event(request, 'Dokument hinzugefügt', req.user.username, { documentId: document.id, documentType: document.documentType }); const { fileBase64: omitted, ...metadata } = document; res.status(201).json(metadata);
  });
  app.get('/api/procurement/:id/documents/:documentId', authMiddleware, requirePermission('procurement.read'), (req, res) => {
    const request = findVisible(req, res); if (!request) return;
    const document = procurementDocuments.find((entry) => entry.id === req.params.documentId && entry.requestId === request.id); if (!document) return res.status(404).json({ error: 'Dokument nicht gefunden.' }); res.json(document);
  });

  app.get('/api/procurement/:id/print/:type', authMiddleware, requirePermission('procurement.export'), (req, res) => {
    const request = findVisible(req, res); if (!request) return;
    const type = String(req.params.type || '');
    let title; let lines;
    if (type === 'orders') {
      title = 'Bestellungen';
      lines = orders.filter((entry) => entry.requestId === request.id).flatMap((order) => [
        `${order.number} | ${suppliers.find((entry) => entry.id === order.supplierId)?.name || ''} | ${order.grossTotal.toFixed(2)} EUR | Freigegeben ${request.approvedBudgetGross.toFixed(2)} EUR`,
        ...order.items.map((item) => `${request.items.find((entry) => entry.id === item.requestItemId)?.name || ''}: ${item.quantity} Stk. | ${item.grossTotal.toFixed(2)} EUR gesamt | ${item.grossUnitPrice.toFixed(2)} EUR je Einheit`),
      ]);
    } else if (type === 'offers') {
      title = 'Angebotsvergleich';
      lines = offers.filter((entry) => entry.requestId === request.id).map((offer) => `${suppliers.find((entry) => entry.id === offer.supplierId)?.name || ''} | ${offer.offerNumber || 'ohne Nummer'} | ${(offer.grossTotal + offer.shippingGross).toFixed(2)} EUR | ${offer.deliveryDays || '-'} Tage${request.selectedOfferId === offer.id ? ' | AUSGEWAEHLT' : ''}`);
    } else if (type === 'receipts') {
      title = 'Wareneingaenge';
      lines = receipts.filter((entry) => entry.requestId === request.id).map((receipt) => `${receipt.number} | Lieferschein ${receipt.deliveryNoteNumber || '-'} | ${receipt.receivedAt} | ${receipt.status}`);
    } else return res.status(400).json({ error: 'Drucktyp muss orders, offers oder receipts sein.' });
    const buffer = minimalPdf([`MaterialKompass - ${title}`, `${request.number} - ${request.title}`, ...lines]);
    res.json({ fileName: `${request.number}-${type}.pdf`, fileBase64: buffer.toString('base64') });
  });

  function minimalPdf(lines) {
    const escaped = lines.join(' | ').replace(/\\/g, '\\\\').replace(/\(/g, '\\(').replace(/\)/g, '\\)').replace(/[^\x20-\x7E]/g, '?');
    const stream = `BT /F1 10 Tf 40 800 Td (${escaped.slice(0, 7000)}) Tj ET`;
    const objects = ['1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj', '2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj', '3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >> endobj', `4 0 obj << /Length ${stream.length} >> stream\n${stream}\nendstream endobj`, '5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj'];
    let pdf = '%PDF-1.4\n'; const offsets = [0]; objects.forEach((object) => { offsets.push(Buffer.byteLength(pdf)); pdf += `${object}\n`; }); const xref = Buffer.byteLength(pdf); pdf += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`; for (let i = 1; i <= objects.length; i += 1) pdf += `${String(offsets[i]).padStart(10, '0')} 00000 n \n`; pdf += `trailer << /Size ${objects.length + 1} /Root 1 0 R >>\nstartxref\n${xref}\n%%EOF`; return Buffer.from(pdf);
  }
  app.get('/api/procurement/export/:format', authMiddleware, requirePermission('procurement.export'), (req, res) => {
    const format = String(req.params.format).toLowerCase(); const visible = requests.filter((entry) => canSee(req.user, entry));
    if (format === 'pdf') { const buffer = minimalPdf(['MaterialKompass Beschaffungen', ...visible.map((entry) => `${entry.number} ${entry.title} ${entry.status} beantragt ${entry.requestedBudgetGross.toFixed(2)} EUR freigegeben ${money(entry.approvedBudgetGross).toFixed(2)} EUR`)]); return res.json({ fileName: `Beschaffungen-${new Date().toISOString().slice(0, 10)}.pdf`, fileBase64: buffer.toString('base64') }); }
    if (!['xlsx', 'ods'].includes(format)) return res.status(400).json({ error: 'Format muss xlsx, ods oder pdf sein.' });
    const rows = visible.map((entry) => Object.fromEntries(Object.entries({ Nummer: entry.number, Titel: entry.title, Status: entry.status, Antragsteller: entry.requestedBy, Fachbereich: entry.department, Kostenstelle: entry.costCenter, Priorität: entry.priority, Wunschlieferdatum: entry.desiredDeliveryDate || '', 'Beantragtes Budget': entry.requestedBudgetGross, 'Freigegebenes Budget': entry.approvedBudgetGross ?? '' })
      .map(([key, value]) => [key, typeof value === 'string' ? neutralizeSpreadsheetCell(value) : value])));
    const workbook = XLSX.utils.book_new(); XLSX.utils.book_append_sheet(workbook, XLSX.utils.json_to_sheet(rows), 'Beschaffungen'); const buffer = XLSX.write(workbook, { type: 'buffer', bookType: format }); res.json({ fileName: `Beschaffungen-${new Date().toISOString().slice(0, 10)}.${format}`, fileBase64: buffer.toString('base64') });
  });

  return { ALLOWED_STATUSES };
}

module.exports = { registerProcurementRoutes, ALLOWED_STATUSES };
