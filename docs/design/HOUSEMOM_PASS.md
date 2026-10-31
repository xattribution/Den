# The housemom pass

The owner's ask: "Not complex, not annoying, simple to use. No extra clicks, not a bunch of crap
on the screen when she wants to do one thing, the important things where and when she needs
them."

She is a busy, non-technical mom on an iPhone, using Den as a Home Screen web app, one-handed and
often interrupted. The family has a kitchen wall screen; the kids use the kid view.

## How this was audited

- Every job below was walked in the whole app (`buildRouter`, the real shell and sheets) at
  iPhone size, 390 by 844, light and dark, with the demo family (Alex is the parent holding the
  phone). The renders are the committed goldens in `app/test/goldens/` and
  `app/test/goldens/housemom/`; the walk-throughs that count taps are
  `app/test/screens/housemom_test.dart`.
- **A tap** is a press on the glass. Typing isn't counted; tapping into a field to type is.
  Every count starts on Today with the app open, which is where she lands.
- Judged against [DESIGN.md](../../DESIGN.md) and [ANTI-SLOP](ANTI-SLOP.md). Nothing here adds
  color, a container or decoration; every change removes or moves something.

## The changes

| Change | Job | Taps before → after |
| --- | --- | --- |
| "Invite someone" in the menu under her face (Search left it: the glass beside her face already searches) | Invite her husband or grandma | 5 and a scroll → 4 (to the invite sheet: 3 and a scroll → 2) |
| "Kitchen screen" on Settings itself, out of Advanced | Set up the kitchen screen | 6 and a scroll → 5 (to its page: 4 and a scroll → 3) |
| Settings fits one screen: Appearance and About are pages, Text size a one-tap sheet, each row saying what it's set to | Change one setting | Text size 3 and a scroll → 4, no scroll; Night 3 → 4; Reminders 3 and a scroll → 3; calendar look 3 and two scrolls → 4 |
| Settings, Family fits one screen: Family colors a page, Weeks start on a sheet | Change a family setting | Colors 4 and a scroll → 5; week start 4 → 5; everything else unchanged and no longer below the colors |
| Chores rows are rings and names: the "Give to…" pill on every row is gone (it stays in the opened row) | Check off a chore, see who has chores left | Check off 2 → 2, with 8 fewer buttons on the board; Give to… 1 → 2 |
| Needs you puts the most pressing first: rides soonest first, then whoever is waiting right now (a device asking to join), then rewards, lists due, late chores, connections, and notices last | The Needs you list | Approving a waiting device: 1 tap, now second in the list instead of last (it was below the fold with four things waiting) |
| "Give stars", not "Give points" (the copy rule: stars, never points) | Give stars | 0 |

The before and after renders:

| Screen | Before | After |
| --- | --- | --- |
| Settings | `housemom/settings_phone_before.png`, `_night_before` | `housemom/settings_phone.png`, `_night` (iPhone size); `settings_phone.png` (tall) |
| Settings, Appearance (new) | the top of `housemom/settings_phone_before.png` | `housemom/settings_appearance_phone.png`, `_night`; `settings_soft_phone.png` |
| Settings, Text size | `housemom/settings_text_size_phone_before.png` | `housemom/settings_text_size_sheet_phone.png`, `settings_text_size_phone.png` |
| Settings, About | `housemom/settings_about_build_before.png` | `settings_about_build.png` |
| Settings, Family | `housemom/settings_family_phone_before.png` | `settings_family_phone.png` |
| Family colors (new page) | `housemom/settings_family_colors_phone_night_before.png` | `housemom/settings_family_colors_phone.png`, `settings_family_colors_phone_night.png` |
| Advanced | `housemom/settings_advanced_phone_before.png` | `settings_advanced_phone.png` |
| Kitchen screen | `housemom/settings_displays_phone_before.png` | `settings_displays_phone.png` |
| The menu under her face | `housemom/person_menu_phone_before.png` | `housemom/person_menu_phone.png` |
| Today, Needs you with a device waiting | `housemom/today_needs_device_phone_before.png`, `_night_before` | `housemom/today_needs_device_phone.png`, `_night` |
| Chores | `housemom/chores_board_phone_before.png`, `_night_before`, `chores_board_open_phone_before.png` | `chores_board_phone.png`, `_night`, `chores_board_open_phone.png` |
| Points and rewards | `housemom/points_phone_before.png` | `points_phone.png` |

All paths are under `app/test/goldens/`.

## Her jobs, one by one

Each: the taps today and after this pass, what's on the screen that she doesn't need at that
moment, and what's missing or hidden when she needs it.

### Glance at today

- **Taps**: 0 → 0. Today is home.
- **On screen**: the date and greeting, Needs you, Today's events (Tomorrow from 5 PM), chores
  by person, groceries. All of it is hers.
- **Clutter**: with three or four things in Needs you, the day's events start below the fold
  (each Needs you row is about 136 pt on a phone, its button under the words). For a parent
  while the AI helper is off, the last line of Today is "Ask in your own words, set up the AI
  helper in Settings", every day (see For Jared).
- **Hidden**: nothing she needs. Groceries are at the bottom, which is fine: the Lists tab is
  one tap.

### Add milk to the Costco list, and check items off at the store

- **Taps to add**: 3 → 3, three ways: Add (+), the field, type "milk @costco", "Add to
  Groceries"; or Lists, the field, Return; or Today's Groceries at the bottom, the field,
  Return. With the Costco chip chosen, the add bar's store is already Costco.
- **Taps at the store**: Lists (1), Costco (2), then one tap per item, which crosses it off in
  place; nothing moves while the list is open. "Clear checked" appears only once something is
  checked.
- **Clutter**: none worth removing. The lists' chips and the stores' chips are two rows of
  chips; both are the point of the screen.

### Add an event: "Dentist Tue 3pm for Mia"

- **Taps**: 3 → 3: Add (+), the field, type, "Add to calendar". The reader finds When and Who
  as she types; Undo stays in the sheet.
- **Clutter**: "Say it", "Photo of a flyer", "Or choose a photo or PDF" and "Or add one thing"
  share the sheet with the field. They are the other ways in and sit under it; fine.
- **Hidden**: the field isn't focused when the sheet opens, so it takes a tap (For Jared).

### Say "I'll drive"

- **Taps**: 1 → 1, in Needs you, done in place with Undo. From the event itself: open it (1),
  "I'll pick up" (2).
- **After**: rides are now soonest first, so the one that's about to matter is on top.

### Approve a reward or a request

- **Taps**: 1 → 1 for a reward ("Approve" in Needs you, with Undo). A device asking to join: 1
  → 1, but it was last in Needs you and below the fold whenever three other things waited; now
  it is right after the rides, because someone is standing there holding the phone. Approvals
  still happen only on a parent's own phone (`allowsTrust`); nothing about who may approve
  changed.
- **Hidden**: Decline for a reward is only on Points and rewards (For Jared).

### Check off a chore for a kid, or see who has chores left

- **Taps**: on Today, 1 (the ring on the kid's pill). On the Chores tab, 2 → 2.
- **Clutter (fixed)**: every row on the Chores board had its own "Give to…" pill: eight
  identical buttons on a board of eight chores, crowding the rings she came to tap and the
  names she came to read. The rows now hold the ring and the words; Give to… is in the row
  once she opens it (the words), with Details. Give to… goes from 1 tap to 2.
- **Who has chores left**: "2 of 8 done" under the title and each person's section, at a
  glance on the Chores tab (1 tap).

### Add or move an event from a text or a photo (Add, capture)

- **Taps**: a flyer: Add (1), Photo of a flyer (2), the camera's shutter (3); it's added with
  Undo, or shown first if the family chose "Show me first". A text: copy it in Messages, Add
  (1), Paste (2). Moving an event: open it, change When; with the AI helper on, "move soccer to
  6" in Add.
- **Unchanged**: the capture flow is already one sheet and one review page.

### Find this week's schedule

- **Taps**: 1 → 1: "Week" beside Today's events, or the Calendar tab.

### Invite her husband or grandma

- **Before**: her face (1), Family (2), then scroll past Needs you, the faces and the whole
  page of the person shown (their switches) to "Invite someone" (3), whom (4), Send invite (5).
- **After**: her face (1), Invite someone (2), whom (3), Send invite (4). No scroll.
- **What moved**: Search left that menu. It was the same thing as the glass right beside her
  face on Today, and in the iPad sidebar.

### Set up the kitchen screen

- **Before**: her face (1), Settings (2), scroll to the end, Advanced (3), Shared displays (4),
  Invite a display (5), Send invite (6). "Shared displays" behind "Advanced" isn't where anyone
  looks for the kitchen screen.
- **After**: her face (1), Settings (2), Kitchen screen (3), Invite a screen (4), Send invite
  (5). The page is called Kitchen screen; its route stays `/settings/advanced/displays` so old
  links keep working. On the screen itself nothing changed: open the invite there, and she lets
  it in from her phone.

### Change one setting

- **Before**: Settings was 1800 pt tall, more than two iPhone screens. Appearance alone was
  most of it: four themes, the preview, three text sizes, two calendar choices, two ways to
  show days. Reminders, Advanced and About were under all of it.
- **After**: Settings fits one screen (`housemom/settings_phone.png`). Every row says what
  it's set to: "Appearance, Auto", "Text size, Default", "Kitchen screen, 1", "AI helper,
  Off", "About, 1.0.0". What she changes once (the theme, how the calendar looks) is a tap
  deeper, with its preview where the choice is; Text size is a short sheet where one tap picks
  and closes.
- **Taps**: Text size 3 and a scroll → 4, no scroll. Night or Soft 3 → 4. Reminders 3 and a
  scroll → 3. How the calendar looks 3 and two scrolls → 4.
- **Settings, Family** had the four color packs open on the page (four rows of six names), so
  "Points and rewards" and "When Den reads a photo or message" were under 700 pt of swatches.
  Now Time zone, Weeks start on and Family colors are one card of rows, each saying its value;
  the colors are a page of their own. Colors and week start each take one more tap; the page
  fits one screen.
- A hub serving a newer Den still says so where she'll see it: on the About row itself.

### First launch and setup, with the Home Screen steps

- **Taps**: Start a family (1), name, time zone (already set from the phone), her name, Create
  family (2), add the kids and grown-ups, Go to Today (3). In Safari the Home Screen steps come
  first, with a picture of where Share is.
- **Clutter**: on a setup or invite link in Safari, "Already have Den on this iPhone?" sits
  above the steps (For Jared).
- **Unchanged**: this flow was reviewed in its own pass (onboarding.md).

### The Needs you list

- **Before**: privacy notice, rides, rewards, late chores, sitters' ended access, devices
  asking to join, AI connections, recovered phones, devices an invite let in, sign-in tries,
  the recovery words reminder, lists due. So a device waiting to join (someone holding a phone,
  waiting) came after a kid's late chore, and a list due today came after everything.
- **After** (`needsYou`): a change to her own privacy; rides in the next 48 hours, soonest
  first; a device asking to join; reward requests; lists due, today's first; late chores; AI
  connections; then the notices that only need "Got it" (a device an invite let in, a
  recovered phone, wrong sign-in tries, a sitter's access ended); and last the reminder to save
  recovery words. Who sees each thing is unchanged.

### Ask, when it's on

- **Taps**: "Ask about your day" under the greeting (1), a chip (2) or typing. In Add, the
  field reads "Add or ask anything".
- **Unchanged**: the empty chat's chips come from her own day, and a change chip only fills the
  field.

### Also checked, from the last few days

- **Soft theme**: her face, Settings, Appearance, Soft: 3 → 4, with the preview beside the
  choice.
- **Google or Apple sign-in**: on Settings' first card, only on a parent's own phone in a family
  with a hub, saying Off, Google or Apple. 3 taps, unchanged.
- **Several families**: the switcher heads Today only with two or more families; nobody in one
  family sees it. Unchanged.
- **Calendar options**: in the Calendar's month view options, and on Settings, Appearance. From
  Settings: 3 and two scrolls → 4.
- **Screen info**: stays in Advanced, under "When something looks wrong".

## What stayed where it was, on purpose

- Kids' views and the wall: nothing changed. Parent-only things stay parent-only: Kitchen
  screen, like Family and the AI helper, shows on Settings only to a parent, and its page still
  says that shared screens change only on a parent's own phone.
- Accessibility: every new row is a `NavRow` (56 pt, its value read with its label), the Text
  size sheet is `showChoiceSheet` (checked rows, one tap), and every new page is a `DenPage`
  that follows text size to 200 % and Reduce Motion.

## For Jared

Things that would help her that change a decision of yours, so they're here and not in the PR:

1. **Open Add with the keyboard up.** The field takes a tap after the sheet opens. A Home Screen
   web app on iOS only raises the keyboard inside the tap that asked for it, and the sheet
   opens on a spring after the tap, so this needs trying on her iPhone (or opening the keyboard
   first and the sheet around it). Saves a tap on every add.
2. **"Already have Den on this iPhone?" above the Home Screen steps** (Safari, from a setup or
   invite link). Most people who see that page don't have Den yet, so the steps are their job;
   the card is there so nobody puts a second Den on the Home Screen. Below the steps, or
   smaller?
3. **The AI helper line at the end of Today** shows for every parent while the helper is off,
   every day. A "Not now" that hides it on this phone, or showing it only for the first weeks?
4. **Decline on Today.** Needs you has only Approve for a reward; Decline is on Points and
   rewards. Two buttons per row is more on the screen; one is a trip for the no.
5. **Needs you can push the day below the fold.** Four waiting things fill an iPhone screen.
   Showing the first three and "2 more" keeps the day in view but hides things that wait.
6. **One word for letting a device in.** Today says "Approve" on "Rosa's iPad wants to join";
   Family says "Let Grandma Rosa in" for the same thing. DESIGN prefers "Let her in".
7. **"Points and rewards"** is the name in the menu, Settings and the page title, but the copy
   rule is "Stars, never points". "Stars and rewards"? It's a feature's name, so yours.
8. **Late kids' chores in her Needs you.** "Return library books, Leo, Mark done" is a kid's
   job showing as hers. Keep, or only when it's a day late?
9. **The kitchen screen joins by invite.** Opening the invite on a wall tablet means getting the
   link onto it. A code or QR shown on the new screen, which she approves from her phone, would
   be less fiddly; it's a new feature, not a move.
10. **"Reminders on this device" over a switch called "Reminders"** says it twice. It could be
    one switch, "Reminders on this iPhone", with no heading; it was left because the browser's
    version of that section has more in it.
