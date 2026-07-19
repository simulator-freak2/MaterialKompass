let nodemailer;
let transport;

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

async function sendAccountMail({ to, subject, text }) {
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
  });
  return true;
}

async function verifyAccountMailTransport() {
  const accountMailTransport = getTransport();
  if (!accountMailTransport) return false;
  await accountMailTransport.verify();
  return true;
}

module.exports = { sendAccountMail, verifyAccountMailTransport };
