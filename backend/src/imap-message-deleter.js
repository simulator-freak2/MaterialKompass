const { ImapFlow } = require('imapflow');

function normalizeMessageId(value) {
  const normalized = String(value || '').trim();
  if (!normalized) return null;
  return normalized.startsWith('<') ? normalized : `<${normalized}>`;
}

function createImapMessageDeleter({
  host,
  port = 993,
  secure = true,
  user,
  password,
  rejectUnauthorized = true,
  socketTimeout = 60000,
  processedMailbox = 'Verarbeitet',
  clientFactory,
} = {}) {
  function createClient() {
    if (clientFactory) return clientFactory();
    if (!host || !user || !password) {
      throw new Error('Das IMAP-Postfach ist nicht vollständig konfiguriert.');
    }
    return new ImapFlow({
      host,
      port: Number(port),
      secure,
      auth: { user, pass: password },
      tls: { rejectUnauthorized },
      socketTimeout: Number(socketTimeout),
      logger: false,
    });
  }

  async function deleteMessage(source = {}) {
    const mailbox = source.mailbox || source.processedMailbox || processedMailbox;
    if (!mailbox) throw new Error('Der IMAP-Ordner der E-Mail ist unbekannt.');
    const client = createClient();
    try {
      await client.connect();
      const selected = await client.mailboxOpen(mailbox);
      let uid = null;
      if (source.uid && (!source.uidValidity
        || String(source.uidValidity) === String(selected.uidValidity))) {
        try {
          const message = await client.fetchOne(source.uid, { uid: true }, { uid: true });
          if (message?.uid) uid = message.uid;
        } catch (_) {
          // The mailbox may have changed. Message-ID is the safe fallback.
        }
      }
      if (!uid && source.messageId) {
        const matches = await client.search({
          header: { 'message-id': normalizeMessageId(source.messageId) },
        }, { uid: true });
        uid = matches[0] || null;
      }
      if (!uid) throw new Error('Die E-Mail wurde im IMAP-Ordner nicht gefunden.');
      const deleted = await client.messageDelete([uid], { uid: true });
      if (!deleted) throw new Error('Der IMAP-Server hat die E-Mail nicht gelöscht.');
      return { mailbox, uid };
    } finally {
      if (client.usable) await client.logout().catch(() => client.close());
    }
  }

  return { deleteMessage };
}

function createConfiguredDeleter(env, prefix) {
  return createImapMessageDeleter({
    host: env[`${prefix}_IMAP_HOST`],
    port: Number(env[`${prefix}_IMAP_PORT`] || 993),
    secure: env[`${prefix}_IMAP_SECURE`] !== 'false',
    user: env[`${prefix}_IMAP_USER`],
    password: env[`${prefix}_IMAP_PASSWORD`],
    rejectUnauthorized: env[`${prefix}_IMAP_TLS_REJECT_UNAUTHORIZED`] !== 'false',
    socketTimeout: Number(env[`${prefix}_IMAP_SOCKET_TIMEOUT_MS`] || 60000),
    processedMailbox: env[`${prefix}_IMAP_PROCESSED_MAILBOX`] || 'Verarbeitet',
  });
}

module.exports = { createConfiguredDeleter, createImapMessageDeleter, normalizeMessageId };
