const { ImapFlow } = require('imapflow');
const { simpleParser } = require('mailparser');
const { sendAccountMail } = require('./mailer');

const DEFAULT_INTERVAL_MS = 5 * 60 * 1000;
const DELIVERY_HEADER_PATTERN = /X-MaterialKompass-Delivery-ID:\s*([0-9a-f-]{36})/i;
const RECIPIENT_PATTERN = /(?:Final|Original)-Recipient:\s*(?:rfc822;)?\s*([^\s;]+)/i;
const ORIGINAL_MESSAGE_ID_PATTERN = /Original-Message-ID:\s*(<[^>\r\n]+>|[^\s\r\n]+)/i;

function normalizeAddress(value) {
  return String(value || '').trim().replace(/[<>;,]$/g, '').toLowerCase();
}

function normalizeMessageId(value) {
  const normalized = String(value || '').trim().toLowerCase();
  return normalized ? (normalized.startsWith('<') ? normalized : `<${normalized}>`) : null;
}

function isPermanentDeliveryFailure(parsed, rawText) {
  const sender = (parsed.from?.value || [])
    .map((entry) => `${entry.name || ''} ${entry.address || ''}`)
    .join(' ');
  const systemSender = /mailer-daemon|postmaster|mail delivery (?:system|subsystem)/i
    .test(`${sender} ${parsed.subject || ''}`);
  const statuses = [...rawText.matchAll(/\bStatus:\s*([245]\.\d{1,3}\.\d{1,3})/gi)]
    .map((match) => match[1]);
  const failedAction = /\bAction:\s*failed\b/i.test(rawText);
  const permanentDiagnostic = /\bDiagnostic-Code:[^\r\n]*(?:\b5\d\d\b|\b5\.\d{1,3}\.\d{1,3}\b)/i
    .test(rawText);
  return systemSender && (statuses.some((status) => status.startsWith('5.'))
    || (failedAction && permanentDiagnostic));
}

function extractDeliveryReference(parsed, rawText) {
  const deliveryId = rawText.match(DELIVERY_HEADER_PATTERN)?.[1] || null;
  const originalMessageId = rawText.match(ORIGINAL_MESSAGE_ID_PATTERN)?.[1] || null;
  const recipient = rawText.match(RECIPIENT_PATTERN)?.[1]
    || parsed.to?.value?.[0]?.address
    || null;
  return {
    deliveryId,
    messageId: normalizeMessageId(originalMessageId),
    recipientEmail: normalizeAddress(recipient),
  };
}

function forwardingRecipients(delivery, users) {
  const creator = users.find((user) => user.id === delivery.createdByUserId);
  if (creator?.active && creator.email) return [creator.email];
  return [...new Set(users
    .filter((user) => user.active && user.email
      && (user.roles?.includes('Admin') || user.permissions?.includes('users.write')))
    .map((user) => normalizeAddress(user.email))
    .filter(Boolean))];
}

async function analyzeBounce(source) {
  const parsed = await simpleParser(source, {
    skipHtmlToText: true,
    skipImageLinks: true,
  });
  const rawText = source.toString('utf8');
  return {
    parsed,
    permanent: isPermanentDeliveryFailure(parsed, rawText),
    reference: extractDeliveryReference(parsed, rawText),
  };
}

function createMailBounceMonitor({
  store,
  users,
  mailSender = sendAccountMail,
  clientFactory,
  env = process.env,
  logger = console,
} = {}) {
  if (!store) throw new Error('Ein User-Store ist für die Rückläuferverarbeitung erforderlich.');
  const mailbox = env.IMAP_MAILBOX || 'INBOX';
  const mailboxKey = `${env.IMAP_USER || ''}:${mailbox}`;
  const intervalMs = Number(env.IMAP_POLL_INTERVAL_MS || DEFAULT_INTERVAL_MS);
  let running = false;
  let timer = null;
  let activeRun = null;

  function createClient() {
    if (clientFactory) return clientFactory();
    const client = new ImapFlow({
      host: env.IMAP_HOST,
      port: Number(env.IMAP_PORT || 993),
      secure: env.IMAP_SECURE !== 'false',
      auth: { user: env.IMAP_USER, pass: env.IMAP_PASSWORD },
      tls: { rejectUnauthorized: env.IMAP_TLS_REJECT_UNAUTHORIZED !== 'false' },
      socketTimeout: Number(env.IMAP_SOCKET_TIMEOUT_MS || 30000),
      logger: false,
    });
    client.on('error', (error) => logger.error('IMAP-Verbindung fehlgeschlagen:', error.message));
    return client;
  }

  async function forwardBounce(delivery, source) {
    const recipients = forwardingRecipients(delivery, users);
    if (recipients.length === 0) {
      throw new Error(`Keine zuständige Person für Rückläufer ${delivery.id} gefunden.`);
    }
    const forwarded = await mailSender({
      to: recipients,
      subject: `Unzustellbare MaterialKompass-Adressbestätigung: ${delivery.recipientEmail}`,
      text: `Die Adressbestätigung an ${delivery.recipientEmail} konnte endgültig nicht zugestellt werden.\n\nDie vollständige Rückmeldung des Mailservers ist angehängt.`,
      attachments: [{
        filename: `zustellfehler-${delivery.id}.eml`,
        content: source,
        contentType: 'message/rfc822',
      }],
    });
    if (forwarded === false) throw new Error('SMTP-Weiterleitung wurde nicht angenommen.');
  }

  async function processMessage(client, message) {
    const source = message.source;
    if (!source) return true;
    const analysis = await analyzeBounce(source);
    if (!analysis.permanent) return true;
    const delivery = await store.findVerificationMailDelivery(analysis.reference);
    if (!delivery) return true;
    if (!delivery.bounceForwardedAt) {
      await forwardBounce(delivery, source);
      await store.markAccountMailBounceForwarded(delivery.id);
    }
    const deleted = await client.messageDelete([message.uid], { uid: true });
    if (!deleted) throw new Error(`Rückläufer mit UID ${message.uid} konnte nicht gelöscht werden.`);
    return true;
  }

  async function runOnce() {
    if (running || !env.IMAP_HOST) return false;
    running = true;
    const client = createClient();
    try {
      await client.connect();
      const selected = await client.mailboxOpen(mailbox);
      const uidValidity = String(selected.uidValidity);
      let state = await store.getMailboxProcessingState(mailboxKey);
      if (!state || state.uidValidity !== uidValidity) {
        state = {
          mailbox: mailboxKey,
          uidValidity,
          lastUid: Math.max(0, Number(selected.uidNext || 1) - 1),
          initializedAt: new Date(),
        };
        await store.saveMailboxProcessingState(state);
        logger.log(`IMAP-Verarbeitung für ${mailbox} ab UID ${state.lastUid + 1} aktiviert.`);
        return true;
      }
      const firstUid = state.lastUid + 1;
      const lastUid = Math.max(0, Number(selected.uidNext || 1) - 1);
      if (firstUid > lastUid) return true;
      const messages = [];
      for await (const message of client.fetch(`${firstUid}:${lastUid}`,
        { uid: true, source: true }, { uid: true })) {
        messages.push(message);
      }
      messages.sort((left, right) => left.uid - right.uid);
      for (const message of messages) {
        await processMessage(client, message);
        state.lastUid = message.uid;
        await store.saveMailboxProcessingState(state);
      }
      return true;
    } finally {
      if (client.usable) await client.logout().catch(() => client.close());
      running = false;
    }
  }

  function start() {
    if (!env.IMAP_HOST || timer) return false;
    const scheduleRun = () => {
      if (activeRun) return;
      activeRun = runOnce()
        .catch((error) => logger.error('Rückläuferprüfung fehlgeschlagen:', error))
        .finally(() => { activeRun = null; });
    };
    scheduleRun();
    timer = setInterval(() => {
      scheduleRun();
    }, intervalMs);
    timer.unref();
    return true;
  }

  async function stop() {
    if (timer) clearInterval(timer);
    timer = null;
    if (activeRun) await activeRun;
  }

  return { runOnce, start, stop };
}

module.exports = {
  analyzeBounce,
  createMailBounceMonitor,
  extractDeliveryReference,
  forwardingRecipients,
  isPermanentDeliveryFailure,
  normalizeMessageId,
};
