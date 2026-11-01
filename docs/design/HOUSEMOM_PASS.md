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

## Found on the way

- **The kitchen screen in portrait.** The wall's new top bar (date, tabs and clock in one row,
  from the wall chores board) ran off the edge between 760 and about 1000 pt wide, which
  includes an iPad standing in portrait on the counter. Below 1000 pt the wall now uses the
  stacked bar it already had (clock and controls, then the date, then the tabs). This was the
  one failing test on family-ready.

## What stayed where it was, on purpose

- Kids' views: nothing changed; the wall only got the fix above. Parent-only things stay parent-only: Kitchen
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

## Round 2

Jared answered the list above: 1, 3, 4, 5, 7 and 8 as asked, and 2, 6 and 10 left to the
defaults suggested there. Item 9 (the kitchen screen joining by a code) is its own change.

| Change | Job | Taps before → after |
| --- | --- | --- |
| Add opens with the field focused and the keyboard up | Add milk, an event, anything | 3 → 2 (Add, type, "Add to Groceries") |
| Needs you shows three, then "2 more", which opens the rest in place | Glance at today with five things waiting | The day's events start on the first screen; a fourth thing waiting is 0 → 1 tap away |
| A kid's late chore never shows in a grown-up's Needs you | (nothing nags her about the kids' chores) | Checking them: the Chores tab, 1, as before |
| Swipe right to approve, left (or a small ×) to decline, with Undo in place | Say no to a reward | 3 (her face, Stars and rewards, Decline) → 1 |
| | Turn away a device asking to join | 3 (her face, Family, Turn it away) → 1 |
| | Approve a reward or a device | 1 → 1 (the button, or a swipe) |
| | Hide "Nobody is driving Zoe" until tomorrow | not possible → 1 |
| The AI helper line at the end of Today: "Not now", and only in the family's first three weeks | Put it away | not possible → 1; after three weeks 0 |
| "Stars and rewards", not "Points and rewards" | Open it | 2 → 2 |
| "Approve" for a device on Family too (it said "Let Grandma Rosa in") | Let a device in | 1 → 1 |
| "Already have Den on this iPhone? Copy invite" is one quiet line under the heading | Follow the Home Screen steps | The steps start a card higher |
| Settings: one switch, "Reminders on this device", no heading saying it again (in a browser, the heading "Reminders" over what names the device) | Reminders | 3 → 3 |

### How each works

- **The keyboard with Add.** iOS raises the keyboard for a Home Screen web app only when a field
  is focused inside the tap itself, and Add's field is built a frame after the tap, in a sheet
  still rising. So the tap on + focuses a stand-in field in the page (`den_web.js`,
  `keyboardNow`), at once, and the field in the sheet (`autofocus`) takes the focus from it as the
  sheet opens, which keeps the keyboard up. If nothing takes it within 1.5 s the stand-in lets
  go and the keyboard goes down. Only on a phone or tablet, and only when Add has a field for
  the person. In the app (not the web) autofocus alone does it.
- **Three, then "2 more".** The count by the heading still says how many things wait ("5
  things"). Settled rows keep their place with Undo, as before; "2 more" is a quiet row with a
  caret that opens the rest in place, in the same order (rides, a device waiting, rewards,
  lists, a grown-up's late chores, connections, notices).
- **Kids' chores.** Needs you leaves out every late chore whose owner is a kid; a grown-up's
  own, and one for anyone, still show. Nothing else nagged her about them: the hub's pushes
  about chores go only to whoever's turn it is, and a phone's own reminders are only for its
  person's chores (and chores for anyone).
- **Swipe to answer** (DESIGN.md, "Swipe to answer"). Right approves, calling exactly what the
  Approve button calls, so a device is still let in only from a parent's own phone. Left, or
  the ×, declines a reward or turns a device away; on a row with no no it means "Not now",
  which puts it off on this phone until tomorrow. What happened shows in the row with Undo for
  five seconds; a decline or a turn-away is only sent once those pass (or Today closes), so a
  swipe by mistake never reaches the kid or the person holding the device; then the row folds
  away. Rows that already have Got it (notices) or Remind me later get the swipe and no ×.
  The × is an 18 pt gray glyph on the title's line, with a 44 pt target. This keeps Den's
  "Undo in place, never a toast" (DESIGN.md): the Undo is where her finger was, not in a bar
  at the bottom.
- **The AI helper line.** "Not now" is kept with the other things she put away on this phone
  (per person, per family); there's no synced per-person place for it without a change to the
  family's records, and it's one tap on another phone. The line shows only for 21 days from
  when the family was made; after that the helper lives in Settings, AI helper, and ⌘K still
  says what it does.
- **Stars and rewards.** The menu, the page's title, Settings, Family's switch, the empty
  states and editors, the web app's description, the hub's sign-in page and its push ("Approve
  it in Stars and rewards"), and what the assistant and MCP tools call it. Routes (`/points`)
  and code names stay.

The before and after renders (all under `app/test/goldens/`; befores of this round in
`housemom/round2/`):

| Screen | Before | After |
| --- | --- | --- |
| Today, Needs you with five waiting | `housemom/round2/today_needs_more_phone_before.png` | `housemom/today_needs_more_phone.png` |
| Today, a device asking to join | `housemom/round2/today_needs_device_phone_before.png`, `_night_before` | `housemom/today_needs_device_phone.png`, `_night` |
| A reward mid-swipe; declined with Undo | (new) | `housemom/today_needs_swiping_phone.png`, `housemom/today_needs_declined_phone.png` |
| Today, the whole page | `housemom/round2/today_phone_full_before.png` | `today_phone_full.png` |
| Today's AI helper line | `housemom/round2/ask_set_up_today_phone_before.png` | `ask_set_up_today_phone.png` |
| Add, as it opens | `housemom/round2/add_open_phone_before.png` | `housemom/add_open_phone.png` |
| Stars and rewards | `housemom/round2/points_phone_before.png` | `points_phone.png` |
| The menu under her face | `housemom/round2/person_menu_phone_before.png` | `housemom/person_menu_phone.png` |
| Settings | `housemom/round2/settings_phone_before.png` | `housemom/settings_phone.png` |
| Family, a device asking to join | `housemom/round2/family_phone_before.png` | `family_phone.png` |
| An invite opened in Safari | `housemom/round2/onboarding_v2_safari_invite_phone_before.png` | `onboarding_v2_safari_invite_phone.png` |

### For Jared, round 2

1. **On her iPhone**: tap + and check the keyboard rises with the sheet, in the Home Screen
   app (Chrome here can't show an on-screen keyboard; it checks the focus lands in the tap and
   ends in Add's field). Also: the keyboard staying up when the sheet's field takes over, and
   no flash of the page scrolling.
2. **On her iPhone**: swipe a Needs you row while scrolling Today; a mostly vertical swipe
   should scroll, a sideways one answer.
3. **Undo in the row, not a bar at the bottom.** Kept to "Undo in place, never a toast"; say if
   you'd rather have the bar.
4. **"Not now" on a ride is until tomorrow**, which for a ride later today means it doesn't come
   back. A few hours instead?
5. **The AI line's "Not now" is this phone's.** Following her to her other devices needs a
   per-person setting in the family's records.
