// Den in the browser: what the app needs from the page that Flutter doesn't do itself. Loaded by
// index.html before flutter_bootstrap.js; the app reaches it as window.denWeb
// (app/lib/platform/web/web_app_web.dart).
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
// - The page stays put around the keyboard, a keyboard closed with its own button ends the
//   editing, and the app learns how much of the screen the keyboard really covers.
// - The keyboard at once: a tap that opens a field a frame later (Add) raises the keyboard in
//   the tap itself, which is the only time iOS allows it.
// - What Settings, Advanced, Show screen info shows: the page's sizes, the keyboard, the focus
//   and the last few viewport events.
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
      mobile: isIos() || /Android/.test(ua()),
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
      current = null;
      if (!s) return null;
      if (key && !sameKey(s, key)) return s.unsubscribe().then(function () { return null; });
      current = s;
      return JSON.stringify(s.toJSON());
    }).catch(function () { return null; });
  }

  // The subscription last looked at, so subscribing for another key can replace it.
  var current = null;

  /**
   * This browser's push subscription as JSON, and whether it was made for [key]:
   * {"subscription": {...} | null, "same": bool}. Unlike pushSubscription, one made for another
   * key is kept (a family's own, while Den holds several families that share the host's key)
   * until subscribe replaces it.
   */
  function pushState(key) {
    function answer(o) { return JSON.stringify(o); }
    if (!pushCapable()) return Promise.resolve(answer({ subscription: null, same: false }));
    return nav.serviceWorker.ready.then(function (r) {
      registration = r;
      return r.pushManager.getSubscription();
    }).then(function (s) {
      current = s || null;
      return answer({ subscription: s ? s.toJSON() : null, same: !!s && sameKey(s, key) });
    }).catch(function () { return answer({ subscription: null, same: false }); });
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
    // A browser holds one subscription: one made for another key goes first.
    var old = current && !sameKey(current, key) ? current : null;
    current = null;
    var made = old
      ? old.unsubscribe().catch(function () {}).then(function () { return registration.pushManager.subscribe(options); })
      : registration.pushManager.subscribe(options);
    return made.then(
      function (s) { current = s; return answer({ subscription: s.toJSON() }); },
      function (e) { return answer({ error: (e && e.name) || 'failed' }); }
    );
  }

  function unsubscribe() {
    if (!pushCapable()) return Promise.resolve(false);
    return nav.serviceWorker.ready
      .then(function (r) { return r.pushManager.getSubscription(); })
      .then(function (s) { current = null; return s ? s.unsubscribe() : false; })
      .catch(function () { return false; });
  }

  // ------------------------------------------------------------------ families

  /**
   * Tells the service worker which families this Den holds, as JSON {"<family id>": "<name>"}:
   * a push names its family by id, and the worker titles it with the name kept here, and shows
   * nothing of a push from a family not in it.
   */
  function setFamilies(json) {
    if (!('serviceWorker' in nav) || typeof caches === 'undefined') return Promise.resolve(false);
    return nav.serviceWorker.ready.then(function (r) {
      return caches.open('den-families').then(function (cache) {
        var body = new Response(json, { headers: { 'content-type': 'application/json' } });
        return cache.put(new URL('families.json', r.scope).href, body);
      });
    }).then(function () { return true; }, function () { return false; });
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

  /**
   * What's on the clipboard, for Add's Paste: an image (a screenshot of a flyer) or text, as
   * JSON: {"kind":"image","type":"image/png","data":"<base64>"}, {"kind":"text","text":"..."},
   * or {"kind":"none"} when there's nothing Den can read or the browser said no. Call it
   * straight from a tap: browsers allow reading the clipboard only then.
   */
  function paste() {
    var none = JSON.stringify({ kind: 'none' });
    var clip = nav.clipboard;
    if (!clip) return Promise.resolve(none);
    function text() {
      if (!clip.readText) return none;
      return clip.readText().then(
        function (t) { return t && t.trim() ? JSON.stringify({ kind: 'text', text: t }) : none; },
        function () { return none; }
      );
    }
    if (!clip.read) return Promise.resolve(text());
    return clip.read().then(function (items) {
      for (var i = 0; i < items.length; i++) {
        var types = items[i].types || [];
        for (var j = 0; j < types.length; j++) {
          if (types[j].indexOf('image/') === 0) {
            var type = types[j];
            return items[i].getType(type).then(function (blob) {
              return blob.arrayBuffer().then(function (buffer) {
                var bytes = new Uint8Array(buffer);
                var binary = '';
                for (var k = 0; k < bytes.length; k += 0x8000) {
                  binary += String.fromCharCode.apply(null, bytes.subarray(k, k + 0x8000));
                }
                return JSON.stringify({ kind: 'image', type: type, data: btoa(binary) });
              });
            });
          }
        }
      }
      return text();
    }, function () { return text(); });
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
  // edges under it; the app pads its content by the safe areas instead
  // (lib/platform/web/web_insets.dart).
  new MutationObserver(function (records) {
    records.forEach(function (record) {
      record.addedNodes.forEach(function (node) {
        if (node.nodeName !== 'META' || node.getAttribute('name') !== 'viewport') return;
        var content = node.getAttribute('content') || '';
        if (content.indexOf('viewport-fit') < 0) node.setAttribute('content', content + ', viewport-fit=cover');
      });
    });
  }).observe(document.head, { childList: true });

  // ------------------------------------------------------------------ the keyboard
  //
  // Flutter paints the whole app into one canvas pinned to the top of the page and hears about
  // the keyboard only through the visual viewport's resize event (FullPageDimensionsProvider and
  // EngineFlutterView in its web engine). While a field is being edited on a phone or tablet it
  // keeps its size and takes what the visual viewport lost as the keyboard; otherwise it takes
  // the visual viewport (Android) or the page (iOS) as its size. A keyboard closed with its own
  // button (the down arrow on Android's keyboard and navigation bar, the close key on an iPad's)
  // goes away without taking the focus from the field, and three things go wrong:
  //
  // - Android, Flutter 3.38.5: each frame drawn while the keyboard is up resets the size Flutter
  //   keeps to the visual viewport's, the part above the keyboard (fixed in 3.38.6, flutter/
  //   flutter#175074). The keyboard then closes with the field still being edited, so the app
  //   stays that small with a negative keyboard inset: an empty, keyboard-shaped band under it
  //   that nothing can be done with until a field is edited and let go of again.
  // - Flutter ignores "show the keyboard" for a field it is still editing, so a tap on the
  //   field doesn't bring the keyboard back.
  // - iOS: Safari scrolls the page and pans the visual viewport to show the field, and after the
  //   close button it can leave the page scrolled, or (iOS 26) the visual viewport panned with
  //   nothing scrolled and its height a little short. The canvas stays at the top, so the screen
  //   shows the empty page below it, black at night, and since Flutter takes every touch
  //   (touch-action: none) no swipe can scroll the page back.
  //
  // So a keyboard that closes while a field still has the focus ends the editing, as Return or a
  // tap elsewhere would: the field lets go, what was typed stays, and a tap on it brings the
  // keyboard back. This page's visual viewport listener runs before Flutter's, so Flutter hears
  // the keyboard close with nothing being edited and takes the whole screen. An app drawn
  // shorter than the screen with no keyboard to account for it, however it got there, is
  // measured again (and a field still holding the focus lets go). The page can't scroll
  // (index.html pins html and body); whatever scrolls it anyway is put back at the top as soon as
  // the viewport moves and again once the keyboard has finished moving; Flutter is asked to
  // measure again afterwards; and on iOS the app takes the keyboard's height from here
  // (lib/platform/web/web_insets.dart) instead of trusting a stale one.

  var vv = window.visualViewport || null;

  /** Below this, what the visual viewport lost isn't a keyboard (iOS 26 leaves 24 px, a
   * browser's own toolbar coming back about 56). */
  var MIN_KEYBOARD = 60;

  /** A keyboard counts as having come up for a field once it covered this much. */
  var SEEN_KEYBOARD = 120;

  /** A keyboard that seems to close this soon after its field got the focus is a field change. */
  var SETTLING_MS = 300;

  /** Corrections allowed per burst of viewport events, so a page that won't settle can't loop. */
  var BUDGET = 8;
  var budget = BUDGET;
  var queued = false;
  var poking = false;
  var watching = false;
  var lastReport = '';
  var viewportListener = null;

  // The field with the focus, when it got it, the page's width then, and whether a keyboard came
  // up for it.
  var field = { el: null, since: 0, width: 0, seen: false };
  // The visual viewport's height the last time no field had the focus, at that width: the whole
  // screen, also where a browser makes the page itself smaller around the keyboard.
  var baseline = { width: 0, height: 0 };
  // Since when the app has been drawn shorter than the screen, or 0.
  var shortSince = 0;

  function frame(callback) {
    if (typeof window.requestAnimationFrame === 'function') window.requestAnimationFrame(callback);
    else setTimeout(callback, 16);
  }

  function now() {
    return Date.now();
  }

  /** Where Flutter keeps its size around the keyboard (its isMobile): iOS and Android. */
  function mobile() {
    return isIos() || /Android/.test(ua());
  }

  function editable(el) {
    if (!el || el === document.body || el === document.documentElement) return false;
    var tag = (el.tagName || '').toUpperCase();
    return tag === 'INPUT' || tag === 'TEXTAREA' || el.isContentEditable === true;
  }

  /** A text field has the browser's focus, so a keyboard may be up. */
  function editing() {
    return editable(document.activeElement);
  }

  /** Someone zoomed in (Zoom in Accessibility, a pinch Flutter didn't take): leave it alone. */
  function zoomed() {
    return vv !== null && (vv.scale || 1) > 1.01;
  }

  /** The layout viewport, which is the screen Flutter lays out on iOS. */
  function layout() {
    var root = document.documentElement;
    return {
      width: (root && root.clientWidth) || window.innerWidth || 0,
      height: (root && root.clientHeight) || window.innerHeight || 0,
    };
  }

  /** What can be seen of the page, in its own pixels. */
  function visible() {
    return vv === null ? layout().height : vv.height * (vv.scale || 1);
  }

  /** The screen's height with no keyboard. */
  function fullHeight() {
    var size = layout();
    return baseline.width === size.width ? Math.max(size.height, baseline.height) : size.height;
  }

  /** How tall Flutter drew the app, from the size it gave its view; 0 before it has. */
  function drawn() {
    var view = typeof document.querySelector === 'function' ? document.querySelector('flutter-view') : null;
    if (!view || typeof view.getBoundingClientRect !== 'function') return 0;
    return view.getBoundingClientRect().height || 0;
  }

  function scrolledBy() {
    var se = document.scrollingElement || document.documentElement;
    var body = document.body;
    return {
      x: Math.max(Math.abs(window.scrollX || window.pageXOffset || 0), se ? Math.abs(se.scrollLeft || 0) : 0, body ? Math.abs(body.scrollLeft || 0) : 0),
      y: Math.max(Math.abs(window.scrollY || window.pageYOffset || 0), se ? Math.abs(se.scrollTop || 0) : 0, body ? Math.abs(body.scrollTop || 0) : 0),
    };
  }

  /** How much of the screen the keyboard covers, in CSS pixels; 0 when it's down. */
  function keyboard() {
    if (vv === null || !editing()) return 0;
    var covered = fullHeight() - visible();
    return covered >= MIN_KEYBOARD ? Math.round(covered) : 0;
  }

  /** What the app reads: the keyboard's height and the page's size and offsets. */
  function viewport() {
    var size = layout();
    var by = scrolledBy();
    return JSON.stringify({
      keyboard: keyboard(),
      width: size.width,
      height: size.height,
      top: vv === null ? 0 : Math.round((vv.offsetTop || 0) * 100) / 100,
      scrolled: by.y,
      editing: editing(),
    });
  }

  // What the screen did lately, for Settings → Advanced → Show screen info; null while that's off.
  var started = now();
  var events = null;

  function describe(el) {
    if (!el) return '';
    if (el === document.body) return 'body';
    var tag = (el.tagName || '?').toLowerCase();
    var cls = typeof el.className === 'string' && el.className ? '.' + el.className.split(/\s+/)[0] : '';
    return tag + cls;
  }

  function note(what) {
    if (events === null) return;
    events.push({
      t: now() - started,
      what: what,
      visual: vv === null ? null : Math.round(vv.height),
      top: vv === null ? null : Math.round(vv.offsetTop || 0),
      inner: window.innerHeight || 0,
      drawn: Math.round(drawn()),
      keyboard: keyboard(),
      focus: describe(document.activeElement),
    });
    if (events.length > 12) events.shift();
  }

  /** Keeps [field] and [baseline] up to date with the focus and the viewport. */
  function track() {
    var el = document.activeElement;
    var width = layout().width;
    if (!editable(el)) {
      field = { el: null, since: 0, width: 0, seen: false };
      if (vv !== null) baseline = { width: width, height: visible() };
      return;
    }
    if (el !== field.el) field = { el: el, since: now(), width: width, seen: false };
    if (width !== field.width) {
      // Turned or folded: what the viewport does now is the new screen, not the keyboard.
      field.width = width;
      field.seen = false;
    }
    if (fullHeight() - visible() >= SEEN_KEYBOARD) field.seen = true;
  }

  /** Ends the editing in [el]: Flutter hears a blur, as from a tap elsewhere, and lets go. */
  function letGo(el, why) {
    note('let go: ' + why);
    field.seen = false;
    try {
      el.blur();
    } catch (e) {
      // Nothing to let go of.
    }
  }

  /** The keyboard came up for the field with the focus and has gone while it still has it. */
  function closedUnderField() {
    var el = document.activeElement;
    if (!mobile() || vv === null || zoomed() || !editable(el)) return false;
    if (el !== field.el || !field.seen || layout().width !== field.width) return false;
    if (now() - field.since < SETTLING_MS) return false;
    return fullHeight() - visible() < MIN_KEYBOARD;
  }

  /** The app has been drawn shorter than the screen, by a keyboard's worth, for a while. */
  function drawnShort() {
    var h = drawn();
    if (!mobile() || vv === null || zoomed() || !h || h >= visible() - MIN_KEYBOARD) {
      shortSince = 0;
      return false;
    }
    if (!shortSince) {
      shortSince = now();
      note('drawn short');
      return false;
    }
    return now() - shortSince >= 100;
  }

  /** Puts the page back at the top if anything moved it; true when something had. */
  function pin() {
    if (zoomed() || budget <= 0) return false;
    var by = scrolledBy();
    var panned = vv !== null && (Math.abs(vv.offsetTop || 0) > 0.5 || Math.abs(vv.offsetLeft || 0) > 0.5);
    if (by.x < 0.5 && by.y < 0.5 && !panned) return false;
    budget--;
    note('back to the top');
    var se = document.scrollingElement;
    if (se) {
      se.scrollTop = 0;
      se.scrollLeft = 0;
    }
    if (document.body) {
      document.body.scrollTop = 0;
      document.body.scrollLeft = 0;
    }
    // With nothing scrolled but the visual viewport still panned (iOS 26 after the keyboard),
    // a scroll down and back makes Safari settle it.
    if (panned && by.y < 0.5) window.scrollTo(0, 1);
    window.scrollTo(0, 0);
    return true;
  }

  /** Has Flutter measure the page again, as it does on a real resize. */
  function poke() {
    if (vv === null || typeof vv.dispatchEvent !== 'function') return;
    poking = true;
    try {
      vv.dispatchEvent(new Event('resize'));
    } catch (e) {
      // An old browser without Event(): Flutter measures on the next real resize.
    }
    poking = false;
  }

  function settle() {
    track();
    var moved = pin();
    if (closedUnderField()) {
      letGo(document.activeElement, 'keyboard gone');
      moved = true;
    }
    if (budget > 0 && drawnShort()) {
      budget--;
      shortSince = 0;
      if (editing()) letGo(document.activeElement, 'drawn short');
      else note('measure again: drawn short');
      moved = true;
    }
    track();
    var report = viewport();
    var changed = report !== lastReport;
    lastReport = report;
    if (moved || changed) poke();
    if (changed && viewportListener) viewportListener(report);
    watch();
  }

  function schedule() {
    if (queued) return;
    queued = true;
    frame(function () {
      queued = false;
      settle();
    });
  }

  /** After a focus change or a resize: now, and again once the keyboard has finished moving. */
  function scheduleBurst() {
    budget = BUDGET;
    schedule();
    [120, 360, 720].forEach(function (ms) { setTimeout(schedule, ms); });
  }

  /** While a field has the focus on a phone or tablet, looks again now and then: a keyboard can
   * go without a word to the page. */
  function watch() {
    if (watching || !mobile() || !editing()) return;
    watching = true;
    setTimeout(function () {
      watching = false;
      if (editing()) schedule();
    }, 600);
  }

  function onViewportResize() {
    if (poking) return;
    track();
    // Before Flutter hears this resize, so it measures with nothing being edited.
    if (closedUnderField()) letGo(document.activeElement, 'keyboard closed');
    note('viewport resize');
    scheduleBurst();
  }

  function onEvent(what, burst) {
    return function () {
      note(what);
      if (burst) scheduleBurst();
      else schedule();
    };
  }

  if (vv !== null && typeof vv.addEventListener === 'function') {
    vv.addEventListener('resize', onViewportResize);
    vv.addEventListener('scroll', onEvent('viewport scroll', false));
  }
  window.addEventListener('scroll', onEvent('page scroll', false), { passive: true });
  window.addEventListener('resize', onEvent('window resize', true));
  window.addEventListener('orientationchange', onEvent('turned', true));
  window.addEventListener('pageshow', scheduleBurst);
  document.addEventListener('focusin', onEvent('focus in', true), true);
  document.addEventListener('focusout', onEvent('focus out', true), true);
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'visible') onEvent('shown', true)();
  });
  // The next touch on an app left drawn short puts it right.
  document.addEventListener('pointerdown', function () {
    if (!mobile()) return;
    var h = drawn();
    if (shortSince || (h && h < visible() - MIN_KEYBOARD)) scheduleBurst();
  }, true);
  // Chromium's VirtualKeyboard API, where there is one, says when the keyboard moves.
  if (nav.virtualKeyboard && typeof nav.virtualKeyboard.addEventListener === 'function') {
    nav.virtualKeyboard.addEventListener('geometrychange', onEvent('keyboard moved', true));
  }

  // ------------------------------------------------------------------ the keyboard, at once
  //
  // Safari on an iPhone or iPad raises the keyboard only for a field focused inside the tap that
  // asked for it (Chrome on Android, much the same), and Add builds its field a frame after the
  // tap, in a sheet that is still rising. So the tap focuses a stand-in field here, at once, and
  // the keyboard comes up with the sheet; Flutter's own field then takes the focus from it, which
  // keeps the keyboard up. If nothing has taken the focus by then, the stand-in lets go and the
  // keyboard goes back down. Only on a phone or tablet: elsewhere there's no keyboard to raise.

  /** How long the stand-in waits for the app's own field. */
  var STAND_IN_MS = 1500;
  var standIn = null;

  function keyboardNow() {
    if (!mobile() || !document.body || typeof document.createElement !== 'function') return false;
    try {
      if (!standIn) {
        standIn = document.createElement('input');
        standIn.type = 'text';
        standIn.setAttribute('aria-label', 'Add');
        standIn.setAttribute('tabindex', '-1');
        standIn.setAttribute('autocomplete', 'off');
        standIn.setAttribute('autocapitalize', 'sentences');
        // Off to the side of nothing: no size, no color, nothing to tap, and 17 px so iOS
        // doesn't zoom in on it.
        standIn.style.cssText = 'position:fixed;top:0;left:0;width:1px;height:1px;margin:0;padding:0;border:0;' +
          'opacity:0;background:transparent;color:transparent;caret-color:transparent;font-size:17px;pointer-events:none';
        document.body.appendChild(standIn);
      }
      standIn.value = '';
      standIn.focus({ preventScroll: true });
      note('keyboard at once');
      var mine = standIn;
      setTimeout(function () {
        if (document.activeElement === mine) {
          note('stand-in let go');
          mine.blur();
        }
      }, STAND_IN_MS);
      return document.activeElement === standIn;
    } catch (e) {
      return false;
    }
  }

  /** Calls [callback] with [viewport]'s answer now and whenever it changes. */
  function onViewport(callback) {
    viewportListener = callback;
    lastReport = viewport();
    callback(lastReport);
  }

  /** Starts (or stops) keeping the last few viewport events for [screenInfo]. */
  function diagnose(on) {
    events = on ? events || [] : null;
    if (on) note('screen info on');
  }

  /** Everything about the screen, the keyboard and the focus, for Show screen info, as JSON. */
  function screenInfo() {
    var size = layout();
    var by = scrolledBy();
    var view = typeof document.querySelector === 'function' ? document.querySelector('flutter-view') : null;
    var rect = view && typeof view.getBoundingClientRect === 'function' ? view.getBoundingClientRect() : null;
    var vk = nav.virtualKeyboard && nav.virtualKeyboard.boundingRect;
    var scr = window.screen || null;
    var display = nav.standalone === true ? 'standalone' : 'browser';
    try {
      ['fullscreen', 'standalone', 'minimal-ui'].some(function (mode) {
        if (!window.matchMedia('(display-mode: ' + mode + ')').matches) return false;
        display = mode;
        return true;
      });
    } catch (e) {
      // No display modes to ask about.
    }
    function round(n) {
      return Math.round((n || 0) * 10) / 10;
    }
    var safe = null;
    try {
      safe = JSON.parse(insets());
    } catch (e) {
      // A page that can't be measured that way.
    }
    return JSON.stringify({
      ua: ua(),
      display: display,
      dpr: window.devicePixelRatio || 1,
      screen: scr ? [scr.width, scr.height] : null,
      orientation: scr && scr.orientation ? scr.orientation.type : '',
      inner: [window.innerWidth || 0, window.innerHeight || 0],
      client: [size.width, size.height],
      visual: vv === null ? null : {
        width: round(vv.width),
        height: round(vv.height),
        offsetTop: round(vv.offsetTop),
        pageTop: round(vv.pageTop),
        scale: round(vv.scale),
      },
      scroll: {
        window: round(window.scrollY || window.pageYOffset),
        root: round(by.y),
        body: document.body ? round(document.body.scrollTop) : 0,
      },
      view: rect ? [round(rect.left), round(rect.top), round(rect.width), round(rect.height)] : null,
      keyboard: keyboard(),
      full: fullHeight(),
      virtualKeyboard: vk ? [round(vk.x), round(vk.y), round(vk.width), round(vk.height)] : null,
      focus: describe(document.activeElement),
      safe: safe,
      events: events === null ? [] : events.slice(),
    });
  }

  // ------------------------------------------------------------------ photos

  var PHOTO_SIDE = 256;
  var PHOTO_MAX = 40 * 1024;

  /** The picked file as something a canvas can draw, turned the way the photo was taken. */
  function photoSource(file) {
    function viaImage() {
      return new Promise(function (resolve, reject) {
        var url = URL.createObjectURL(file);
        var img = new Image();
        img.onload = function () { resolve(img); };
        img.onerror = function () { URL.revokeObjectURL(url); reject(new Error('unreadable')); };
        img.src = url;
      });
    }
    if (typeof window.createImageBitmap !== 'function') return viaImage();
    return window.createImageBitmap(file, { imageOrientation: 'from-image' }).catch(viaImage);
  }

  /** A canvas of [side] pixels with [source]'s center square drawn into it. */
  function square(source, sx, sy, size, side) {
    var canvas = document.createElement('canvas');
    canvas.width = side;
    canvas.height = side;
    var ctx = canvas.getContext('2d');
    ctx.imageSmoothingEnabled = true;
    ctx.imageSmoothingQuality = 'high';
    ctx.drawImage(source, sx, sy, size, size, 0, 0, side, side);
    return canvas;
  }

  /** The center square of the photo at 256 pixels, as JPEG under 40 KB, in base64. */
  function smallPhoto(file) {
    return photoSource(file).then(function (source) {
      var w = source.width || source.naturalWidth;
      var h = source.height || source.naturalHeight;
      if (!w || !h) throw new Error('empty');
      var size = Math.min(w, h);
      // Halve in steps first, so a large photo doesn't shimmer when it's made small.
      var canvas = square(source, (w - size) / 2, (h - size) / 2, size, Math.max(PHOTO_SIDE, Math.min(size, 2048)));
      while (canvas.width / 2 >= PHOTO_SIDE) canvas = square(canvas, 0, 0, canvas.width, Math.floor(canvas.width / 2));
      if (canvas.width !== PHOTO_SIDE) canvas = square(canvas, 0, 0, canvas.width, PHOTO_SIDE);
      if (source.close) source.close();
      function encode(quality) {
        return new Promise(function (resolve, reject) {
          canvas.toBlob(function (blob) {
            if (!blob) { reject(new Error('encode')); return; }
            if (blob.size > PHOTO_MAX && quality > 0.35) { resolve(encode(quality - 0.1)); return; }
            if (blob.size > PHOTO_MAX) { reject(new Error('too big')); return; }
            blob.arrayBuffer().then(function (buffer) {
              var bytes = new Uint8Array(buffer);
              var binary = '';
              for (var k = 0; k < bytes.length; k += 0x8000) {
                binary += String.fromCharCode.apply(null, bytes.subarray(k, k + 0x8000));
              }
              resolve(btoa(binary));
            }, reject);
          }, 'image/jpeg', quality);
        });
      }
      return encode(0.85);
    });
  }

  /**
   * Opens the browser's picker for one image (accept="image/*": on an iPhone or iPad that offers
   * Take Photo and Photo Library) and answers with the photo made small: its center square at
   * 256 pixels as a JPEG under 40 KB, in base64. With [camera], the camera opens straight away
   * where the browser can. '' when nothing was picked, 'error' when the image couldn't be read.
   * Must be the first thing a tap does.
   */
  function pickPhoto(camera) {
    return new Promise(function (resolve) {
      var input = document.createElement('input');
      input.type = 'file';
      input.accept = 'image/*';
      if (camera) input.setAttribute('capture', 'user');
      input.style.position = 'fixed';
      input.style.left = '-1000px';
      var settled = false;
      function finish(value) {
        if (settled) return;
        settled = true;
        input.remove();
        resolve(value);
      }
      input.addEventListener('change', function () {
        var file = input.files && input.files[0];
        if (!file) { finish(''); return; }
        smallPhoto(file).then(finish, function () { finish('error'); });
      });
      input.addEventListener('cancel', function () { finish(''); });
      document.body.appendChild(input);
      input.click();
    });
  }

  window.denWeb = {
    start: start,
    info: info,
    listen: listen,
    persist: persist,
    holdEngine: holdEngine,
    waitForEngine: waitForEngine,
    pushSubscription: pushSubscription,
    pushState: pushState,
    subscribe: subscribe,
    unsubscribe: unsubscribe,
    setFamilies: setFamilies,
    share: share,
    copy: copy,
    paste: paste,
    pickPhoto: pickPhoto,
    insets: insets,
    viewport: viewport,
    onViewport: onViewport,
    diagnose: diagnose,
    screenInfo: screenInfo,
    keyboardNow: keyboardNow,
    reload: function () { window.location.reload(); },
  };
})();
