const { createApp } = require('./src/app');
const { createUserStore } = require('./src/db/user-store');
const { seedData } = require('./src/data/seed');
const { loadRuntimeConfig } = require('./src/config');
const { verifyAccountMailTransport } = require('./src/mailer');

async function start() {
  const config = loadRuntimeConfig();
  if (config.nodeEnv === 'production') {
    await verifyAccountMailTransport();
    console.log('SMTP-Verbindung für Account-E-Mails erfolgreich geprüft.');
  }
  if (!process.env.DB_HOST || !process.env.DB_USER || !process.env.DB_PASSWORD) {
    throw new Error('DB_HOST, DB_USER und DB_PASSWORD sind erforderlich; alle Daten werden in MariaDB gespeichert.');
  }

  const store = createUserStore();
  try {
    await store.initialize();
    const userData = await store.load();
    const storedCollections = await store.loadCollections();
    const data = structuredClone(seedData);
    for (const [name, values] of Object.entries(storedCollections)) data[name] = values;

    if (userData.roles.length === 0) {
      userData.roles = structuredClone(seedData.roles);
      await Promise.all(userData.roles.map((role) => store.saveRole(role)));
    }
    if (userData.users.length === 0) {
      if (config.nodeEnv === 'production' && !process.env.INITIAL_ADMIN_PASSWORD) {
        throw new Error('INITIAL_ADMIN_PASSWORD muss für den ersten Produktivstart gesetzt sein.');
      }
      userData.users = [structuredClone(seedData.users.find((user) => user.roles.includes('Admin')))];
      await store.saveUser(userData.users[0]);
      console.warn('Erster Admin wurde angelegt. Startpasswort vor Produktivbetrieb ändern.');
    }
    data.users = userData.users;
    data.roles = userData.roles;

    const app = createApp({ userStore: store, userData, data, dataStore: store });
    await app.locals.applyUserRetentionPolicy();
    await app.locals.persistData();
    console.log(`Alle Anwendungsdaten aus MariaDB geladen (${userData.users.length} Accounts).`);

    const retentionTimer = setInterval(() => {
      app.locals.applyUserRetentionPolicy()
        .then(() => app.locals.persistData())
        .catch((error) => console.error('Aufbewahrungsregel fehlgeschlagen:', error));
    }, 24 * 60 * 60 * 1000);
    retentionTimer.unref();

    const server = app.listen(config.port, config.host, () => {
      console.log(`MaterialKompass backend listening on http://${config.host}:${config.port}`);
    });
    let shuttingDown = false;
    const shutdown = (signal) => {
      if (shuttingDown) return;
      shuttingDown = true;
      console.log(`${signal} empfangen, Backend wird sauber beendet.`);
      const forceExitTimer = setTimeout(() => {
        console.error('Zeitlimit beim Herunterfahren überschritten.');
        process.exit(1);
      }, config.shutdownTimeoutMs);
      forceExitTimer.unref();
      server.close(async (error) => {
        clearTimeout(forceExitTimer);
        if (error) {
          console.error('Backend konnte nicht sauber beendet werden:', error);
          process.exitCode = 1;
        }
        try { await store.close(); } catch (closeError) {
          console.error('MariaDB-Verbindungen konnten nicht geschlossen werden:', closeError);
          process.exitCode = 1;
        }
      });
    };
    process.once('SIGTERM', () => shutdown('SIGTERM'));
    process.once('SIGINT', () => shutdown('SIGINT'));
  } catch (error) {
    await store.close();
    throw error;
  }
}

start().catch((error) => {
  console.error('Backend konnte nicht gestartet werden:', error);
  process.exitCode = 1;
});
