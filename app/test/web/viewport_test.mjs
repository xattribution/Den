// Exercises the keyboard part of app/web/den_web.js against a fake Safari on an iPhone: a field
// gets the keyboard, Safari scrolls the page to show it, the keyboard is closed with its own
// button (no Return, no blur), and Safari leaves the page scrolled or the visual viewport panned.
// The page must end back at the top, the app must hear that the keyboard is gone, and Flutter
// (modelled the way its engine measures on iOS) must measure the restored page again.
// Also checks index.html pins the page. Run from app/:
//   node test/web/viewport_test.mjs web/den_web.js web/index.html
import fs from 'node:fs';
import vm from 'node:vm';
import assert from 'node:assert/strict';

const denWebSource = fs.readFileSync(process.argv[2] ?? 'web/den_web.js', 'utf8');
const indexHtml = fs.readFileSync(process.argv[3] ?? 'web/index.html', 'utf8');

// ---------------------------------------------------------------- the page can't scroll

const style = /<style>([\s\S]*?)<\/style>/.exec(indexHtml)[1];
const rule = /html,\s*body\s*\{([^}]*)\}/.exec(style)[1].replace(/\s+/g, ' ');
for (const decl of ['position: fixed', 'top: 0', 'right: 0', 'bottom: 0', 'left: 0', 'width: 100%', 'height: 100%', 'overflow: hidden', 'overscroll-behavior: none', 'margin: 0']) {
  assert.ok(rule.includes(decl), `html, body have ${decl}`);
}

// ---------------------------------------------------------------- a fake iPhone

class Target {
  constructor() { this.listeners = {}; }
  addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); }
  removeEventListener(type, fn) { this.listeners[type] = (this.listeners[type] ?? []).filter((f) => f !== fn); }
  dispatchEvent(event) {
    for (const fn of [...(this.listeners[event.type] ?? [])]) fn.call(this, event);
    return true;
  }
}

/** A clock whose timers and animation frames run only when the test says. */
function makeClock() {
  let now = 0;
  let seq = 0;
  const timers = [];
  return {
    setTimeout(fn, ms = 0) { timers.push({ at: now + ms, seq: seq++, fn }); return seq; },
    run(ms) {
      const end = now + ms;
      for (;;) {
        timers.sort((a, b) => a.at - b.at || a.seq - b.seq);
        const next = timers[0];
        if (!next || next.at > end) break;
        timers.shift();
        now = next.at;
        next.fn();
      }
      now = end;
    },
  };
}

function makePhone({ stuckPan = false, scrollWorks = true } = {}) {
  const clock = makeClock();
  const window = new Target();
  const documentElement = { clientWidth: 390, clientHeight: 844, scrollTop: 0, scrollLeft: 0 };
  const body = { tagName: 'BODY', scrollTop: 0, scrollLeft: 0 };
  const document = new Target();
  Object.assign(document, {
    documentElement,
    body,
    head: {},
    scrollingElement: documentElement,
    activeElement: body,
    readyState: 'complete',
    visibilityState: 'visible',
  });
  const vv = new Target();
  Object.assign(vv, { width: 390, height: 844, offsetTop: 0, offsetLeft: 0, scale: 1 });

  // Safari: the page's scroll and the visual viewport's pan, with its events a moment later.
  const page = { y: 0, scrollCalls: 0 };
  function setScroll(y, { pan = 0 } = {}) {
    page.y = y;
    documentElement.scrollTop = y;
    vv.offsetTop = pan;
    clock.setTimeout(() => window.dispatchEvent({ type: 'scroll' }), 0);
  }
  Object.defineProperty(window, 'scrollY', { get: () => page.y });
  Object.defineProperty(window, 'pageYOffset', { get: () => page.y });
  window.scrollX = 0;
  window.pageXOffset = 0;
  window.innerWidth = 390;
  window.innerHeight = 844;
  window.scrollTo = (x, y) => {
    page.scrollCalls++;
    if (!scrollWorks) return;
    const moved = y !== page.y;
    page.y = y;
    documentElement.scrollTop = y;
    // iOS 26: a pan left behind only settles once something actually scrolls.
    if (!stuckPan || moved) vv.offsetTop = 0;
    if (moved) clock.setTimeout(() => window.dispatchEvent({ type: 'scroll' }), 0);
  };
  window.visualViewport = vv;
  window.requestAnimationFrame = (fn) => clock.setTimeout(fn, 16);
  window.matchMedia = () => ({ matches: true });
  window.isSecureContext = true;
  window.location = { reload() {} };

  const navigator = {
    userAgent: 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1',
    standalone: true,
    maxTouchPoints: 5,
  };
  const context = vm.createContext({
    window,
    document,
    navigator,
    MutationObserver: class { observe() {} },
    Event: class { constructor(type) { this.type = type; } },
    setTimeout: (fn, ms) => clock.setTimeout(fn, ms),
    JSON,
    Math,
    Promise,
    console,
  });
  context.window.navigator = navigator;
  vm.runInContext(denWebSource, context);
  const denWeb = window.denWeb;
  assert.ok(denWeb, 'den_web.js set up window.denWeb');

  // Flutter's engine on iOS (FullPageDimensionsProvider, EngineFlutterView._didResize): on a
  // visual viewport resize it takes the page's size as the screen's when no field is being
  // edited, and while one is, keeps the size and takes the keyboard as what the visual viewport
  // lost. It listens on the visual viewport, so it hears den_web.js's nudge too.
  const flutter = { editing: false, size: { w: 390, h: 844 }, inset: 0, measures: 0, scrollAtMeasure: null };
  vv.addEventListener('resize', () => {
    flutter.measures++;
    flutter.scrollAtMeasure = page.y + vv.offsetTop;
    if (flutter.editing) {
      flutter.inset = flutter.size.h - vv.height;
    } else {
      flutter.size = { w: documentElement.clientWidth, h: documentElement.clientHeight };
      flutter.inset = 0;
    }
  });

  // The app's root listens for the keyboard (lib/platform/web/web_insets.dart).
  const reports = [];
  denWeb.onViewport((json) => reports.push(JSON.parse(json)));

  const input = { tagName: 'INPUT' };
  return {
    clock, window, document, vv, page, flutter, reports, denWeb, setScroll,
    focus() {
      document.activeElement = input;
      flutter.editing = true;
      document.dispatchEvent({ type: 'focusin' });
    },
    blur() {
      document.activeElement = body;
      flutter.editing = false;
      document.dispatchEvent({ type: 'focusout' });
    },
    keyboard(height) {
      vv.height = 844 - height;
      vv.dispatchEvent({ type: 'resize' });
    },
    last() { return reports[reports.length - 1]; },
  };
}

// ---------------------------------------------------------------- 1. the close arrow

{
  const p = makePhone();
  assert.equal(p.last().keyboard, 0, 'no keyboard to start with');

  // A long press opens an item's sheet; its field takes the focus and the keyboard comes up.
  p.focus();
  p.clock.run(50);
  // Safari scrolls the page to show the field, then the keyboard finishes coming up.
  p.setScroll(300);
  p.keyboard(336);
  p.clock.run(1000);
  assert.equal(p.window.scrollY, 0, 'the page is back at the top while the keyboard is up');
  assert.equal(p.vv.offsetTop, 0);
  assert.equal(p.last().keyboard, 336, 'the app hears how much the keyboard covers');
  assert.equal(p.flutter.inset, 336, 'Flutter lifts what is under the keyboard');

  // Typing: Safari scrolls again to keep the caret in view; the page goes back.
  p.setScroll(120, { pan: 40 });
  p.clock.run(200);
  assert.equal(p.window.scrollY, 0);
  assert.equal(p.vv.offsetTop, 0);

  // The keyboard's close arrow: the keyboard goes, the field keeps the focus (no blur), and
  // Safari leaves the page scrolled and the visual viewport panned.
  p.keyboard(0);
  p.setScroll(336, { pan: 336 });
  p.clock.run(1000);
  assert.equal(p.window.scrollY, 0, 'the page is back at the top after the close arrow');
  assert.equal(p.document.documentElement.scrollTop, 0);
  assert.equal(p.vv.offsetTop, 0, 'the visual viewport is back at the top');
  assert.equal(p.last().keyboard, 0, 'the app hears the keyboard is gone');
  assert.equal(p.last().editing, true, 'the field still has the focus');
  assert.deepEqual(p.flutter.size, { w: 390, h: 844 }, 'Flutter has the whole page');
  assert.equal(p.flutter.inset, 0, 'and no keyboard');
  assert.equal(p.flutter.scrollAtMeasure, 0, 'Flutter measured again after the page was back');

  // Touching the field again brings the keyboard back, and the same holds.
  p.keyboard(336);
  p.setScroll(200);
  p.clock.run(1000);
  assert.equal(p.window.scrollY, 0);
  assert.equal(p.last().keyboard, 336);
  // Return this time: the field lets go and the keyboard goes.
  p.blur();
  p.keyboard(0);
  p.clock.run(1000);
  assert.equal(p.last().keyboard, 0);
  assert.equal(p.last().editing, false);
  assert.deepEqual(p.flutter, { ...p.flutter, size: { w: 390, h: 844 }, inset: 0 });
}

// ---------------------------------------------------------------- 2. iOS 26 leaves the pan

{
  const p = makePhone({ stuckPan: true });
  p.focus();
  p.keyboard(336);
  p.clock.run(500);
  // The keyboard closes with nothing scrolled, but the visual viewport stays panned and 24 px
  // short, and Safari sends no resize, only a scroll.
  p.vv.height = 820;
  p.vv.offsetTop = 300;
  p.vv.dispatchEvent({ type: 'scroll' });
  p.clock.run(1000);
  assert.equal(p.vv.offsetTop, 0, 'a scroll down and back settles the pan');
  assert.equal(p.window.scrollY, 0);
  assert.equal(p.last().keyboard, 0, '24 px short is not a keyboard');
  assert.ok(p.flutter.measures >= 2, 'Flutter was asked to measure again without a real resize');
}

// ---------------------------------------------------------------- 3. a page that won't move

{
  const p = makePhone({ scrollWorks: false });
  p.focus();
  p.setScroll(300);
  p.keyboard(336);
  p.clock.run(5000);
  for (let i = 0; i < 20; i++) p.window.dispatchEvent({ type: 'scroll' });
  p.clock.run(5000);
  assert.ok(p.page.scrollCalls <= 16, `tries a few times, then stops (${p.page.scrollCalls} tries)`);
}

// ---------------------------------------------------------------- 4. zoomed in on purpose

{
  const p = makePhone();
  p.vv.scale = 2;
  p.setScroll(250, { pan: 100 });
  p.vv.dispatchEvent({ type: 'scroll' });
  p.clock.run(1000);
  assert.equal(p.window.scrollY, 250, 'someone zoomed in keeps their place');
  assert.equal(p.page.scrollCalls, 0);
}

// ---------------------------------------------------------------- 5. what the app reads

{
  const p = makePhone();
  const v = JSON.parse(p.denWeb.viewport());
  assert.deepEqual(Object.keys(v).sort(), ['editing', 'height', 'keyboard', 'scrolled', 'top', 'width']);
  assert.equal(v.width, 390);
  assert.equal(v.height, 844);
  // Focus without a keyboard (a hardware keyboard, or one just closing) is no keyboard.
  p.focus();
  p.vv.height = 800;
  assert.equal(JSON.parse(p.denWeb.viewport()).keyboard, 0);
  p.vv.height = 508;
  assert.equal(JSON.parse(p.denWeb.viewport()).keyboard, 336);
  p.blur();
  assert.equal(JSON.parse(p.denWeb.viewport()).keyboard, 0, 'no field, no keyboard, whatever the viewport says');
}

console.log('den_web.js keyboard: all checks passed');
