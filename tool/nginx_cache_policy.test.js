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
