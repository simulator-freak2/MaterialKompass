const { readFileSync } = require('node:fs');
const path = require('node:path');
const sanitizeHtml = require('sanitize-html');

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

function safeActionUrl(value) {
  try {
    const url = new URL(String(value || ''));
    return ['http:', 'https:'].includes(url.protocol) ? url.toString() : '';
  } catch (_) {
    return '';
  }
}

const RICH_TEXT_TAGS = [
  'p', 'br', 'strong', 'b', 'em', 'i', 'u', 's', 'ul', 'ol', 'li',
  'blockquote', 'code', 'pre', 'h2', 'h3', 'h4', 'a',
];

function sanitizeRichHtml(value) {
  return sanitizeHtml(String(value || ''), {
    allowedTags: RICH_TEXT_TAGS,
    allowedAttributes: { a: ['href', 'title'] },
    allowedSchemes: ['http', 'https', 'mailto'],
    allowProtocolRelative: false,
    transformTags: {
      a: (_tagName, attribs) => ({
        tagName: 'a',
        attribs: {
          ...attribs,
          style: 'color:#b71c1c;text-decoration:underline;',
        },
      }),
    },
  });
}

function markdownToHtml(value) {
  let html = escapeHtml(value);
  html = html
    .replace(/^####\s+(.+)$/gm, '<h4>$1</h4>')
    .replace(/^###\s+(.+)$/gm, '<h3>$1</h3>')
    .replace(/^##\s+(.+)$/gm, '<h2>$1</h2>')
    .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
    .replace(/__(.+?)__/g, '<strong>$1</strong>')
    .replace(/(?<!\*)\*([^*\n]+)\*(?!\*)/g, '<em>$1</em>')
    .replace(/`([^`\n]+)`/g, '<code>$1</code>')
    .replace(/\[([^\]]+)]\((https?:\/\/[^\s)]+|mailto:[^\s)]+)\)/g, '<a href="$2">$1</a>');

  const blocks = html.split(/\n{2,}/).filter((entry) => entry.trim());
  return blocks.map((block) => {
    const lines = block.split('\n');
    if (lines.every((line) => /^[-*]\s+/.test(line))) {
      return `<ul>${lines.map((line) => `<li>${line.replace(/^[-*]\s+/, '')}</li>`).join('')}</ul>`;
    }
    if (lines.every((line) => /^\d+\.\s+/.test(line))) {
      return `<ol>${lines.map((line) => `<li>${line.replace(/^\d+\.\s+/, '')}</li>`).join('')}</ol>`;
    }
    if (lines.every((line) => /^&gt;\s?/.test(line))) {
      return `<blockquote>${lines.map((line) => line.replace(/^&gt;\s?/, '')).join('<br>')}</blockquote>`;
    }
    if (/^<h[2-4]>/.test(block)) return block.replaceAll('\n', '');
    return `<p>${block.replaceAll('\n', '<br>')}</p>`;
  }).join('');
}

function renderRichContent(message) {
  if (!message || !String(message.content || '').trim()) return '';
  return message.format === 'html'
    ? sanitizeRichHtml(message.content)
    : sanitizeRichHtml(markdownToHtml(String(message.content)));
}

function richContentToText(message) {
  if (!message || !String(message.content || '').trim()) return '';
  if (message.format !== 'html') return String(message.content).trim();
  return sanitizeHtml(String(message.content), {
    allowedTags: [],
    allowedAttributes: {},
  }).trim();
}

function richMessageBlock(message) {
  const html = renderRichContent(message);
  if (!html) return '';
  return `<tr>
          <td class="mobile-pad" style="padding:8px 32px 18px 32px;">
            <div class="custom-message" style="padding:18px;border-left:4px solid #f4b400;border-radius:8px;background:#fffaf0;color:#2b2100;font-family:Arial,sans-serif;font-size:16px;line-height:25px;">${html}</div>
          </td>
        </tr>`;
}

function buildBrandedHtml({ subject, preheader, text, richContent, customMessage, actionUrl, actionLabel }) {
  const safeUrl = safeActionUrl(actionUrl);
  const bodyText = actionUrl
    ? String(text || '').replace(actionUrl, '').trim()
    : String(text || '').trim();
  const paragraphs = richContent
    ? renderRichContent(richContent)
    : bodyText
      .split(/\n{2,}/)
      .filter(Boolean)
      .map((paragraph) => `<p>${escapeHtml(paragraph).replaceAll('\n', '<br>')}</p>`)
      .join('');
  const customBlock = richMessageBlock(customMessage);
  const placement = ['before-content', 'before-action', 'after-action']
    .includes(customMessage?.placement) ? customMessage.placement : 'before-action';
  const action = safeUrl
    ? `<tr>
            <td style="padding:8px 32px 12px 32px;">
              <table role="presentation" cellspacing="0" cellpadding="0" border="0"><tr>
                <td bgcolor="#d32f2f" style="border-radius:10px;">
                  <a href="${escapeHtml(safeUrl)}" style="display:inline-block;padding:13px 22px;border:1px solid #d32f2f;border-radius:10px;color:#ffffff;font-family:Arial,sans-serif;font-size:16px;font-weight:700;line-height:20px;text-decoration:none;">${escapeHtml(actionLabel || 'MaterialKompass öffnen')}</a>
                </td>
              </tr></table>
            </td>
          </tr>
          <tr>
            <td style="padding:8px 32px 24px 32px;color:#6b5b3e;font-family:Arial,sans-serif;font-size:13px;line-height:20px;">
              Falls der Button nicht funktioniert, kopieren Sie diesen Link in Ihren Browser:<br>
              <a href="${escapeHtml(safeUrl)}" style="color:#b71c1c;text-decoration:underline;word-break:break-all;">${escapeHtml(safeUrl)}</a>
            </td>
          </tr>`
    : '';
  const mailTitle = escapeHtml(subject || 'Nachricht von MaterialKompass');
  const previewText = escapeHtml(preheader || bodyText.replace(/\s+/g, ' ').slice(0, 140));

  return `<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="x-apple-disable-message-reformatting">
  <meta name="color-scheme" content="light dark">
  <meta name="supported-color-schemes" content="light dark">
  <title>${mailTitle}</title>
  <style>
    table { border-collapse: collapse; }
    img { border: 0; display: block; }
    .content p { margin: 0 0 16px 0; }
    .content p:last-child { margin-bottom: 0; }
    @media only screen and (max-width: 640px) {
      .shell { width: 100% !important; }
      .mobile-pad { padding-left: 22px !important; padding-right: 22px !important; }
      .logo { width: 270px !important; max-width: 100% !important; height: auto !important; }
      h1 { font-size: 23px !important; line-height: 29px !important; }
    }
    @media (prefers-color-scheme: dark) {
      .page { background: #1b1710 !important; }
      .card { background: #2b2418 !important; }
      .heading, .content, .custom-message { color: #fff7e6 !important; }
      .custom-message { background: #3a301f !important; }
      .muted { color: #d8ccb4 !important; }
    }
  </style>
</head>
<body class="page" style="margin:0;padding:0;background:#fff7e6;word-spacing:normal;">
  <div style="display:none;max-height:0;overflow:hidden;opacity:0;color:transparent;">${previewText}&#847; &zwnj;&nbsp;&#847; &zwnj;&nbsp;&#847;</div>
  <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" class="page" style="width:100%;background:#fff7e6;">
    <tr><td align="center" style="padding:32px 12px;">
      <table role="presentation" width="620" cellspacing="0" cellpadding="0" border="0" class="shell card" style="width:620px;max-width:620px;background:#ffffff;border:1px solid #f4b400;border-radius:16px;overflow:hidden;box-shadow:0 8px 24px rgba(43,33,0,.08);">
        <tr><td height="7" bgcolor="#f4b400" style="height:7px;font-size:0;line-height:0;">&nbsp;</td></tr>
        <tr>
          <td align="center" class="mobile-pad" style="padding:28px 32px 22px 32px;border-bottom:1px solid #f3e7cb;">
            <img class="logo" src="cid:${LOGO_CID}" width="340" alt="MaterialKompass" style="width:340px;max-width:100%;height:auto;">
          </td>
        </tr>
        ${placement === 'before-content' ? customBlock : ''}
        <tr>
          <td class="mobile-pad" style="padding:28px 32px 4px 32px;">
            <h1 class="heading" style="margin:0;color:#2b2100;font-family:Arial,sans-serif;font-size:26px;font-weight:700;line-height:34px;">${mailTitle}</h1>
          </td>
        </tr>
        <tr>
          <td class="content mobile-pad" style="padding:16px 32px 8px 32px;color:#2b2100;font-family:Arial,sans-serif;font-size:16px;line-height:25px;">${paragraphs}</td>
        </tr>
        ${placement === 'before-action' ? customBlock : ''}
        ${action}
        ${placement === 'after-action' ? customBlock : ''}
        <tr>
          <td class="muted mobile-pad" style="padding:22px 32px;background:#fffaf0;border-top:1px solid #f3e7cb;color:#6b5b3e;font-family:Arial,sans-serif;font-size:12px;line-height:18px;">
            Diese Nachricht wurde automatisch von MaterialKompass versendet. Bitte antworten Sie nicht auf diese E-Mail.<br>
            Wenn Sie diese Aktion nicht angefordert haben, können Sie die Nachricht ignorieren.
          </td>
        </tr>
      </table>
    </td></tr>
  </table>
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
  richContent,
  customMessage,
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
    text: [text, richContentToText(richContent), richContentToText(customMessage)]
      .filter(Boolean).join('\n\n'),
    html: buildBrandedHtml({
      subject, text, richContent, customMessage, actionUrl, actionLabel,
    }),
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
  renderRichContent,
  richContentToText,
  sendAccountMail,
  verifyAccountMailTransport,
};
