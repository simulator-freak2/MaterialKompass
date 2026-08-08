const { ImapFlow } = require('imapflow');

function normalizeMessageId(value) {
  const normalized = String(value || '').trim();
  if (!normalized) return null;
  return normalized.startsWith('<') ? normalized : `<${normalized}>`;
}

function createStocktakeMailMonitor({
  store, service, stocktakes = [], stocktakeEmailImports = [],
  persistData = async () => {}, clientFactory, env = process.env, logger = console,
} = {}) {
  if (!store || !service) throw new Error('Store und Dienst sind für den Inventur-Mail-Eingang erforderlich.');
  const mailbox = env.INVENTORY_IMAP_MAILBOX || 'INBOX';
  const processedMailbox = env.INVENTORY_IMAP_PROCESSED_MAILBOX || 'Verarbeitet';
  const mailboxKey = `stocktakes:${env.INVENTORY_IMAP_USER || ''}:${mailbox}`;
  const intervalMs = Number(env.INVENTORY_IMAP_POLL_INTERVAL_MS || 300000);
  let running = false; let timer; let activeRun;

  function client() {
    if (clientFactory) return clientFactory();
    const result = new ImapFlow({
      host: env.INVENTORY_IMAP_HOST, port: Number(env.INVENTORY_IMAP_PORT || 993),
      secure: env.INVENTORY_IMAP_SECURE !== 'false',
      auth: { user: env.INVENTORY_IMAP_USER, pass: env.INVENTORY_IMAP_PASSWORD },
      tls: { rejectUnauthorized: env.INVENTORY_IMAP_TLS_REJECT_UNAUTHORIZED !== 'false' },
      socketTimeout: Number(env.INVENTORY_IMAP_SOCKET_TIMEOUT_MS || 60000), logger: false,
    });
    result.on('error', (error) => logger.error('IMAP-Verbindung für Inventuren fehlgeschlagen:', error.message));
    return result;
  }

  async function ensureProcessed(connection) {
    if (!(await connection.list()).some((entry) => entry.path === processedMailbox)) await connection.mailboxCreate(processedMailbox);
  }

  async function runOnce() {
    if (running || !env.INVENTORY_IMAP_HOST) return false;
    running = true; const connection = client();
    try {
      await connection.connect(); const selected = await connection.mailboxOpen(mailbox);
      let state = await store.getMailboxProcessingState(mailboxKey);
      const uidValidity = String(selected.uidValidity);
      if (!state || state.uidValidity !== uidValidity) {
        state = { mailbox: mailboxKey, uidValidity, lastUid: 0, initializedAt: new Date() };
        await store.saveMailboxProcessingState(state);
      }
      const lastUid = Math.max(0, Number(selected.uidNext || 1) - 1);
      if (state.lastUid < lastUid) {
        const messages = [];
        for await (const message of connection.fetch(`${state.lastUid + 1}:${lastUid}`, { uid: true, source: true, envelope: true }, { uid: true })) messages.push(message);
        messages.sort((left, right) => left.uid - right.uid);
        for (const message of messages) {
          const sourceInfo = { mailbox, uid: message.uid, uidValidity, messageId: normalizeMessageId(message.envelope?.messageId) };
          let entry;
          try { entry = (await service.ingestSource(message.source, sourceInfo)).entry; }
          catch (error) { entry = await service.recordFailure(sourceInfo, error); }
          await ensureProcessed(connection);
          const moved = await connection.messageMove([message.uid], processedMailbox, { uid: true });
          const status = await connection.status(processedMailbox, { uidValidity: true });
          await service.updateMoved(entry, {
            mailbox: processedMailbox,
            uid: moved?.uidMap?.get(message.uid) || null,
            uidValidity: String(status.uidValidity || ''),
          });
          state.lastUid = message.uid; await store.saveMailboxProcessingState(state);
        }
      }
      await deleteCompletedMessages(connection);
      await persistData(); return true;
    } finally {
      if (connection.usable) await connection.logout().catch(() => connection.close());
      running = false;
    }
  }

  async function findMessage(connection, entry, selected) {
    const source = entry.emailSource || {};
    if (source.uid && String(source.uidValidity || '') === String(selected.uidValidity)) {
      try {
        const existing = await connection.fetchOne(source.uid, { uid: true }, { uid: true });
        if (existing?.uid) return [existing.uid];
      } catch (_) {
        // The processed folder may have been changed outside MaterialKompass.
      }
    }
    if (!source.messageId) return [];
    return connection.search({
      header: { 'message-id': normalizeMessageId(source.messageId) },
    }, { uid: true });
  }

  async function deleteCompletedMessages(connection) {
    const completedIds = new Set(stocktakes.filter((entry) => entry.status === 'Abgeschlossen')
      .map((entry) => entry.id));
    const pending = stocktakeEmailImports.filter((entry) => completedIds.has(entry.stocktakeId)
      && !entry.emailSource?.deletedAt);
    if (!pending.length) return;
    await ensureProcessed(connection);
    const selected = await connection.mailboxOpen(processedMailbox);
    for (const entry of pending) {
      entry.emailSource ||= {};
      entry.emailSource.deleteRequestedAt ||= new Date().toISOString();
      try {
        const uids = await findMessage(connection, entry, selected);
        if (uids.length) await connection.messageDelete(uids, { uid: true });
        entry.emailSource.deletedAt = new Date().toISOString();
        entry.emailSource.deleteResult = uids.length ? 'deleted' : 'not-found';
        delete entry.emailSource.deleteError;
      } catch (error) {
        entry.emailSource.deleteError = String(error?.message || error).slice(0, 1000);
        logger.error(`Inventur-E-Mail ${entry.id} konnte nicht gelöscht werden:`, error);
      }
    }
    await persistData();
  }

  function start() {
    if (!env.INVENTORY_IMAP_HOST || timer) return false;
    const schedule = () => { if (!activeRun) activeRun = runOnce().catch((error) => logger.error('Inventur-Mail-Prüfung fehlgeschlagen:', error)).finally(() => { activeRun = null; }); };
    schedule(); timer = setInterval(schedule, intervalMs); timer.unref(); return true;
  }

  async function stop() { if (timer) clearInterval(timer); timer = null; if (activeRun) await activeRun; await service.stop(); }
  return { runOnce, start, stop, deleteCompletedMessages };
}

module.exports = { createStocktakeMailMonitor };
