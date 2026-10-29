// The real web build in a browser made to look like a Home Screen iPhone (Flutter takes it for
// iOS), with the keyboard played by a stand-in visual viewport, since no desktop browser has an
// on-screen keyboard: a field gets the focus, the keyboard comes up, Safari pans the page, the
// keyboard closes with its own button (no Return, no blur) and Safari leaves the pan behind.
// Checks the page can't be scrolled, the app fills the screen again, Flutter and the app both
// know the keyboard is gone, the field keeps its focus until a tap elsewhere, and Paste still
// fills the field. Screenshots go to the output folder for a look.
//
// Given a second build (test/web/ask_e2e_app.dart: the demo family with the AI helper on), it
// does the same in Ask: opens it from Today's pill, types in its field, brings the keyboard up
// and closes it with the arrow, keeps typing, and asks. That build is served the way the hub
// serves the app, under its Content-Security-Policy, and this server plays the hub's helper
// endpoints at the same origin, so the helper's real calls are checked too.
//
// Not part of CI (it needs Playwright and release builds). From app/:
//   flutter build web --release --csp --dart-define=FLUTTER_WEB_CANVASKIT_URL=canvaskit/
//   flutter build web --release --csp --dart-define=FLUTTER_WEB_CANVASKIT_URL=canvaskit/ \
//     -t test/web/ask_e2e_app.dart -o "$PWD/build/web_ask"
//   NODE_PATH=<dir with playwright> node test/web/keyboard_e2e.mjs build/web webkit [out-dir] [build/web_ask]
//   (or chromium; CHROME_EXECUTABLE picks the Chromium binary)
import crypto from 'node:crypto';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import zlib from 'node:zlib';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
const { chromium, webkit } = require('playwright');

const root = path.resolve(process.argv[2] ?? 'build/web');
const engine = process.argv[3] ?? 'chromium';
const out = path.resolve(process.argv[4] ?? 'build/keyboard_e2e');
const askRoot = process.argv[5] ? path.resolve(process.argv[5]) : null;
fs.mkdirSync(out, { recursive: true });

const types = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json',
  '.wasm': 'application/wasm', '.png': 'image/png', '.ttf': 'font/ttf', '.otf': 'font/otf', '.svg': 'image/svg+xml',
};
/** The hub's Content-Security-Policy for the web app (den_hub's webAppPolicy), for [dir]'s index.html. */
function hubPolicy(dir, connect) {
  const html = fs.readFileSync(path.join(dir, 'index.html'), 'utf8');
  const hashes = [...html.matchAll(/<script\b(?![^>]*\bsrc\s*=)[^>]*>([\s\S]*?)<\/script\s*>/gi)]
    .filter((m) => m[1].trim())
    .map((m) => `'sha256-${crypto.createHash('sha256').update(m[1]).digest('base64')}'`);
  return [
    "default-src 'self'",
    ["script-src 'self' 'wasm-unsafe-eval'", ...hashes].join(' '),
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob:",
    "font-src 'self' data:",
    `connect-src 'self' ${connect}`,
    "media-src 'self' data: blob:",
    "worker-src 'self' blob:",
    "manifest-src 'self'",
    "object-src 'none'",
    "base-uri 'self'",
    "form-action 'self'",
    "frame-ancestors 'none'",
  ].join('; ');
}

/** The AI helper's two hub endpoints, as the hub answers them for a parent with Claude set up. */
const helper = {
  calls: [],
  status: {
    provider: 'anthropic',
    speaker: 'Claude',
    models: [{ model: 'claude-haiku-5-5', size: 'small' }],
    you: { allowed: true },
    this_month: { month: '2026-10', stopped: false },
  },
  answer: 'Zoe has her swim lesson at 4:30 PM. Nobody is driving her yet.',
  reply() {
    return {
      id: 'msg_e2e', type: 'message', role: 'assistant', model: 'claude-haiku-5-5',
      content: [{ type: 'text', text: this.answer }],
      stop_reason: 'end_turn', stop_sequence: null,
      usage: { input_tokens: 900, output_tokens: 20 },
    };
  },
};

/** Serves [dir] with single-page fallback; with [hub], under the hub's policy and with its helper endpoints. */
async function serve(dir, { hub = false } = {}) {
  let policy = null;
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x');
    if (hub && url.pathname.startsWith('/api/v1/assistant')) {
      const chunks = [];
      req.on('data', (c) => chunks.push(c));
      req.on('end', () => {
        const body = Buffer.concat(chunks).toString('utf8');
        helper.calls.push({ method: req.method, path: url.pathname, provider: req.headers['x-den-provider'], body });
        const json = url.pathname === '/api/v1/assistant' && req.method === 'GET' ? helper.status
          : url.pathname === '/api/v1/assistant/model' && req.method === 'POST' ? helper.reply() : null;
        res.writeHead(json ? 200 : 404, { 'content-type': 'application/json', 'cache-control': 'no-store' });
        res.end(JSON.stringify(json ?? { error: { code: 'not_found', message: 'Not found' } }));
      });
      return;
    }
    let file = path.join(dir, decodeURIComponent(url.pathname));
    if (!file.startsWith(dir) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) file = path.join(dir, 'index.html');
    const headers = { 'content-type': types[path.extname(file)] ?? 'application/octet-stream', 'cache-control': 'no-store' };
    if (policy) headers['content-security-policy'] = policy;
    res.writeHead(200, headers);
    fs.createReadStream(file).pipe(res);
  });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const at = `http://127.0.0.1:${server.address().port}`;
  if (hub) policy = hubPolicy(dir, at.replace('http:', 'ws:'));
  return { server, origin: at };
}

const main = await serve(root);
const origin = main.origin;

const W = 390, H = 844, KEYBOARD = 336;
const iphone = {
  viewport: { width: W, height: H },
  deviceScaleFactor: 3,
  hasTouch: true,
  userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1',
  permissions: engine === 'chromium' ? ['clipboard-read', 'clipboard-write'] : [],
};

// Runs before any of the page's scripts: an iPhone's navigator, and a visual viewport the test
// moves the way Safari moves it around the keyboard.
function stage(iPhone) {
  // Flutter's accessibility tree, which the test reads positions from, turns on differently on a
  // phone, so that one look is taken as a desktop browser of the same size.
  if (iPhone) Object.defineProperty(Navigator.prototype, 'platform', { get: () => 'iPhone' });
  Object.defineProperty(Navigator.prototype, 'maxTouchPoints', { get: () => 5 });
  Object.defineProperty(Navigator.prototype, 'standalone', { get: () => true });
  const vv = new EventTarget();
  const state = { height: window.innerHeight, top: 0 };
  Object.defineProperties(vv, {
    width: { get: () => window.innerWidth },
    height: { get: () => state.height },
    offsetTop: { get: () => state.top },
    offsetLeft: { get: () => 0 },
    pageTop: { get: () => state.top + window.scrollY },
    pageLeft: { get: () => 0 },
    scale: { get: () => 1 },
  });
  Object.defineProperty(window, 'visualViewport', { get: () => vv, configurable: true });
  // Safari: a scroll that moves the page also settles a pan it left behind; one that moves
  // nothing doesn't (iOS 26).
  const scrollTo = window.scrollTo.bind(window);
  window.scrollTo = (x, y) => {
    if (typeof x === 'object') ({ left: x, top: y } = x);
    if (y !== 0 || window.scrollY !== 0) state.top = 0;
    if (y === 1) state.top = 0;
    scrollTo(x, y);
  };
  window.__keyboard = {
    up(height) { state.height = window.innerHeight - height; vv.dispatchEvent(new Event('resize')); },
    // The close arrow: the keyboard goes, the page stays panned by [pan].
    closeWithArrow(pan) { state.height = window.innerHeight; state.top = pan; vv.dispatchEvent(new Event('resize')); },
    // iOS 26 at its worst: the keyboard goes with no resize at all, only a scroll, and leaves
    // the visual viewport [short] pixels short and panned by [pan].
    closeQuietly(pan, short) { state.height = window.innerHeight - short; state.top = pan; vv.dispatchEvent(new Event('scroll')); },
    pan(top) { state.top = top; vv.dispatchEvent(new Event('scroll')); },
    get top() { return state.top; },
  };
  window.__flutterResizes = 0;
  vv.addEventListener('resize', () => { window.__flutterResizes++; });
  window.__csp = [];
  document.addEventListener('securitypolicyviolation', (e) => window.__csp.push(`${e.violatedDirective} ${e.blockedURI}`));
}

const browserType = engine === 'webkit' ? webkit : chromium;
const browser = await browserType.launch(engine === 'chromium' && process.env.CHROME_EXECUTABLE ? { executablePath: process.env.CHROME_EXECUTABLE } : {});
const failures = [];

/** A page at [url]; with [semantics], the app's accessibility tree on and [ready] in it. */
async function open(semantics, url = `${origin}/#/welcome/join`, ready = 'flt-semantics-host input, flt-semantics-host textarea') {
  const context = await browser.newContext(iphone);
  await context.addInitScript(stage, !semantics);
  const page = await context.newPage();
  page.on('pageerror', (e) => failures.push(`page error: ${e.message}`));
  await page.goto(url);
  await page.waitForSelector('flutter-view', { timeout: 60000 });
  // The scene is drawn in the glass pane's shadow root.
  await page.waitForFunction(
    () => document.querySelector('flt-glass-pane')?.shadowRoot?.querySelector('canvas') ?? document.querySelector('flutter-view canvas'),
    null,
    { timeout: 60000 },
  );
  await page.waitForTimeout(2500);
  if (semantics) {
    await page.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
    await page.waitForSelector(ready, { state: 'attached', timeout: 20000 });
  }
  return { context, page };
}

/** Where the words field and the Paste button are, read once from the app's accessibility tree. */
async function layout() {
  const { context, page } = await open(true);
  const where = await page.evaluate(() => {
    const box = (el) => { const r = el.getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; };
    const field = document.querySelector('flt-semantics-host input, flt-semantics-host textarea');
    const paste = [...document.querySelectorAll('flt-semantics-host [role="button"]')]
      .find((e) => (e.textContent ?? '').trim() === 'Paste the invite' || e.getAttribute('aria-label') === 'Paste the invite');
    return { field: field ? box(field) : null, paste: paste ? box(paste) : null };
  });
  await context.close();
  return where;
}

/** A screenshot's pixels: 8-bit RGB or RGBA, not interlaced, as Playwright writes them. */
function pixels(png) {
  let at = 8;
  let width = 0, height = 0, channels = 0;
  const data = [];
  while (at < png.length) {
    const length = png.readUInt32BE(at);
    const type = png.toString('ascii', at + 4, at + 8);
    const body = png.subarray(at + 8, at + 8 + length);
    if (type === 'IHDR') {
      width = body.readUInt32BE(0);
      height = body.readUInt32BE(4);
      channels = { 2: 3, 6: 4 }[body[9]];
      assert.ok(body[8] === 8 && channels && body[12] === 0, 'an 8-bit RGB(A) screenshot');
    }
    if (type === 'IDAT') data.push(body);
    at += 12 + length;
  }
  const raw = zlib.inflateSync(Buffer.concat(data));
  const stride = width * channels;
  const out = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)];
    const line = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    for (let x = 0; x < stride; x++) {
      const left = x >= channels ? out[y * stride + x - channels] : 0;
      const up = y > 0 ? out[(y - 1) * stride + x] : 0;
      const upLeft = y > 0 && x >= channels ? out[(y - 1) * stride + x - channels] : 0;
      let v = line[x];
      if (filter === 1) v += left;
      else if (filter === 2) v += up;
      else if (filter === 3) v += (left + up) >> 1;
      else if (filter === 4) {
        const p = left + up - upLeft;
        const pa = Math.abs(p - left), pb = Math.abs(p - up), pc = Math.abs(p - upLeft);
        v += pa <= pb && pa <= pc ? left : pb <= pc ? up : upLeft;
      }
      out[y * stride + x] = v & 0xff;
    }
  }
  return { width, height, channels, out };
}

/** Share of pixels that differ between two screenshots. */
function difference(a, b) {
  const pa = pixels(a), pb = pixels(b);
  if (pa.width !== pb.width || pa.height !== pb.height) return 1;
  let diff = 0;
  for (let i = 0; i < pa.width * pa.height; i++) {
    for (let c = 0; c < 3; c++) {
      if (pa.out[i * pa.channels + c] !== pb.out[i * pb.channels + c]) {
        diff++;
        break;
      }
    }
  }
  return diff / (pa.width * pa.height);
}

try {
  const where = await layout();
  assert.ok(where.field, 'found the words field');
  const { page } = await open(false);
  const shot = async (name) => { const png = await page.screenshot({ path: path.join(out, `${engine}_${name}.png`) }); return png; };
  const pageState = () => page.evaluate(() => {
    const view = document.querySelector('flutter-view').getBoundingClientRect();
    const body = document.body.getBoundingClientRect();
    const cs = getComputedStyle(document.documentElement);
    return {
      scrollY: window.scrollY,
      rootScroll: document.scrollingElement.scrollTop,
      pan: window.__keyboard.top,
      view: [view.x, view.y, view.width, view.height],
      body: [body.x, body.y, body.width, body.height],
      htmlPosition: cs.position,
      htmlOverflow: cs.overflow,
      active: document.activeElement?.tagName,
      app: JSON.parse(window.denWeb.viewport()),
      resizes: window.__flutterResizes,
    };
  });

  // The page can't be scrolled, by script or by finger.
  await page.evaluate(() => { window.scrollTo(0, 400); document.documentElement.scrollTop = 400; document.body.scrollTop = 400; });
  await page.mouse.wheel(0, 600);
  await page.waitForTimeout(300);
  let s = await pageState();
  assert.equal(s.scrollY, 0, 'the page does not scroll');
  assert.equal(s.htmlPosition, 'fixed');
  assert.equal(s.htmlOverflow, 'hidden');
  assert.deepEqual(s.view, [0, 0, W, H], 'Flutter fills the screen');

  // The field gets the focus; the keyboard comes up and Safari pans the page to the field.
  await page.touchscreen.tap(where.field.x, where.field.y);
  await page.waitForTimeout(600);
  await page.keyboard.type('maple river');
  const before = await shot('1_focused');
  s = await pageState();
  assert.equal(s.active, 'INPUT', 'the field has the browser\'s focus');
  await page.evaluate((k) => window.__keyboard.up(k), KEYBOARD);
  await page.evaluate(() => window.__keyboard.pan(180));
  await page.waitForTimeout(1200);
  s = await pageState();
  await shot('2_keyboard_up');
  assert.equal(s.pan, 0, 'the page is put back at the top while the keyboard is up');
  assert.equal(s.app.keyboard, KEYBOARD, 'the app hears the keyboard');

  // The close arrow: no blur, the pan left behind.
  const resizes = s.resizes;
  await page.evaluate((k) => window.__keyboard.closeWithArrow(k), KEYBOARD);
  await page.waitForTimeout(1500);
  s = await pageState();
  const after = await shot('3_closed_with_arrow');
  assert.equal(s.pan, 0, 'the pan is settled');
  assert.equal(s.scrollY, 0);
  assert.equal(s.rootScroll, 0);
  assert.deepEqual(s.view, [0, 0, W, H], 'Flutter fills the screen again');
  assert.deepEqual(s.body, [0, 0, W, H]);
  assert.equal(s.app.keyboard, 0, 'the app hears the keyboard is gone');
  assert.equal(s.active, 'INPUT', 'the field keeps the focus');
  assert.ok(s.resizes > resizes + 1, 'Flutter was asked to measure the page again');
  const changed = difference(before, after);
  assert.ok(changed < 0.02, `the screen is as it was before the keyboard (${(changed * 100).toFixed(2)} % differs)`);

  // Still typing into the same field.
  await page.keyboard.type(' canoe');
  await page.waitForTimeout(300);
  const value = await page.evaluate(() => document.activeElement?.value);
  assert.equal(value, 'maple river canoe', 'what was typed is kept, and more goes after it');

  // Up again, then gone with no resize at all (only a scroll), a little short and panned.
  const typed = await shot('3b_typing');
  await page.evaluate((k) => window.__keyboard.up(k), KEYBOARD);
  await page.waitForTimeout(1200);
  await page.evaluate(() => window.__keyboard.closeQuietly(300, 24));
  await page.waitForTimeout(1500);
  s = await pageState();
  const quiet = await shot('3c_closed_quietly');
  assert.equal(s.pan, 0, 'the pan is settled');
  assert.equal(s.app.keyboard, 0, '24 px short is no keyboard');
  assert.equal(s.active, 'INPUT');
  const moved = difference(typed, quiet);
  assert.ok(moved < 0.02, `nothing stays lifted (${(moved * 100).toFixed(2)} % differs)`);

  // A tap elsewhere (the empty middle of the join page) lets go of the field.
  await page.touchscreen.tap(W / 2, H / 2);
  await page.waitForTimeout(600);
  s = await pageState();
  assert.notEqual(s.active, 'INPUT', 'a tap elsewhere unfocuses the field');
  await shot('4_tapped_elsewhere');

  // Paste still fills the field (Chromium lets the test put text on the clipboard).
  if (engine === 'chromium' && where.paste) {
    await page.evaluate(() => navigator.clipboard.writeText('maple river canoe tiger'));
    await page.touchscreen.tap(where.paste.x, where.paste.y);
    await page.waitForTimeout(800);
    await shot('5_pasted');
  }
} catch (e) {
  failures.push(e.message);
}

/** The words in the app's accessibility tree: labels, and the text of the innermost nodes. */
const spoken = (page) => page.evaluate(() => [...document.querySelectorAll('flt-semantics-host *')]
  .map((e) => `${e.getAttribute('aria-label') ?? ''} ${e.childElementCount === 0 ? e.textContent ?? '' : ''}`)
  .join(' '));

/** The middle of the first accessibility node with [role] that says [words], as its label or its
 * text, once it is there (null after 15 s). */
const findNode = async (page, words, role = 'button') => {
  try {
    const handle = await page.waitForFunction(({ words, role }) => {
      const says = (e) => (e.getAttribute('aria-label') ?? '').trim() === words || (e.textContent ?? '').trim() === words;
      const el = [...document.querySelectorAll(`flt-semantics-host [role="${role}"]`)].find(says);
      if (!el) return null;
      const r = el.getBoundingClientRect();
      return r.width > 0 ? { x: r.x + r.width / 2, y: r.y + r.height / 2 } : null;
    }, { words, role }, { timeout: 15000 });
    return await handle.jsonValue();
  } catch {
    return null;
  }
};

if (askRoot) {
  const ask = await serve(askRoot, { hub: true });
  const today = `${ask.origin}/#/today`;
  // The page being checked, for a look when something fails.
  let showing = null;
  try {
    // A look with the accessibility tree: where Today's pill, Ask's field and its button are, and
    // the helper's calls from a chip to the answer on screen.
    const look = await open(true, today, 'flt-semantics-host [role="button"]');
    showing = look.page;
    await look.page.screenshot({ path: path.join(out, `${engine}_ask_0_today.png`) });
    const pill = await findNode(look.page, 'Ask about your day');
    assert.ok(pill, 'Today has the Ask pill');
    await look.page.mouse.click(pill.x, pill.y);
    // The sheet has stopped moving: the field is in the same place twice running, on screen.
    await look.page.waitForFunction(() => {
      const r = document.querySelector('flt-semantics-host textarea')?.getBoundingClientRect();
      if (!r) return false;
      const last = window.__fieldY;
      window.__fieldY = Math.round(r.y);
      return last === window.__fieldY && r.bottom <= window.innerHeight;
    }, null, { timeout: 30000, polling: 400 });
    const field = await look.page.evaluate(() => {
      const r = document.querySelector('flt-semantics-host textarea').getBoundingClientRect();
      return { x: r.x + r.width / 2, y: r.y + r.height / 2 };
    });
    const button = await findNode(look.page, 'Ask');
    if (!button) {
      await look.page.screenshot({ path: path.join(out, `${engine}_ask_0_no_button.png`) });
      const buttons = await look.page.evaluate(() => [...document.querySelectorAll('flt-semantics-host [role]')]
        .map((e) => `${e.getAttribute('role')}:${e.getAttribute('aria-label') ?? ''}|${e.childElementCount ? '' : e.textContent}`).join(' ; '));
      console.error(`no Ask button; the tree has: ${buttons}`);
    }
    assert.ok(button, 'Ask has its Ask button');
    assert.match(await spoken(look.page), /What can I help with\?/, 'an empty chat greets the person');
    assert.ok(helper.calls.some((c) => c.method === 'GET' && c.path === '/api/v1/assistant'), 'Ask asked the hub as it opened');
    const chip = await findNode(look.page, "Ask: What's on today?");
    assert.ok(chip, 'a chip to ask what\'s on today');
    await look.page.mouse.click(chip.x, chip.y);
    await look.page.waitForFunction(
      (answer) => [...document.querySelectorAll('flt-semantics-host *')]
        .some((e) => (e.getAttribute('aria-label') ?? '').includes(answer) || (e.childElementCount === 0 && (e.textContent ?? '').includes(answer))),
      helper.answer,
      { timeout: 20000 },
    );
    // The accessibility tree hears the answer a little before the canvas shows it.
    await look.page.waitForTimeout(2000);
    await look.page.screenshot({ path: path.join(out, `${engine}_ask_0_answered.png`) });
    const asked = helper.calls.filter((c) => c.path === '/api/v1/assistant/model');
    assert.equal(asked.length, 1, 'one model call, through the hub at the same origin');
    assert.equal(asked[0].provider, 'anthropic');
    assert.match(asked[0].body, /What's on today\?/);
    const blocked = await look.page.evaluate(() => window.__csp.filter((v) => v.startsWith('connect-src')));
    assert.deepEqual(blocked, [], 'the hub\'s policy lets the helper\'s calls through');
    await look.context.close();

    // The iPhone: Today's pill opens Ask, and its field gets the focus and the keyboard.
    const { context, page } = await open(false, today);
    showing = page;
    const shot = (name) => page.screenshot({ path: path.join(out, `${engine}_ask_${name}.png`) });
    const state = () => page.evaluate(() => {
      const view = document.querySelector('flutter-view').getBoundingClientRect();
      const body = document.body.getBoundingClientRect();
      return {
        scrollY: window.scrollY,
        pan: window.__keyboard.top,
        view: [view.x, view.y, view.width, view.height],
        body: [body.x, body.y, body.width, body.height],
        active: document.activeElement?.tagName,
        value: document.activeElement?.value,
        app: JSON.parse(window.denWeb.viewport()),
        resizes: window.__flutterResizes,
      };
    });
    await page.touchscreen.tap(pill.x, pill.y);
    await page.waitForTimeout(2500);
    // A tap while the sheet still settles can miss on a busy machine: tap until the field has it.
    for (let i = 0; i < 4; i++) {
      await page.touchscreen.tap(field.x, field.y);
      await page.waitForTimeout(800);
      if (await page.evaluate(() => ['INPUT', 'TEXTAREA'].includes(document.activeElement?.tagName))) break;
    }
    await page.keyboard.type('Who is driving Zoe');
    const before = await shot('1_focused');
    let s = await state();
    assert.ok(['INPUT', 'TEXTAREA'].includes(s.active), `Ask's field has the browser's focus (${s.active})`);

    // Up, with Safari panning to the field; then the close arrow, the pan left behind.
    await page.evaluate((k) => window.__keyboard.up(k), KEYBOARD);
    await page.evaluate(() => window.__keyboard.pan(180));
    await page.waitForTimeout(1200);
    s = await state();
    await shot('2_keyboard_up');
    assert.equal(s.pan, 0, 'the page is put back at the top while the keyboard is up');
    assert.equal(s.app.keyboard, KEYBOARD, 'the app hears the keyboard');
    const resizes = s.resizes;
    await page.evaluate((k) => window.__keyboard.closeWithArrow(k), KEYBOARD);
    await page.waitForTimeout(1500);
    s = await state();
    const after = await shot('3_closed_with_arrow');
    assert.equal(s.pan, 0, 'the pan is settled');
    assert.equal(s.scrollY, 0);
    assert.deepEqual(s.view, [0, 0, W, H], 'Flutter fills the screen again: no black band');
    assert.deepEqual(s.body, [0, 0, W, H]);
    assert.equal(s.app.keyboard, 0, 'the app hears the keyboard is gone');
    assert.ok(['INPUT', 'TEXTAREA'].includes(s.active), 'the field keeps the focus');
    assert.ok(s.resizes > resizes + 1, 'Flutter was asked to measure the page again');
    const changed = difference(before, after);
    assert.ok(changed < 0.02, `Ask is as it was before the keyboard (${(changed * 100).toFixed(2)} % differs)`);

    // Still typing; then up again and gone with only a scroll, a little short and panned.
    await page.keyboard.type(' to swimming');
    // The words drawn (the field wraps to a second line) before the next look is taken.
    await page.waitForTimeout(1500);
    s = await state();
    assert.equal(s.value, 'Who is driving Zoe to swimming', 'what was typed is kept, and more goes after it');
    const typed = await shot('4_typing');
    await page.evaluate((k) => window.__keyboard.up(k), KEYBOARD);
    await page.waitForTimeout(1200);
    await page.evaluate(() => window.__keyboard.closeQuietly(300, 24));
    await page.waitForTimeout(1500);
    s = await state();
    const quiet = await shot('5_closed_quietly');
    assert.equal(s.pan, 0, 'the pan is settled');
    assert.equal(s.app.keyboard, 0, '24 px short is no keyboard');
    const moved = difference(typed, quiet);
    assert.ok(moved < 0.02, `nothing stays lifted (${(moved * 100).toFixed(2)} % differs)`);

    // Ask: the question goes to the helper through the hub, and the screen stays whole.
    const calls = helper.calls.length;
    await page.touchscreen.tap(button.x, button.y);
    await page.waitForTimeout(2500);
    await shot('6_asked');
    const sent = helper.calls.slice(calls).filter((c) => c.path === '/api/v1/assistant/model');
    assert.equal(sent.length, 1, 'the question went to the helper');
    assert.match(sent[0].body, /Who is driving Zoe to swimming/);
    s = await state();
    assert.deepEqual(s.view, [0, 0, W, H]);
    await context.close();
  } catch (e) {
    failures.push(`Ask: ${e.message}`);
    await showing?.screenshot({ path: path.join(out, `${engine}_ask_failed.png`) }).catch(() => {});
    const tree = await showing?.evaluate(() => (document.querySelector('flt-semantics-host')?.outerHTML ?? '')
      .replace(/ style="[^"]*"/g, '').slice(0, 6000)).catch(() => null);
    if (tree != null) console.error(`  the accessibility tree when it failed:\n    ${tree || '(empty)'}`);
  } finally {
    ask.server.close();
  }
}

await browser.close();
main.server.close();

if (failures.length) {
  console.error(`keyboard e2e (${engine}): FAILED\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log(`keyboard e2e (${engine}): all checks passed; screenshots in ${out}`);
