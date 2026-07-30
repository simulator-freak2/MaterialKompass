const assert = require('node:assert/strict');
const test = require('node:test');

const { buildBrandedHtml } = require('../src/mailer');

test('account mail HTML includes the inline brand and a safe action link', () => {
  const html = buildBrandedHtml({
    text: 'Bitte <Konto> bestätigen.\n\nhttps://materialkompass.org/#/verify',
    actionUrl: 'https://materialkompass.org/#/verify',
    actionLabel: 'Jetzt bestätigen',
  });

  assert.match(html, /cid:materialkompass-logo/);
  assert.match(html, /prefers-color-scheme: dark/);
  assert.match(html, /Bitte &lt;Konto&gt; bestätigen\./);
  assert.match(html, /href="https:\/\/materialkompass\.org\/#\/verify"/);
  assert.match(html, />Jetzt bestätigen</);
  assert.doesNotMatch(html, /Bitte <Konto>/);
});
