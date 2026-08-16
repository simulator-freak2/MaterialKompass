{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  serviceWorkerSettings: {
    serviceWorkerVersion: "{{flutter_service_worker_version}}",
    serviceWorkerUrl:
        "materialkompass_service_worker.js?v={{flutter_service_worker_version}}",
  },
});
