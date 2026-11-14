const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { join } = require('node:path');
const test = require('node:test');

// Sichert die Massnahmen fuer einen Start der Loginseite unter einer Sekunde
// (siehe PERFORMANCE.md, Abschnitt "Startzeit der Loginseite").
const repositoryRoot = join(__dirname, '..');
const read = (...parts) => readFileSync(join(repositoryRoot, ...parts), 'utf8');
const indexHtml = read('flutter', 'web', 'index.html');
const bootstrap = read('flutter', 'web', 'flutter_bootstrap.js');
const serviceWorker = read('flutter', 'web', 'materialkompass_service_worker.js');
const nginxConfig = read('ops', 'nginx-web.conf');

function locationBody(header) {
  const start = nginxConfig.indexOf(header);
  assert.notEqual(start, -1, `nginx location fehlt: ${header}`);
  return nginxConfig.slice(start, nginxConfig.indexOf('\n    }', start));
}

test('index.html shows a static login placeholder until Flutter has drawn', () => {
  assert.match(indexHtml, /<div id="mk-splash"/);
  assert.match(indexHtml, /addEventListener\('flutter-first-frame'/);
  assert.match(indexHtml, /<link rel="preload" href="main\.dart\.js" as="script">/);
  assert.match(indexHtml, /<script src="passkeys\.js" defer><\/script>/);
});

test('the Flutter loader does not wait for the service worker', () => {
  assert.doesNotMatch(bootstrap, /serviceWorkerSettings\s*:/);
  assert.match(bootstrap, /_flutter\.loader\.load\(\);/);
  assert.match(bootstrap, /'flutter-first-frame',\s*registerMaterialKompassServiceWorker/);
});

test('the versioned service worker serves build files cache-first', () => {
  assert.match(serviceWorker, /const cacheName = `materialkompass-web-\$\{version\}`;/);
  assert.match(serviceWorker, /event\.respondWith\(cacheFirst\(request\)\);/);
  // Navigation und Bootstrap muessen neue Builds weiterhin sofort erkennen.
  assert.match(serviceWorker, /request\.mode === 'navigate'[\s\S]*networkFirst\(request\)/);
  assert.match(serviceWorker, /fileName === 'flutter_bootstrap\.js'[\s\S]*networkFirst\(request\)/);
  assert.match(serviceWorker, /url\.pathname\.includes\('\/api\/'\)/);
});

test('start files are revalidated instead of re-downloaded', () => {
  for (const header of [
    'location = /index.html {',
    'location = /flutter_bootstrap.js {',
    'location = /main.dart.js {',
    'location ^~ /canvaskit/ {',
  ]) {
    const body = locationBody(header);
    assert.match(body, /add_header Cache-Control "no-cache" always;/, header);
    assert.doesNotMatch(body, /no-store/, header);
  }
  assert.ok(
    nginxConfig.indexOf('location ^~ /canvaskit/ {') <
      nginxConfig.indexOf('location ~* \\.(?:js|css|wasm'),
    'CanvasKit darf nicht unter die unveraenderliche Asset-Regel fallen',
  );
  assert.match(
    locationBody('location = /materialkompass_service_worker.js {'),
    /no-store/,
  );
  assert.match(nginxConfig, /\n {4}gzip_static on;/);
});

test('web builds serve CanvasKit from the own origin', () => {
  assert.match(read('ops', 'build-web.ps1'), /'--no-web-resources-cdn'/);
  assert.match(
    read('.github', 'workflows', 'client-installers.yml'),
    /flutter build web --release --no-web-resources-cdn/,
  );
});
