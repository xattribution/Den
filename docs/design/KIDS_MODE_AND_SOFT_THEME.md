# Kids mode and the Soft theme

Status: proposal for Jared, 2026-10-29. Base `family-ready` @ 7248c3c868. Nothing in `app/` is changed by this doc.

## The direction in one paragraph

Den stays an Apple-clean app: neutral or cool grounds, navy ink for anything you press, one heading per screen, no decoration that isn't information. Kids mode adds the toy-box layer on top of that: chunky tiles with a solid colored lip under them (the look of a molded plastic button you push down), a fat colored disc per job holding a navy pictogram, and one big star that lands with a spring. Color is loud only where a kid acts. The family Soft theme is the same app with its grays swapped for baby-blue tints and its ink swapped for navy. Nothing warm: no cream, tan, sand or brown in either theme, light or dark.

What "Fisher-Price" means here, concretely: thick rounded shapes (24 to 32 radius), a 6 dp solid lip instead of shadows, primaries that read from across a kitchen, and a press that physically sinks the tile onto its lip. It does not mean gradients, glossy plastic shading, mascots or confetti everywhere.

## What the current code already does (read first)

- Tokens: `DenColors` with `day` and `night` at `app/lib/design/tokens.dart:142` and `:168`. Neutral grays, ink for actions; the only chroma is people, the star and destructive red (`tokens.dart:6-8`, `DESIGN.md:54-57`, `docs/design/ANTI-SLOP.md:8-37`).
- Family color packs including an existing `soft` pack (Bluebell `#71C8FF`, Mint, Lilac, Apricot...) at `tokens.dart:332-341`; pack switching via `DenColors.withPack` `tokens.dart:200` and `PackTheme` `app/lib/design/day_theme.dart:34`.
- Theme choice is `enum ThemeChoice { auto, day, night }` at `app/lib/app/app_state.dart:22`, wired at `app/lib/app/den_app.dart:143-149`.
- Spacing `Sp` `tokens.dart:392`, radii `Radii` `tokens.dart:404`, touch targets `Targets.kid = 72` `tokens.dart:448-451`, type `DenText` `tokens.dart:506` (Atkinson Hyperlegible Next, `tokens.dart:461`), wall type scale 1.3 `tokens.dart:462`, applied at `den_app.dart:130`.
- Motion springs `DenMotion.ui/sheet/check` `app/lib/design/motion.dart:12-37`; press feedback `DenPressable` `motion.dart:112`.
- Kid view: `KidHome` `app/lib/features/shared_screens/screens/kid_home.dart:27`; `kidRadius = 24` `kid_home.dart:20`; star card `_StarCard` `:180`; job grid `_Grid` `:259`; job tile `_JobTile` `:284` (168 min height `:314`, done tile filled in the kid's color `:310`); "Read my jobs to me" `:61-67`; columns from `DenWidth.kidColumns` `app/lib/design/layout.dart:31`.
- Wall display: `WallScreen` `app/lib/features/shared_screens/screens/wall_screen.dart:25`; side strip at width >= 1500 `:98`, header + divider + week/today board `:108-140`.
- Kid mode rules today: `DESIGN.md:665-670` (one celebration: the star landing, a single spring with a light haptic).

The existing rules are good and this spec keeps them. One is deliberately bent, and only inside an opt-in surface (flagged as a decision for Jared at the end):
1. "No brand accent" (`ANTI-SLOP.md:30`): kids mode gets six soft primaries for job discs on a kid's own board.

"Dark is true black" (`ANTI-SLOP.md:32`) is kept: this spec first proposed navy-black `#060D16` for Soft dark, and Jared chose true black `#000000` (2026-10-30). It is one token (`DenColors.softNightGround`), with the cards still stepping up in navy.

## Tokens

All hex values below are checked by `tool/design/contrast.py` (WCAG 2.2 relative luminance). Run it after any change.

### Soft theme, mapped onto existing `DenColors` names

| Token | Soft light | Soft dark | Note |
|---|---|---|---|
| `bg` | `#EEF5FC` | `#000000` | Baby-blue tint page / true black page (`softNightGround`) |
| `card` | `#FFFFFF` | `#111F30` | Sections, inputs |
| `raised` | `#FFFFFF` | `#192B40` | Menus (dark: `line` edge, no shadow) |
| `fill` | `#DCEBF8` | `#192B40` | Segmented track, hover |
| `line` | `#D3E0EE` | `#22364E` | Hairlines |
| `ink` | `#0F2338` | `#EAF3FC` | Navy ink: text and primary fill |
| `ink2` | `#45596E` | `#A8BCD1` | Secondary text |
| `ink3` | `#55697F` | `#8DA3BA` | Quiet text, unselected tabs |
| `onPrimary` | `#FFFFFF` | `#000000` | `softNightGround` |
| `onMarker` | `#071426` | `#071426` | Deep navy on every person color: 4.8:1 on every color of every pack (Soft's ink `#0F2338` falls to 4.16:1 on Deep's Cherry, and a Soft family can still pick Deep or Bold) |
| `destructive` | `#B8231C` | `#FF8A7E` | Text + icon only |
| `star` | `#FFC83D` | `#FFC83D` | |
| `starEdge` | `#1F3B57` | `#FFC83D` | Navy edge replaces the old `#8A6200` (that one reads brown) |
| `scrim` | `#7A0F2338` | `#D9152536` | Navy-tinted, not gray; at night a flat navy between card and raised, so the black sheet stands out (as Night does) |
| `handle` | `#B9CADC` | `#3A5270` | |
| `track` | `#D3E0EE` | `#22364E` | |
| `switchOff` | `#C6D5E5` | `#2E4560` | |
| `knob` | `#FFFFFF` | `#EAF3FC` | |
| `pictureBg` | `#E3EFFA` | `#192B40` | |
| `photoBg` | `#CFDDEB` | `#2E4560` | |
| `photoFg` | `#94A9BF` | `#8DA3BA` | |
| `bar` | `#FFFFFF` | `#000000` | `softNightGround` |
| selected day / today (new: `selection`) | `#A9D4F5` baby blue | `#1E4A73` | The one place baby blue is a fill |
| text on it (new: `onSelection`) | `#0F2338` | `#EAF3FC` | Ink |

Day and Night set `selection` to ink and `onSelection` to `onPrimary`, which is how the week strip draws the chosen day today, so they look exactly as before. (This spec first said `fill` for them; that would have turned Day's chosen day into a light gray at 1.2:1 against its card.)

Soft defaults the family pack to `ColorPack.soft` (`tokens.dart:332`) but the family can still pick any pack. Dark is designed: true black with surfaces stepping up in navy (`#000000` → `#111F30` → `#192B40`), secondary text is re-picked for the navy card, the star edge drops away because gold on black already passes, and the "everyone" event block flips to a light ink block rather than a dimmed one.

### Kids mode tokens (new `KidColors` extension)

| Name | Face | Lip (decorative) | Navy text on face |
|---|---|---|---|
| sky | `#4FB4F7` | `#2C8FD6` | 6.98:1 |
| leaf | `#4CC968` | `#2FA34C` | 7.48:1 |
| sun | `#FFD23F` | `#E8B400` | 11.04:1 |
| tangerine | `#FF9B3F` | `#E87A1C` | 7.60:1 |
| berry | `#FF6F7D` | `#E04A5C` | 5.94:1 |
| bubble | `#F58BC0` | `#D9619E` | 7.08:1 |

Rules: text and pictograms on a face are always navy `#0F2338`. A lip never carries text. On a kid's own board the disc color is chosen per job from this set (stable per job, hashed; as built the key is the job's title, so it also holds across devices and screenshots, and a job that would match the one beside or above it takes the next color), and a done tile always fills with the kid's person color so "my color = done" holds. On the wall, where several kids share one screen, discs use the person's color only (the "a hue means a person" rule in `DESIGN.md:40-41` is kept where it matters).

Todo ring (unchecked circle, non-text 3:1): `#7F96AE` on white 3.05:1; `#5F7894` on `#111F30` 3.64:1. In Day and Night: `#8C8C8C` on white 3.36:1; `#6B6B6B` on `#141414` 3.46:1.

A done tile's face is a person's color, so its text and check are that theme's `onMarker`, not the kid navy, and its lip is the face darkened (lightness −0.13, saturation ×0.8, which is how the six lips above sit under their faces).

### Contrast results (from `python3 tool/design/contrast.py`)

| Theme | Foreground | Background | Ratio | Need | Pass |
|---|---|---|---|---|---|
| soft-light | ink `#0F2338` | bg `#EEF5FC` | 14.50:1 | 4.5:1 | yes |
| soft-light | ink `#0F2338` | card `#FFFFFF` | 15.94:1 | 4.5:1 | yes |
| soft-light | ink2 `#45596E` | bg `#EEF5FC` | 6.57:1 | 4.5:1 | yes |
| soft-light | ink2 `#45596E` | card `#FFFFFF` | 7.22:1 | 4.5:1 | yes |
| soft-light | ink3 `#55697F` | bg `#EEF5FC` | 5.14:1 | 4.5:1 | yes |
| soft-light | ink3 `#55697F` | fill `#DCEBF8` | 4.65:1 | 4.5:1 | yes |
| soft-light | onPrimary `#FFFFFF` | primary(ink) `#0F2338` | 15.94:1 | 4.5:1 | yes |
| soft-light | destructive `#B8231C` | card `#FFFFFF` | 6.37:1 | 4.5:1 | yes |
| soft-light | destructive `#B8231C` | bg `#EEF5FC` | 5.80:1 | 4.5:1 | yes |
| soft-light | starEdge `#1F3B57` | bg `#EEF5FC` | 10.49:1 | 3.0:1 | yes |
| soft-light | ink `#0F2338` | babyBlue `#A9D4F5` | 10.19:1 | 4.5:1 | yes |
| soft-dark | ink `#EAF3FC` | bg `#000000` | 18.72:1 | 4.5:1 | yes |
| soft-dark | ink `#EAF3FC` | card `#111F30` | 14.83:1 | 4.5:1 | yes |
| soft-dark | ink2 `#A8BCD1` | bg `#000000` | 10.78:1 | 4.5:1 | yes |
| soft-dark | ink2 `#A8BCD1` | card `#111F30` | 8.54:1 | 4.5:1 | yes |
| soft-dark | ink3 `#8DA3BA` | card `#111F30` | 6.40:1 | 4.5:1 | yes |
| soft-dark | ink3 `#8DA3BA` | raised `#192B40` | 5.53:1 | 4.5:1 | yes |
| soft-dark | onPrimary `#000000` | primary(ink) `#EAF3FC` | 18.72:1 | 4.5:1 | yes |
| soft-dark | destructive `#FF8A7E` | card `#111F30` | 7.28:1 | 4.5:1 | yes |
| soft-dark | star `#FFC83D` | bg `#000000` | 13.58:1 | 3.0:1 | yes |
| soft-dark | ink `#EAF3FC` | babyBlueDeep `#1E4A73` | 8.20:1 | 4.5:1 | yes |
| soft-dark | ink3 `#8DA3BA` | bg `#000000` | 8.08:1 | 4.5:1 | yes |
| soft-dark | destructive `#FF8A7E` | bg `#000000` | 9.19:1 | 4.5:1 | yes |
| soft-dark | destructive `#FF8A7E` | raised `#192B40` | 6.29:1 | 4.5:1 | yes |
| kid | onMarker `#0F2338` | sky `#4FB4F7` | 6.98:1 | 4.5:1 | yes |
| kid | onMarker `#0F2338` | leaf `#4CC968` | 7.48:1 | 4.5:1 | yes |
| kid | onMarker `#0F2338` | sun `#FFD23F` | 11.04:1 | 4.5:1 | yes |
| kid | onMarker `#0F2338` | tangerine `#FF9B3F` | 7.60:1 | 4.5:1 | yes |
| kid | onMarker `#0F2338` | berry `#FF6F7D` | 5.94:1 | 4.5:1 | yes |
| kid | onMarker `#0F2338` | bubble `#F58BC0` | 7.08:1 | 4.5:1 | yes |
| kid | todo ring `#7F96AE` | card `#FFFFFF` | 3.05:1 | 3.0:1 | yes |
| kid | todo ring dark `#5F7894` | card `#111F30` | 3.64:1 | 3.0:1 | yes |
| kid | todo ring day `#8C8C8C` | card `#FFFFFF` | 3.36:1 | 3.0:1 | yes |
| kid | todo ring night `#6B6B6B` | card `#141414` | 3.46:1 | 3.0:1 | yes |

34/34 pass

Soft `onMarker` `#071426` on every family color (need 4.8:1, the packs' own bar):

| Pack | Lowest | On | Pass |
|---|---|---|---|
| bright | 5.42:1 | `#F05653` | yes |
| deep | 4.83:1 | `#F33A3F` | yes |
| soft | 7.80:1 | `#FF8482` | yes |
| bold | 4.92:1 | `#FF2920` | yes |

32/32 pack colors pass; 66/66 pass in all.

Summary: 66 of 66 pairs pass. Lowest text pair: Soft light `ink3` on `fill` 4.65:1. Lowest non-text pair: todo ring on white 3.05:1 (at the floor; do not lighten it). Kids mode also runs in Day and Night, so their todo rings are neutral grays (`#8C8C8C`, `#6B6B6B`). `app/test/design/tokens_test.dart` checks the same pairs against the Dart tokens.

### Type (Atkinson Hyperlegible Next, already bundled at `app/assets/fonts/`)

Keep `DenText` (`tokens.dart:506`). Kids mode adds four roles; the wall multiplies by `wallScale` 1.3 (`tokens.dart:462`) as today.

| Role | Size / weight / line | Use |
|---|---|---|
| `kidHello` | 30 / 800 / 1.15 | "Hi, Leo" |
| `kidJob` | 20 / 800 / 1.2 | Job title on a tile (phone); 40 on the wall |
| `kidMeta` | 15 / 700 / 1.2 | "+2 stars", "1 of 3", "Done" |
| `kidCount` | 46 / 800 / 1.0 | The star total |

Family Soft uses the existing scale unchanged (30 screen title, 20 section, 17 row title, 15 meta).

### Radii

Existing `Radii` stay. Kids mode: `kidTile` 24 on phone and tablet, 32 on the wall; `kidCard` 28 (star card); `kidButton` 24 (the read-to-me bar is a rounded slab, not a pill). Disc and avatar: circles.

### Spacing

`Sp` 4-pt scale unchanged. Kids mode grid gap 16; tile padding 16; between sections 20 (current `kid_home.dart:98`). Wall: outer margin 64, column gap 48, tile gap 22.

### Elevation

No blur shadows anywhere. Kids mode uses a solid lip: the tile is drawn twice, the lip offset 6 dp down (4 dp for the star card and read-to-me bar, 8 on the wall). Level map otherwise unchanged from `DESIGN.md:295-304`.

### Motion and haptics

- Press: the face translates down by the lip height (6 dp) and the lip shrinks to 0 using `DenMotion.ui` (`motion.dart:22`); release springs back. This replaces the 0.97 scale (`motion.dart:35`) on kid tiles only.
- Check: tile fill crossfades to the kid color, the check draws its stroke over 240 ms on `DenMotion.check` (`motion.dart:28`), `HapticFeedback.mediumImpact`.
- Star landing (the one celebration, `DESIGN.md:668`): the star scales 0 → 1 on `LandingSpring` (`motion.dart:91`), the counter ticks up, one pip in the progress row fills. `HapticFeedback.heavyImpact` once. No confetti.
- Reward reached: the progress row fills its last pip, the star card's text becomes "Park trip is ready" with a navy Get it button. `HapticFeedback.heavyImpact` then `lightImpact` 120 ms later.
- Reduce Motion: every one of these becomes a 100 ms fade (`DenMotion.fade`, `motion.dart:31`); haptics stay.
- Wall: no haptics (wall devices rarely have them); press depth 8.

## Components (kids mode)

All targets >= 64 dp; kid tiles keep `Targets.kid` 72 (`tokens.dart:450`) as the floor and are 136 to 168 tall.

1. Chunky job tile. Undone: white face, `line` lip, 60 dp colored disc with a navy pictogram (existing `choreGlyph`, `app/lib/design/chore_pictograms.dart`), job title, then a small star with "+2 stars" or "1 of 3". Done: kid-color face and lip, white disc with a navy check, title, "Done". The whole tile is the button (as today, `kid_home.dart:306`). Semantics label unchanged.
2. Star card. Big star, total in `kidCount`, the next reward's name, and a row of pips (one per star needed, max 12; beyond 12 a bar). Filled pips are gold with a navy edge; empty pips are `fill`. Pips carry the count for pre-readers who can't read "3 more".
3. Avatar. The kid's picture (`app/lib/design/avatar.dart`) in a person-color disc with a 3 dp white inner ring, 56 dp on phone, 88 on the wall.
4. Read my jobs to me. Full-width navy slab, 72 tall, speaker pictogram, pinned to the bottom on phones for pre-readers (`kid_home.dart:58-67` moves to a bottom bar).
5. Steps sheet (`kid_home.dart:346`): step tiles become chunky tiles with a number disc.
6. Wall row. On the wall a job is a 156-tall row: disc left, title and stars, a 68 dp todo ring right. One tap anywhere on the row checks it.

Not included on purpose: badges or counts on every tile, pill tabs, a confetti burst, a mascot, three feature cards.

## Navigation

Jared asked for top navigation and no left rail. Kids mode and the wall use top navigation now: on the phone the kid header is the top bar (avatar, name, Grown-ups on the right); on the wall a white top bar with the date left, text tabs (Week, Chores, Lists) centered with a 4 dp navy underline under the selected one, and the clock right. Text tabs, not pills.

The family app's own navigation (bottom tab bar on phones, 248 pt sidebar on iPad, `DESIGN.md:401-410`, `app/lib/design/widgets/navigation.dart:23`) is out of scope for this pass. Moving iPad off the sidebar is a separate decision; the calendar mock shows a top Day/Week/Month switch inside the page, which fits either.

## Layouts

- Phone (< 700): kid board is 2 columns (`kidColumns`), header, star card, grid, read-to-me bar pinned. Mock: `mocks/kid-chore-board-phone.png`.
- Tablet (700 to 1100): 3 columns, 24 side margins, read-to-me moves up under the star card; star card and today's events sit side by side at >= 900.
- Wall (>= 1100, `wallScale` 1.3): one column per kid (2 to 4 kids; at 5+ the columns scroll sideways by page), each with avatar, name, "2 of 4 done", star total, then job rows. Mock: `mocks/kid-chore-board-wall.png`. This is a new `DisplayLayout.chores` next to the existing today/week layouts (`wall_screen.dart:99-104`).
- Family Soft calendar (phone): title, top view switch, week strip with the selected day in baby blue and person dots, then today's events as solid person-color blocks with navy text and a pictogram; "everyone" events are a solid ink block. Light and dark side by side: `mocks/family-soft-calendar.png`.

## Accessibility for pre-readers

- Every state has a shape as well as a color: done is a check in a white disc plus a filled face; todo is an empty ring; stars owed are drawn as stars, not only a number.
- Every job has a pictogram; color never identifies a job alone.
- Read my jobs to me reads the whole list; long-press on a tile reads that job (new).
- Navy text on every kid color passes AA (lowest 5.94:1 on berry).
- Tile titles never truncate: they wrap to 2 lines and the tile grows (`DESIGN.md:251`).
- Text scale up to 200 % keeps 1 column at phone width when a title would wrap to 3 lines.
- Reduce Motion and Reduce Transparency respected as above.

## Per-file change list

| File | Change |
|---|---|
| `app/lib/app/app_state.dart:22` | `ThemeChoice` gains `soft` (auto light/dark inside Soft) |
| `app/lib/app/den_app.dart:143-149` | Pick `DenColors.softDay` / `softNight` when theme is `soft` |
| `app/lib/design/tokens.dart:142-194` | Add `static const softDay` and `softNight` (`DenPalette.soft`), the one `softNightGround` token, and `selection` / `onSelection` (Day and Night: ink and `onPrimary`, so they look as before) |
| `app/lib/design/kid_tokens.dart` (new, exported by `tokens.dart`) | `KidColors` ThemeExtension with the six face/lip pairs and the todo ring per theme; `KidText` roles; `Lip` and `KidLayout` |
| `app/lib/design/tokens.dart:404-446` | `Radii.kidTile 24`, `kidTileWall 32`, `kidCard 28`, `kidButton 24` |
| `app/lib/design/theme.dart:9` | Register `KidColors` in `denTheme` |
| `app/lib/design/motion.dart` | `ChunkyPressable`: lip press (translate + lip collapse), reduce-motion fade |
| `app/lib/features/shared_screens/screens/kid_home.dart:20,180-345` | Use `ChunkyPressable`, disc + pictogram tile, star pips, pinned read-to-me |
| `app/lib/features/shared_screens/widgets/kid_parts.dart` | Shared `KidDisc`, `StarPips`, `TodoRing` |
| `app/lib/features/shared_screens/screens/wall_screen.dart:96-140` | Add `DisplayLayout.chores` board; top bar with text tabs |
| `packages/den_core/lib/src/model.dart:222`, `app/lib/features/shared_screens/state/display.dart:4-10` | Add `chores` to `DisplayLayout` and to `wallLayouts`; the Lists tab on the wall mock is only shown if Lists comes back (it was cut, `display.dart:6-7`) |
| `app/lib/features/settings/...` (Appearance) | Show Soft as a fourth theme choice with a preview |
| `DESIGN.md:54-110, 665-670`, `docs/design/ANTI-SLOP.md:30-36` | Record Soft as a second palette, and kid primaries as the scoped exception |
| `tool/design/contrast.py` | Already added; exits non-zero on a failing pair, so it can be wired into CI |

## Phased checklist for Claude

Phase 1: tokens (no visible change unless Soft is chosen)
- [ ] `softDay`, `softNight`, `selection`, `KidColors`, kid radii added. Accept: `python3 tool/design/contrast.py` prints 66/66 pass (34 pairs and 32 pack colors); `flutter analyze` clean; default Day/Night screenshots unchanged pixel for pixel.
- [ ] `ThemeChoice.soft` stored and restored. Accept: switching Day → Soft → Night in Settings animates without a rebuild flash; restart keeps Soft.

Phase 2: Soft theme visible
- [ ] Settings shows Soft with a live preview card. Accept: screenshot at 390 wide, light and dark; no warm hex (R > B by more than 8) anywhere in Soft tokens (add a test).
- [ ] Calendar week strip uses `selection`. Accept: matches `mocks/family-soft-calendar.png` within layout tolerance.

Phase 3: kid tiles
- [ ] `ChunkyPressable` with lip press and reduce-motion fade. Accept: widget test for press-down offset 6 and for reduce-motion path; haptic called once per toggle.
- [ ] Job tile disc + pictogram + done state. Accept: golden test at 390 x 844 matches `mocks/kid-chore-board-phone.png` structure; every tile >= 136 tall and >= 64 wide; semantics label unchanged.
- [ ] Star pips and reward-ready state. Accept: 0, 7 of 10, 10 of 10 and 15-star goldens.
- [ ] Read-to-me pinned bottom on compact. Accept: never overlaps the last tile (bottom padding = bar + 16).

Phase 4: wall chores board
- [ ] `DisplayLayout.chores` with per-kid columns and top text tabs. Accept: 1920 x 1080 golden matches `mocks/kid-chore-board-wall.png`; 2, 3, 4 and 5 kids render without clipping; titles wrap, never ellipsize.

Phase 5: docs
- [ ] DESIGN.md and ANTI-SLOP.md updated with the scoped exception (kid primaries). Accept: Jared signs off on the exceptions list below.

## Decisions for Jared

1. Decided 2026-10-30: Soft dark is true black `#000000`, not the navy-black `#060D16` first proposed, so "dark is true black" holds in Soft too. Cards keep their navy steps and every ratio passes. It is one token (`DenColors.softNightGround`).
2. Kid primaries on a kid's own board break "a hue means a person" for job discs. Wall keeps person colors only. This is the one scoped exception left for sign-off.
3. The family app still has a bottom tab bar and an iPad sidebar. Top navigation there is a separate pass.
4. The PRESS house style (paper `#E4DFD1`, Newsreader) was not used: it is a warm cream ground, which this brief bans, and Den already has its own documented system.

## Mocks

- `docs/design/mocks/kid-chore-board-phone.svg` / `.png` (390 x 844 @2x)
- `docs/design/mocks/kid-chore-board-wall.svg` / `.png` (1920 x 1080)
- `docs/design/mocks/family-soft-calendar.svg` / `.png` (Soft light and dark, 2 x 390 x 844 @2x)

Regenerate with `python3 tool/design/mocks.py` then cairosvg (`pip install cairosvg`; `rsvg-convert` also works).
