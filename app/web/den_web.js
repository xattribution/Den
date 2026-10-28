// Den in the browser: what the app needs from the page that Flutter doesn't do itself. Loaded by
// index.html before flutter_bootstrap.js; the app reaches it as window.denWeb
// (app/lib/web/web_app_web.dart).
//
// - The service worker (sw.js): registered with this build's version, so a new version installs
//   whole in the background and takes over the next time Den opens. See sw.js.
// - Whether Den runs from the Home Screen, on an iPhone or iPad, in a secure context, and what
//   it can do there (Web Push, the share sheet).
// - Web Push: subscribing has to start straight from a tap, so the worker's registration is
//   looked up ahead of time.
// - Sharing text with the share sheet, or copying it where there is none.
// - One engine per browser: tabs share the family's IndexedDB, so only one may write it.
// - The screen's safe areas (the home indicator, the notch), which Flutter doesn't report.
(function () {
  'use strict';

  var nav = window.navigator;
  var version = null;
  var registration = null;
  var opened = [];
  var onOpen = null;
  var hiddenAt = 0;
  var reloadOnChange = false;

  function ua() {
    return nav.userAgent || '';
  }

  /** An iPhone, iPad or iPod; iPadOS asks for desktop pages and calls itself a Mac. */
  function isIos() {
    return /iPhone|iPad|iPod/.test(ua()) || (/Macintosh/.test(ua()) && (nav.maxTouchPoints || 0) > 1);
  }

  /** [major, minor] of iOS, from Safari's version or the OS version, whichever is newer. */
  function iosVersion() {
    if (!isIos()) return null;
    var best = null;
    var patterns = [/Version\/(\d+)(?:\.(\d+))?/, /OS (\d+)(?:_(\d+))?/];
    for (var i = 0; i < patterns.length; i++) {
      var m = patterns[i].exec(ua());
      if (!m) continue;
      var v = [parseInt(m[1], 10), parseInt(m[2] || '0', 10)];
      if (!best || v[0] > best[0] || (v[0] === best[0] && v[1] > best[1])) best = v;
    }
    return best;
  }

  function standalone() {
    if (nav.standalone === true) return true;
    try {
      return window.matchMedia('(display-mode: standalone)').matches ||
        window.matchMedia('(display-mode: fullscreen)').matches;
    } catch (e) {
      return false;
    }
  }

  function pushCapable() {
    return 'serviceWorker' in nav && 'PushManager' in window && 'Notification' in window;
  }

  function info() {
    return JSON.stringify({
      ios: isIos(),
      ios_version: iosVersion(),
      ipad: isIos() && !/iPhone|iPod/.test(ua()),
      standalone: standalone(),
      secure: window.isSecureContext === true,
      worker: 'serviceWorker' in nav,
      push: pushCapable(),
      permission: 'Notification' in window ? Notification.permission : 'unsupported',
      share: typeof nav.share === 'function',
      ready: registration !== null,
    });
  }

  // ------------------------------------------------------------------ service worker

  /** The CanvasKit build Flutter will load in this browser (flutter.js decides the same way). */
  function canvasKitVariant() {
    var blink = nav.vendor === 'Google Inc.' || ua().indexOf('Edg/') >= 0;
    var codecs = typeof window.ImageDecoder !== 'undefined' && blink;
    var breaks = typeof Intl.v8BreakIterator !== 'undefined' && typeof Intl.Segmenter !== 'undefined';
    return codecs && breaks ? 'chromium' : 'full';
  }

  function register(v) {
    return nav.serviceWorker.register(
      'sw.js?v=' + encodeURIComponent(v) + '&ck=' + canvasKitVariant(),
      { scope: './', updateViaCache: 'none' }
    );
  }

  /** Asks the hub which version it serves now; a different one starts installing. */
  function checkForUpdate() {
    if (!version || version === 'null' || !('serviceWorker' in nav)) return;
    fetch('flutter_bootstrap.js?den-check=' + Date.now(), { cache: 'no-store' })
      .then(function (r) { return r.ok ? r.text() : ''; })
      .then(function (text) {
        var m = /denWeb\.start\(\s*"?([^")\s]+)"?\s*\)/.exec(text);
        if (m && m[1] !== 'null' && m[1] !== version) register(m[1]).catch(function () {});
      })
      .catch(function () {});
  }

  function start(buildVersion) {
    version = String(buildVersion);
    if (!('serviceWorker' in nav) || !window.isSecureContext) return;
    var sw = nav.serviceWorker;
    // Setting onmessage (rather than adding a listener) also starts the message queue.
    sw.onmessage = function (event) {
      var data = event.data || {};
      if (data.type === 'den-open' && typeof data.route === 'string') open(data.route);
    };
    sw.addEventListener('controllerchange', function () {
      if (reloadOnChange) window.location.reload();
    });
    sw.ready.then(function (r) { registration = r; });
    function registerNow() {
      register(version).then(checkForUpdate, function () {});
    }
    // After the page's own downloads, so the worker's copies don't compete with them.
    if (document.readyState === 'complete') registerNow();
    else window.addEventListener('load', registerNow);
    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'hidden') {
        hiddenAt = Date.now();
        return;
      }
      var away = hiddenAt ? Date.now() - hiddenAt : 0;
      hiddenAt = 0;
      if (away < 60 * 1000) return;
      checkForUpdate();
      // After ten minutes away, coming back is like opening Den again: a version that finished
      // installing takes over now, with a fresh page, instead of mixing with this one.
      if (away >= 10 * 60 * 1000 && registration && registration.waiting) {
        reloadOnChange = true;
        registration.waiting.postMessage({ type: 'den-skip-waiting' });
      }
    });
  }

  function open(route) {
    if (onOpen) onOpen(route);
    else opened.push(route);
  }

  /** Routes from tapped notifications, including ones tapped before the app was listening. */
  function listen(callback) {
    onOpen = callback;
    while (opened.length) callback(opened.shift());
  }

  // ------------------------------------------------------------------ storage and tabs

  /** Asks the browser not to evict Den's storage when space runs low. */
  function persist() {
    var storage = nav.storage;
    if (!storage || !storage.persist) return Promise.resolve(false);
    return storage.persisted()
      .then(function (already) { return already || storage.persist(); })
      .catch(function () { return false; });
  }

  /** Holds the engine lock for as long as this page lives; false when another tab has it. */
  function holdEngine() {
    if (!nav.locks || !nav.locks.request) return Promise.resolve(true);
    return new Promise(function (resolve) {
      nav.locks.request('den.engine', { ifAvailable: true }, function (lock) {
        if (!lock) {
          resolve(false);
          return null;
        }
        resolve(true);
        return new Promise(function () {});
      }).catch(function () { resolve(true); });
    });
  }

  /** Waits for the other tab to close, then holds the engine lock. */
  function waitForEngine() {
    if (!nav.locks || !nav.locks.request) return Promise.resolve(true);
    return new Promise(function (resolve) {
      nav.locks.request('den.engine', function () {
        resolve(true);
        return new Promise(function () {});
      }).catch(function () { resolve(true); });
    });
  }

  // ------------------------------------------------------------------ push

  function bytes(base64url) {
    var text = base64url.replace(/-/g, '+').replace(/_/g, '/');
    while (text.length % 4) text += '=';
    var raw = atob(text);
    var out = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
    return out;
  }

  function sameKey(subscription, key) {
    var have = subscription.options && subscription.options.applicationServerKey;
    if (!have) return true;
    var a = new Uint8Array(have);
    var b = bytes(key);
    if (a.length !== b.length) return false;
    for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    return true;
  }

  /**
   * This browser's push subscription for the hub's [key], as JSON, or null. A subscription
   * made for another key (the hub was replaced) is dropped, so the next tap subscribes afresh.
   */
  function pushSubscription(key) {
    if (!pushCapable()) return Promise.resolve(null);
    return nav.serviceWorker.ready.then(function (r) {
      registration = r;
      return r.pushManager.getSubscription();
    }).then(function (s) {
      if (!s) return null;
      if (key && !sameKey(s, key)) return s.unsubscribe().then(function () { return null; });
      return JSON.stringify(s.toJSON());
    }).catch(function () { return null; });
  }

  /**
   * Subscribes to the hub's pushes: {"subscription": {...}} or {"error": "<name>"}. Call it
   * straight from a tap: Safari shows its permission prompt only for a user gesture, so
   * nothing may be awaited before this.
   */
  function subscribe(key) {
    function answer(o) { return JSON.stringify(o); }
    if (!pushCapable()) return Promise.resolve(answer({ error: 'unsupported' }));
    if (!registration) return Promise.resolve(answer({ error: 'not-ready' }));
    var options = { userVisibleOnly: true, applicationServerKey: bytes(key) };
    return registration.pushManager.subscribe(options).then(
      function (s) { return answer({ subscription: s.toJSON() }); },
      function (e) { return answer({ error: (e && e.name) || 'failed' }); }
    );
  }

  function unsubscribe() {
    if (!pushCapable()) return Promise.resolve(false);
    return nav.serviceWorker.ready
      .then(function (r) { return r.pushManager.getSubscription(); })
      .then(function (s) { return s ? s.unsubscribe() : false; })
      .catch(function () { return false; });
  }

  // ------------------------------------------------------------------ sharing

  function copy(text) {
    if (!nav.clipboard || !nav.clipboard.writeText) return Promise.resolve('failed');
    return nav.clipboard.writeText(text).then(
      function () { return 'copied'; },
      function () { return 'failed'; }
    );
  }

  /** The share sheet with [text]; copies it where there's none. Call it straight from a tap. */
  function share(text) {
    if (typeof nav.share === 'function') {
      return nav.share({ text: text }).then(
        function () { return 'shared'; },
        function (e) { return e && e.name === 'AbortError' ? 'cancelled' : copy(text); }
      );
    }
    return copy(text);
  }

  // ------------------------------------------------------------------ safe areas

  /** [top, right, bottom, left] in CSS pixels. */
  function insets() {
    var probe = document.createElement('div');
    var s = probe.style;
    s.position = 'fixed';
    s.visibility = 'hidden';
    s.pointerEvents = 'none';
    s.paddingTop = 'env(safe-area-inset-top)';
    s.paddingRight = 'env(safe-area-inset-right)';
    s.paddingBottom = 'env(safe-area-inset-bottom)';
    s.paddingLeft = 'env(safe-area-inset-left)';
    document.documentElement.appendChild(probe);
    var cs = window.getComputedStyle(probe);
    var out = [cs.paddingTop, cs.paddingRight, cs.paddingBottom, cs.paddingLeft].map(function (v) {
      var n = parseFloat(v);
      return isNaN(n) ? 0 : n;
    });
    probe.remove();
    return JSON.stringify(out);
  }

  // Flutter replaces the page's viewport tag with its own. Den keeps drawing to the screen's
  // edges under it; the app pads its content by the safe areas instead (lib/web/web_insets.dart).
  new MutationObserver(function (records) {
    records.forEach(function (record) {
      record.addedNodes.forEach(function (node) {
        if (node.nodeName !== 'META' || node.getAttribute('name') !== 'viewport') return;
        var content = node.getAttribute('content') || '';
        if (content.indexOf('viewport-fit') < 0) node.setAttribute('content', content + ', viewport-fit=cover');
      });
    });
  }).observe(document.head, { childList: true });

  window.denWeb = {
    start: start,
    info: info,
    listen: listen,
    persist: persist,
    holdEngine: holdEngine,
    waitForEngine: waitForEngine,
    pushSubscription: pushSubscription,
    subscribe: subscribe,
    unsubscribe: unsubscribe,
    share: share,
    copy: copy,
    insets: insets,
    reload: function () { window.location.reload(); },
  };
})();
