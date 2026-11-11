const { isPlatformAdministration } = require('./platform-administration');
function requirePlatformAccountAdmin(req, res, next) {
  if (!isPlatformAdministration(req)) return res.status(403).json({
    error: 'Globale Kontosicherheit wird ausschließlich in der zentralen MaterialKompass-Verwaltung administriert.',
  });
  return next();
}

module.exports = { requirePlatformAccountAdmin };
