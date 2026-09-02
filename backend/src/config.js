const SUPPORTED_PLATFORMS = Object.freeze([
  'windows',
  'linux',
  'android',
  'ios',
  'macos',
]);
const { validateLegalConfig } = require('./legal-config');

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
      if (parsed.protocol !== 'https:' || parsed.origin !== origin) {
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
    const passkeyRpId = String(env.PASSKEY_RP_ID || appBaseUrl.hostname).toLowerCase();
    if (!/^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9][a-z0-9-]{0,62}$/.test(passkeyRpId)) {
      throw new Error('PASSKEY_RP_ID muss im Produktivbetrieb eine gültige Domain sein.');
    }
    const appHostname = appBaseUrl.hostname.toLowerCase();
    if (appHostname !== passkeyRpId && !appHostname.endsWith(`.${passkeyRpId}`)) {
      throw new Error('PASSKEY_RP_ID muss die Domain von APP_BASE_URL oder deren übergeordnete Domain sein.');
    }
    const passkeyOrigins = parseOrigins(env.PASSKEY_ORIGINS || appBaseUrl.origin);
    if (passkeyOrigins.length === 0) {
      throw new Error('PASSKEY_ORIGINS muss mindestens einen HTTPS-Origin enthalten.');
    }
    for (const origin of passkeyOrigins) {
      let parsed;
      try { parsed = new URL(origin); } catch (_) {
        throw new Error(`Ungültiger PASSKEY_ORIGIN: ${origin}`);
      }
      if (parsed.protocol !== 'https:' || parsed.origin !== origin
          || parsed.origin !== appBaseUrl.origin
          || (parsed.hostname !== passkeyRpId && !parsed.hostname.endsWith(`.${passkeyRpId}`))) {
        throw new Error(
          `PASSKEY_ORIGIN muss dem Origin von APP_BASE_URL entsprechen und zur RP-ID ${passkeyRpId} gehören: ${origin}`,
        );
      }
    }
    const androidOrigins = parseOrigins(env.PASSKEY_ANDROID_ORIGINS);
    if (androidOrigins.some((origin) => !/^android:apk-key-hash:[A-Za-z0-9_-]{43}$/.test(origin))) {
      throw new Error('PASSKEY_ANDROID_ORIGINS enthält einen ungültigen APK-Key-Hash-Origin.');
    }
    const androidPackage = String(env.PASSKEY_ANDROID_PACKAGE || '').trim();
    if (androidPackage && !/^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$/.test(androidPackage)) {
      throw new Error('PASSKEY_ANDROID_PACKAGE ist kein gültiger Android-Paketname.');
    }
    const androidFingerprints = String(env.PASSKEY_ANDROID_SHA256_FINGERPRINTS || '')
      .split(',').map((value) => value.trim()).filter(Boolean);
    if (androidFingerprints.some((value) => !/^(?:[A-Fa-f0-9]{2}:){31}[A-Fa-f0-9]{2}$/.test(value))) {
      throw new Error('PASSKEY_ANDROID_SHA256_FINGERPRINTS enthält einen ungültigen SHA-256-Fingerprint.');
    }
    const appleTeamId = String(env.PASSKEY_APPLE_TEAM_ID || '').trim();
    if (appleTeamId && !/^[A-Z0-9]{10}$/.test(appleTeamId)) {
      throw new Error('PASSKEY_APPLE_TEAM_ID muss aus 10 Großbuchstaben oder Ziffern bestehen.');
    }
    const appleBundleId = String(env.PASSKEY_APPLE_BUNDLE_ID || '').trim();
    if (appleBundleId && !/^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$/.test(appleBundleId)) {
      throw new Error('PASSKEY_APPLE_BUNDLE_ID ist ungültig.');
    }
    if (parseTrustProxy(env.TRUST_PROXY) === null) {
      throw new Error(
        'TRUST_PROXY muss im Produktivbetrieb explizit für den TLS-Reverse-Proxy gesetzt sein.',
      );
    }
    if (env.DEFECT_IMAP_SECURE === 'false'
      || env.DEFECT_IMAP_TLS_REJECT_UNAUTHORIZED === 'false'
      || env.PROCUREMENT_IMAP_SECURE === 'false'
      || env.PROCUREMENT_IMAP_TLS_REJECT_UNAUTHORIZED === 'false') {
      throw new Error(
        'E-Mail-Postfächer müssen im Produktivbetrieb TLS mit Zertifikatsprüfung verwenden.',
      );
    }
    if (env.INITIAL_ADMIN_PASSWORD
      && (env.INITIAL_ADMIN_PASSWORD.length < 12
        || /^replace-/i.test(env.INITIAL_ADMIN_PASSWORD))) {
      throw new Error(
        'INITIAL_ADMIN_PASSWORD muss mindestens 12 Zeichen lang und individuell gesetzt sein.',
      );
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
    const missingProcurementImapSettings = [
      'PROCUREMENT_IMAP_HOST',
      'PROCUREMENT_IMAP_USER',
      'PROCUREMENT_IMAP_PASSWORD',
    ].filter((name) => !env[name]);
    if (missingProcurementImapSettings.length > 0) {
      throw new Error(
        `Für das Angebots-Postfach fehlen IMAP-Einstellungen: ${missingProcurementImapSettings.join(', ')}.`,
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
    if (!/^[a-f0-9]{64}$/i.test(env.MFA_ENCRYPTION_KEY || '')) {
      throw new Error(
        'MFA_ENCRYPTION_KEY muss ein zufälliger 64-stelliger Hex-Wert sein.',
      );
    }
    if (!env.MAILBOX_PROVISIONER_SOCKET) {
      let provisionerUrl;
      try { provisionerUrl = new URL(env.MAILBOX_PROVISIONER_URL || ''); } catch (_) {
        throw new Error(
          'MAILBOX_PROVISIONER_SOCKET oder eine gültige MAILBOX_PROVISIONER_URL ist erforderlich.',
        );
      }
      if (provisionerUrl.protocol !== 'https:') {
        throw new Error(
          'MAILBOX_PROVISIONER_URL muss im Produktivbetrieb HTTPS verwenden; '
          + 'für Compose sollte MAILBOX_PROVISIONER_SOCKET verwendet werden.',
        );
      }
    }
    if (!env.DB_HOST && (!env.INITIAL_ADMIN_PASSWORD || env.INITIAL_ADMIN_PASSWORD.length < 12)) {
      throw new Error('INITIAL_ADMIN_PASSWORD muss ohne Datenbank mindestens 12 Zeichen lang sein.');
    }
    validateLegalConfig(env);
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
