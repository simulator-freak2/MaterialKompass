const version = new URL(self.location.href).searchParams.get('v') || 'dev';
const cacheName = `materialkompass-web-${version}`;
const shell = [
  './',
  './index.html',
  './flutter_bootstrap.js',
  './main.dart.js',
  './manifest.json',
  './passkeys.js',
  './assets/assets/branding/materialkompass_logo_mit_schriftzug.png',
];

// Dateien, deren Name ueber Builds hinweg stabil bleibt, deren Inhalt sich
// aber mit jedem Build aendert. Sie werden immer zuerst vom Netz geladen.
const alwaysNetwork = new Set(['version.json']);

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(cacheName)
      // nginx liefert die Shell mit "no-cache" aus: Der Browser validiert
      // bereits geladene Dateien per ETag (304), statt sie erneut zu
      // uebertragen, und uebernimmt nie einen veralteten Build.
      .then((cache) => cache.addAll(shell))
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys
          .filter((key) => key.startsWith('materialkompass-web-') && key !== cacheName)
          .map((key) => caches.delete(key)),
      ))
      .then(() => self.clients.claim()),
  );
});

// Nimmt die Startdateien auf, die die Seite vor der Registrierung dieses
// Workers geladen hat. Bereits vorhandene Eintraege werden nicht erneut
// geladen; einzelne Fehler verhindern die uebrigen Eintraege nicht.
async function cacheLoadedResources(urls) {
  const cache = await caches.open(cacheName);
  await Promise.all(urls.map(async (value) => {
    let url;
    try {
      url = new URL(value, self.location.href);
    } catch (_) {
      return;
    }
    if (url.origin !== self.location.origin || url.pathname.includes('/api/')) {
      return;
    }
    const fileName = url.pathname.split('/').pop();
    if (fileName === 'flutter_bootstrap.js' || alwaysNetwork.has(fileName)) return;
    if (await cache.match(url.href, { ignoreSearch: true })) return;
    try {
      const response = await fetch(url.href);
      if (response.ok) await cache.put(url.href, response);
    } catch (_) {
      // Wird beim naechsten Zugriff ueber cacheFirst nachgeholt.
    }
  }));
}

self.addEventListener('message', (event) => {
  const data = event.data;
  if (!data || data.type !== 'materialkompass-cache-loaded') return;
  if (!Array.isArray(data.urls)) return;
  event.waitUntil(cacheLoadedResources(data.urls.slice(0, 200)));
});

async function networkFirst(request) {
  const cache = await caches.open(cacheName);
  try {
    const response = await fetch(request);
    if (response.ok) await cache.put(request, response.clone());
    return response;
  } catch (error) {
    const cached = await cache.match(request, { ignoreSearch: true });
    if (cached) return cached;
    throw error;
  }
}

async function cacheFirst(request) {
  const cache = await caches.open(cacheName);
  const cached = await cache.match(request, { ignoreSearch: true });
  if (cached) return cached;
  const response = await fetch(request);
  if (response.ok) await cache.put(request, response.clone());
  return response;
}

self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin || url.pathname.includes('/api/')) {
    return;
  }

  // Die Navigation prueft weiterhin zuerst den Server. Nur so wird ein neuer
  // Build (neue Service-Worker-Version in flutter_bootstrap.js) erkannt.
  if (request.mode === 'navigate') {
    event.respondWith(
      networkFirst(request).catch(() => caches.match('./index.html')),
    );
    return;
  }

  const fileName = url.pathname.split('/').pop();
  if (fileName === 'flutter_bootstrap.js' || alwaysNetwork.has(fileName)) {
    event.respondWith(networkFirst(request));
    return;
  }

  // Der Cache ist an die Build-Version dieses Service Workers gebunden. Ein
  // neuer Build installiert einen neuen Worker mit eigenem Cache und laedt die
  // Seite neu (siehe index.html). Innerhalb einer Version sind main.dart.js,
  // CanvasKit, Schriften und Assets daher unveraenderlich und werden ohne
  // Netzanfrage ausgeliefert. Das ist der entscheidende Schritt fuer einen
  // Start der Loginseite unter einer Sekunde.
  event.respondWith(cacheFirst(request));
});
