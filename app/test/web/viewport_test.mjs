// Exercises the keyboard part of app/web/den_web.js against a fake phone and a model of how
// Flutter's web engine measures it:
//
// - Safari on an iPhone: a field gets the keyboard, Safari scrolls the page to show it, the
//   keyboard is closed with its own button (no Return, no blur), and Safari leaves the page
//   scrolled or the visual viewport panned. The page must end back at the top, the field must let
//   go, the app must hear that the keyboard is gone, and Flutter must measure the restored page.
// - Chrome on Android (a Galaxy Z Fold, folded and open), with Flutter 3.38.5's engine, whose
//   every frame drawn while a field is edited resets the size it keeps to the part above the
//   keyboard: closing the keyboard with the arrow must not leave the app drawn short.
//
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

// ---------------------------------------------------------------- a fake phone

class Target {
  constructor() { this.listeners = {}; }
  addEventListener(type, fn) { (this.listeners[type] ??= []).push(fn); }
  removeEventListener(type, fn) { this.listeners[type] = (this.listeners[type] ?? []).filter((f) => f !== fn); }
  dispatchEvent(event) {
    for (const fn of [...(this.listeners[event.type] ?? [])]) fn.call(this, event);
    return true;
  }
}

/** A clock whose timers, animation frames and Date.now() move only when the test says. */
function makeClock() {
  let now = 1000000;
  let seq = 0;
  const timers = [];
  return {
    get now() { return now; },
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

const IPHONE = 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1';
const FOLD = 'Mozilla/5.0 (Linux; Android 16; SM-F966U) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Mobile Safari/537.36';
const SAMSUNG = 'Mozilla/5.0 (Linux; Android 16; SM-F966U) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/29.0 Chrome/136.0.0.0 Mobile Safari/537.36';
const LINUX = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';

/**
 * A phone running den_web.js and a model of Flutter's engine on it.
 *
 * [engine] 'ios' measures the way Flutter does on iOS (the page's size; the keyboard from the
 * visual viewport while editing). 'android' the way it does elsewhere (the visual viewport's
 * size), and with [fixed] false the way Flutter 3.38.5 does: each frame drawn takes the visual
 * viewport's size as the one it keeps, even while editing (flutter/flutter#175074).
 * [resizesContent] makes the page itself shrink around the keyboard, as Chrome did before 108.
 */
function makePhone({ ua = IPHONE, engine = 'ios', fixed = false, width = 390, height = 844, resizesContent = false, stuckPan = false, scrollWorks = true, withDenWeb = true } = {}) {
  const clock = makeClock();
  const window = new Target();
  const documentElement = { clientWidth: width, clientHeight: height, scrollTop: 0, scrollLeft: 0 };
  const body = { tagName: 'BODY', scrollTop: 0, scrollLeft: 0 };
  const document = new Target();
  const flutter = { editing: false, size: { w: width, h: height }, inset: 0, drawn: height, measures: 0, frames: 0, scrollAtMeasure: null };
  const view = { getBoundingClientRect: () => ({ left: 0, top: 0, width: flutter.size.w, height: flutter.drawn }) };
  Object.assign(document, {
    documentElement,
    body,
    head: {},
    scrollingElement: documentElement,
    activeElement: body,
    readyState: 'complete',
    visibilityState: 'visible',
    querySelector: (selector) => (selector === 'flutter-view' ? view : null),
  });
  const vv = new Target();
  Object.assign(vv, { width, height, offsetTop: 0, offsetLeft: 0, scale: 1 });

  // The browser: the page's scroll and the visual viewport's pan, with its events a moment later.
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
  window.innerWidth = width;
  window.innerHeight = height;
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

  const navigator = { userAgent: ua, standalone: engine === 'ios', maxTouchPoints: 5 };
  const context = vm.createContext({
    window,
    document,
    navigator,
    MutationObserver: class { observe() {} },
    Event: class { constructor(type) { this.type = type; } },
    setTimeout: (fn, ms) => clock.setTimeout(fn, ms),
    Date: { now: () => clock.now },
    JSON,
    Math,
    Promise,
    console,
  });
  context.window.navigator = navigator;
  if (withDenWeb) vm.runInContext(denWebSource, context);
  const denWeb = window.denWeb;
  assert.ok(denWeb || !withDenWeb, 'den_web.js set up window.denWeb');

  // Flutter's engine (FullPageDimensionsProvider, EngineFlutterView._didResize): it listens on
  // the visual viewport, after den_web.js, so it hears den_web.js's nudge too. While a field is
  // edited it keeps its size and takes the keyboard as what the visual viewport lost; otherwise
  // it measures afresh. Each change is drawn a frame later at the size it then reports.
  function measured() {
    return engine === 'ios'
      ? { w: documentElement.clientWidth, h: documentElement.clientHeight }
      : { w: vv.width, h: vv.height };
  }
  vv.addEventListener('resize', () => {
    flutter.measures++;
    flutter.scrollAtMeasure = page.y + vv.offsetTop;
    const next = measured();
    const turned = next.w !== flutter.size.w && next.h !== flutter.size.h && (next.w > next.h) !== (flutter.size.w > flutter.size.h);
    if (flutter.editing && !turned) {
      flutter.inset = flutter.size.h - (engine === 'ios' ? vv.height : vv.height);
    } else {
      flutter.size = next;
      flutter.inset = flutter.size.h - (engine === 'ios' ? documentElement.clientHeight : vv.height);
    }
    // The app lays out at that size and draws, a frame later.
    flutter.drawn = flutter.size.h;
    clock.setTimeout(() => {
      flutter.frames++;
      // Flutter 3.38.5 on Android: drawing a frame takes the visual viewport's size as the one
      // to keep, even while a field is edited (3.38.6 keeps it while one is).
      if (engine === 'android' && (!fixed || !flutter.editing)) flutter.size = measured();
    }, 16);
  });

  // The app's root listens for the keyboard (lib/platform/web/web_insets.dart).
  const reports = [];
  denWeb?.onViewport((json) => reports.push(JSON.parse(json)));

  function field(name) {
    return {
      tagName: 'INPUT',
      className: `flt-text-editing ${name}`,
      blur() {
        if (document.activeElement !== this) return;
        // The engine's blur handler: the focus left the page's fields, so editing ends.
        document.activeElement = body;
        flutter.editing = false;
        document.dispatchEvent({ type: 'focusout' });
      },
    };
  }
  const input = field('a');
  return {
    clock, window, document, documentElement, vv, page, flutter, reports, denWeb, setScroll, input,
    field,
    focus(el = input) {
      document.activeElement = el;
      flutter.editing = true;
      document.dispatchEvent({ type: 'focusin' });
    },
    blur() { document.activeElement.blur?.(); },
    keyboard(kb) {
      vv.height = documentElement.clientHeight - kb;
      if (resizesContent) {
        documentElement.clientHeight = height - kb;
        window.innerHeight = height - kb;
        vv.height = height - kb;
      }
      vv.dispatchEvent({ type: 'resize' });
    },
    turn() {
      const w = documentElement.clientWidth;
      documentElement.clientWidth = documentElement.clientHeight;
      documentElement.clientHeight = w;
      window.innerWidth = documentElement.clientWidth;
      window.innerHeight = documentElement.clientHeight;
      vv.width = documentElement.clientWidth;
      vv.height = documentElement.clientHeight;
      window.dispatchEvent({ type: 'resize' });
      vv.dispatchEvent({ type: 'resize' });
    },
    tap() { document.dispatchEvent({ type: 'pointerdown' }); },
    last() { return reports[reports.length - 1]; },
  };
}

// ---------------------------------------------------------------- 1. iPhone: the close arrow

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
  assert.equal(p.last().editing, true);

  // Typing: Safari scrolls again to keep the caret in view; the page goes back.
  p.setScroll(120, { pan: 40 });
  p.clock.run(200);
  assert.equal(p.window.scrollY, 0);
  assert.equal(p.vv.offsetTop, 0);
  assert.equal(p.document.activeElement, p.input, 'the field keeps the focus while the keyboard is up');

  // The keyboard's close arrow: the keyboard goes, Safari doesn't blur the field, and it leaves
  // the page scrolled and the visual viewport panned.
  p.keyboard(0);
  p.setScroll(336, { pan: 336 });
  p.clock.run(1000);
  assert.equal(p.window.scrollY, 0, 'the page is back at the top after the close arrow');
  assert.equal(p.document.documentElement.scrollTop, 0);
  assert.equal(p.vv.offsetTop, 0, 'the visual viewport is back at the top');
  assert.equal(p.last().keyboard, 0, 'the app hears the keyboard is gone');
  assert.equal(p.last().editing, false, 'the field let go, as after Return');
  assert.equal(p.flutter.editing, false, 'so Flutter stopped editing, and the next tap on the field brings the keyboard back');
  assert.deepEqual(p.flutter.size, { w: 390, h: 844 }, 'Flutter has the whole page');
  assert.equal(p.flutter.inset, 0, 'and no keyboard');
  assert.equal(p.flutter.scrollAtMeasure, 0, 'Flutter measured again after the page was back');

  // Touching the field again brings the keyboard back, and the same holds.
  p.focus();
  p.clock.run(400);
  p.keyboard(336);
  p.setScroll(200);
  p.clock.run(1000);
  assert.equal(p.window.scrollY, 0);
  assert.equal(p.last().keyboard, 336);
  assert.equal(p.last().editing, true);
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
  p.clock.run(400);
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
  assert.equal(p.last().editing, false, 'and the field let go');
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

// ---------------------------------------------------------------- 6. the Fold, Flutter 3.38.5

/** Opens the keyboard over a field and closes it with the arrow, the field keeping the focus. */
function arrow(p, kb) {
  p.focus();
  p.clock.run(400);
  p.keyboard(kb);
  p.clock.run(1000);
  // A second resize while the keyboard is up (Chrome sends more than one, and den_web.js has
  // Flutter measure again): with 3.38.5, Flutter now lays out in the part above the keyboard.
  p.vv.dispatchEvent({ type: 'resize' });
  p.clock.run(1000);
  p.keyboard(0);
  p.clock.run(1000);
}

for (const [name, size] of [['folded', [412, 915]], ['open', [884, 1004]], ['open, on its side', [1004, 884]]]) {
  // First the engine alone, as before: it stays a keyboard short. This is the bug, so the model
  // has to show it.
  {
    const p = makePhone({ ua: FOLD, engine: 'android', width: size[0], height: size[1], withDenWeb: false });
    p.focus();
    p.keyboard(320);
    p.clock.run(100);
    p.keyboard(0);
    p.clock.run(100);
    assert.equal(p.flutter.drawn, size[1] - 320, `${name}, engine alone: drawn a keyboard short (the bug the model has to show)`);
    assert.equal(p.flutter.inset, -320, `${name}, engine alone: with a negative keyboard inset`);
  }
  const p = makePhone({ ua: FOLD, engine: 'android', width: size[0], height: size[1] });
  arrow(p, 320);
  assert.equal(p.flutter.drawn, size[1], `${name}: the app fills the screen after the arrow`);
  assert.equal(p.flutter.inset, 0, `${name}: with no keyboard inset`);
  assert.equal(p.document.activeElement, p.document.body, `${name}: the field let go`);
  assert.equal(p.flutter.editing, false, `${name}: Flutter stopped editing, so a tap on the field opens the keyboard again`);
  assert.equal(p.last()?.keyboard ?? 0, 0);

  // The field again: the keyboard comes up, and the arrow again leaves nothing behind.
  arrow(p, 300);
  assert.equal(p.flutter.drawn, size[1], `${name}: and again`);
}

// ---------------------------------------------------------------- 7. the Fold, other ways in

{
  // Samsung Internet's UA, and a fixed engine (Flutter 3.38.6 on): the same.
  for (const fixed of [false, true]) {
    const p = makePhone({ ua: SAMSUNG, engine: 'android', fixed, width: 884, height: 1004 });
    arrow(p, 320);
    assert.equal(p.flutter.drawn, 1004, `Samsung Internet (engine fixed: ${fixed}): fills the screen`);
    assert.equal(p.document.activeElement, p.document.body);
  }
}

{
  // A browser that shrinks the page itself around the keyboard: the screen's height is what the
  // viewport had before the field.
  const p = makePhone({ ua: FOLD, engine: 'android', width: 412, height: 915, resizesContent: true });
  p.clock.run(100);
  arrow(p, 320);
  assert.equal(p.flutter.drawn, 915, 'a page that shrinks too: fills the screen');
  assert.equal(p.document.activeElement, p.document.body);
}

{
  // The arrow's resize never came (or came too soon after the focus to trust): the app is drawn
  // short with the field still focused. A look a moment later puts it right.
  const p = makePhone({ ua: FOLD, engine: 'android', width: 412, height: 915 });
  p.focus();
  p.keyboard(320);
  p.clock.run(100);
  p.keyboard(0);
  p.clock.run(2000);
  assert.equal(p.flutter.drawn, 915, 'too soon after the focus: still put right a moment later');
  assert.equal(p.document.activeElement, p.document.body);
}

{
  // Drawn short with nothing focused and no event at all (Flutter missed a resize): the next
  // touch puts it right.
  const p = makePhone({ ua: FOLD, engine: 'android', width: 412, height: 915 });
  p.flutter.size = { w: 412, h: 595 };
  p.flutter.drawn = 595;
  p.clock.run(2000);
  assert.equal(p.flutter.drawn, 595, 'nothing happened yet');
  p.tap();
  p.clock.run(1000);
  assert.equal(p.flutter.drawn, 915, 'the next touch has Flutter measure again');
}

{
  // Typing on: from one field to the next with the keyboard up, the keyboard flickering as it
  // restarts. Nobody lets go.
  const p = makePhone({ ua: FOLD, engine: 'android', width: 412, height: 915 });
  p.focus();
  p.clock.run(400);
  p.keyboard(320);
  p.clock.run(1000);
  const next = p.field('b');
  p.focus(next);
  p.keyboard(0);
  p.keyboard(320);
  p.clock.run(1000);
  assert.equal(p.document.activeElement, next, 'the next field keeps the focus');
  assert.equal(p.flutter.editing, true);
  // Turned on its side while typing: the viewport changes shape, the keyboard stays.
  p.turn();
  p.clock.run(1000);
  assert.equal(p.document.activeElement, next, 'turning the phone keeps the focus');
}

{
  // A floating keyboard (the Fold's open screen can float it): the viewport never changes.
  const p = makePhone({ ua: FOLD, engine: 'android', width: 884, height: 1004 });
  p.focus();
  p.clock.run(3000);
  assert.equal(p.document.activeElement, p.input, 'a field with a floating keyboard keeps the focus');
}

{
  // A desktop browser: its Flutter never keeps a size for the keyboard, so nothing to do.
  const p = makePhone({ ua: LINUX, engine: 'android', width: 1200, height: 800 });
  p.focus();
  p.clock.run(400);
  p.keyboard(300);
  p.clock.run(500);
  p.keyboard(0);
  p.clock.run(1000);
  assert.equal(p.document.activeElement, p.input, 'a desktop browser keeps the focus');
}

// ---------------------------------------------------------------- 8. Show screen info

{
  const p = makePhone({ ua: FOLD, engine: 'android', width: 412, height: 915 });
  let info = JSON.parse(p.denWeb.screenInfo());
  assert.deepEqual(info.events, [], 'no events kept until it is on');
  assert.deepEqual(info.client, [412, 915]);
  assert.equal(info.ua, FOLD);
  p.denWeb.diagnose(true);
  arrow(p, 320);
  info = JSON.parse(p.denWeb.screenInfo());
  const what = info.events.map((e) => e.what);
  assert.ok(info.events.length <= 12, 'only the last few');
  assert.ok(what.includes('let go: keyboard closed'), `it says the field let go (${what.join(', ')})`);
  assert.deepEqual(info.view, [0, 0, 412, 915]);
  assert.equal(info.visual.height, 915);
  assert.equal(info.focus, 'body');
  p.denWeb.diagnose(false);
  assert.deepEqual(JSON.parse(p.denWeb.screenInfo()).events, [], 'off again, nothing kept');
}

console.log('den_web.js keyboard: all checks passed');
