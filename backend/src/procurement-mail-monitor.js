const { ImapFlow } = require('imapflow');

function createProcurementMailMonitor({ store, service, persistData = async () => {},
  runInContext = (callback) => callback(), clientFactory, env = process.env,
  logger = console } = {}) {
  if (!store || !service) throw new Error('Store und Dienst sind für den Angebots-Mail-Eingang erforderlich.');
  const mailbox = env.PROCUREMENT_IMAP_MAILBOX || 'INBOX';
  const processedMailbox = env.PROCUREMENT_IMAP_PROCESSED_MAILBOX || 'Verarbeitet';
  const mailboxKey = `procurement:${env.PROCUREMENT_IMAP_USER || ''}:${mailbox}`;
  const intervalMs = Number(env.PROCUREMENT_IMAP_POLL_INTERVAL_MS || 300000);
  // Pro Lauf nur einen begrenzten UID-Bereich laden und jede Nachricht sofort
  // verarbeiten, damit eine Flut großer E-Mails den Prozess nicht überlastet.
  const batchSize = Math.min(Math.max(Number(env.PROCUREMENT_IMAP_BATCH_SIZE) || 10, 1), 100);
  let running = false; let timer; let activeRun;

  function client() {
    if (clientFactory) return clientFactory();
    const result = new ImapFlow({
      host: env.PROCUREMENT_IMAP_HOST, port: Number(env.PROCUREMENT_IMAP_PORT || 993),
      secure: env.PROCUREMENT_IMAP_SECURE !== 'false',
      auth: { user: env.PROCUREMENT_IMAP_USER, pass: env.PROCUREMENT_IMAP_PASSWORD },
      tls: { rejectUnauthorized: env.PROCUREMENT_IMAP_TLS_REJECT_UNAUTHORIZED !== 'false' },
      socketTimeout: Number(env.PROCUREMENT_IMAP_SOCKET_TIMEOUT_MS || 60000), logger: false,
    });
    result.on('error', (error) => logger.error('IMAP-Verbindung für Angebote fehlgeschlagen:', error.message));
    return result;
  }

  async function ensureProcessed(connection) {
    if (!(await connection.list()).some((entry) => entry.path === processedMailbox)) await connection.mailboxCreate(processedMailbox);
  }

  async function locateMessage(connection, source) {
    if (source.uid) {
      try {
        const found = await connection.fetchOne(source.uid, { uid: true, envelope: true }, { uid: true });
        const foundId = String(found?.envelope?.messageId || '');
        if (found?.uid && (!source.messageId || !foundId || foundId === source.messageId)) return [found.uid];
      } catch (_) {
        // Der Ordner kann außerhalb von MaterialKompass verändert worden sein;
        // dann wird unten über die Message-ID gesucht.
      }
    }
    if (!source.messageId) return [];
    return (await connection.search({ header: { 'message-id': source.messageId } }, { uid: true })) || [];
  }

  // Zugewiesene, übernommene oder verworfene E-Mails werden auch im Postfach
  // gelöscht. Fehlschläge bleiben vorgemerkt und werden im nächsten Lauf wiederholt.
  async function deleteReleasedMessages(connection) {
    const pending = service.pendingMailDeletions ? service.pendingMailDeletions() : [];
    if (!pending.length) return;
    const folders = new Set((await connection.list()).map((entry) => entry.path));
    for (const entry of pending) {
      const source = entry.emailSource || {};
      const folder = source.mailbox || processedMailbox;
      try {
        let uids = [];
        if (folders.has(folder)) {
          await connection.mailboxOpen(folder);
          uids = await locateMessage(connection, source);
          if (uids.length) await connection.messageDelete(uids, { uid: true });
        }
        if (!uids.length) logger.warn?.(`Angebots-E-Mail ${entry.id} war im Postfach nicht mehr vorhanden.`);
        await service.completeMailDeletion(entry);
      } catch (error) {
        source.deleteError = String(error?.message || error).slice(0, 1000);
        logger.error(`Angebots-E-Mail ${entry.id} konnte im Postfach nicht gelöscht werden:`, error.message);
      }
    }
  }

  async function runOnce() {
    if (running || !env.PROCUREMENT_IMAP_HOST) return false;
    return runInContext(async () => {
      running = true; const connection = client();
      try {
      await connection.connect(); const selected = await connection.mailboxOpen(mailbox);
      let state = await store.getMailboxProcessingState(mailboxKey);
      const uidValidity = String(selected.uidValidity);
      if (!state || state.uidValidity !== uidValidity) {
        state = { mailbox: mailboxKey, uidValidity, lastUid: 0, initializedAt: new Date() };
        await store.saveMailboxProcessingState(state);
      }
      const firstUid = state.lastUid + 1;
      const lastUid = Math.min(Math.max(0, Number(selected.uidNext || 1) - 1), firstUid + batchSize - 1);
      if (firstUid <= lastUid) {
        const headers = [];
        for await (const message of connection.fetch(`${firstUid}:${lastUid}`, { uid: true, envelope: true }, { uid: true })) headers.push(message);
        headers.sort((left, right) => left.uid - right.uid);
        for (const message of headers) {
          const sourceInfo = { mailbox, uid: message.uid, uidValidity, messageId: String(message.envelope?.messageId || '') };
          let entry;
          try {
            const { source } = await connection.fetchOne(message.uid, { uid: true, source: true }, { uid: true }) || {};
            entry = (await service.ingestSource(source, sourceInfo)).entry;
          }
          catch (error) { entry = await service.recordFailure(sourceInfo, error); }
          await ensureProcessed(connection);
          const moved = await connection.messageMove([message.uid], processedMailbox, { uid: true });
          await service.updateMoved(entry, { mailbox: processedMailbox, uid: moved?.uidMap?.get(message.uid) || null });
          state.lastUid = message.uid; await store.saveMailboxProcessingState(state);
        }
        // Gelöschte Nachrichten erzeugen UID-Lücken; den begrenzten Bereich
        // trotzdem abschließen, damit kein leerer Bereich endlos abgefragt wird.
        if (state.lastUid < lastUid) { state.lastUid = lastUid; await store.saveMailboxProcessingState(state); }
      }
        await deleteReleasedMessages(connection);
        await persistData(); return true;
      } finally {
        if (connection.usable) await connection.logout().catch(() => connection.close());
        running = false;
      }
    });
  }

  function start() {
    if (!env.PROCUREMENT_IMAP_HOST || timer) return false;
    const schedule = () => { if (!activeRun) activeRun = runOnce().catch((error) => logger.error('Angebots-Mail-Prüfung fehlgeschlagen:', error)).finally(() => { activeRun = null; }); };
    schedule(); timer = setInterval(schedule, intervalMs); timer.unref(); return true;
  }

  async function stop() { if (timer) clearInterval(timer); timer = null; if (activeRun) await activeRun; await service.stop(); }
  return { runOnce, start, stop };
}

module.exports = { createProcurementMailMonitor };
