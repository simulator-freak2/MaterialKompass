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
  let userStore;
  let userData;
  if (process.env.DB_HOST) {
    userStore = createUserStore();
    userData = await userStore.load();
    if (userData.roles.length === 0) {
      userData.roles = structuredClone(seedData.roles);
      await Promise.all(userData.roles.map((role) => userStore.saveRole(role)));
    }
    if (userData.users.length === 0) {
      if (process.env.NODE_ENV === 'production' && !process.env.INITIAL_ADMIN_PASSWORD) {
        throw new Error('INITIAL_ADMIN_PASSWORD muss für den ersten Produktivstart gesetzt sein.');
      }
      userData.users = [structuredClone(seedData.users.find((user) => user.roles.includes('Admin')))];
      await userStore.saveUser(userData.users[0]);
      console.warn('Erster Admin wurde angelegt. Startpasswort vor Produktivbetrieb ändern.');
    }
    console.log(`Nutzerverwaltung aus MariaDB geladen (${userData.users.length} Accounts).`);
  }
  const app = createApp({ userStore, userData });
  await app.locals.applyUserRetentionPolicy();
  const retentionTimer = setInterval(() => {
    app.locals.applyUserRetentionPolicy().catch((error) => console.error('Aufbewahrungsregel fehlgeschlagen:', error));
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
    server.close((error) => {
      clearTimeout(forceExitTimer);
      if (error) {
        console.error('Backend konnte nicht sauber beendet werden:', error);
        process.exitCode = 1;
      }
    });
  };
  process.once('SIGTERM', () => shutdown('SIGTERM'));
  process.once('SIGINT', () => shutdown('SIGINT'));
}

start().catch((error) => {
  console.error('Backend konnte nicht gestartet werden:', error);
  process.exitCode = 1;
});
