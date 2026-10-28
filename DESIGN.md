# Den design system

The rules every screen follows. Agents and people building Den read this before touching UI.

- The tokens live in code in `app/lib/design/` (`tokens.dart`, `theme.dart`, `layout.dart`,
  `motion.dart`, `sheet.dart`, `pictures.dart`, `avatar.dart`, `words.dart`). This file says
  what each one is for.
- Two rule books override anything softer here: [ANTI-SLOP](docs/design/ANTI-SLOP.md) (what
  makes a screen look generated; a screen that breaks one is not done) and
  [MOTION-AND-TABLET](docs/design/MOTION-AND-TABLET.md) (motion, text sizing and wrapping, iPad).
- The approved canvas (Today, Add, Calendar, Chores, Lists, Family, Invite, Kid, Event detail,
  their dark versions, iPad Today and family week, the picture picker, the picture pack and the
  family colors) is the reference for every screen. When this file and the canvas disagree, the
  canvas wins and this file gets fixed.

## Domain read

- **Who.** First, a busy parent who runs the family: not technical, on an iPhone, using Den as a
  web app pinned to the home screen, often one-handed, often interrupted, with oversight of the
  kids. Then the other parent; kids from pre-readers to teens; adults outside the house:
  grandparents, a sitter.
- **Where.** A phone in one hand while carrying groceries, in the car line, at the store; an
  iPad on the kitchen counter read from across the room, in bright morning light and a dark
  kitchen at night; a laptop on Sunday night when the week gets planned.
- **What they already read fluently.** The fridge door: each kid's chore chart in their color,
  round magnets, big circles to tick, star stickers. The paper family organizer with one column
  per person. A grocery list crossed off as you go. "Today", "Tomorrow", "Wed", "3:30 PM". And
  iPhone conventions: tab bars, sheets, large titles, swipe back.
- **What binds it.** WCAG 2.2 AA; touch targets of 44 (72 for kids); the system text size up to
  200 %; US date and time formats by default (locale aware); offline first; privacy between
  family members; readability for early readers and older eyes; iOS Safari's rules for
  home-screen web apps.
- **The job.** The first screen answers "what's happening today, who's doing what, and what
  needs me". Anything she does daily is one tap from where her thumb already is.

## Principles

1. **One tap does the thing, inline.** Tap "I'll drive", tap a chore to check it, tap an item to
   cross it off; the row changes in place and offers Undo right there. No modal for anything
   the row can do.
2. **People are the color, at full strength.** A hue means a person, always and only: their
   avatar ring, their check, their dot, their event block. Never a tint, a wash or a tinted lane.
3. **Ink for everything you press.** No brand accent. Actions are near-black by day and
   near-white at night, in pill shapes.
4. **Calm until it needs you.** What needs a person goes first on Today, under the plain heading
   "Needs you", with an ink icon or their face and one sentence. No amber, no warning colors.
5. **Soft where you rest, firm where you press.** Grouped sections have 20 corners; anything you
   press is a pill; inputs have 14; faces are circles.
6. **Thumb first.** Add, primary buttons and approvals live in the lower part of the screen.
7. **Say it like a person.** Plain verbs, no system nouns, no exclamation marks.
8. **Instant and honest.** Every tap changes the screen in the same frame, works offline, and
   says plainly when something hasn't reached the rest of the family.

## Color

Grays are neutral: R, G and B equal (within 2). No cream, sand, warm gray or brown-tinted text.
Elevation is a step in gray, never a shadow (shadows only on true overlays).

### Light

| Token | Hex | For | Text contrast on bg / card |
| --- | --- | --- | --- |
| `bg` | `#F2F2F2` | The page behind sections; sheets | |
| `card` | `#FFFFFF` | Grouped sections, inputs, unselected chips, secondary buttons | |
| `raised` | `#FFFFFF` | Menus and popovers, with the overlay shadow | |
| `fill` | `#E6E6E6` | Segmented-control track, the selected sidebar item | |
| `line` | `#E0E0E0` | Dividers inside a section, the tab bar's edge, chip outlines on a card | |
| `ink` | `#141414` | Text, icons, primary buttons, selected states, focus ring | 16.5 / 18.4 |
| `ink2` | `#595959` | Secondary text: times, places, counts | 6.3 / 7.0 |
| `ink3` | `#6B6B6B` | Unselected tab labels and quiet text | 4.8 / 5.3 |
| `onPrimary` | `#FFFFFF` | Text and icons on ink | 18.4 on ink |
| `onMarker` | `#141414` | Text and icons on a person's color | 5.4 or better |
| `destructive` | `#BE241F` | Destructive and failed, as text plus icon, never a background | 5.4 / 6.1 |
| `star` / `starEdge` | `#F2B705` / `#8A6200` | The star shape, and nothing else | edge 4.9 / 5.5 |
| `scrim` | black at 48 % | Behind sheets | |
| `handle` | `#C4C4C4` | A sheet's grab handle | |
| `track` | `#E0E0E0` | The empty part of a goal bar | |
| `switchOff` / `knob` | `#D4D4D4` / `#FFFFFF` | A switch that is off | |
| `pictureBg` | `#F0F0F0` | Behind a picture inside its ring | |
| `bar` | `#FFFFFF` | Tab bar, iPad sidebar | |

### Dark: true black for OLED

Designed, not inverted. The page is `#000000` (pixels off); cards are a step up in gray; no
glows; secondary text is checked on both black and the card.

| Token | Hex | Text contrast on bg / card / raised |
| --- | --- | --- |
| `bg` | `#000000` | |
| `card` | `#141414` | |
| `raised` | `#1F1F1F` (with a `line` edge, no shadow) | |
| `fill` | `#242424` | |
| `line` | `#262626` | |
| `ink` | `#F2F2F2` | 18.8 / 16.5 / 14.7 |
| `ink2` | `#A6A6A6` | 8.6 / 7.6 / 6.8 |
| `ink3` | `#8C8C8C` | 6.2 / 5.5 / 4.9 |
| `onPrimary` | `#000000` | 18.8 on ink |
| `onMarker` | `#141414` | 5.4 or better |
| `destructive` | `#F9786A` | 7.9 / 7.0 / 6.2 |
| `star` / `starEdge` | `#FFC83D` / `#FFC83D` | 11.9 on card |
| `scrim` | `#1A1A1A` at 85 %: a black page can't be dimmed, so the page behind a sheet goes flat dark gray and the black sheet stands out | |
| `handle` | `#4A4A4A` | |
| `track` | `#2A2A2A` | |
| `switchOff` / `knob` | `#3A3A3A` / `#F2F2F2` | |
| `pictureBg` | `#262626` | |
| `bar` | `#000000` | |

### Family colors

Eight bright colors, one per person, validated for color-blind separation: the same hex in
light and dark, always with `#141414` text on top. They are assigned in this order; every
neighbor in it passes the color-blind (deltaE 15.9 worst) and normal-vision (deltaE 25.8 worst)
checks in both themes. Never pick one by hand and never add a ninth by eye: run the validator.

| Order | Name | Hex | `#141414` on it |
| --- | --- | --- | --- |
| 1 | Sky | `#339FEE` | 6.4 |
| 2 | Grass | `#4CC157` | 8.0 |
| 3 | Lavender | `#AD87ED` | 6.5 |
| 4 | Tangerine | `#F88B1C` | 7.6 |
| 5 | Aqua | `#10CACA` | 9.1 |
| 6 | Coral | `#F05653` | 5.4 |
| 7 | Sunshine | `#F4CE23` | 12.0 |
| 8 | Bubblegum | `#F075AA` | 6.9 |

In code: `PersonColor` in assignment order (`PersonColor.assignmentOrder` for pickers,
`PersonColor.next(taken)` for a new person). Color is never the only clue: every person also has
their picture or initial and their name, which is why a light color like Sunshine may sit on the
light page without 3:1 against it.

den_core's `Marker` still has the ten old values; until it moves to these names (reading the
old ones as aliases), `context.colors.marker(m)` maps them: blue and sky to Sky, green to Grass,
plum and slate to Lavender, orange to Tangerine, teal to Aqua, brown to Coral, olive to
Sunshine, pink to Bubblegum.

### What may carry color

| Color | Appears on | Never on |
| --- | --- | --- |
| A person's color, at full strength | Their avatar disc or ring, their filled check and check ring, their dot, the solid block of their events (`#141414` text), their goal bar | Text, a tinted card, row or chip, a 10 to 20 % wash, a side stripe, a category |
| `ink` | Text, primary buttons, selected chips and segments, list checks, events for everyone (a solid ink block with the family's dots), focus ring | |
| `destructive` | Destructive and failed: text plus icon | Any background, decoration, counts |
| `star` | The star shape | Anything else |

Done is readable without color: the check mark and the strike-through.

### Old names

Screens written before the redesign still compile through deprecated aliases. Each maps onto a
new value, so old screens already render in the new colors:

| Old | New |
| --- | --- |
| `paper` | `bg` |
| `well` | `card` (inputs, chips), or `fill` for a segmented track |
| `rule` | `line` |
| `onInk` | `onPrimary` |
| `bad` | `destructive` |
| `caution` | `ink`: there is no amber; attention is position, a word and an ink icon |
| `Radii.control` / `card` / `round` | `Radii.input` / `section` / `pill` |
| `Motion` | `DenMotion` |
| `context.type.meta/body/bodyStrong/title/heading/display` | `context.text.meta/body/rowTitle/section/screenTitle/display` |

## Type

**Atkinson Hyperlegible Next** (Braille Institute, SIL OFL), the bundled variable font. Its
letterforms can't be confused (I l 1, 0 O, b d), which serves kids learning to read and older
eyes. One family, two weights: 400 and 700, with 800 only for the one heading on a screen or
sheet. Body text is 17. Figures are tabular, so times and counts line up.

| Role (`context.text.`) | Size | Weight | Line height | For |
| --- | --- | --- | --- | --- |
| `screenTitle` | 30 (34 on iPad) | 800, -0.4 tracking | 1.15 | The one heading: "Good morning", "October" |
| `sheetTitle` | 26 | 800 | 1.2 | A sheet's heading: "Add", "Mia's picture" |
| `section` | 20 | 700 | 1.25 | "Needs you", "Today", "Chores" |
| `rowTitle` | 17 | 700 | 1.25 | The first line of a row |
| `body` | 17 | 400 | 1.35 | Reading text, what people type |
| `label` | 16 | 700 | 1.25 | Buttons, selected chips |
| `control` | 16 | 400 | 1.25 | Unselected chips |
| `meta` | 15 | 400 | 1.35 | A row's second line, counts beside a heading |
| `caption` | 13 | 400 | 1.3 | Names under pictures, day letters |
| `tab` | 11 | 400, 700 selected | 1.2 | Tab bar labels |
| `display` | 44 | 700 | 1.05 | A kid's star total |

- Change a weight with `.bold` or `.regular`, never `copyWith(fontWeight:)` alone: the font is
  variable and its weight axis has to move too.
- Left-aligned. Nothing centered except a single empty-state line or a kid tile.
- The wall display multiplies every size by 1.3 (`DenText(DenType.wallScale)`).
- No semibold, no monospace, no all caps, no look-alike faces.

## Words: scaling and wrapping

- **Text follows the system size** up to 200 % (`DenTextScale` clamps above that, never below
  135 %). Nothing holding text has a fixed height; use a minimum.
- **Actions never squeeze text.** A button sits beside its text only while the text fits on one
  line at the current size; otherwise, and always for "Needs you" rows on phones, it moves under
  the text. Button labels never wrap or truncate.
- **Units stay together**: `keepUnits("3:30 PM at Field 4")` puts non-breaking spaces in
  "3:30 PM" and "Field 4". Time columns are sized for the longest time at the current size
  (`MediaQuery.textScalerOf(context).scale(68)`), and past 135 % the time moves above the title.
- **No orphans**: `noOrphan()` (or `tidy()`, both) joins the last two words of a short line.
- **Truncate only where space is the point**: names, times and what an action affects never
  truncate. Event titles may clamp to two lines on phones; dense iPad week cells use one line
  with an ellipsis and show the full text on tap.
- Copy is written to fit: titles 28 characters or fewer, detail lines 40 or fewer.

## Shape, space and elevation

### Radii follow the object

| `Radii.` | Value | For |
| --- | --- | --- |
| `pill` (a `StadiumBorder`) | full | Buttons, chips, segmented tracks and segments, the Add button, sidebar items |
| `input` | 14 | Text fields, search, the add-item bar |
| `tile` | 16 | Tiles inside a section: the week strip's days, the picker's photo buttons |
| `block` | 18 | A calendar event block (6 where blocks stack) |
| `section` | 20 | Grouped sections |
| `sheet` | 28 | A sheet's top corners; all four on an iPad form sheet |
| circle | | Avatars, check circles, round icon buttons |

Kid tiles use 24. Never a card inside a card, never one radius for everything.

### Spacing and layout

4 pt base (`Sp`: 4, 8, 12, 16, 24, 32, 48). Page gutter 16 on phones (`DenLayout.gutter`);
24 between sections (`sectionGap`); 10 between a section's heading and its card
(`headingGap`); headings sit 4 in from the card's edge (`headingInset`); sections pad 16 at the
sides; rows pad 14 to 16 vertically, divided by `line` inset to the text.

Touch targets (`Targets`): 44 for adults, 72 for kids. The visible part can be smaller inside
the target. 8 between separate targets.

### Elevation

| Level | Light | Dark | For |
| --- | --- | --- | --- |
| 0 | `bg` | `bg` | The page |
| 1 | `card`, no shadow, no border | `card` | Sections, inputs, chips |
| 2 | `raised` with a soft shadow | `raised` with a `line` edge | Menus, popovers |
| 3 | `bg` over the `scrim` | `bg` over the `scrim` | Sheets |

No shadow on anything that scrolls, no shadow stacked with a border and a tint, no glass.

## Layout: phone, iPad, the counter

Breakpoints by available width, not device (`DenLayout.forWidth`, `DenLayoutBuilder`):

| `DenWidth` | Width | Layout |
| --- | --- | --- |
| `compact` | under 700 pt | iPhone, iPad Slide Over: bottom tab bar with Add in the middle, one column |
| `regular` | 700 to 1100 pt | iPad portrait, split view: a 248 pt sidebar with Add at the top and the five sections, up to two content columns |
| `wide` | 1100 pt and up | iPad landscape, Mac, the counter: sidebar plus two columns on Today; Calendar opens on the family week |

- Sheets become centered form sheets at most 560 wide (`DenSheetRoute` does this).
- Text columns never pass 680 (`ReadableWidth`); grids reflow.
- Kid mode tiles: 2, 3 or 4 across (`DenWidth.kidColumns`), 72 pt targets.
- iPad pointer and keyboard: hover shading on rows, context menus with the row's actions,
  shortcuts (⌘N add, ⌘F search, ⌘1 to ⌘5 sections, space checks the focused chore), a visible
  focus ring. Rotation and split view keep the screen and scroll position.
- The counter iPad uses the wide layout at Display scale 1.3 with the family week as home.

## Motion

Physics, not tweens (`app/lib/design/motion.dart`). Nothing else invents a curve.

| Spring | Damping ratio | Response | For |
| --- | --- | --- | --- |
| `DenMotion.ui` | 0.86 | 0.32 s | Press feedback, menus, reordering, inline changes (overshoot under 1 %) |
| `DenMotion.sheet` | 1.0 | 0.38 s | Sheets (no overshoot) |
| `DenMotion.check` | 0.7 | 0.24 s | A check filling, the kids' star landing: one small settle, the only bounce allowed |

- **Interruptible and velocity-aware**: `controller.springTo(target)` starts from the current
  value with the current velocity, so anything can be grabbed mid-flight.
- **Press feedback in the same frame**: `DenPressable` shades the fill 6 % (darker on a light
  fill, lighter on a dark one) on pointer down and springs to a 0.97 scale, back on release; a
  drag past the slop lets go. It also draws the keyboard focus ring and hover shading, and can
  give a selection click (`haptic: true`) for check-off, approve and drop.
- **Sheets**: `showDenSheet` / `DenSheetRoute` follow a drag 1:1 and hand the release velocity
  to the spring; flung down faster than 700 pt/s or dragged past 35 % of its height, it closes,
  otherwise it settles back. A tap outside or the back gesture closes it on the same spring.
- **Inline changes**: `DenReveal` grows and fades a piece in place; `DenCrossfade` swaps one
  state for another ("Nobody is driving Leo" for "You're driving Leo, Undo") with the height
  following on the UI spring.
- **Transform and opacity only**; wrap moving pieces in `RepaintBoundary`; lists insert and
  remove with size and fade so rows never jump.
- **Navigation**: the iOS push with parallax and edge-swipe back on every platform (the theme
  sets it). Tabs switch instantly with state kept. An event row opening its detail uses `Hero`.
- **Reduce Motion** (`MediaQuery.disableAnimations`): every spring becomes a 100 ms opacity
  fade; nothing slides or scales.
- **Never decorative**: no bounce or elastic on chrome, no confetti, shimmer, pulsing or
  looping. Motion only for a state the person caused.
- 120 Hz clean: no frame over 8 ms on iPad Pro and iPhone Pro; no `BackdropFilter`.

## Pictures and avatars

**The picture pack**: 64 original, full-color illustrations (`assets/pictures/<id>.svg`, drawn
with flutter_svg) in eight groups, as the picker shows them: Animals, Critters, Snacks,
Outdoors, Play, Home and adventure, Heroes and jobs, Action and wheels. `DenPictures` lists
them with each one's short picker label ("Melon") and full name ("Watermelon"); call
`DenPictures.load()` early so avatars draw in their first frame. The pictures are identity, never
icons on buttons or headings, and always sit inside the person's ring.

**`DenAvatar`**, the same piece everywhere:

- `DenAvatar.picture(id, color:)`: a solid ring of their color (a 24th of the size, at least 2)
  around `pictureBg`, the picture filling 84 % of the inside.
- `DenAvatar.initial(name, color:)`: the first letter in `#141414` on their color, 45 % of the
  size, bold; it never scales with the text size.
- `DenAvatar.photo(bytes, color:)`: the photo in their ring; a silhouette until it arrives.
- `DenAvatar(member)`: today's model, which has an animal instead of a picture.

Sizes: 26 in face stacks (with a 2 pt ring of the card color between faces), 32 in chips, 40 in
rows, 44 in the Today header, 64 in the picker grid, 68 in a kid's header, 96 in the picker.

**Icons** are one set (Phosphor), in ink, only where people scan for them: tabs, row status,
the few row actions. No icon on a tinted disc, no sparkle for the assistant, no emoji in the
interface.

## Navigation

- **Phone**: a tab bar with Today, Calendar, Add (a 52 pt ink circle in the middle), Chores and
  Lists. Selected tab: ink icon and a bold label; others `ink3`. The bar is `bar` with a `line`
  top edge. Family and settings open from the person's own avatar at the top right of Today.
- **iPad**: the 248 pt sidebar: the family's name, an ink Add pill, then Today, Calendar,
  Chores, Lists and Family (the current one on `fill`, bold), and the person at the bottom.
- Each screen has its large title and at most one icon action. Re-tapping the current tab
  scrolls to the top.

## Components

From the canvas; phase 2 builds them in `app/lib/design/` on the pieces above.

- **Sections**: a heading row (`section`, with a count or a quiet bold `meta` action like
  "Week" on the right) over one `card` with 20 corners. Rows inside are divided by `line`,
  inset to the text. Not every block needs a card; never a card in a card.
- **Rows**: 44 or taller; `rowTitle` plus at most one `meta` line; leading face (40) or check;
  one trailing group (time, faces, stars). A tap anywhere does the row's one thing.
- **"Needs you"**: first on Today and Family. Each row is the person's face (or an ink icon),
  one sentence ("Nobody is driving Leo", "Soccer, 3:30 PM at Field 4") and its action under the
  text on phones ("I'll drive", "Approve"). Done in place: a check, "You're driving Leo at
  3:30 PM" and an underlined Undo.
- **Buttons**: primary is an ink pill, 44 tall, 20 side padding, `label`, one per region.
  Secondary is a `card` pill with a 1.5 `line` edge. Quiet is text only (Undo is underlined).
  Round: Add is a 52 ink circle; More is a 44 `card` circle. Destructive is `destructive` text
  and icon, never a filled red button. Disabled says why next to it.
- **Chips**: chores on Today are 44 pills on the card with a 1.5 `line` edge, a 26 check ring in
  the person's color that fills with a dark check, the title, and stars. Picker categories are
  40 pills: ink when chosen, `card` otherwise. Calendar filters carry a 32 face; chosen gets an
  ink edge and a bold name.
- **Checks**: rings in the owner's color, filled with their color when done, the title in `ink2`
  with a strike-through. List items: ink.
- **Fields**: 52 tall, `card`, 14 corners, `body` 17 (iOS zooms into anything smaller),
  placeholder `ink2`; focused: a 2 pt ink edge. Labels above, never floating.
- **Switches**: on is an ink track with a light thumb; off is `switchOff` with `knob`. The row
  says what on means.
- **Segmented controls**: for views only ("Day, Week, Month"): a `fill` pill track with the
  chosen segment in ink (or `card` on iPad, as the week view has it).
- **Event blocks**: the person's color at full strength with `#141414` text and a line pictogram
  of the kind of event (ball, tooth, music, car); everyone's events are a solid ink block with
  `onPrimary` text and the family's dots. Stacked blocks share 6 corners.
- **Sheets**: `bg` with 28 top corners, a 40 x 5 `handle`, the title and its Done at the top,
  primary action within reach of the thumb. On iPad, a centered form sheet.
- **Empty states**: one sentence in `ink2` and one action, inside the section where content
  would be.
- **Errors**: inline, next to what failed, `destructive` text and icon, naming the cause and the
  way out.
- **Focus** is a 2 pt ink ring with a gap on everything focusable.

### Using the shared pieces

Every screen builds from these (`import 'design/widgets.dart'`, which exports them all). They
take plain values and den_core model types, never the app's state, so any feature can use them.

| Piece | Use it for | Notes |
| --- | --- | --- |
| `DenSection` (+ `SectionCount`, `SectionLink`) | A heading over one grouped card | `carded: false` for a row of fields or chips. Sections sit `DenLayout.sectionGap` apart. A `SectionLink` keeps the heading's height (its tap area reaches 16 pt before the words) so the card stays 10 pt under the heading. |
| `GroupCard`, `RowRule`, `ruled()` | The card itself; hairlines between rows | `RowRule(indent: RowRule.afterFace)` after 40 pt faces. Never a card in a card. |
| `ActionRow` | A row that asks for one thing (Needs you, requests) | Face, bold sentence, detail, one action. The action sits under the words below 360 pt (a phone's card) and past 135 % text, at the end otherwise (an iPad column). |
| `DoneRow`, `DoneSwap` | What a row did, with Undo in place | `DoneSwap(done: …, child: row)` crossfades on the UI spring; pass a receipt's undo as `onUndo`. Never a toast. |
| `InfoRow` | One fact on a detail page (Repeats, Due, Who sees it) | Label in meta beside the value, or over it on a narrow card and at large text. |
| `NavRow` | A row that goes somewhere (menus, "Or add one thing") | Optional glyph or face, label, detail, chevron; 56 tall. |
| `FaceStack` | Who something is for | `DenAvatar`s 26 across, each ringed in the card color. |
| `CheckPill` | A chore (or anything checked off) as a pill | Ring in the person's color. Ring tap checks; label tap opens details (steps, Give to…). `stars: null` when points are off. With steps, the ring fills as an arc and "1 of 4" follows the name once a step is done. |
| `CheckRow`, `CheckRing` | The same as a full-width row (PadToday's chores); the ring alone (a step) | 32 pt ring in a 48 target, whose it is at the end; 60 tall. `CheckRing(progress:)` draws steps as an arc of the person's color: never a digit in a ring (the slashed zero reads as a glitch at that size). |
| `ChipRow` | Chips that may not fit (the lists, people to filter by) | Scrolls sideways edge to edge; the first chip lines up with the page. |
| `ProgressBar` | Progress toward a goal | 8 pt, round ends, the person's color on a quiet track; say the words beside it and in `label`. |
| `MoreOptions` | An editor's rarely used fields | A quiet "More options" row that reveals them; `initiallyOpen` when one is already set. |
| `DayStepper` | Moving a page by days (Chores, a calendar day) | Back, Today (only when it isn't today), forward; the page's heading names the day. |
| `TagChip` | One of a few choices (a category, a kind) | Ink when chosen. |
| `PersonPill` | A person to filter by or pick | 32 pt face; ink edge when chosen. |
| `ValueChip` | One thing Den understood, to adjust (When, Who, Repeats) | `missing: true` asks for it. |
| `DenSegmented` | Views of the same thing ("Week", "Day") | Not for settings; use a switch or a picker. |
| `RoundButton`, `UndoButton` | Add (52 ink), More (44 card); Undo | Buttons otherwise come from the theme: `FilledButton` is the ink pill, `OutlinedButton` the secondary. |
| `InlineAdd` | Adding where the list is (Groceries on Today) | Return adds and keeps the keyboard up. |
| `EmptyState` | Nothing here yet | One line and the one action; `compact` inside a card. |
| `ErrorState` | Something failed | What happened and the way out; red text and icon only. |
| `NoticeLine` | How things stand (offline) | Ink glyph and a plain line, no colored box. |
| `DisabledReason` | A control that can't be used now | Keeps the control and says why under it. |
| `PageHeader` | A screen's title, the date above it, the person's face | 30/800 (`large` on iPad). |
| `DenTabBar`, `DenSidebar`, `NavPlace` | The app's navigation | The shell owns them; screens never draw their own. |
| `showPeoplePicker` | Choosing a person (Give to…, Who?, Who's driving?) | A sheet of faces; `anyoneLabel` adds "Anyone". |
| `showDenSheet` | Every sheet | Springs, drag to close, centered form sheet on iPad. |

Writes from these pieces go through the feature's actions (ARCHITECTURE.md, "The app"); an
action's `ActionResult.receipt` is what Undo takes back.

## Screens (phone)

- **Today**: the date and the greeting for the time of day, the person's face at the right
  (it opens Family, Points, History and Settings); Needs you, for whoever may settle each thing
  (rides in the next 48 hours, reward requests while points are on, late chores from today and
  yesterday, devices and AI connections asking to join, lists due), one action each, which
  turns into what it did with Undo in place; Today's events (time column, title, who and
  whether anyone is driving, faces); from 5 PM, Tomorrow too; Chores by person (face, pills; a
  pill's name opens its steps, Give to… and Details in place); Groceries with the add bar. With
  room for two columns (an iPad in landscape, beside the sidebar), Needs you and the events on
  the left, chores as rows and groceries on the right. Every part draws its empty state with
  the way to start, and Today says when the device can't reach the hub.
- **Add** (one sheet from the tab bar, the sidebar or ⌘N): type or say anything; Den's own
  reader shows what it found as you type, with When, Who and Repeats chips to adjust, and one
  button that says where it goes ("Add to calendar", "Add to Groceries"). What was added stays
  in the sheet with Undo, and Undo brings the words back. Photo of a flyer (a phone's camera),
  a photo or PDF, and on the web Paste (text, or a screenshot) go to the review page. "Or add
  one thing" offers Event, Chore and Grocery item, each only to someone who may.
- **Calendar**: the month as the title and a Today button; a week strip in a card (selected day
  in ink, people's dots); person filters; the day's events as solid blocks by time; on iPad the
  family week (a column per person, a row per day, everyone's events across the row).
- **Chores** (Chores.dc.html): the day with back, Today and forward, and how many are done;
  a section per person with their stars and goal bar in their color (while points are on),
  then their chores in one card. A row's ring checks it (steps fill the ring as an arc); its
  words open it in place (steps, Give to…, Details); "Give to…" at the end hands it on for the
  day, and its old section says so with Undo. iPad: the people in two columns. The editor asks
  only for name, picture, who, when and stars; the rest is under More options.
- **Points and rewards** (no board; built from Chores): requests waiting for a parent with
  Approve and Decline in place, each person's stars and goal bar (tap to give or take),
  the rewards as cards (a kid asks for one, or gets it when it needs no asking, with Undo),
  goals as one kind ("reach 25 stars by Saturday, each week"), and Recent. Points on or off
  lives in Settings, under Family (`PointsSwitch`).
- **Lists** (Lists.dc.html): the lists as chips, pinned first; one add field that reads "2
  milk @Costco, eggs"; groceries grouped by store with store chips; "In the cart" below with
  Clear; adding, removing, clearing and "Add to groceries" (meals) each say what they did in
  place, with Undo. More holds Share, Copy, Reorder, Edit and Delete. iPad: the lists in a
  column beside the chosen one.
- **Family**: Needs you, the people (face, name, who they are), parent controls as switches.
- **Add**: one field that understands a sentence, the kinds as chips, one button naming what it
  will add.
- **Kid**: "Hi, Leo" with their picture, a star card with their goal bar, 2 to 4 big chore tiles.
- **An event**: a solid block in the owner's color with the title (tap to change), then the
  details as rows that open in place.

## Parental oversight

- **One place for waiting things**: "Needs you" at the top of Family (devices asking to join,
  apps asking to connect, rewards asked for, kids' additions to look at, sync trouble), each with
  its one-tap answer and Undo; Today repeats the ones about today.
- **One page per child**: everything about a child is on their page.
- **Presets by age**: "Who is Leo?" sets the starting switches; every switch stays visible.
- **Privacy**: when a parent can't see an item, the calendar shows "Busy" in the owner's color,
  never the title.

## Kid mode

The kid's color and picture in their header; cards with 24 corners; tiles 72 or larger (168 tall
on phones); the whole tile is the button. The star landing is the one celebration: a single
spring scale with a light haptic. Leaving kid mode asks for the parent's PIN, and says whose and
why.

## The web app on iPhone

- `apple-mobile-web-app-title` "Den"; an opaque 180 x 180 `apple-touch-icon`; manifest
  `background_color` and `theme_color` `#F2F2F2` (and `#000000` under dark).
- `html, body` take `bg` of the system appearance until Flutter's first frame; preload the font.
- Safe areas: the title starts below the top inset; the tab bar is its height plus the bottom
  inset; nothing tappable in the inset; sheets pad their bottom by the inset.
- Every editable field is 17 or larger at every text size (iOS zooms into smaller ones).
- `MediaQuery.disableAnimations` must follow Reduce Motion (read `prefers-reduced-motion` if it
  doesn't). Dynamic Type doesn't reach web apps, so the Text size setting lives in Settings.

## Copy

- Verb and object on buttons: "Add event", "I'll drive", "Approve", "Let her in". The
  confirmation uses the same verb.
- Plain words, no system nouns (hub, relay, sync, token, scope, admin) outside Settings,
  Advanced. "Stars", never "points". "Color", not "marker".
- No explainer text under headings, no exclamation marks, no emoji, no "Oops", no invented
  people or numbers. Sentence case, American spelling.
- Never "Unlock", "Supercharge", "Streamline", "Get started", "Learn more".

## Justification ledger

| Element | Encodes | Source |
| --- | --- | --- |
| Eight family colors, full strength | Who something belongs to; nothing else is chromatic | The fridge chart; validated for color-blind separation |
| Dark text on every person color | One rule in both themes, 5.4:1 or better | Palette validation |
| Ink actions, no accent | "You can press this" without competing with people's colors | One meaning per hue |
| Neutral grays, white cards on `#F2F2F2` | Groups visible without lines or shadows | iOS grouped lists; owner: clean light theme |
| True black at night | OLED pixels off, calm at bedtime and on the counter | Owner: true-black OLED theme |
| "Needs you" by position and a word | Attention without alarm colors | Calm until it needs you |
| Red only as text and icon | Destructive and failed, nothing else | Status needs words |
| Star gold | Stars, on the star shape only | Star stickers |
| Pictures in their color's ring | Identity that pre-readers recognize | The picture pack |
| Atkinson Hyperlegible Next at 17 | Legible for early readers and older eyes | Braille Institute; iOS body size |
| Springs, interruptible | Motion that feels physical and never fights the finger | Owner: premium, never jittery |
| Sidebar at 700 pt | A real iPad layout, not a stretched phone | Owner: optimize for iPad |

## Swap test

A generic "family organizer" prompt produces pastel category colors, a purple or teal brand
accent, a rounded geometric face, emoji avatars, every block in an identical shadowed card, an
amber warning box and confetti. Den: color belongs to people only and only at full strength,
there is no accent, the face is chosen for legibility, avatars are original pictures in the
person's ring, radius follows the object and nothing carries a decorative shadow, attention is
a position and a word, and the one celebration is a star landing on a kid's own chart.

## Screenshots

Golden tests are screenshots for review, rendered with the real bundled fonts:
`test/design/gallery_test.dart` draws the foundation the way the canvas does (Today, the type
ramp and controls, the family colors, the picture pack, the picture sheet on phone and iPad,
200 % text) in light and dark, and the tests in `test/screens` draw every screen.

- **One source: CI on Linux.** The images in the repository are the ones the screenshots
  workflow renders. Tests never compare pixels on any machine
  (`app/test/flutter_test_config.dart`): every screen still renders, so overflows and
  exceptions fail, but text rasterizes differently from one platform to the next and a pixel
  diff would mostly measure that.
- **Make them**: label the pull request `screenshots`. On every push while the label is on,
  `.github/workflows/screenshots.yml` runs all the tests with `--update-goldens` and pushes the
  images, and the `pubspec.lock` it resolved, to the branch `screenshots/<branch>`. It pushes
  what rendered even when a test fails, and then fails itself. Once the workflow is on `main`
  it can also be run by hand, for some tests only, or with the app icon and Home Assistant
  brand sources (the tests tagged `golden`).
- **Look at them and bring them in**:

  ```bash
  git fetch origin screenshots/<branch>:refs/remotes/origin/screenshots/<branch>
  git show origin/screenshots/<branch>:app/test/design/goldens/today_phone.png > today_phone.png
  git checkout origin/screenshots/<branch> -- app/test    # then commit
  ```

## Migrating a screen

1. Build it from the canvas with `context.colors`, `context.text`, `Radii`, `DenLayout`,
   `DenMotion`, `DenPressable`, `showDenSheet`, `DenAvatar`.
2. Replace every deprecated name (table under "Old names"). To list what's left, delete the
   `deprecated_member_use_from_same_package` line in `app/analysis_options.yaml` and run
   `flutter analyze`.
3. Golden it in light and dark, at 100 %, 135 % and 200 % text, on phone and iPad widths, and
   check it against the canvas and the [ANTI-SLOP check](docs/design/ANTI-SLOP.md).

When the last screen has moved: remove the aliases and the analyzer line, and migrate den_core's
`Marker` to the eight family colors (and `Animal` to pictures) with read aliases for old data.
