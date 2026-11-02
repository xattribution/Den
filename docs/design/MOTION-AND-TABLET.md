# Den: motion and tablet rules

Owner direction: every animation and interaction should feel premium, never jittery, and not
lean on CSS-style tweens. Use real motion for menus and buttons. Optimize for iPad as much as
iPhone.

## Motion: physics, not tweens

The app is Flutter (it paints its own frames on iPhone, iPad and the web), so motion is built
with Flutter's animation system, never CSS transitions. Rules:

1. **Springs for anything that moves.** Use `SpringSimulation` / `SpringDescription` driven by an
   `AnimationController` (unbounded) for sheets, menus, press feedback, check marks, reordering
   and the Add sheet. Defaults:
   - UI spring: damping ratio 0.86, response ~0.32 s (stiffness ≈ (2π/response)² × mass),
     no visible overshoot beyond 2 %.
   - Sheet spring: critically damped (ratio 1.0), response 0.38 s.
   - Check fill: ratio 0.7, response 0.24 s (one small settle, the only "bounce" allowed).
   Put these in one `DenMotion` file; nothing else invents curves.
2. **Interruptible and velocity-aware.** Every animation can be grabbed mid-flight. A sheet
   follows the finger 1:1, and on release continues with the fling velocity into the spring
   (dismiss when velocity > 700 px/s down or dragged past 35 % of its height). Menus that open
   from a button scale from that button's position, not from the screen center.
3. **Press feedback in the same frame.** Buttons, rows and chips respond on pointer down (not up)
   with a 0.97 scale and a 6 % darker/lighter fill, springing back on release. Never delay
   feedback, never flash opacity. Light haptic (`HapticFeedback.selectionClick`) on check-off,
   approve and drop where the platform supports it.
4. **Transform and opacity only.** Animate `Transform`, `Opacity`/`FadeTransition`,
   `SizeTransition` and clip; never animate padding, text style or layout of large subtrees. Wrap
   animated pieces in `RepaintBoundary`. Lists use `SliverAnimatedList` for insert/remove (size +
   fade, 220 ms equivalent spring), so rows never jump.
5. **Navigation.** iOS-style push with parallax on every platform
   (`CupertinoPageTransitionsBuilder`), with the edge-swipe back gesture. Tabs switch instantly
   with state kept (no slide). Shared elements (an event row opening its detail) use `Hero`.
6. **120 Hz clean.** No frame over 8 ms on iPad Pro / iPhone Pro: rebuild only the widgets whose
   data changed (see the product review's snappiness section), precompute views off the UI
   thread, no `BackdropFilter`, no `saveLayer`-heavy effects, no shadows on scrolling content.
   Measure with the performance overlay and `flutter run --profile`; a jank test runs in CI on the
   main screens' scroll and the Add sheet.
7. **Reduce Motion** (`MediaQuery.disableAnimations`): springs become 100 ms opacity fades;
   nothing slides or scales.
8. **Never decorative:** no bounce/elastic curves, confetti, shimmer, pulsing, parallax
   backgrounds or looping animation. The kids' star landing is the one celebration, a single
   spring scale with a light haptic.

## Words: scaling and wrapping

1. **Text scales with the system.** Respect iOS Text Size / Android font scale up to 200 %
   (`MediaQuery.textScaler`), never clamp it below 135 %. No fixed heights on anything holding
   text (min-height only). Test every screen at 100 %, 135 % and 200 % in golden tests.
2. **Actions never squeeze text.** A row's button sits beside its text only while the text fits
   on one line at the current size; otherwise (and always for "Needs you" rows on phones) the
   button moves under the text, aligned with it. Button labels never wrap or truncate.
3. **Units stay together.** Non-breaking spaces between a number and its unit or meridiem
   ("3:30 PM", "40 stars", "Field 4"); times never split across lines. Time columns are sized
   for the longest localized time at the current text size.
4. **No orphans.** Headings balance their lines; a body line never ends with one lonely word
   (Flutter: a `noOrphan()` helper joins the last two words with a non-breaking space for text
   under ~60 characters).
5. **Truncate only where space is the point.** Names, times and what an action affects are
   never truncated. Event titles may clamp to two lines on phones; dense iPad week and month
   cells use one line with an ellipsis and show the full text on tap or hover.
6. **Line height:** 1.25 for titles, 1.35 for body. Two weights. Left-aligned.
7. **Copy is written to fit:** titles aim for 28 characters or fewer, detail lines 40 or fewer,
   and the shortest clear phrasing wins ("Costs 40 stars, she has 52").

## Tablet: a real iPad layout, not a stretched phone

Breakpoints by available width (not device type):
- **Compact, under 700 pt** (iPhone, iPad Slide Over): bottom tab bar, center Add, one column.
- **Regular, 700 to 1100 pt** (iPad portrait, split view): left sidebar of 248 pt with Add at the
  top and the five sections; content in up to two columns.
- **Wide, over 1100 pt** (iPad landscape, Mac): sidebar plus two content columns on Today; the
  Calendar defaults to the family week (one column per person, a row per day, everyone-events
  spanning the row).

Rules:
- Sheets become centered form sheets, at most 560 pt wide, with the same springs. Menus are
  popovers anchored to their button.
- Content never stretches past a readable width: text columns max 680 pt; grids reflow.
- Pointer and keyboard on iPad: hover highlight on rows, right-click / long-press context menus
  with the same actions as the row, keyboard shortcuts (⌘N add, ⌘F search, ⌘1–5 sections, space
  to check the focused chore), visible focus ring.
- Rotation and split view keep the current screen and scroll position.
- Kid mode on iPad: 3 or 4 tile columns, 72 pt minimum targets.
- The wall display (a shared iPad on the kitchen counter) uses the wide layout with Display scale
  1.3 and the family week as home.
