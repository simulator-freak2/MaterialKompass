const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const test = require('node:test');

const repositoryRoot = join(__dirname, '..');
const nginxConfig = readFileSync(
  join(repositoryRoot, 'ops', 'nginx-web.conf'),
  'utf8',
);

test('Dart deferred chunks are never served from an immutable cache', () => {
  const partLocation =
    'location ~ ^/main\\.dart\\.js_[0-9]+\\.part\\.js$ {';
  const partLocationIndex = nginxConfig.indexOf(partLocation);
  assert.notEqual(
    partLocationIndex,
    -1,
    'nginx must define an explicit cache rule for Dart part files',
  );

  const partLocationEnd = nginxConfig.indexOf('\n    }', partLocationIndex);
  assert.notEqual(partLocationEnd, -1, 'Dart part-file location must be closed');
  const partLocationBody = nginxConfig.slice(
    partLocationIndex,
    partLocationEnd,
  );
  assert.match(
    partLocationBody,
    /Cache-Control "no-store, no-cache, must-revalidate"/,
  );
  assert.match(partLocationBody, /try_files \$uri =404;/);

  const immutableAssetLocationIndex = nginxConfig.indexOf(
    'location ~* \\.(?:js|css|wasm|png|jpg|jpeg|gif|svg|ico|woff2?)$ {',
  );
  assert.ok(
    immutableAssetLocationIndex > partLocationIndex,
    'the specific Dart part-file rule must precede the generic immutable asset rule',
  );
});

test('every location with its own add_header repeats the security headers', () => {
  // nginx only inherits server-level add_header directives into locations
  // that define none themselves.
  const securityHeaders = [
    'X-Content-Type-Options',
    'X-Frame-Options',
    'Content-Security-Policy',
    'Referrer-Policy',
    'Permissions-Policy',
  ];
  const locationPattern = /\n {4}location [^\n]*\{\n([\s\S]*?)\n {4}\}/g;
  let checked = 0;
  for (const match of nginxConfig.matchAll(locationPattern)) {
    const body = match[1];
    if (!/add_header /.test(body)) continue;
    checked += 1;
    for (const header of securityHeaders) {
      assert.match(
        body,
        new RegExp(`add_header ${header} .* always;`),
        `${match[0].split('\n')[1].trim()} must repeat ${header}`,
      );
    }
  }
  assert.ok(checked >= 6, 'expected the cache-policy locations to be checked');
  assert.match(nginxConfig, /frame-ancestors 'none'/);
});
