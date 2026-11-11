function requirePlatformAccountAdmin(req, res, next) {
  if (req.user?.platformAdmin !== true) return res.status(403).json({
    error: 'Globale Kontosicherheit darf nur die Plattformadministration verwalten.',
  });
  return next();
}

module.exports = { requirePlatformAccountAdmin };
