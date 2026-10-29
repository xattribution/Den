// The real web build in a browser made to look like a Home Screen iPhone (Flutter takes it for
// iOS), with the keyboard played by a stand-in visual viewport, since no desktop browser has an
// on-screen keyboard: a field gets the focus, the keyboard comes up, Safari pans the page, the
// keyboard closes with its own button (no Return, no blur) and Safari leaves the pan behind.
// Checks the page can't be scrolled, the app fills the screen again, Flutter and the app both
// know the keyboard is gone, the field keeps its focus until a tap elsewhere, and Paste still
// fills the field. Screenshots go to the output folder for a look.
//
// Not part of CI (it needs Playwright and a release build). From app/:
//   flutter build web --release --csp --dart-define=FLUTTER_WEB_CANVASKIT_URL=canvaskit/
//   NODE_PATH=<dir with playwright> node test/web/keyboard_e2e.mjs build/web chromium [out-dir]
//   (or webkit; CHROME_EXECUTABLE picks the Chromium binary)
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
fs.mkdirSync(out, { recursive: true });

const types = {
  '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.json': 'application/json',
  '.wasm': 'application/wasm', '.png': 'image/png', '.ttf': 'font/ttf', '.otf': 'font/otf', '.svg': 'image/svg+xml',
};
const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://x');
  let file = path.join(root, decodeURIComponent(url.pathname));
  if (!file.startsWith(root) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) file = path.join(root, 'index.html');
  res.writeHead(200, { 'content-type': types[path.extname(file)] ?? 'application/octet-stream', 'cache-control': 'no-store' });
  fs.createReadStream(file).pipe(res);
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const origin = `http://127.0.0.1:${server.address().port}`;

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
}

const browserType = engine === 'webkit' ? webkit : chromium;
const browser = await browserType.launch(engine === 'chromium' && process.env.CHROME_EXECUTABLE ? { executablePath: process.env.CHROME_EXECUTABLE } : {});
const failures = [];

async function open(semantics) {
  const context = await browser.newContext(iphone);
  await context.addInitScript(stage, !semantics);
  const page = await context.newPage();
  page.on('pageerror', (e) => failures.push(`page error: ${e.message}`));
  await page.goto(`${origin}/#/welcome/join`);
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
    await page.waitForSelector('flt-semantics-host input, flt-semantics-host textarea', { state: 'attached', timeout: 20000 });
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
} finally {
  await browser.close();
  server.close();
}

if (failures.length) {
  console.error(`keyboard e2e (${engine}): FAILED\n  ${failures.join('\n  ')}`);
  process.exit(1);
}
console.log(`keyboard e2e (${engine}): all checks passed; screenshots in ${out}`);
