{{flutter_js}}
{{flutter_build_config}}

// Der Service Worker wird bewusst NICHT ueber serviceWorkerSettings an den
// Loader uebergeben: Der Loader wuerde sonst vor dem Laden von CanvasKit und
// main.dart.js auf die Installation warten, die beim ersten Aufruf die
// komplette App-Shell herunterlaedt. Die Registrierung erfolgt stattdessen,
// sobald die Engine geladen ist.
const materialKompassServiceWorkerVersion = {{flutter_service_worker_version}};

// Dateien, die der Browser fuer den ersten Start bereits geladen hat
// (CanvasKit, Schriften, Manifeste). Der Service Worker uebernimmt sie in den
// versionsgebundenen Cache, damit der naechste Start ohne Netz auskommt.
function loadedSameOriginResources() {
  return performance
    .getEntriesByType('resource')
    .map((entry) => entry.name)
    .filter((name) => {
      const url = new URL(name);
      return url.origin === location.origin && !url.pathname.includes('/api/');
    });
}

function registerMaterialKompassServiceWorker() {
  if (!('serviceWorker' in navigator)) return;
  navigator.serviceWorker
    .register(
      'materialkompass_service_worker.js?v=' +
        materialKompassServiceWorkerVersion,
    )
    .then(() => navigator.serviceWorker.ready)
    .then((registration) => {
      registration.active?.postMessage({
        type: 'materialkompass-cache-loaded',
        urls: loadedSameOriginResources(),
      });
    })
    .catch((error) => {
      console.warn('Service Worker konnte nicht registriert werden.', error);
    });
}

// Die Engine wird sofort geladen und initialisiert, die App aber erst
// gestartet, wenn die HTML-Loginseite in index.html das anfordert (nach der
// Anmeldung, bei vorhandener Sitzung oder fuer Anmeldewege, die nur die App
// kennt).
_flutter.loader.load({
  onEntrypointLoaded: async (engineInitializer) => {
    const appRunner = await engineInitializer.initializeEngine();
    registerMaterialKompassServiceWorker();
    if (window.materialKompassStartup) {
      window.materialKompassStartup.engineReady(appRunner);
    } else {
      await appRunner.runApp();
    }
  },
});
