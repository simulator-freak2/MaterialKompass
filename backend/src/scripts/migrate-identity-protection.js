const { createUserStore } = require('../db/user-store');

const CONFIRMATION = 'IDENTITAETEN VERSCHLUESSELN';

async function main() {
  const confirmation = process.argv.find((entry) => entry.startsWith('--confirmation='))
    ?.slice('--confirmation='.length);
  if (!process.argv.includes('--apply') || confirmation !== CONFIRMATION) {
    throw new Error(
      `Abbruch. Aufruf: node src/scripts/migrate-identity-protection.js --apply --confirmation="${CONFIRMATION}"`,
    );
  }

  const store = createUserStore();
  try {
    await store.acquireProcessLock();
    await store.initialize();
    const { users } = await store.load();
    const collections = await store.loadCollections();
    await store.prepareIdentityKeys(users);

    for (const user of users) await store.saveUser(user);
    store.invalidateCollectionCache();
    await store.saveCollections(collections);
    if (!await store.markIdentityProtectionReadyIfComplete()) {
      throw new Error('Die Identity-Migration konnte nicht vollständig bestätigt werden.');
    }
    console.log(`${users.length} Konten und alle Fachsammlungen wurden geschützt.`);
  } finally {
    await store.close();
  }
}

main().catch((error) => {
  console.error('Identity-Migration fehlgeschlagen:', error.message);
  process.exitCode = 1;
});
