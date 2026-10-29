// Exercises app/web/sw.js with a fake build, an in-memory Cache API and fake clients:
// offline start, a new version installing whole beside the old one, the hub's own paths left
// alone, notifications and taps.  Run from app/:  node test/web/sw_test.mjs web/sw.js
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const swSource = fs.readFileSync(process.argv[2], 'utf8');
const ORIGIN = 'https://den.example.com';

function build(version, mainText) {
  return {
    '/': `<html>index ${version}</html>`,
    '/flutter_bootstrap.js': `flutter.js...{"engineRevision":"abc123"}\nif (window.denWeb) window.denWeb.start("${version}");`,
    '/main.dart.js': mainText,
    '/den_web.js': 'den web',
    '/manifest.json': '{}',
    '/assets/FontManifest.json': JSON.stringify([{ family: 'Atkinson', fonts: [{ asset: 'assets/fonts/AtkinsonHyperlegibleNext.ttf' }] }, { family: 'MaterialIcons', fonts: [{ asset: 'fonts/MaterialIcons-Regular.otf' }] }]),
    '/assets/assets/fonts/AtkinsonHyperlegibleNext.ttf': 'font1',
    '/assets/fonts/MaterialIcons-Regular.otf': 'font2',
    '/canvaskit/canvaskit.js': 'ck js',
    '/canvaskit/canvaskit.wasm': 'ck wasm',
    '/icons/Icon-192.png': 'png',
    '/version.json': '{"version":"1.0.0"}',
  };
}

let server = build('111', 'main v1');
const fetched = [];

class FakeCache {
  constructor() { this.map = new Map(); }
  key(req) { const u = new URL(typeof req === 'string' ? req : req.url, ORIGIN + '/sw.js'); return u; }
  async put(req, res) { const u = this.key(req); this.map.set(u.origin + u.pathname + u.search, await res.clone().text()); }
  async match(req, opts = {}) {
    const u = this.key(req);
    const k = u.origin + u.pathname + (opts.ignoreSearch ? '' : u.search);
    for (const [key, body] of this.map) {
      const ku = new URL(key);
      const kk = ku.origin + ku.pathname + (opts.ignoreSearch ? '' : ku.search);
      if (kk === k) return new Response(body);
    }
    return undefined;
  }
}
const store = new Map();
const caches = {
  async open(name) { if (!store.has(name)) store.set(name, new FakeCache()); return store.get(name); },
  async keys() { return [...store.keys()]; },
  async delete(name) { return store.delete(name); },
};

async function fakeFetch(req) {
  const url = new URL(typeof req === 'string' ? req : req.url, ORIGIN + '/');
  fetched.push(url.pathname + url.search);
  const body = server[url.pathname];
  if (body === undefined) return new Response('nope', { status: 404 });
  const r = new Response(body, { status: 200 });
  Object.defineProperty(r, 'type', { value: 'basic' });
  return r;
}

function makeWorker(version, ck = 'full') {
  const listeners = {};
  const notifications = [];
  const posted = [];
  const windows = [];
  const self = {
    location: new URL(`${ORIGIN}/sw.js?v=${version}&ck=${ck}`),
    registration: { scope: ORIGIN + '/', showNotification: async (t, o) => notifications.push([t, o]) },
    addEventListener: (type, fn) => { listeners[type] = fn; },
    skipWaiting: () => { self.skipped = true; },
    clients: {
      claim: async () => {},
      matchAll: async () => windows,
      openWindow: async (u) => { self.opened = u; },
    },
  };
  const context = vm.createContext({ self, caches, fetch: fakeFetch, Request: class extends Request { constructor(i, o) { super(new URL(i, ORIGIN + '/sw.js'), o); } }, Response, URL, encodeURI, console, Promise });
  vm.runInContext(swSource, context);
  async function dispatch(type, event) {
    let waited;
    let responded;
    event.waitUntil = (p) => { waited = p; };
    event.respondWith = (p) => { responded = p; };
    listeners[type](event);
    if (waited) await waited;
    return responded;
  }
  return { self, dispatch, notifications, posted, windows };
}

function req(path, mode = 'cors') {
  const r = new Request(ORIGIN + path);
  Object.defineProperty(r, 'mode', { value: mode });
  return r;
}

// 1. Install v111 caches the whole app.
const v1 = makeWorker('111');
await v1.dispatch('install', {});
const c1 = store.get('den-app-111');
assert.ok(c1, 'cache for v111');
for (const p of ['/', '/flutter_bootstrap.js', '/main.dart.js', '/den_web.js', '/assets/FontManifest.json', '/assets/assets/fonts/AtkinsonHyperlegibleNext.ttf', '/assets/fonts/MaterialIcons-Regular.otf', '/canvaskit/canvaskit.wasm', '/canvaskit/canvaskit.js', '/version.json']) {
  assert.ok(await c1.match(p), 'cached ' + p);
}
await v1.dispatch('activate', {});

// 2. Navigation and files come from the cache, offline.
server = {};
fetched.length = 0;
let res = await v1.dispatch('fetch', { request: req('/', 'navigate') });
assert.equal(await (await res).text(), '<html>index 111</html>');
res = await v1.dispatch('fetch', { request: req('/main.dart.js') });
assert.equal(await (await res).text(), 'main v1');
res = await v1.dispatch('fetch', { request: req('/version.json?cachebuster=5') });
assert.equal(await (await res).text(), '{"version":"1.0.0"}');
assert.deepEqual(fetched, [], 'nothing went to the network');

// 3. The API, sync and update checks pass through.
for (const p of ['/api/v1/hub/status', '/ws', '/mcp', '/oauth/authorize', '/health', '/flutter_bootstrap.js?den-check=1', '/sw.js']) {
  assert.equal(await v1.dispatch('fetch', { request: req(p) }), undefined, p + ' passes through');
}

// 4. A worker for a version the hub no longer serves doesn't install.
server = build('222', 'main v2');
const stale = makeWorker('111b');
await assert.rejects(stale.dispatch('install', {}));
assert.equal(store.has('den-app-111b'), false, 'a failed install leaves no cache');

// 5. v222 installs alongside, reusing CanvasKit for the same engine, and takes over on activate.
fetched.length = 0;
const v2 = makeWorker('222');
await v2.dispatch('install', {});
assert.ok(!fetched.includes('/canvaskit/canvaskit.wasm'), 'CanvasKit for the same engine is copied, not downloaded');
assert.equal(await (await store.get('den-app-222').match('/main.dart.js')).text(), 'main v2');
assert.equal(await (await store.get('den-app-111').match('/main.dart.js')).text(), 'main v1', 'v1 keeps serving until v2 takes over');
store.set('flutter-app-cache', new FakeCache());
await v2.dispatch('activate', {});
assert.deepEqual([...store.keys()].sort(), ['den-app-222']);

// 6. Pushes show a notification; a tap focuses an open window and sends it the route.
await v2.dispatch('push', { data: { json: () => ({ title: 'Soccer at 5:30', body: 'Leo, Field 3', route: '/event/E1?at=5', tag: 'event:E1' }) } });
assert.deepEqual(v2.notifications[0][0], 'Soccer at 5:30');
assert.equal(v2.notifications[0][1].data.route, '/event/E1?at=5');
await v2.dispatch('push', { data: { json: () => { throw new Error('bad'); }, text: () => 'plain' } });
assert.equal(v2.notifications[1][0], 'Den');
const client = { url: ORIGIN + '/#/today', focus: async () => {}, postMessage: (m) => v2.posted.push(m) };
v2.windows.push(client);
await v2.dispatch('notificationclick', { notification: { close() {}, data: { route: '/chore/C1?date=2026-10-28' } } });
assert.equal(JSON.stringify(v2.posted), JSON.stringify([{ type: 'den-open', route: '/chore/C1?date=2026-10-28' }]));
v2.windows.length = 0;
await v2.dispatch('notificationclick', { notification: { close() {}, data: { route: '/today' } } });
assert.equal(v2.self.opened, ORIGIN + '/#/today');

// 6b. A push from one of several families this Den holds says whose it is and opens there; a
// tap sends that family's route.
await v2.dispatch('push', { data: { json: () => ({ title: 'Soccer at 5:30', body: 'Field 3', route: '/event/E2?at=9', tag: 'event:E2', family: 'smith2345', label: 'Smith family' }) } });
const smith = v2.notifications[v2.notifications.length - 1];
assert.equal(smith[0], 'Smith family: Soccer at 5:30');
assert.equal(smith[1].data.route, '/l/smith2345/event/E2?at=9');
assert.equal(smith[1].tag, 'smith2345|event:E2');
v2.windows.push(client);
v2.posted.length = 0;
await v2.dispatch('notificationclick', { notification: { close() {}, data: smith[1].data } });
assert.equal(JSON.stringify(v2.posted), JSON.stringify([{ type: 'den-open', route: '/l/smith2345/event/E2?at=9' }]));
// A route that isn't the app's own is never followed.
await v2.dispatch('push', { data: { json: () => ({ title: 'X', route: 'https://elsewhere.example/', family: 'f' }) } });
assert.equal(v2.notifications[v2.notifications.length - 1][1].data.route, '/l/f/today');
v2.windows.length = 0;

// 7. Skip waiting on request.
await v2.dispatch('message', { data: { type: 'den-skip-waiting' } });
assert.equal(v2.self.skipped, true);

console.log('sw.js: all checks passed');
