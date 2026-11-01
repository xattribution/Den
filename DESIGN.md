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
| `onMarker` | `#141414` | Text and icons on a person's color | 4.8 or better (5.4 in Bright) |
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
| `onMarker` | `#141414` | 4.8 or better (5.4 in Bright) |
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
light and dark, always with `#141414` text on top. These are the Bright pack, the default; a
family can pick another pack of the same eight places (see "Color packs" below). They are assigned in this order; every
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

den_core's `Marker` names the eight places (sky to bubblegum) and reads the ten older names as
aliases: blue and sky to Sky, green to Grass, plum and slate to Lavender, orange to Tangerine,
teal to Aqua, brown to Coral, olive to Sunshine, pink to Bubblegum.

#### Color packs

The eight colors above are the **Bright** pack. A family can pick another in Settings, Family,
"Family colors" (`family.colors`: `bright`, `deep`, `soft` or `bold`; any parent, through
`update_family_settings`, so MCP and the assistant can set it too). It is the family's setting:
every device in the family draws the same pack, and each person keeps their place, so Mia's
Bubblegum becomes Mia's Raspberry in Deep. Every pack keeps each place's family of hue (blue,
green, purple, orange, aqua, red, yellow, pink), the same hex by day and at night, and `#141414`
text on every color. Only the person colors change: grays, ink, the star and red stay.

| Place | Bright | Deep | Soft | Bold |
| --- | --- | --- | --- | --- |
| 1 | Sky `#339FEE` | Ocean `#2682FF` | Bluebell `#71C8FF` | Blue `#477FFF` |
| 2 | Grass `#4CC157` | Emerald `#009D4F` | Mint `#7CE695` | Green `#30C532` |
| 3 | Lavender `#AD87ED` | Grape `#9D64F6` | Lilac `#C7A8FF` | Purple `#B853FF` |
| 4 | Tangerine `#F88B1C` | Pumpkin `#E97200` | Apricot `#FFB072` | Orange `#FF7902` |
| 5 | Aqua `#10CACA` | Teal `#009EA4` | Lagoon `#5DE9E9` | Turquoise `#06C1EC` |
| 6 | Coral `#F05653` | Cherry `#F33A3F` | Watermelon `#FF8482` | Red `#FF2920` |
| 7 | Sunshine `#F4CE23` | Gold `#ECC906` | Lemon `#FEE657` | Yellow `#F5DA04` |
| 8 | Bubblegum `#F075AA` | Raspberry `#EC3F94` | Blossom `#FA96C3` | Pink `#F33BBF` |

- **Deep** is as dark as dark text allows (4.8 to 6.0:1), so it stays readable without white
  text; its yellow is a clear gold, never amber or mustard.
- **Soft** is light sorbet shades that keep their color (OKLCH chroma 0.11 or more): cheerful,
  never cream, beige or a wash.
- **Bold** is the crayon box: each hue as strong as the screen draws it.

Validated with the data-viz palette validator (`validate_palette.js`), adjacent pairs in
assignment order, in both modes against Den's surfaces (light card `#FFFFFF` and page `#F2F2F2`;
dark card `#141414` and page `#000000`). The same hexes in both modes give the same separations:

| Pack | Worst color-blind neighbors (ΔE, bar 8) | Worst normal-vision neighbors (ΔE, bar 15) | `#141414` on the palest-for-it color | Chroma floor 0.10 |
| --- | --- | --- | --- | --- |
| Bright | 15.9, Coral and Aqua (deutan) | 25.8, Grass and Sky | 5.4, Coral | pass |
| Deep | 15.5, Cherry and Teal (deutan) | 27.6, Teal and Pumpkin | 4.8, Cherry | pass |
| Soft | 14.2, Watermelon and Lagoon (deutan) | 19.1, Mint and Bluebell | 7.7, Watermelon | pass |
| Bold | 23.6, Yellow and Red (deutan) | 32.8, Turquoise and Orange | 4.9, Red | pass |

The validator's lightness band and contrast against the surface are chart rules for lines on a
page: like Bright, the packs sit lighter than that band because they carry dark text, and a
person's color is never the only clue. No 8-color set separates every pair for color-blind
eyes, so the order puts the clearest pairs side by side. `tokens_test.dart` pins the hexes and
checks contrast and neighbor separation with the validator's math.

In code: `ColorPack` (den_core) and its look (`pack.colors`, `pack.of(m)`, tokens.dart).
`context.colors.marker(m)` draws the family's pack: `FamilyColors` (app/family_colors.dart)
puts it over the whole app from the family record, and `PackTheme(pack:)` shows another pack
(the Family colors preview).

### What may carry color

| Color | Appears on | Never on |
| --- | --- | --- |
| A person's color, at full strength | Their avatar disc or ring, their filled check and check ring, their dot, the solid block of their events (`#141414` text), their goal bar, a calendar day they have something on when the month shows days as colors | Text, a tinted card, row or chip, a 10 to 20 % wash, a side stripe, a category |
| A calendar source's color (the family's own calendar, a subscription, a group shared with other families) | Its small source tag (the source's initial in a rounded square) and the outline of its event blocks | Anything a person's color is on: it never takes the place of a person's color on a block, dot, face or day |
| `ink` | Text, primary buttons, selected chips and segments, list checks, events for everyone (a solid ink block with the family's dots), focus ring | |
| `destructive` | Destructive and failed: text plus icon | Any background, decoration, counts |
| `star` | The star shape | Anything else |

Done is readable without color: the check mark and the strike-through.

A calendar source's color is data of its own, apart from people's: `CalendarSource`
(`features/calendar/state/calendar_sources.dart`) has a kind (the family, a subscription, the
phone, a group), a label for its tag and filter chip, and a color, one of the eight places drawn
in the family's pack, null until someone picks one (then its tag is ink). `SourceTag`
(`design/widgets/source_tag.dart`) draws the tag. On a device in several families each family
is a source with a color of this device's (the first family the first place, each next family
the next free one): its tag marks its things in "All my families" and in the switcher, and its
event blocks there are ringed in it, a gap of the page between ring and block, the way a face is
ringed; the block itself stays its people's.

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
  135 %), times the person's own Text size (Settings, Text size: Default, Larger at 20 pt
  body, Largest at 23 pt), which is how a Home Screen web app gets larger words at all. The
  product still stops at 200 %, and every screen is checked there (`text_size_test.dart`). Nothing holding text has a fixed height; use a minimum.
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

Breakpoints by available room, not device (`DenLayout.forWidth`, `DenLayoutBuilder`). The
window as a whole (`DenLayout.of`: the frame, sheets, what Today carries) is also `compact` when
it is under 480 pt tall, whatever its width (`DenLayout.forWindow`):

| `DenWidth` | Window | Layout |
| --- | --- | --- |
| `compact` | under 700 pt wide, or under 480 pt tall | iPhone (on its side too), iPad Slide Over, a folding phone shut, half of a split screen: bottom tab bar with Add in the middle, one column |
| `regular` | 700 to 1100 pt wide | iPad portrait, split view, a folding phone open (Galaxy Z Fold): a 248 pt sidebar with Add at the top and the five sections, up to two content columns |
| `wide` | 1100 pt and up | iPad landscape, Mac, the counter: sidebar plus two columns on Today; Calendar opens on the family week |

- Why 480 tall: every iPhone on its side is 375 to 440 tall and wider than 700, and a 248 pt
  sidebar there runs the person off the bottom. Apple calls that height compact; Material's
  window classes draw the line at 480 too. A folding phone open (about 750 to 840 each way) or a
  short desktop window keeps the sidebar.
- The height that counts is the page's (`DenWindow`, from `WebSafeArea`), which no keyboard
  changes: a keyboard never swaps the sidebar for a tab bar.
- The sidebar never cuts anything off: in a window too short for all of it, the name, Add and
  the places scroll and the person stays at the bottom with a hairline over it; shorter still
  (large text), the person scrolls with the rest.
- On a phone on its side the tab bar's tabs, bottom sheets and pages stay between the safe
  areas (the notch or Dynamic Island at one end, the rounded corners); bottom sheets are at most
  680 wide. Ask opens as a sheet there, not the side panel.
- Sheets become centered form sheets at most 560 wide (`DenSheetRoute` does this).
- Text columns never pass 680 (`ReadableWidth`); grids reflow.
- Kid mode tiles: 2, 3 or 4 across (`DenWidth.kidColumns`), 72 pt targets.
- iPad pointer and keyboard: hover shading on rows, context menus with the row's actions,
  shortcuts (⌘N add, ⌘F search, ⌘K ask, ⌘1 to ⌘5 sections, space checks the focused chore), a visible
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
- **Small state changes** (a check filling, a switch's knob, a caret turning, a goal bar, a
  chip being chosen): `SpringValue` moves a number on a spring from wherever it is, so a second
  tap mid-way turns it around, and crossfades the old look to the new under Reduce Motion.
  Checks use `DenMotion.check`, the rest `DenMotion.ui`. No `AnimatedContainer`, implicit
  curves or Material defaults; pickers and menus are Den sheets (`showChoiceSheet`,
  `showDayPicker`, `showTimeWheel`, `showPeoplePicker`), never Material dialogs or popup menus.
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
  Chores, Lists and Family (the current one on `fill`, bold), and the person at the bottom,
  always in reach (the places scroll above them when the window is short).
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
  3:30 PM" and an underlined Undo. On Today, at most three rows, then a quiet "2 more" that
  opens the rest in place; rows answer by a swipe too (see "Swipe to answer").
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
  `onPrimary` text and the family's dots. Stacked blocks share 6 corners. The pictograms are
  `Pictograms.event(kind)` (Phosphor bold line icons, keys in `Pictograms.events`); the
  calendar reads the kind from the title, then the place, then an imported category
  (`features/calendar/words/event_kinds.dart`). In a person's column (the family week, the
  iPad day) or a list narrowed to one person, the block takes that person's color. In a board
  cell (the iPad week) the title wraps to two lines and the block grows to fit; when it still
  doesn't fit, the time goes, then the pictogram, and only then does it end in an ellipsis,
  between words (`CellFit`). Events combined into one block show their people's faces, never
  a pictogram in a colored disc.
- **Sheets**: `bg` with 28 top corners, a 40 x 5 `handle`, the title and its Done at the top,
  primary action within reach of the thumb. On iPad, a centered form sheet. A route that opens
  as a sheet (`/event/new`, an event on iPad) uses `DenSheetPage` (`design/sheet_page.dart`)
  as its page, so it gets the same route, springs and drag.
- **Empty states**: one sentence in `ink2` and one action, inside the section where content
  would be.
- **Errors**: inline, next to what failed, `destructive` text and icon, naming the cause and the
  way out.
- **Focus** is a 2 pt ink ring with a gap on everything focusable.

### Swipe to answer

On Needs you, a row that asks a yes or no answers by a swipe as well as by its button, the way
Mail and Messages rows do on an iPhone (`SwipeActions`, `ActionRow.onApprove`/`onDecline`):

- **Right is yes** ("Approve": a reward, a device asking to join). It calls exactly what the
  row's Approve button calls, so the same rules decide who may (a device is let in only from a
  parent's own phone).
- **Left is no** ("Decline" a reward, "Turn away" a device), or **"Not now"** on a row with no
  no (a ride, a list due, a grown-up's late chore, an AI connection, a notice): put off on this
  device until tomorrow.
- **The ×**: a small quiet glyph on the title's line does what the swipe left does, for anyone
  who doesn't swipe. Rows whose own buttons already put them away (Got it, Remind me later) get
  the swipe and no ×.
- **Following the finger**: the row moves 1:1 over the card, slowing past 60 % of its width;
  behind it, in ink on the card (never a green or red wash), the glyph and word of what letting
  go would do, bold once it's far enough, with a selection click. Let go past 35 % of the row
  (`DenMotion.dismissFraction`) or flung faster than 700 pt/s and it does that; either way the
  row springs back on the UI spring. Under Reduce Motion it returns at once.
- **Undo, in place**: what a swipe or the × did shows in the row's place (`DoneRow`) with Undo
  for five seconds. A no that would reach someone else or can't be taken back (a declined
  reward, a device turned away) is only sent once those seconds pass, or when Today closes;
  then the row folds away. "Not now" is this device's own and is undone at once.
- **Never the only way** (ANTI-SLOP 19): the button and the × do the same, and screen readers
  get both as actions on the row.

### Using the shared pieces

Every screen builds from these (`import 'design/widgets.dart'`, which exports them all). They
take plain values and den_core model types, never the app's state, so any feature can use them.

| Piece | Use it for | Notes |
| --- | --- | --- |
| `DenSection` (+ `SectionCount`, `SectionLink`) | A heading over one grouped card | `carded: false` for a row of fields or chips. Sections sit `DenLayout.sectionGap` apart. A `SectionLink` keeps the heading's height (its tap area reaches 16 pt before the words) so the card stays 10 pt under the heading. |
| `GroupCard`, `RowRule`, `ruled()` | The card itself; hairlines between rows | `RowRule(indent: RowRule.afterFace)` after 40 pt faces. Never a card in a card. |
| `ActionRow` | A row that asks for one thing (Needs you, requests) | Face, bold sentence, detail, one action. The action sits under the words below 360 pt (a phone's card) and past 135 % text, at the end otherwise (an iPad column). `onApprove` and `onDecline` make it a `SwipeActions` row; `onDecline` is also its × (`declineButton: false` where its buttons already say Got it). |
| `SwipeActions`, `DeclineButton` | Answering a row by a swipe; the small × that says no or not now | See "Swipe to answer". The × is an 18 pt `ink3` glyph in a 44 target on the title's line, never a second big button. |
| `DoneRow`, `DoneSwap` | What a row did, with Undo in place | `DoneSwap(done: …, child: row)` crossfades on the UI spring; pass a receipt's undo as `onUndo`. Never a toast. |
| `InfoRow` | One fact on a detail page (Repeats, Due, Who sees it) | Label in meta beside the value, or over it on a narrow card and at large text. |
| `NavRow` | A row that goes somewhere (menus, "Or add one thing", settings) | Optional glyph or face, label, detail, what it's set to (`value`: "Off"), chevron; 56 tall. |
| `FaceStack` | Who something is for | `DenAvatar`s 26 across, each ringed in the card color. |
| `CheckPill` | A chore (or anything checked off) as a pill | Ring in the person's color. Ring tap checks; label tap opens details (steps, Give to…). `stars: null` when points are off. With steps, the ring fills as an arc and "1 of 4" follows the name once a step is done. |
| `CheckRow`, `CheckRing` | The same as a full-width row (PadToday's chores); the ring alone (a step) | 32 pt ring in a 48 target, whose it is at the end; 60 tall. `CheckRing(progress:)` draws steps as an arc of the person's color: never a digit in a ring (the slashed zero reads as a glitch at that size). |
| `ChipRow` | Chips that may not fit (the lists, people to filter by) | Scrolls sideways edge to edge; the first chip lines up with the page. |
| `ProgressBar` | Progress toward a goal | 8 pt, round ends, the person's color on a quiet track; say the words beside it and in `label`. |
| `MoreOptions` | An editor's rarely used fields | A quiet "More options" row that reveals them; `initiallyOpen` when one is already set. Its words line up with the labels above. |
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
| `DenPage`, `Ungapped`, `PageBackButton` | A page pushed over the app (Family, Settings, a setup step) | Round back button and the 30/800 title, sections `sectionGap` apart at a readable width, `bottom` for the one primary button within reach of the thumb. Wrap a child that may draw nothing in `Ungapped` and give it its own bottom gap. |
| `SheetHeader` | A sheet's title and the pill that closes it | "Close" on the card color; `primary` ("Done" on a picture) in ink. |
| `SwitchLine` | A setting said as a sentence ("Can add to lists") | Detail line under it, the switch at the end, the whole row flips it, 64 tall. `onChanged: null` with a `reason` keeps it visible and says why it can't change. |
| `DenSwitch` | The switch itself | 52 by 32 with nothing around it, so it lines up with the gutter; 44 tall to tap; the knob springs. Never Material's `Switch`. |
| `BarAction` | An editor's one top-bar action ("Add chore", "Save list", "Edit") | Ends on the 16 pt gutter like the cards below (`quiet` for a text button, whose words line up). |
| `showChoiceSheet`, `showDayPicker`, `showTimeWheel` | Picking one of a few, a day, a time of day | Den sheets: a checked list, a month calendar with Done, the iPhone time wheel with Done. |
| `ChoiceRows`, `Choice` | A setting with a few answers (Day, Night, Auto) | Rows in a section's card, an ink check before the chosen one. Not for views (`DenSegmented`), not for on and off (`SwitchLine`). |
| `LabeledField` | A text field with its label | The label above in meta ink2, never floating inside; an error under it in red text with its icon. |
| `NumberedSteps` | Steps to follow in another app (a connector, a Shortcut) | Bold numbers in their own column, reading text beside them; a step may be a widget (an address to copy). |
| `DenTabBar`, `DenSidebar`, `NavPlace` | The app's navigation | The shell owns them; screens never draw their own. |
| `showPeoplePicker` | Choosing a person (Give to…, Who?, Who's driving?) | A sheet of faces; `anyoneLabel` adds "Anyone". |
| `showDenSheet` | Every sheet | Springs, drag to close, centered form sheet on iPad. A sheet opened from a part drawn in another theme (the calendar kept light) takes that theme, scrim and all; `DenSheetRoute(theme:)` and `DenSheetPage(theme:)` say it outright. |
| `DayTheme`, `PackTheme` | Part of the app in the day tokens whatever the app's theme (the calendar kept light); people in another pack (a pack's preview) | Each theme is made once, so nothing animates or rebuilds for nothing. |
| `SpringValue` | A small state change that moves | See Motion, "Small state changes". |

Writes from these pieces go through the feature's actions (ARCHITECTURE.md, "The app"); an
action's `ActionResult.receipt` is what Undo takes back. A screen keeps what a tap did as a
`Done` (`app/actions.dart`: the words, "Gave Maya 5 stars", and that receipt) in the place the
tap happened, and shows it in a `DoneRow`.

## Screens (phone)

- **Several families** (a device in two or more): the family showing heads Today on a phone,
  "Kotvas ▾" with its tag, above the date; on iPad it is the sidebar's title. It opens the
  switcher, a sheet: each family with three faces, how many people, a dot when it has something
  in Needs you and a check on the one showing; "All my families"; Paste an invite. "All my
  families" heads each family's Needs you with its name ("Smith family needs you"), lists every
  family's events in one card by time with their tags, and says Chores and stars stay with each
  family. Someone in one family sees none of it, except Settings' **Join another family**.
- **Today**: the date and the greeting for the time of day, the person's face at the right
  (it opens Family, Invite someone, Stars and rewards and Settings; Search is the glass beside
  it); "Ask about your day" while the AI helper is on
  for them (see "AI helper"); Needs you, for whoever may settle each thing, most pressing first
  (rides in the next 48 hours, soonest first; then whoever waits on an answer now: a device
  asking to join, a reward request while points are on; lists due; a grown-up's or anyone's
  late chores from today and yesterday, never a kid's (they stay late on Chores); AI
  connections asking to connect; then notices that only need "Got it"), three at most and "2
  more" for the rest, one action each, which turns into what it did with Undo in place, and a
  swipe or a small × for no or not now; Today's events (time column, title, who and
  whether anyone is driving, faces); from 5 PM, Tomorrow too; Chores by person (face, pills; a
  pill's name opens its steps, Give to… and Details in place); Groceries with the add bar. With
  room for two columns (an iPad in landscape, beside the sidebar), Needs you and the events on
  the left, chores as rows and groceries on the right. Every part draws its empty state with
  the way to start, and Today says when the device can't reach the hub.
- **Add** (one sheet from the tab bar, the sidebar or ⌘N): the field has the focus and the
  keyboard is up as it opens (on the web, `den_web.js` raises it inside the tap, the only time
  iOS allows it); type or say anything; Den's own
  reader shows what it found as you type, with When, Who and Repeats chips to adjust, and one
  button that says where it goes ("Add to calendar", "Add to Groceries"). What was added stays
  in the sheet with Undo, and Undo brings the words back. Photo of a flyer (a phone's camera),
  a photo or PDF, and on the web Paste (text, or a screenshot) go to the review page. "Or add
  one thing" offers Event, Chore and Grocery item, each only to someone who may. With the AI
  helper on for the person, the field reads "Add or ask anything" (see "AI helper").
- **Calendar**: the month as the title and a Today button; a week strip in a card (selected day
  in ink, people's dots); person filters; the day's events as solid blocks by time; on iPad the
  family week (a column per person, a row per day, everyone's events across the row).
  - **Show days as: Dots or Colors** (the month's view options, a 44 card circle beside the
    views, and Settings, Appearance; kept on the device; Dots by default). With Colors, a day of
    the month someone has something on is their color at full strength with `#141414` numbers;
    two or three people split it into equal side-by-side parts, like the paper organizer's
    columns; four or more show the first two and "+2" in dark ink. A day with something for
    everyone is ink with the family's dots, as their events are. The chosen day keeps an ink ring
    with a gap of the card's color, and today's number sits in a disc (ink, or the page color on
    an ink day), as on the iPad month. Days of the months around keep their dots, so the month's
    edge stays plain. On iPad each day of the month is its colors and its events are lines of dark
    ink on them (light on an ink day). Screen readers hear who: "Saturday, October 24, Alex,
    Maya, Leo and Zoe".
  - **Calendar: Match the app or Always light** (Settings, Appearance; kept on the device; Match
    the app by default). Always light draws the calendar's content (list, day, week, month, the
    event page and the sheets opened from it) in the day tokens on a light panel with 20 corners
    set into the app's frame, while the tab bar, the sidebar, the status bar's strip, the safe
    areas and the other screens follow the app. `CalendarSurface` scopes a `DayTheme` around the
    calendar; nothing is forked. The panel doesn't depend on the app's brightness, so it never
    flashes when Auto turns to night, and pages opened from it carry `from=calendar`.
- **Chores** (Chores.dc.html): the day with back, Today and forward, and how many are done;
  a section per person with their stars and goal bar in their color (while points are on),
  then their chores in one card. A row's ring checks it (steps fill the ring as an arc); its
  words open it in place (steps, Give to…, Details), and nothing else sits on the row; "Give
  to…" there hands it on for the day, and its old section says so with Undo. iPad: the people in two columns. The editor asks
  only for name, picture, who, when and stars; the rest is under More options.
- **Stars and rewards** (no board; built from Chores): requests waiting for a parent with
  Approve and Decline in place, each person's stars and goal bar (tap to give or take),
  the rewards as cards (a kid asks for one, or gets it when it needs no asking, with Undo),
  goals as one kind ("reach 25 stars by Saturday, each week"), and Recent. Points on or off
  lives in Settings, under Family (`PointsSwitch`).
- **Lists** (Lists.dc.html): the lists as chips, pinned first; one add field that reads "2
  milk @Costco, eggs", with where new things go as a store chip in it ("Costco ▾", "Any
  store ▾": the store showing, or as picked from a short card of stores and New store…; it
  stays for the next things, and "@Costco" moves it); groceries grouped by store with store
  chips. A tap crosses an item off where it is (filled ring, struck in ink) and another tap
  there takes it back: nothing moves while the list is open. "Clear checked (3)" floats at the
  bottom end once something is checked and turns into what it did, with Undo. Adding,
  removing and "Add to groceries" (meals) each say what they did in place, with Undo. More
  holds Share, Copy, Reorder, Edit and Delete. iPad: the lists in a column beside the chosen
  one. Today's Groceries add the same way.
- **Family**: Needs you, the people (face, name, who they are), parent controls as switches.
- **Settings** fits one iPhone screen: rows that say what each is set to (Family, Calendars,
  Kitchen screen, AI helper, and on a parent's own phone the Google or Apple sign-in;
  Appearance and Text size), the reminders switch, Advanced and About. A choice made once lives
  a tap deeper: Appearance (Day, Night, Auto, Soft with the preview; how the calendar looks),
  Text size (a short sheet: one tap picks and closes), About (version, build, licenses; a hub
  serving a newer Den says so on the About row), Family's colors and first day of the week.
  The hub, assistants, Home Assistant, data and screen info stay in Advanced.
- **Add**: one field that understands a sentence, the kinds as chips, one button naming what it
  will add.
- **Kid**: "Hi, Leo" with their picture, a star card with their goal bar, 2 to 4 big chore tiles.
- **An event**: a solid block in the owner's color with the title (tap to change), then the
  details as rows that open in place.

## AI helper

Optional, and off until a parent turns it on (Settings, AI helper). It is a word ("Ask") and a
speech bubble, never a sparkle, a wand or a glow. It is not a tab of its own: the phone's tab bar
keeps its four places and Add (`features/assistant`).

- **Who sees it.** Parents once it's on, and each other person a parent switches on (never a
  little kid or a pre-reader). Never on a wall display or a shared screen, and never without a
  family hub, which runs it and keeps the key. The rule is `askEntry`.
- **Ways in**, each only for someone it's on for: a wide pill under Today's greeting ("Ask about
  your day", on the card color, 52 tall); "Ask" in the iPad sidebar after Search; "Open Ask" in
  Add under "Or add one thing" (Add's round button is on every phone tab); ⌘K (Ctrl+K) with a
  keyboard, the field ready to type. While it's off, a parent gets one quiet row at the end of
  Today ("Ask in your own words", "Set up the AI helper in Settings", and a quiet "Not now" that
  puts it away for them on that device), only in the family's first three weeks; ⌘K opens Ask
  saying what it does, with "Set up the helper"; nobody else sees anything, and ⌘K stays the browser's.
- **An empty chat** greets the person ("Hi Alex. What can I help with?") with what can be asked
  and three or four chips from the family's own day: what's on today (tomorrow from 5 PM), who's
  driving to the next event with a ride to sort out, "Add milk to Costco" (the store most of the
  groceries are for), who still has chores. A question chip asks at once; a change chip only
  fills the field, its example word chosen, so a chip never changes anything. A kid gets their
  chores, their stars and their own rides. A kid whose questions for the day are used up, or a
  spent budget, gets those words in place of the chips and the field: never a dead button.
- **Add or ask.** The field reads "Add or ask anything" ("Ask anything" for someone who may ask
  but not add). The rule, in this order:
  1. A **question** goes to the helper: it ends with a question mark, or starts with a question
     word (what, when, where, who, which, why, how, is, are, can, will, does, did, "do we", tell,
     show, find, plan...).
  2. A **change to something already there** goes to the helper: any part of it starts with
     move, reschedule, postpone, push, cancel, delete, remove, rename, swap, give, mark, undo,
     uncheck, approve or decline ("add milk and move soccer to 6").
  3. Otherwise **Den's own reader** takes it as it does today: when it finds something
     ("milk", "Soccer Wednesday at 5 for Leo"), its chips show and Add adds at once, with Undo,
     and a quiet "Ask instead" under the button. When it finds nothing, it's the helper's.
  Photos, PDFs and pastes still go to the review page. The rule is `addOrAsk`
  (`features/assistant/words`); a word on the list that also starts a chore ("Give the dog his
  pill") reaches the helper, which can add it too.
- **Answers** open in Ask: a sheet on phones, a panel at the right edge from 840 pt with the page
  behind in view (an iPad turning keeps the conversation). What was asked, quietly, beside the
  person's face; the answer in plain sentences; then each change as a row: a filled check in the
  person's color, what it did ("Moved Dentist to 4:00 PM Tue") and Undo in place. Taken back, the
  ring empties and the row says "Took back: ...". "Undo that" takes back the newest change still
  in place, without asking the helper.
- **Do it / Not now.** A change that needs a tap (someone else's things, a whole series, a
  removal) shows first as a card on the card color: the question ("Remove the chore Feed the
  cat?"), what it would change from the preview on a fork ("Removes Feed the cat"), any warning
  with an ink icon, and "Do it" (ink) and "Not now". Nothing changes before the tap; a spoken yes
  doesn't count.
- **Limits and outages, plainly.** A limit a parent set is a line with an ink icon: "That's 20
  questions today. Ask a parent for more.", "The family's AI budget is used up for October."
  Off or not set up says who can change it. A hub or a company that doesn't answer is red text
  and icon with Try again ("Claude can't be reached right now. Try again in a few minutes.").
  "Asking Claude" fades in only after a second and gives way to the answer; nothing pulses.
- **Kids** a parent turned it on for get 72 pt buttons and chips, "Read it to me" (the kids' app's
  read-aloud), simpler words and only the tools they may use.
- **One conversation, in memory only.** The device keeps the conversation while the app runs:
  Ask closed and opened again shows it, and Add's words go on from it. "New chat" (beside Done)
  starts over; so does someone else using the device, or 3 hours untouched, or a new day. It is
  never written to the device or the family's log. Closing Ask stops a turn still running from
  changing anything more ("Stopped when Ask closed. Nothing more changed.", with Ask again). What
  it changed shows in History as "from the assistant (Claude)", like any other change.

## Parental oversight

- **One place for waiting things**: "Needs you" at the top of Family (devices asking to join,
  apps asking to connect, rewards asked for, kids' additions to look at, sync trouble), each with
  its one-tap answer and Undo; Today repeats the ones about today.
- **One page per child**: everything about a child is on their page.
- **Presets by age**: "Who is Leo?" sets the starting switches; every switch stays visible.
- **Privacy**: when a parent can't see an item, the calendar shows "Busy" in the owner's color,
  never the title.
- **Telling them**: when a parent changes a teen's privacy, the teen's Today says who and what
  in Needs you ("Mom changed this: parents can now see things you mark Just me") with Got it;
  the confirm card says first what can't be undone ("What you already saw can't be unseen").
- **A sitter's last day** is a row on their page ("Has Den: Until Sunday"); once it passes,
  Needs you says "Sam's access ended Sunday" with Got it, and the sitter's own app says so.

## Kid mode

The kid's color and picture in their header; cards with 24 corners; tiles 72 or larger (168 tall
on phones); the whole tile is the button. The star landing is the one celebration: a single
spring scale with a light haptic. Leaving kid mode asks for the parent's PIN, and says whose and
why.

## The web app on iPhone, iPad and Android

- `apple-mobile-web-app-title` "Den"; an opaque 180 x 180 `apple-touch-icon`; manifest
  `background_color` and `theme_color` `#F2F2F2` (and `#000000` under dark).
- `html, body` take `bg` of the system appearance until Flutter's first frame; preload the font.
- Safe areas: the title starts below the top inset; the tab bar is its height plus the bottom
  inset; nothing tappable in the inset; sheets pad their bottom by the inset.
- Every editable field is 17 or larger at every text size (iOS zooms into smaller ones).
- The page never scrolls: `html` and `body` are pinned to the screen (`index.html`), the
  engine takes every touch (`touch-action: none`), so the browser never scrolls, refreshes or
  hides its bars under the app, and `den_web.js` puts the page back at the top whenever the
  browser moves it for the keyboard, then has Flutter measure again.
- A keyboard closed with its own button (Android's down arrow on the keyboard or the navigation
  bar, an iPad's close key) ends the editing as Return would: the field lets go, what was typed
  stays, and a tap on the field brings the keyboard back. Nothing stays lifted or drawn short
  (`den_web.js` explains how Flutter 3.38.5 got that wrong on Android). On iOS the keyboard's
  height comes from the page (`WebSafeArea`). A sheet rises over the keyboard once; what's
  inside it lays out as if there were none.
- Settings, Advanced, Show screen info draws the screen's numbers and the last few viewport
  events over the app, for a screenshot when something looks wrong; Settings, About says which
  build this is and which the hub serves.
- Getting in: [onboarding](docs/design/onboarding.md). A link opens the step it is for; Safari
  shows the Home Screen steps with a picture of where Share is, and "Already have Den on this
  iPhone? Copy invite" as one quiet line under the heading; the
  welcome screen has Paste an invite.
- `MediaQuery.disableAnimations` must follow Reduce Motion (read `prefers-reduced-motion` if it
  doesn't). Dynamic Type doesn't reach web apps, so the Text size setting lives in Settings.

## Copy

- Verb and object on buttons: "Add event", "I'll drive", "Approve". Letting a device in is
  "Approve" everywhere (Today and Family). The confirmation uses the same verb.
- Plain words, no system nouns (hub, relay, sync, token, scope, admin) outside Settings,
  Advanced. "Stars", never "points". "Color", not "marker".
- No explainer text under headings, no exclamation marks, no emoji, no "Oops", no invented
  people or numbers. Sentence case, American spelling.
- Never "Unlock", "Supercharge", "Streamline", "Get started", "Learn more".

## Justification ledger

| Element | Encodes | Source |
| --- | --- | --- |
| Eight family colors, full strength | Who something belongs to; nothing else is chromatic | The fridge chart; validated for color-blind separation |
| Color packs (Bright, Deep, Soft, Bold), one per family | The same people in shades the family likes; a person keeps their place | Owner: "a couple more color schemes", cheerful, never muted or earthy |
| Days as colors in the month | Who is busy which day, at a glance, across a room | Owner: "whole day highlighted, not just dots" |
| The calendar kept light | Paper-like reading of the busiest screen at night, chrome still dark | Owner: "not everything has to be dark" |
| Dark text on every person color | One rule in both themes and every pack, 4.8:1 or better | Palette validation |
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

- **Rendered on Linux, with the real fonts.** Tests never compare pixels on any machine
  (`app/test/flutter_test_config.dart`): every screen still renders, so overflows and
  exceptions fail, but text rasterizes differently from one platform to the next and a pixel
  diff would mostly measure that. Render the committed images on Linux (or in a Linux
  container) so they stay consistent.
- **Make them**: `cd app && flutter test --update-goldens [test files]`, look at the images that
  changed, and commit them. `tool/local_ci.sh` runs the rest of the checks.
- **Or on GitHub, by hand**: the screenshots workflow (Actions tab, "Run workflow") renders all
  tests, some tests, or the app icon and Home Assistant brand sources (the tests tagged
  `golden`), and pushes the images to the branch `screenshots/<branch>`:

  ```bash
  git fetch origin screenshots/<branch>:refs/remotes/origin/screenshots/<branch>
  git checkout origin/screenshots/<branch> -- app/test    # then commit
  ```

  It's manual only, because Actions minutes cost money on a private repository.

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
