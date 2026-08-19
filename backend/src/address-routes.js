const { createAddressLookupService } = require('./address-lookup');

function registerAddressLookupRoutes({
  app,
  authMiddleware,
  addressLookup = createAddressLookupService(),
  rateLimit,
}) {
  const middleware = [authMiddleware, ...(rateLimit ? [rateLimit] : [])];
  const sendLookup = async (res, operation, error) => {
    try {
      return res.json(await operation());
    } catch (_) {
      return res.status(503).json({ error });
    }
  };

  app.get('/api/address-suggestions', ...middleware, async (req, res) => {
    const query = String(req.query.query || '').trim();
    const country = String(req.query.country || '').trim();
    if (query.length < 3 || query.length > 255 || country.length > 128) {
      return res.status(400).json({
        error: 'Für die Adresssuche sind mindestens drei und höchstens 255 Zeichen erforderlich.',
      });
    }
    return sendLookup(
      res,
      () => addressLookup.suggestions({ query, country }),
      'Die automatische Adresssuche ist momentan nicht verfügbar. Die Adresse kann manuell eingegeben werden.',
    );
  });

  // Compatibility endpoints for already installed clients.
  app.get('/api/address-suggestions/localities', ...middleware, async (req, res) => {
    const country = String(req.query.country || '').trim();
    const postalCode = String(req.query.postalCode || '').trim();
    if (!country || country.length > 128 || !postalCode || postalCode.length > 32) {
      return res.status(400).json({ error: 'Land und Postleitzahl sind erforderlich.' });
    }
    return sendLookup(
      res,
      () => addressLookup.localities({ country, postalCode }),
      'Die automatische Ortssuche ist momentan nicht verfügbar. Der Ort kann manuell eingegeben werden.',
    );
  });

  app.get('/api/address-suggestions/streets', ...middleware, async (req, res) => {
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
    return sendLookup(
      res,
      () => addressLookup.streets({ country, postalCode, city, query }),
      'Die automatische Straßensuche ist momentan nicht verfügbar. Die Straße kann manuell eingegeben werden.',
    );
  });
}

module.exports = { registerAddressLookupRoutes };
