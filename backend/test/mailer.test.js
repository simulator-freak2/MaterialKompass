const assert = require('node:assert/strict');
const test = require('node:test');

const { buildBrandedHtml } = require('../src/mailer');

test('account mail HTML includes the inline brand and a safe action link', () => {
  const html = buildBrandedHtml({
    subject: 'Konto bestätigen',
    text: 'Bitte <Konto> bestätigen.\n\nhttps://materialkompass.org/#/verify',
    actionUrl: 'https://materialkompass.org/#/verify',
    actionLabel: 'Jetzt bestätigen',
  });

  assert.match(html, /cid:materialkompass-logo/);
  assert.match(html, /<meta name="viewport"/);
  assert.match(html, /prefers-color-scheme: dark/);
  assert.match(html, /<h1[^>]*>Konto bestätigen<\/h1>/);
  assert.match(html, /Bitte &lt;Konto&gt; bestätigen\./);
  assert.match(html, /href="https:\/\/materialkompass\.org\/#\/verify"/);
  assert.match(html, />Jetzt bestätigen</);
  assert.doesNotMatch(html, /Bitte <Konto>/);
});

test('account mail HTML rejects unsafe action protocols', () => {
  const html = buildBrandedHtml({
    subject: 'Systemnachricht',
    text: 'Öffnen Sie den Link nicht.',
    actionUrl: 'javascript:alert(1)',
    actionLabel: 'Öffnen',
  });

  assert.doesNotMatch(html, /href=/);
  assert.doesNotMatch(html, /javascript:/);
});

test('custom Markdown and HTML are rendered at the configured slot and sanitized', () => {
  const markdown = buildBrandedHtml({
    subject: 'Willkommen',
    text: 'Standardtext',
    actionUrl: 'https://materialkompass.org/start',
    customMessage: {
      content: '**Wichtig**\n\n- Punkt eins\n- Punkt zwei',
      format: 'markdown',
      placement: 'before-content',
    },
  });
  assert.match(markdown, /<strong>Wichtig<\/strong>/);
  assert.match(markdown, /<ul><li>Punkt eins<\/li><li>Punkt zwei<\/li><\/ul>/);
  assert.ok(markdown.indexOf('custom-message') < markdown.indexOf('Standardtext'));

  const unsafeHtml = buildBrandedHtml({
    subject: 'Hinweis',
    text: 'Standardtext',
    customMessage: {
      content: '<p onclick="alert(1)">Hallo</p><script>alert(2)</script><a href="javascript:alert(3)">Link</a>',
      format: 'html',
      placement: 'after-action',
    },
  });
  assert.match(unsafeHtml, /<p>Hallo<\/p>/);
  assert.doesNotMatch(unsafeHtml, /onclick|<script|javascript:/);
});
