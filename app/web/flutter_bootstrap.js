{{flutter_js}}
{{flutter_build_config}}

// Den's own service worker and browser glue (den_web.js), with this build's version so a new
// one installs in the background. Flutter's own service worker isn't registered.
if (window.denWeb) window.denWeb.start({{flutter_service_worker_version}});

_flutter.loader.load({
  config: {
    // Everything comes from the hub with the app, never from a CDN (the hub's
    // Content-Security-Policy allows nothing else): CanvasKit, and the fonts Flutter falls back
    // to for emoji and scripts the app's own font lacks, which the hub image ships in
    // fonts/fallback/ (deploy/hub/fallback_fonts.sh). Where they're missing, those characters
    // show as boxes instead of the page reaching out to fonts.gstatic.com.
    canvasKitBaseUrl: 'canvaskit/',
    fontFallbackBaseUrl: 'fonts/fallback/',
  },
});
