# Den design system

The rules every screen follows. Agents and people building Den read this before touching UI.
The tokens live in code at `app/lib/design/tokens.dart`; this file says why each one exists.

## Domain read

- **Who.** Parents (daily, short sessions, low patience for software), kids from pre-readers to
  teens, and occasional adults outside the house: grandparents, a sitter, a co-parent.
- **Where.** A phone in one hand while carrying groceries or in a car line; a tablet on the
  kitchen wall read from two or three meters away, in bright morning light and dim evening light;
  a laptop on Sunday night when the week gets planned.
- **What they already read fluently.** The paper family organizer calendar with **one column per
  family member**; one marker color per person on the kitchen calendar; the fridge chore chart
  with check boxes and star stickers; a grocery list grouped by store with items crossed out;
  school flyers and team schedules; "Today", "Tomorrow", "Wed", "3:30 PM".
- **What binds it.** iOS and Android conventions, US date and time formats by default (locale
  aware), WCAG 2.2 AA, touch targets of 48 dp (72 dp for kids), offline use, privacy, and
  readability for kids learning to read and grandparents with weaker eyes.
- **The job.** The first screen answers "what's happening today, and who's doing what". On the
  wall it answers the same for the whole week.

## Plan

### Color: people are the color

On a paper family calendar each person writes in their own marker. Den does the same: **a hue
means a person, always and only.** Categories are icons and words, never colors. Sett let member
colors and category colors share hex values, so a member dot and a category bar could look the
same and mean different things. Den removes that.

| Token | Day | Night | Role |
| --- | --- | --- | --- |
| `paper` | `#FBFAF7` | `#15120F` | Page background, whiteboard white or a dark kitchen at night |
| `well` | `#F2F0EC` | `#211D1A` | Inputs, segmented-control tracks, sheets' grab area |
| `rule` | `#DCD9D3` | `#393530` | The one hairline that separates rows and regions |
| `ink` | `#231E19` | `#F0EEEA` | Text, and the interactive accent (graphite marker) |
| `ink2` | `#5F5A54` | `#AFAAA4` | Secondary text: times, counts, done items |
| `ink3` | `#847F7A` | `#78746E` | Placeholders and disabled controls only, never body text |
| `onInk` | `#FBFAF7` | `#15120F` | Text on a solid ink fill (selected tab, primary button) |
| `bad` | `#BE241F` | `#F9786A` | Late, failed, destructive. Always with an icon and a word |
| `caution` | `#A85F08` | `#ECA851` | Needs a person: a gap, a conflict, an approval. Icon and word |
| `star` | `#E7B726` | `#F3C443` | Fill of the star shape and nothing else (points) |
| `starEdge` | `#8A6200` | `#F3C443` | Outline that gives the star 3:1 against the page |

**Person markers** (fills only, never text; day L 0.58, night L 0.72; contrast against the page
3.8 to 4.5:1 by day and about 7:1 at night): blue `#2B7EC9`, green `#348F4F`, orange `#BF5914`,
pink `#BB4E7F`, teal `#008E8E`, plum `#A05DA4`, brown `#9B6F52`, olive `#78822B`, sky `#2785A9`,
slate `#6C7B96`. Night variants: `#59AAF8`, `#62BB78`, `#EF8448`, `#EC79A9`, `#36BABA`,
`#CD87D1`, `#C8997B`, `#A2AD58`, `#59B1D6`, `#95A5C2`. Red and gold are excluded from the marker
set because they already mean "late" and "points".

The interactive accent is the graphite ink itself: selected tabs, primary buttons and toggles
are solid ink with `onInk` text (owner rule O1). There is no chromatic accent to compete with
the family's colors.

### Type

**Atkinson Hyperlegible Next** (Braille Institute, 2025, SIL OFL), self-hosted. It was designed
so similar letterforms (I l 1, 0 O, b d) can't be confused, which serves kids learning to read,
grandparents, and anyone reading the wall from across the room. Numbers use tabular figures.

| Role | Size | Weight | Used for |
| --- | --- | --- | --- |
| `meta` | 13 | 400 | Times, counts, who and when in History |
| `body` | 15 | 400 | Rows, inputs, buttons |
| `title` | 18 | 700 | Row titles that lead a group, sheet titles |
| `heading` | 24 | 700 | The one screen heading |
| `display` | 40 | 700 | The wall clock and date, kids' star totals |

Two weights, five sizes, sentence case everywhere. Display mode multiplies every size by 1.3;
the kids' apps use only `title`, `heading` and `display`.

### Shape, space and motion

- Radius: `6` on controls (buttons, inputs, chips), `16` on kids' cards and the top corners of
  sheets, full circles for avatars and stars. Regions are flush and separated by space or one
  `rule` line. Cards exist only for things you act on by themselves: a chore, a list, a
  reward.
- Spacing on a 4 px scale: 4, 8, 12, 16, 24, 32, 48. More space between groups than within.
- One shadow, for true overlays only (sheets, menus): `0 8 24` at 18% ink.
- Motion only for a state the person caused: a check landing (150 ms ease-out), a sheet
  arriving (200 ms). Reduced-motion settings turn both off. No confetti, no skeletons under a
  second, no toast per save. Saved state shows inline.

### Icons and avatars

One set: **Phosphor** (MIT), regular weight in the adult app, fill weight as pictograms in the
kids' apps. Icons appear only for things people scan for repeatedly: chore pictograms, list
kinds, event kinds, the four tabs. Avatars are an animal pictogram the person chooses, in their
marker color, or a photo. The same nine animals make up the picture-pattern sign-in, so a
pre-reader recognizes themselves and their secret without reading.

## Primary screens

Phone, **Today** (the first screen for every adult):

```
Fri, Oct 17                                  [ Add ]  (avatar)
─────────────────────────────────────────────────────────
 7:30 AM  |  School drop-off                   Dad
 3:30 PM  |  Soccer, Field 4                   Leo
          ⚠ Nobody is driving                [Take it]
 6:00 PM  |  Dinner at Grandma's            Everyone
─────────────────────────────────────────────────────────
Chores                                       9 of 14 done
 Mia   ( ) Dishes  2★   (✓) Feed the cat
 Leo   (✓) Make bed     ( ) Trash out  1★
─────────────────────────────────────────────────────────
Groceries                       14 items, 5 at Costco
─────────────────────────────────────────────────────────
  Today      Calendar      Chores      Lists
```

The vertical bar before each event is the person's marker. Times use tabular figures so the
column holds.

Wall, **Family week** (the signature element, see below), landscape tablet:

```
Friday, October 17   3:42 PM                         Kitchen
──────────┬───────────┬───────────┬───────────┬───────────
          │ Mom       │ Dad       │ Mia       │ Leo
──────────┼───────────┼───────────┼───────────┼───────────
Today     │ 9:00 Work │ 7:30 Drop │ ( ) Dishes│ 3:30 Socc
          │           │           │ (✓) Cat   │ ( ) Trash
Sat 18    │           │ 10:00 Gym │ 1:00 Party│ 9:00 Game
Sun 19    │      Dinner at Grandma's, 6:00 PM (everyone)
...
```

## Signature element: family columns

The paper family organizer gives every person a column and every day a row. Den's week view
on the wall and the calendar's "Family" view use exactly that grid: a column per person headed
by their avatar and marker, a row per day, each cell holding that person's events and chores.
Events for everyone span the row. It is the one bold structure in the app; every other screen
stays quiet.

## Justification ledger

| Element | Encodes | Source |
| --- | --- | --- |
| Person marker hues | Who an event, chore or step belongs to; nothing else is chromatic | Domain read: one marker per person |
| Graphite as the accent | "You can act here" without competing with people's colors | O1, one meaning per hue |
| Solid ink selected states | The current tab, the chosen option | O1 |
| `bad` red | Late chores, failed sync, destructive actions, with icon and word | B7, status ladder |
| `caution` amber | A gap or conflict a person must resolve, approvals waiting | Status ladder |
| Star gold | Points, on the star shape only | Domain read: star stickers |
| Check plus strike-through | Done, readable in grayscale | Fridge chart, B5 |
| Atkinson Hyperlegible Next | Legibility for early readers, older eyes and distance | Braille Institute research |
| Tabular figures | Times and points line up in columns | Required practices: Type |
| Radius 6 on controls only | Marks what you can press; regions sit flush | O4, B11 |
| Radius 16 on kids' cards | Big friendly targets for small hands | Kids' tier, 72 dp targets |
| Phosphor pictograms | Chores and lists recognizable before kids can read | Domain read |
| Animal avatars | Identity and sign-in for non-readers | Sett's picture pattern, kept |
| Overlay shadow | A sheet or menu floats over the page | B3, true overlays only |
| 150 to 200 ms motion | A check or a sheet the person caused | B13 |
| Star sticker landing (kids) | The reward itself, as on a sticker chart | Domain read; motion is the content |
| Night theme | The wall in a dark kitchen, phones at bedtime | Domain read: evening light |
| Display mode scale 1.3 | Reading from two to three meters | Domain read: the wall |

## Swap test

A generic "family organizer app" prompt produces pastel category colors, rounded cards on every
section, a purple or teal accent, Nunito or Poppins, emoji avatars, a floating action button and
confetti. Den changes each: color belongs to people only, regions are flush with one hairline,
the accent is graphite, the face is chosen for legibility, avatars are chosen animals, adding
lives in the top bar as "Add", and the reward is a star sticker on the kids' chart.

## Copy

- Verb and object on every button: "Add event", "Take it", "Give points", "Approve Mia's tablet".
- No exclamation marks, no emoji, no "Oops". Errors name the cause and the way out: "Couldn't
  reach the hub at 192.168.1.20. Your changes are saved on this phone and will sync later."
- No explainer text under headings. Where help is needed, a small (i) next to the label.
- American spelling.
