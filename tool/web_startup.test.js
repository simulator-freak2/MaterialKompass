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

test('index.html is a usable HTML login page that does not wait for Flutter', () => {
  assert.match(indexHtml, /<form id="mk-password"/);
  assert.match(indexHtml, /autocomplete="username"/);
  assert.match(indexHtml, /autocomplete="current-password"/);
  assert.match(indexHtml, /post\('\/api\/auth\/login'/);
  assert.match(indexHtml, /post\('\/api\/auth\/mfa\/verify'/);
  assert.match(indexHtml, /post\('\/api\/auth\/mfa\/push\/start'/);
  // Gleiche Speicherorte wie SessionValueStore der App (session_value_store_web.dart).
  assert.match(indexHtml, /'materialkompass_access_token_v1'/);
  assert.match(indexHtml, /'materialkompass_refresh_token_v1'/);
  assert.match(indexHtml, /window\.materialKompassAppReady = appReady;/);
  assert.match(indexHtml, /window\.materialKompassPendingLogin = \{/);
  assert.match(indexHtml, /<meta name="materialkompass-api" content="__MATERIALKOMPASS_API_BASE_URL__">/);
  assert.match(indexHtml, /<link rel="preload" href="main\.dart\.js" as="script">/);
  assert.match(indexHtml, /<script src="passkeys\.js" defer><\/script>/);
  // Ein neuer Build wird nie mitten in einer Eingabe neu geladen.
  assert.match(indexHtml, /if \(!startRequested && !userIsTyping\(\)\) window\.location\.reload\(\);/);
});

test('the HTML login and the app agree on the startup bridge', () => {
  const bridge = read('flutter', 'lib', 'services', 'web_startup_bridge_web.dart');
  assert.match(bridge, /const _readyCallback = 'materialKompassAppReady';/);
  assert.match(bridge, /const _pendingLogin = 'materialKompassPendingLogin';/);
  const types = read('flutter', 'lib', 'services', 'web_startup_bridge_types.dart');
  for (const match of indexHtml.matchAll(/data-handoff="([^"]+)"/g)) {
    if (match[1] === 'show') continue;
    assert.match(types, new RegExp(`= '${match[1]}';`), `Aktion ${match[1]} fehlt in der App`);
  }
});

test('the Flutter loader starts the app only on request', () => {
  assert.doesNotMatch(bootstrap, /serviceWorkerSettings\s*:/);
  assert.match(bootstrap, /engineInitializer\.initializeEngine\(\)/);
  assert.match(bootstrap, /window\.materialKompassStartup\.engineReady\(appRunner\)/);
  assert.match(bootstrap, /registerMaterialKompassServiceWorker\(\);/);
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

test('web builds serve CanvasKit from the own origin and set the API origin', () => {
  const buildScript = read('ops', 'build-web.ps1');
  const workflow = read('.github', 'workflows', 'client-installers.yml');
  assert.match(buildScript, /'--no-web-resources-cdn'/);
  assert.match(workflow, /flutter build web --release --no-web-resources-cdn/);
  assert.match(buildScript, /Replace\('__MATERIALKOMPASS_API_BASE_URL__', \$apiOrigin\)/);
  assert.match(workflow, /s\|__MATERIALKOMPASS_API_BASE_URL__\|\$origin\|/);
});
