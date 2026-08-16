const { ImapFlow } = require('imapflow');

const DEFAULT_INTERVAL_MS = 5 * 60 * 1000;
const DEFAULT_BATCH_SIZE = 10;

function normalizeMessageId(value) {
  const normalized = String(value || '').trim();
  if (!normalized) return null;
  return normalized.startsWith('<') ? normalized : `<${normalized}>`;
}

function createDefectMailMonitor({
  store,
  service,
  defectReports,
  persistData = async () => {},
  clientFactory,
  env = process.env,
  logger = console,
} = {}) {
  if (!store) throw new Error('Ein Store ist für den Mängel-Mail-Eingang erforderlich.');
  if (!service) throw new Error('Der Mängel-Mail-Dienst ist nicht konfiguriert.');
  const mailbox = env.DEFECT_IMAP_MAILBOX || 'INBOX';
  const processedMailbox = env.DEFECT_IMAP_PROCESSED_MAILBOX || 'Verarbeitet';
  const mailboxKey = `defects:${env.DEFECT_IMAP_USER || ''}:${mailbox}`;
  const intervalMs = Number(env.DEFECT_IMAP_POLL_INTERVAL_MS || DEFAULT_INTERVAL_MS);
  const batchSize = Math.min(Math.max(Number(env.DEFECT_IMAP_BATCH_SIZE) || DEFAULT_BATCH_SIZE, 1), 100);
  let running = false;
  let timer = null;
  let activeRun = null;

  function createClient() {
    if (clientFactory) return clientFactory();
    const client = new ImapFlow({
      host: env.DEFECT_IMAP_HOST,
      port: Number(env.DEFECT_IMAP_PORT || 993),
      secure: env.DEFECT_IMAP_SECURE !== 'false',
      auth: {
        user: env.DEFECT_IMAP_USER,
        pass: env.DEFECT_IMAP_PASSWORD,
      },
      tls: {
        rejectUnauthorized: env.DEFECT_IMAP_TLS_REJECT_UNAUTHORIZED !== 'false',
      },
      socketTimeout: Number(env.DEFECT_IMAP_SOCKET_TIMEOUT_MS || 60000),
      logger: false,
    });
    client.on('error', (error) =>
      logger.error('IMAP-Verbindung für Mängelmeldungen fehlgeschlagen:', error.message));
    return client;
  }

  async function ensureProcessedMailbox(client) {
    const existing = await client.list();
    if (!existing.some((entry) => entry.path === processedMailbox)) {
      await client.mailboxCreate(processedMailbox);
    }
  }

  async function moveProcessed(client, entry, sourceUid) {
    await ensureProcessedMailbox(client);
    const moved = await client.messageMove([sourceUid], processedMailbox, { uid: true });
    const processedUid = moved?.uidMap?.get(sourceUid) || null;
    const status = await client.status(processedMailbox, { uidValidity: true });
    await service.updateMoved(entry, {
      mailbox: processedMailbox,
      uid: processedUid,
      uidValidity: String(status.uidValidity || ''),
    });
  }

  async function ingestMessages(client, selected) {
    let state = await store.getMailboxProcessingState(mailboxKey);
    const uidValidity = String(selected.uidValidity);
    if (!state || state.uidValidity !== uidValidity) {
      state = {
        mailbox: mailboxKey,
        uidValidity,
        lastUid: 0,
        initializedAt: new Date(),
      };
      await store.saveMailboxProcessingState(state);
      logger.log(`Mängel-Mail-Eingang für ${mailbox} ab UID 1 aktiviert.`);
    }
    const firstUid = state.lastUid + 1;
    const mailboxLastUid = Math.max(0, Number(selected.uidNext || 1) - 1);
    const lastUid = Math.min(mailboxLastUid, firstUid + batchSize - 1);
    if (firstUid > lastUid) return;
    for await (const message of client.fetch(`${firstUid}:${lastUid}`,
      { uid: true, source: true, envelope: true }, { uid: true })) {
      const messageId = normalizeMessageId(message.envelope?.messageId);
      let entry;
      try {
        const result = await service.ingestSource(message.source, {
          mailbox,
          uid: message.uid,
          uidValidity,
          processedMailbox,
          messageId,
        });
        entry = result.entry;
      } catch (error) {
        logger.error(`Mängel-Mail UID ${message.uid} konnte nicht ausgewertet werden:`, error);
        entry = await service.recordFailure({
          mailbox,
          uid: message.uid,
          uidValidity,
          processedMailbox,
          messageId,
        }, error);
      }
      await moveProcessed(client, entry, message.uid);
      state.lastUid = message.uid;
      await store.saveMailboxProcessingState(state);
    }
    // Deleted messages create UID gaps. Advancing to the bounded range end
    // prevents an empty range from being fetched forever without retaining
    // all message sources in memory.
    if (state.lastUid < lastUid) {
      state.lastUid = lastUid;
      await store.saveMailboxProcessingState(state);
    }
  }

  async function findMessageForReport(client, report, selected) {
    const source = report.emailSource;
    if (!source) return [];
    if (source.uid && String(source.uidValidity || '') === String(selected.uidValidity)) {
      try {
        const exists = await client.fetchOne(source.uid, { uid: true }, { uid: true });
        if (exists?.uid) return [exists.uid];
      } catch (_) {
        // The processed folder may have been changed outside MaterialKompass.
        // Fall back to Message-ID below.
      }
    }
    if (!source.messageId) return [];
    return client.search({ header: { 'message-id': normalizeMessageId(source.messageId) } }, { uid: true });
  }

  async function deleteArchivedMessages(client) {
    const pending = defectReports.filter((report) =>
      report.archivedAt
      && report.emailSource?.deleteRequestedAt
      && !report.emailSource.deletedAt);
    if (!pending.length) return;
    await ensureProcessedMailbox(client);
    const selected = await client.mailboxOpen(processedMailbox);
    for (const report of pending) {
      const uids = await findMessageForReport(client, report, selected);
      if (uids.length) await client.messageDelete(uids, { uid: true });
      report.emailSource.deletedAt = new Date().toISOString();
      report.emailSource.deleteResult = uids.length ? 'deleted' : 'not-found';
    }
    await persistData();
  }

  async function runOnce() {
    if (running || !env.DEFECT_IMAP_HOST) return false;
    running = true;
    const client = createClient();
    try {
      await client.connect();
      const selected = await client.mailboxOpen(mailbox);
      await ingestMessages(client, selected);
      await deleteArchivedMessages(client);
      return true;
    } finally {
      if (client.usable) await client.logout().catch(() => client.close());
      running = false;
    }
  }

  function start() {
    if (!env.DEFECT_IMAP_HOST || timer) return false;
    const scheduleRun = () => {
      if (activeRun) return;
      activeRun = runOnce()
        .catch((error) => logger.error('Mängel-Mail-Prüfung fehlgeschlagen:', error))
        .finally(() => { activeRun = null; });
    };
    scheduleRun();
    timer = setInterval(scheduleRun, intervalMs);
    timer.unref();
    return true;
  }

  async function stop() {
    if (timer) clearInterval(timer);
    timer = null;
    if (activeRun) await activeRun;
    await service.stop();
  }

  return {
    deleteArchivedMessages,
    runOnce,
    start,
    stop,
  };
}

module.exports = { createDefectMailMonitor, normalizeMessageId };
