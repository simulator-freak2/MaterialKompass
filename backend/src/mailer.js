const { readFileSync } = require('node:fs');
const path = require('node:path');

let nodemailer;
let transport;

const LOGO_CID = 'materialkompass-logo';
const logo = readFileSync(path.join(
  __dirname,
  'assets',
  'materialkompass-logo-with-wordmark.png',
));

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

function buildBrandedHtml({ text, actionUrl, actionLabel }) {
  const bodyText = actionUrl
    ? String(text || '').replace(actionUrl, '').trim()
    : String(text || '').trim();
  const paragraphs = bodyText
    .split(/\n{2,}/)
    .filter(Boolean)
    .map((paragraph) => `<p>${escapeHtml(paragraph).replaceAll('\n', '<br>')}</p>`)
    .join('');
  const action = actionUrl
    ? `<p class="action"><a href="${escapeHtml(actionUrl)}">${escapeHtml(actionLabel || 'MaterialKompass öffnen')}</a></p>`
    : '';

  return `<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <meta name="color-scheme" content="light dark">
  <meta name="supported-color-schemes" content="light dark">
  <style>
    body { margin: 0; padding: 24px; background: #fff7e6; color: #2b2100; font: 16px/1.5 Arial, sans-serif; }
    .card { max-width: 620px; margin: 0 auto; padding: 28px; background: #ffffff; border: 1px solid #f4b400; border-radius: 16px; }
    .logo { display: block; width: 100%; max-width: 360px; height: auto; margin: 0 auto 24px; }
    .action a { display: inline-block; padding: 12px 18px; border-radius: 10px; background: #d32f2f; color: #ffffff !important; font-weight: 700; text-decoration: none; }
    .footer { margin-top: 28px; color: #6b5b3e; font-size: 13px; }
    @media (prefers-color-scheme: dark) {
      body { background: #1b1710; color: #fff7e6; }
      .card { background: #2b2418; border-color: #f4b400; }
      .footer { color: #d8ccb4; }
    }
  </style>
</head>
<body>
  <main class="card">
    <img class="logo" src="cid:${LOGO_CID}" alt="MaterialKompass">
    ${paragraphs}
    ${action}
    <p class="footer">Diese Nachricht wurde automatisch von MaterialKompass versendet.</p>
  </main>
</body>
</html>`;
}

function getTransport() {
  if (!process.env.SMTP_HOST) return null;
  nodemailer ||= require('nodemailer');
  transport ||= nodemailer.createTransport({
    host: process.env.SMTP_HOST,
    port: Number(process.env.SMTP_PORT || 587),
    secure: process.env.SMTP_SECURE === 'true',
    requireTLS: process.env.NODE_ENV === 'production' && process.env.SMTP_SECURE !== 'true',
    disableFileAccess: true,
    disableUrlAccess: true,
    auth: process.env.SMTP_USER
      ? { user: process.env.SMTP_USER, pass: process.env.SMTP_PASSWORD }
      : undefined,
    connectionTimeout: Number(process.env.SMTP_CONNECTION_TIMEOUT_MS || 10000),
    greetingTimeout: Number(process.env.SMTP_GREETING_TIMEOUT_MS || 10000),
    socketTimeout: Number(process.env.SMTP_SOCKET_TIMEOUT_MS || 20000),
  });
  return transport;
}

async function sendAccountMail({
  to,
  subject,
  text,
  actionUrl,
  actionLabel,
}) {
  const transport = getTransport();
  if (!transport) {
    if (process.env.NODE_ENV !== 'test') {
      console.warn(`E-Mail nicht versendet (SMTP_HOST fehlt): ${subject} -> ${to}`);
    }
    return false;
  }
  await transport.sendMail({
    from: process.env.MAIL_FROM || 'MaterialKompass <noreply@materialkompass.org>',
    to,
    subject,
    text,
    html: buildBrandedHtml({ text, actionUrl, actionLabel }),
    attachments: [{
      filename: 'materialkompass-logo.png',
      content: logo,
      cid: LOGO_CID,
      contentType: 'image/png',
      contentDisposition: 'inline',
    }],
  });
  return true;
}

async function verifyAccountMailTransport() {
  const accountMailTransport = getTransport();
  if (!accountMailTransport) return false;
  await accountMailTransport.verify();
  return true;
}

module.exports = {
  buildBrandedHtml,
  sendAccountMail,
  verifyAccountMailTransport,
};
