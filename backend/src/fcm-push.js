'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');

const FCM_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';
const DEFAULT_TOKEN_URI = 'https://oauth2.googleapis.com/token';

function base64UrlJson(value) {
  return Buffer.from(JSON.stringify(value)).toString('base64url');
}

function approvalMessage(device, approval) {
  return {
    token: device.pushToken,
    notification: {
      title: 'MaterialKompass-Anmeldung',
      body: 'Warst du das? Öffne die App, um die Anmeldung zu bestätigen oder abzulehnen.',
    },
    data: {
      type: 'mfa_approval',
      approvalId: approval.id,
      deviceId: device.id,
      expiresAt: approval.expiresAt,
    },
    android: { priority: 'high' },
    apns: {
      headers: { 'apns-priority': '10' },
      payload: { aps: { sound: 'default' } },
    },
  };
}

function createFcmPushSender({
  credentialsFile = process.env.GOOGLE_APPLICATION_CREDENTIALS,
  fetchImpl = fetch,
  now = Date.now,
  requestTimeoutMs = 10_000,
} = {}) {
  let credentials;
  let accessToken;
  let accessTokenExpiresAt = 0;

  function loadCredentials() {
    if (credentials !== undefined) return credentials;
    if (!credentialsFile) {
      credentials = null;
      return credentials;
    }
    const parsed = JSON.parse(fs.readFileSync(credentialsFile, 'utf8'));
    if (!parsed.project_id || !parsed.client_email || !parsed.private_key) {
      throw new Error('Die Firebase-Service-Account-Datei ist unvollständig.');
    }
    credentials = parsed;
    return credentials;
  }

  async function token() {
    const serviceAccount = loadCredentials();
    if (!serviceAccount) throw new Error('Firebase Cloud Messaging ist nicht konfiguriert.');
    if (accessToken && accessTokenExpiresAt > now() + 60_000) return accessToken;
    const issuedAt = Math.floor(now() / 1000);
    const header = base64UrlJson({ alg: 'RS256', typ: 'JWT' });
    const claims = base64UrlJson({
      iss: serviceAccount.client_email,
      scope: FCM_SCOPE,
      aud: serviceAccount.token_uri || DEFAULT_TOKEN_URI,
      iat: issuedAt,
      exp: issuedAt + 3600,
    });
    const unsigned = `${header}.${claims}`;
    const signature = crypto.sign('RSA-SHA256', Buffer.from(unsigned), {
      key: serviceAccount.private_key,
    }).toString('base64url');
    const response = await fetchImpl(serviceAccount.token_uri || DEFAULT_TOKEN_URI, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion: `${unsigned}.${signature}`,
      }),
      signal: AbortSignal.timeout(requestTimeoutMs),
    });
    const body = await response.json();
    if (!response.ok || !body.access_token) {
      throw new Error('Firebase-Zugriffstoken konnte nicht erstellt werden.');
    }
    accessToken = body.access_token;
    accessTokenExpiresAt = now() + Number(body.expires_in || 3600) * 1000;
    return accessToken;
  }

  async function sendOne(device, approval) {
    const serviceAccount = loadCredentials();
    if (!serviceAccount) return { ok: false, notConfigured: true };
    const bearer = await token();
    const response = await fetchImpl(
      `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(serviceAccount.project_id)}/messages:send`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${bearer}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ message: approvalMessage(device, approval) }),
        signal: AbortSignal.timeout(requestTimeoutMs),
      },
    );
    if (response.ok) return { ok: true };
    const body = await response.text();
    let fcmErrorCode = '';
    try {
      const parsed = JSON.parse(body);
      const detail = parsed?.error?.details?.find((entry) =>
        entry?.['@type'] === 'type.googleapis.com/google.firebase.fcm.v1.FcmError'
      );
      fcmErrorCode = String(detail?.errorCode || '');
    } catch (_) {
      // Nicht strukturierte Gatewayfehler sind Zustellfehler, kein Widerrufsgrund.
    }
    return {
      ok: false,
      invalidToken: ['UNREGISTERED', 'INVALID_ARGUMENT'].includes(fcmErrorCode),
    };
  }

  return {
    configured: Boolean(credentialsFile && fs.existsSync(credentialsFile)),
    async sendApproval(devices, approval) {
      const results = await Promise.all(devices.map(async (device) => {
        try {
          return { device, result: await sendOne(device, approval) };
        } catch (_) {
          return { device, result: { ok: false } };
        }
      }));
      return {
        sent: results.filter((entry) => entry.result.ok).length,
        invalidDeviceIds: results
          .filter((entry) => entry.result.invalidToken)
          .map((entry) => entry.device.id),
      };
    },
  };
}

module.exports = { approvalMessage, createFcmPushSender };
