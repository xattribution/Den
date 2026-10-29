'use strict';
// Den's service worker, registered by den_web.js as sw.js?v=<build>&ck=<canvaskit variant>.
//
// - Den opens from the Home Screen at once, and with no connection: every file the app needs
//   to start is kept in a cache named for its build, and the app shell is answered from there.
// - A new version installs whole in the background: the build's files are fetched and checked
//   to belong to that build before the worker counts as installed. It takes over when Den next
//   opens (no window left on the old one), never in the middle of a page that runs the old one.
// - Reminders and nudges from the hub arrive as notifications; a tap opens the right screen.
//
// The hub's API, sync socket, MCP, OAuth and calendar feeds are never cached.

const params = new URL(self.location.href).searchParams;
const VERSION = params.get('v') || 'dev';
const CANVASKIT = params.get('ck') === 'chromium' ? 'canvaskit/chromium/' : 'canvaskit/';
const PREFIX = 'den-app-';
const CACHE = PREFIX + VERSION;
const ENGINE = 'den-engine-revision';

// What Den can't start without.
const SHELL = ['./', 'flutter_bootstrap.js', 'main.dart.js', 'den_web.js', 'manifest.json', 'assets/FontManifest.json'];

// What helps but may be missing from a build.
const EXTRA = [
  'flutter.js',
  'favicon.png',
  'icons/Icon-192.png',
  'icons/Icon-512.png',
  'icons/apple-touch-icon.png',
  'assets/AssetManifest.bin.json',
  'assets/AssetManifest.bin',
  'assets/AssetManifest.json',
  'assets/shaders/ink_sparkle.frag',
  'assets/shaders/stretch_effect.frag',
  'version.json',
];

const PASS_THROUGH = /^(api|ws|mcp|oauth|ics|health|\.well-known)(\/|$)/;

async function fresh(path) {
  const response = await fetch(new Request(path, { cache: 'no-cache' }));
  if (!response.ok) throw new Error(path + ' answered ' + response.status);
  return response;
}

async function fontFiles(cache) {
  const manifest = await cache.match('assets/FontManifest.json');
  if (!manifest) return [];
  try {
    const families = await manifest.json();
    const files = [];
    for (const family of families) {
      for (const font of family.fonts || []) {
        if (typeof font.asset === 'string') files.push('assets/' + encodeURI(font.asset));
      }
    }
    return files;
  } catch (e) {
    return [];
  }
}

/** An older version's cache holding CanvasKit for the same Flutter engine, if any. */
async function sameEngine(engine) {
  if (!engine) return null;
  for (const name of await caches.keys()) {
    if (!name.startsWith(PREFIX) || name === CACHE) continue;
    const cache = await caches.open(name);
    const kept = await cache.match(ENGINE);
    if (kept && (await kept.text()) === engine) return cache;
  }
  return null;
}

async function install() {
  const cache = await caches.open(CACHE);
  const bootstrap = await fresh('flutter_bootstrap.js');
  const text = await bootstrap.clone().text();
  // The hub may have moved on since this worker was registered; that version installs instead.
  if (VERSION !== 'dev' && text.indexOf('"' + VERSION + '"') < 0) throw new Error('not the version the hub serves');
  await cache.put('flutter_bootstrap.js', bootstrap);
  await Promise.all(SHELL.filter((p) => p !== 'flutter_bootstrap.js').map(async (p) => cache.put(p, await fresh(p))));
  await Promise.all(EXTRA.map((p) => fresh(p).then((r) => cache.put(p, r), () => {})));
  await Promise.all((await fontFiles(cache)).map((p) => fresh(p).then((r) => cache.put(p, r), () => {})));
  const engine = (/"engineRevision":"([^"]+)"/.exec(text) || [])[1] || '';
  const older = await sameEngine(engine);
  for (const file of [CANVASKIT + 'canvaskit.js', CANVASKIT + 'canvaskit.wasm']) {
    const kept = older ? await older.match(file) : undefined;
    await cache.put(file, kept || (await fresh(file)));
  }
  await cache.put(ENGINE, new Response(engine));
}

self.addEventListener('install', (event) => {
  event.waitUntil(install().catch(async (e) => {
    await caches.delete(CACHE);
    throw e;
  }));
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    for (const name of await caches.keys()) {
      // Older versions, and the caches of Flutter's own worker from before Den had this one.
      if (name !== CACHE && (name.startsWith(PREFIX) || name.startsWith('flutter-'))) await caches.delete(name);
    }
    await self.clients.claim();
  })());
});

self.addEventListener('message', (event) => {
  if (event.data && event.data.type === 'den-skip-waiting') self.skipWaiting();
});

async function page(request) {
  const cache = await caches.open(CACHE);
  return (await cache.match('./')) || fetch(request);
}

async function file(request, url) {
  const cache = await caches.open(CACHE);
  const kept = await cache.match(request, { ignoreSearch: true });
  if (kept) return kept;
  const response = await fetch(request);
  if (response.ok && response.type === 'basic' && !url.search) cache.put(request, response.clone()).catch(() => {});
  return response;
}

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;
  const scope = new URL(self.registration.scope).pathname;
  if (!url.pathname.startsWith(scope)) return;
  const path = url.pathname.slice(scope.length);
  if (PASS_THROUGH.test(path) || path === 'sw.js' || url.searchParams.has('den-check')) return;
  event.respondWith(request.mode === 'navigate' ? page(request) : file(request, url));
});

// ------------------------------------------------------------------ notifications

self.addEventListener('push', (event) => {
  let data = {};
  try {
    data = event.data ? event.data.json() : {};
  } catch (e) {
    data = { body: event.data ? event.data.text() : '' };
  }
  // Every push shows a notification: Safari stops delivering to pages whose pushes show nothing.
  // A push from one of several families this Den holds names the family: its title says whose
  // it is, and a tap opens it in that family (/l/<family>/...).
  const route = typeof data.route === 'string' && data.route.startsWith('/') ? data.route : '/today';
  const family = typeof data.family === 'string' && data.family ? data.family : null;
  const label = typeof data.label === 'string' && data.label ? data.label : null;
  const title = data.title || 'Den';
  const options = {
    body: data.body || '',
    icon: 'icons/Icon-192.png',
    data: { route: family ? '/l/' + encodeURIComponent(family) + route : route },
  };
  if (data.tag) options.tag = family ? family + '|' + data.tag : data.tag;
  event.waitUntil(self.registration.showNotification(label ? label + ': ' + title : title, options));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const route = (event.notification.data && event.notification.data.route) || '/today';
  const target = new URL('./', self.registration.scope);
  target.hash = route;
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const client of windows) {
      if (new URL(client.url).origin !== target.origin) continue;
      await client.focus();
      client.postMessage({ type: 'den-open', route: route });
      return;
    }
    await self.clients.openWindow(target.href);
  })());
});
