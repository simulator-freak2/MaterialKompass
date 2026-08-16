function configurePersistence({
  app,
  appData,
  dataStore,
  collectionNames,
}) {
  if (!dataStore) {
    app.locals.persistData = async () => {};
    return;
  }

  let saveRunning = false;
  let saveRequested = false;
  let saveWaiters = [];

  async function drainSaves() {
    if (saveRunning) return;
    saveRunning = true;
    while (saveRequested) {
      saveRequested = false;
      const currentWaiters = saveWaiters;
      saveWaiters = [];
      try {
        // Capture when the queued write starts. Concurrent mutations are
        // coalesced into the next cycle, retaining at most one full snapshot.
        const snapshot = structuredClone(Object.fromEntries(
          collectionNames.map((name) => [name, appData[name] || []]),
        ));
        await dataStore.saveCollections(snapshot);
        currentWaiters.forEach(({ resolve }) => resolve());
      } catch (error) {
        currentWaiters.forEach(({ reject }) => reject(error));
      }
    }
    saveRunning = false;
    if (saveRequested) void drainSaves();
  }

  const saveState = () => {
    saveRequested = true;
    const pending = new Promise((resolve, reject) => {
      saveWaiters.push({ resolve, reject });
    });
    void drainSaves();
    return pending;
  };

  app.locals.persistData = saveState;
  app.use((req, res, next) => {
    const stateChangingGet = req.method === 'GET'
      && ['/api/auth/verify-email', '/api/users'].includes(req.path);
    if (!stateChangingGet
      && !['POST', 'PUT', 'PATCH', 'DELETE'].includes(req.method)) {
      return next();
    }

    const originalEnd = res.end.bind(res);
    let ending = false;
    res.end = function persistentEnd(chunk, encoding, callback) {
      if (ending) return res;
      ending = true;
      const successfulProtectedMutation = Boolean(req.user) && res.statusCode < 400;
      const explicitPublicMutation = req.persistenceRequired === true;
      if (!successfulProtectedMutation && !explicitPublicMutation) {
        return originalEnd(chunk, encoding, callback);
      }
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
}

module.exports = { configurePersistence };
