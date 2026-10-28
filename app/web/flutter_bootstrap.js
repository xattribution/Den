{{flutter_js}}
{{flutter_build_config}}

// Den's own service worker and browser glue (den_web.js), with this build's version so a new
// one installs in the background. Flutter's own service worker isn't registered.
if (window.denWeb) window.denWeb.start({{flutter_service_worker_version}});

_flutter.loader.load({
  config: {
    // CanvasKit comes from the hub with the app, never from a CDN.
    canvasKitBaseUrl: 'canvaskit/',
  },
});
