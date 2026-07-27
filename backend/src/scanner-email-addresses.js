const { randomUUID } = require('node:crypto');

const DESTINATIONS = Object.freeze([
  'Mängel',
  'Dokumente',
  'Inventar',
  'Kleiderkammer',
  'Beschaffung',
]);

function normalize(value) {
  return String(value || '').trim().toLowerCase();
}

function registerScannerEmailRoutes({
  app,
  authMiddleware,
  scannerEmailAddresses,
  users,
  logEvent,
}) {
  const domain = normalize(process.env.SCANNER_EMAIL_DOMAIN || 'materialkompass.org')
    .replace(/^@/, '');
  if (!/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/.test(domain)) {
    throw new Error('SCANNER_EMAIL_DOMAIN ist keine gültige E-Mail-Domain.');
  }

  function requireAdmin(req, res, next) {
    if (!req.user?.roles?.includes('Admin')) {
      return res.status(403).json({ error: 'Nur Administratoren dürfen Scanner-E-Mail-Adressen verwalten.' });
    }
    return next();
  }

  function response() {
    return {
      domain,
      destinations: DESTINATIONS,
      addresses: scannerEmailAddresses.slice().sort((left, right) =>
        left.email.localeCompare(right.email, 'de')),
    };
  }

  app.get('/api/scanner-email-addresses', authMiddleware, requireAdmin, (_req, res) => {
    return res.json(response());
  });

  app.post('/api/scanner-email-addresses', authMiddleware, requireAdmin, (req, res) => {
    const localPart = normalize(req.body.localPart);
    const name = String(req.body.name || '').trim();
    const destination = String(req.body.destination || '').trim();
    if (!/^[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?$/.test(localPart)) {
      return res.status(400).json({
        error: 'Der Adressteil darf nur Kleinbuchstaben, Zahlen, Punkt, Bindestrich und Unterstrich enthalten.',
      });
    }
    if (!name) return res.status(400).json({ error: 'Eine Bezeichnung ist erforderlich.' });
    if (!DESTINATIONS.includes(destination)) {
      return res.status(400).json({ error: 'Der Zielbereich ist ungültig.' });
    }

    const email = `${localPart}@${domain}`;
    if (scannerEmailAddresses.some((entry) => normalize(entry.email) === email)
      || users.some((user) => normalize(user.email) === email)) {
      return res.status(409).json({ error: 'Diese E-Mail-Adresse ist bereits vergeben.' });
    }

    const address = {
      id: `scanner-email-${randomUUID()}`,
      localPart,
      email,
      name: name.slice(0, 120),
      destination,
      active: req.body.active !== false,
      createdAt: new Date().toISOString(),
      createdBy: req.user.username,
    };
    scannerEmailAddresses.push(address);
    logEvent('create', 'ScannerEmailAddress', {
      id: address.id, email: address.email, destination: address.destination,
    }, req.user.username);
    return res.status(201).json(address);
  });

  app.put('/api/scanner-email-addresses/:id', authMiddleware, requireAdmin, (req, res) => {
    const address = scannerEmailAddresses.find((entry) => entry.id === req.params.id);
    if (!address) return res.status(404).json({ error: 'Scanner-E-Mail-Adresse nicht gefunden.' });
    const name = String(req.body.name ?? address.name).trim();
    const destination = String(req.body.destination ?? address.destination).trim();
    if (!name) return res.status(400).json({ error: 'Eine Bezeichnung ist erforderlich.' });
    if (!DESTINATIONS.includes(destination)) {
      return res.status(400).json({ error: 'Der Zielbereich ist ungültig.' });
    }
    Object.assign(address, {
      name: name.slice(0, 120),
      destination,
      active: req.body.active ?? address.active,
      updatedAt: new Date().toISOString(),
      updatedBy: req.user.username,
    });
    logEvent('update', 'ScannerEmailAddress', {
      id: address.id, email: address.email, destination: address.destination,
    }, req.user.username);
    return res.json(address);
  });

  app.delete('/api/scanner-email-addresses/:id', authMiddleware, requireAdmin, (req, res) => {
    const index = scannerEmailAddresses.findIndex((entry) => entry.id === req.params.id);
    if (index < 0) return res.status(404).json({ error: 'Scanner-E-Mail-Adresse nicht gefunden.' });
    const [address] = scannerEmailAddresses.splice(index, 1);
    logEvent('delete', 'ScannerEmailAddress', {
      id: address.id, email: address.email, destination: address.destination,
    }, req.user.username);
    return res.status(204).end();
  });
}

module.exports = { DESTINATIONS, registerScannerEmailRoutes };
