const SUPPORTED_PLATFORMS = Object.freeze([
  'windows',
  'linux',
  'android',
  'ios',
  'macos',
]);

function parsePort(value = '3001') {
  const port = Number(value);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    throw new Error(`PORT muss eine ganze Zahl zwischen 1 und 65535 sein (erhalten: ${value}).`);
  }
  return port;
}

function parsePositiveInteger(value, fallback, name) {
  if (value === undefined || value === '') return fallback;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed < 1) {
    throw new Error(`${name} muss eine positive ganze Zahl sein.`);
  }
  return parsed;
}

function parseOrigins(value) {
  return String(value || '')
    .split(',')
    .map((origin) => origin.trim().replace(/\/$/, ''))
    .filter(Boolean);
}

function parseTrustProxy(value) {
  if (value === undefined || value === '') return null;
  if (/^\d+$/.test(String(value))) return Number(value);
  if (['loopback', 'linklocal', 'uniquelocal'].includes(value)) return value;
  throw new Error('TRUST_PROXY muss eine Hop-Anzahl oder loopback, linklocal bzw. uniquelocal sein.');
}

function createCorsOptions({
  corsOrigin = process.env.CORS_ORIGIN,
  nodeEnv = process.env.NODE_ENV,
} = {}) {
  const allowedOrigins = parseOrigins(corsOrigin);
  const allowDevelopmentOrigins = allowedOrigins.length === 0 && nodeEnv !== 'production';

  return {
    origin(origin, callback) {
      // Native Windows/Linux/Android/iOS/macOS clients do not send a browser
      // Origin header. CORS is a browser security mechanism and must not block them.
      if (!origin || allowDevelopmentOrigins) return callback(null, true);
      const normalizedOrigin = origin.replace(/\/$/, '');
      if (allowedOrigins.includes(normalizedOrigin)) return callback(null, true);
      const error = new Error('Origin ist für diese API nicht freigegeben.');
      error.status = 403;
      return callback(error);
    },
    methods: ['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
    allowedHeaders: ['Authorization', 'Content-Type', 'X-Request-Id'],
    exposedHeaders: ['X-API-Version', 'X-Request-Id'],
    maxAge: 86400,
  };
}

function loadRuntimeConfig(env = process.env) {
  if (env.NODE_ENV === 'production') {
    if (!env.JWT_SECRET || env.JWT_SECRET.length < 32 || /^replace-/i.test(env.JWT_SECRET)) {
      throw new Error('JWT_SECRET muss im Produktivbetrieb mindestens 32 zufällige Zeichen lang sein.');
    }
    const origins = parseOrigins(env.CORS_ORIGIN);
    if (origins.length === 0 || origins.includes('*')) {
      throw new Error('CORS_ORIGIN muss im Produktivbetrieb explizite Ursprünge enthalten.');
    }
    for (const origin of origins) {
      let parsed;
      try { parsed = new URL(origin); } catch (_) {
        throw new Error(`Ungültiger CORS_ORIGIN: ${origin}`);
      }
      if (!['http:', 'https:'].includes(parsed.protocol) || parsed.origin !== origin) {
        throw new Error(`CORS_ORIGIN muss ein Origin ohne Pfad sein: ${origin}`);
      }
    }
    let appBaseUrl;
    try { appBaseUrl = new URL(env.APP_BASE_URL || ''); } catch (_) {
      throw new Error('APP_BASE_URL muss im Produktivbetrieb eine gültige HTTPS-URL sein.');
    }
    if (appBaseUrl.protocol !== 'https:') {
      throw new Error('APP_BASE_URL muss im Produktivbetrieb HTTPS verwenden.');
    }
    const missingMailSettings = ['SMTP_HOST', 'SMTP_USER', 'SMTP_PASSWORD', 'MAIL_FROM']
      .filter((name) => !env[name]);
    if (missingMailSettings.length > 0) {
      throw new Error(`Für Account-E-Mails fehlen SMTP-Einstellungen: ${missingMailSettings.join(', ')}.`);
    }
    const missingDefectImapSettings = [
      'DEFECT_IMAP_HOST',
      'DEFECT_IMAP_USER',
      'DEFECT_IMAP_PASSWORD',
    ].filter((name) => !env[name]);
    if (missingDefectImapSettings.length > 0) {
      throw new Error(
        `Für das Mängel-Postfach fehlen IMAP-Einstellungen: ${missingDefectImapSettings.join(', ')}.`,
      );
    }
    if (!env.MAILBOX_PROVISIONER_TOKEN || env.MAILBOX_PROVISIONER_TOKEN.length < 32
      || /^replace-/i.test(env.MAILBOX_PROVISIONER_TOKEN)) {
      throw new Error(
        'MAILBOX_PROVISIONER_TOKEN muss mindestens 32 zufällige Zeichen lang sein.',
      );
    }
    if (!/^[a-f0-9]{64}$/i.test(env.MAILBOX_PASSWORD_ENCRYPTION_KEY || '')) {
      throw new Error(
        'MAILBOX_PASSWORD_ENCRYPTION_KEY muss ein zufälliger 64-stelliger Hex-Wert sein.',
      );
    }
    if (!env.DB_HOST && (!env.INITIAL_ADMIN_PASSWORD || env.INITIAL_ADMIN_PASSWORD.length < 12)) {
      throw new Error('INITIAL_ADMIN_PASSWORD muss ohne Datenbank mindestens 12 Zeichen lang sein.');
    }
  }

  parseTrustProxy(env.TRUST_PROXY);

  return {
    nodeEnv: env.NODE_ENV || 'development',
    host: env.HOST || '0.0.0.0',
    port: parsePort(env.PORT),
    shutdownTimeoutMs: parsePositiveInteger(
      env.SHUTDOWN_TIMEOUT_MS,
      10000,
      'SHUTDOWN_TIMEOUT_MS',
    ),
  };
}

module.exports = {
  SUPPORTED_PLATFORMS,
  createCorsOptions,
  loadRuntimeConfig,
  parseOrigins,
  parsePort,
  parseTrustProxy,
};
