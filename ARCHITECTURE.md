# Den architecture

The contract every package builds against. If code and this file disagree, fix one of them in
the same change.

## Packages

| Path | Language | What |
| --- | --- | --- |
| `packages/den_core` | Dart (pure, no `dart:io` in `lib/den_core.dart`) | Data model, hybrid logical clock, signed change log, materializer, permissions, recurrence, chores, points, history, queries, the `Den` engine facade, storage interface |
| `packages/den_net` | Dart | Device handshake and encrypted sessions, sync protocol, pairing (QR invites, spoken codes, matching words), relay client, encrypted backups |
| `packages/den_capture` | Dart (pure) | Capture: reads a photo, a shared email, link or PDF, or a sentence into proposed events, chores, list items and reminders (see "Capture" below) |
| `packages/den_actions` | Dart (pure) | Actions: every verb the app, the hub's REST API, MCP and the assistant offer, defined once (`ActionSpec`: names, portable schemas, scopes, permissions, effect, confirmation, the engine methods it calls) and run by one `ActionRunner` (checks, previews on a fork, confirmations, undo receipts); the API's JSON (`Wire`), time parsing and name resolution (see "Actions" below) |
| `packages/den_hub` | Dart (server, `dart:io`) | The hub: HTTP API, WebSocket sync endpoint, MCP server, OAuth for MCP, scoped tokens, ICS import and export, reminders and notifiers, Home Assistant bridge, mDNS advertising, static web app. `bin/den_hub.dart` compiles to one binary |
| `packages/den_relay` | Dart (server) | Rendezvous, tunnel and mailbox for devices that can't reach each other or the hub directly. Sees only ciphertext |
| `app` | Flutter | The designed app for iOS, Android, macOS, Windows, Linux and web. Embeds `den_core`; runs `den_hub` in-process in hub mode on desktop and Android |
| `integrations/homeassistant/custom_components/den` | Python (Home Assistant requires it) | HACS integration: calendars, to-do lists, sensors, services, events |
| `deploy` | Docker | `den_hub` and `den_relay` images, compose file |

Ports: hub `47733` (HTTP + WebSocket), relay `47734`. mDNS service type `_den._tcp`.

## The model: spaces, records, changes

A **family** owns several **spaces**. Every record lives in exactly one space, and a device only
ever receives the spaces its member may read. This is how privacy is enforced: a kid's tablet
never holds a parent's private event, so no filter on any server is needed.

| Space id | Who receives it |
| --- | --- |
| `f` | Every approved device in the family, including shared displays |
| `p` | Parents' devices and hubs |
| `m:<memberId>` | That member's devices, hubs, and parents' devices when the family's oversight policy for that member allows it (default: allowed) |

A **record** is `(type, id)` with a map of fields. A **change** sets some fields of one record:

```
Change {
  id      String   "<deviceId>:<counter>"   counter is per device, starts at 1, never reused
  space   String   "f" | "p" | "m:<memberId>"
  hlc     String   hybrid logical clock, "<millis 13 digits>-<counter 4 hex>-<deviceId>"
  type    String   record type (below)
  rid     String   record id
  fields  Map      field name -> JSON value; {"_deleted": true} deletes
  device  String   author device id
  actor   String?  member acting (a personal device's owner; on a shared display, the member who
                   verified with their PIN or pattern; null for open check-off on displays)
  sig     String   base64url Ed25519 signature by the device over canonical bytes
}
```

Canonical bytes: UTF-8 JSON of `[id, space, hlc, type, rid, fields, device, actor]` with object
keys sorted recursively and no whitespace. Bookkeeping fields (`_via`, `_from`) are fields, so
they are signed too and can't be stripped on the way.

A device numbers its changes from its own counter and never reuses one. A device that receives
its own changes back from a peer (after a restore from an older backup, say) moves its counter
past them before it writes again.

**Merging.** Each field of a record takes the value from the valid change with the greatest HLC
that set it (last-writer-wins per field). HLC order is `(millis, counter, deviceId)`, with the
change id as the final tiebreak. A record is deleted when its winning `_deleted` is true. Merging
is commutative and idempotent: every device that holds the same set of changes computes the same
state.

A field named `"<field>.<key>"` sets one entry of a map field, so concurrent edits of different
entries merge instead of overwriting each other. Den writes `completion.steps` (`steps.<stepId>`),
`eventException.patch` (`patch.<eventField>`, null clears an override) and `family.oversight`
(`oversight.<memberId>` for privacy, `oversight.<memberId>.<setting>` for each other per-person
setting, a key with a dot in it) this way; a write of the whole map replaces it.

A record is identified by `(space, type, id)`: a change's validity depends only on its own space
and `f`, which every replica holding it also holds. Changing who can see an event, chore or list
writes a copy (and its exceptions, completions or items) with the same id into the new space and
removes the old one.

**Validity.** A change counts only if, replayed in HLC order:

1. Its signature verifies against the author device's public key.
2. The author device is approved and not revoked at that HLC, except the genesis changes, a
   device's own pending join record, and a new device letting itself in by recovery (below).
3. The acting member may make it (permissions below), and the device may act for that member.
4. Its fields pass the type's schema (types, lengths, enums).

Invalid changes stay in the log so every replica agrees on what was rejected, but they never
affect state. Each applied change keeps what it overwrote (the field values and field times it
replaced, or that it created the record), so when a change arrives older than the newest one
applied (a partner's week of offline edits, say) the materializer takes back the changes after
its place, newest first, and applies from there: the result is the one a replay from scratch
gives. It does replay from scratch when a revocation with a cutoff, or a replaced recovery key,
lies at or after that place (see below: which of those count can turn on any earlier change),
and when the place is before the window a snapshot kept.

**Snapshots.** Storage that can (files on phones and the hub, IndexedDB in browsers) keeps a
snapshot of what the log materializes to: every record, the rejected changes, the revocation
cutoffs and replaced recovery keys, and what each change of the last 30 days overwrote, with the set of changes it covers
and a digest of them (SHA-256 over each covered change's hash, in log order). A device opens
from it and adds the changes it doesn't cover as if they had just arrived; History of the older
changes is read from it only when asked for. The snapshot never changes an outcome: one that
covers changes the log lacks, was written for another family, is damaged, or has another format
(`snapshotFormat`, bumped whenever validation or merging changes) is ignored and the log
replayed; a stored change older than its window (arriving after it was written) makes the open
replay from scratch too, and the snapshot is written again. Den writes one every 256 changes and
whenever a change lands before the stored one's window, encoding it off the write lock.

Signatures are checked when a change arrives, before it is stored, a batch at a time: in worker
isolates on phones and the hub, in slices that let the page draw (the browser's Web Crypto
checking a slice at once) in browsers. A change whose signature fails is refused and never
stored, so a forged copy can't occupy the genuine change's id. After opening from a snapshot,
off the critical path, the changes stored since it was written have their signatures checked,
and the ones it covers must still give its digest, so a stored change altered since is caught
without checking every signature again (when the digest doesn't match, every signature is checked
and the state is replayed from what is stored). A change that fails is dropped as if it had never
arrived. A log from before snapshots is trusted as it was, every change having been checked when
it arrived. A device's key
is learned from any `device` record whose `pubkey` hashes to the record's id (ids are hashes of
keys); a change from a device whose key isn't known yet waits in memory until it is. A device's
clock moves past valid changes only, so a device nobody approved can't push the family's clocks
ahead.

**Version vectors.** Because change ids are `<deviceId>:<counter>`, "what I have" is a map of
device id to the highest contiguous counter held. Sync sends whatever the peer lacks. A device
that receives only some spaces would see holes where other spaces' changes go, so a sender whose
spaces include the receiver's also sends its `completeVector` (counters up to which it holds every
change in every space); after a clean batch the receiver counts those counters as held
(`Den.ingest(changes, through: ...)`).

### Genesis and trust

Creating a family writes, signed by the founding device: the `family` record (with
`founderDevice`), the founder's `member` record (role `parent`), and the founder's `device`
record with `approved: true`. These are valid because the family's id commits to them: `familyId`
is base32 of the first 10 bytes of SHA-256 of the founder device's public key bytes followed by
the creation time (the family change's HLC milliseconds, as a decimal string), and every joining
device receives the family id and founder key out of band (the QR code). Genesis is open only
until the founder's device record exists.

A new device writes its own `device` record with `approved: false` (its join request), signed by
itself, with no actor, and with a `pubkey` that hashes to its id. While it waits it may only
rename itself or withdraw. It becomes approved only when a change setting `approved: true` is
signed by an already approved, non-shared device whose actor is a parent; the approval also pins
the device's `mode` and `member`. An approved device's `member` never changes while it stays
approved: what it holds follows its owner, so a device handed to someone else is removed (revoked,
which rotates the keys of what it held) and added again. **A device can never approve itself**: a change approving device
X signed by device X is invalid (Sett's self-approval bug, closed by construction), with one narrow
exception, recovery with a proof from a parent's recovery key or the key the family lets its hub
use (see "Recovery" below), and no device
may change its own `approved`, `approvedBy` or `member`, or un-revoke itself. A device may revoke
itself. A parent acting on their own approved device (its owner, or a parent who verified on it)
may change that device's `mode`, `name` and `display`: this is how "Keep the family online" turns
a parent's tablet into the hub; nobody else may change a device's mode from the device itself,
and a personal device always needs an owner. Changes signed after a device's revocation (by HLC)
are invalid.

A device sets its own clock, so a revoked (stolen) device could sign new changes with clocks from
before its revocation, and post them to an old epoch's mailbox the relay still keeps. So a
revocation also records `revokedAfter`: the highest counter of that device's changes the revoking
device held (in its log, or vouched for by a peer's `completeVector`). A change from the revoked
device numbered past `revokedAfter` and clocked before the revocation is invalid, whatever clock
it claims. A replay runs in two passes, both determined by the log alone: the first finds the
valid revocations, the second applies their cutoffs from the start, so a backdated change already
applied is dropped when the revocation arrives. Changes of the revoked device that
the revoker never held are lost with it; a device re-approved later writes normally after its
re-approval.

**Trust decisions are made only on a parent's own device.** Approving, revoking or changing
another device; removing or restoring a member, or changing an existing member's `role`,
`grants`, `signIn` (their own included) or `until` (a sitter's last day); a parent's recovery
key (`member.recovery`, set only by that parent, removable by any) and whether the hub may help
a parent back in (`family.recovery`); the family's `oversight` (every entry) and `assistant`
(which AI reads the family's day, for whom, and what it may spend); and creating, activating,
re-scoping or deleting an AI connection are valid only from a personal device, or from a
hub-mode device whose actor is that device's own owner (a parent's phone running "Keep the
family online") with no `_via`. A shared display never makes them, whoever verified on it, and
neither does a hub nobody owns. A change carrying `_via` (the hub acting for an API token or MCP
client) never touches a device record at all, its own included, so a connection can't switch the
hub back to a personal device and act as its owner. The hub keeps its narrow part of connections: asking for OAuth access
(`pending`), recording token hashes for active ones, and revoking. Adding a member isn't a trust
decision (a parent's import through the hub does it): nothing can act for a new member until a
parent approves a device or an AI connection for them on their own device.

Each space has a key for sealing changes on the relay, with an epoch. The founder's device makes
the first keys at genesis and a parent's device makes one for each member it adds. When a parent's
device revokes another device (directly or by removing its member), it rotates the key of every
space that device held: a new random key, one epoch past every epoch it holds. Older epochs are
kept for reading what was sealed with them. A device that leaves its family wipes its log and
metadata and starts over as a fresh device; it joins again with new keys, since the family
remembers devices it declined or removed.

Every key is bound to the device that made it. The maker signs `"den/space-key/v1" 0x00 |
canonical JSON [family, space, epoch, hash, by, revoked]`, where `hash` is hex SHA-256 of
`"den/space-key/v1/hash" 0x00 | key` and `revoked` lists, sorted, the approved devices that were
revoked when it made the key. Only an approved hub or a parent's own approved device makes keys;
any device may pass one on, and a receiver keeps it only when the statement verifies against a
maker that may make keys. A key whose maker has since been revoked is never used to seal, so a
stolen phone that mints keys after its revocation gets nowhere.

Two parents who revoke devices while out of touch each make a key for the same epoch. Every
replica keeps both and seals with the same one, the lowest `hash` among keys whose maker is in good
standing (`pickSpaceKey`), so the epoch's mailbox doesn't split; the other key's mailbox is still
read. The winner may have been handed to the device the other parent revoked, so a key-making
device that holds a key listing a revoked device the key in use doesn't list rotates again
(`staleSpaceKeys`). The new key lists both revocations, and the family settles one epoch later.

### Recovery

A parent whose phone is lost, wiped or replaced, with no other parent device left to approve a
new one, would otherwise leave the family with nobody able to make a trust decision again, and
by design the hub can't make one either. Recovery lets a new device in as that parent's own,
with one change to its own device record: `approved: true`, `mode: personal`, `member: <the
parent>`, no actor, and a `recovery` field holding a proof. It is the only change a device may
use to approve itself, and validity (`den_core`'s recovery.dart, one hook in validity.dart)
accepts it only when all of this holds, at its place in the log:

- it writes nothing but the device's own `name`, `kind`, `pubkey` (which must hash to its id and
  match any earlier request), `xpub`, `member`, `mode`, `approved`, `revoked: false` and
  `recovery`, and the device isn't approved, revoked or removed already;
- `member` is a live member who is a **parent**: recovery never makes anyone a parent, or lets in
  a device for anyone else;
- the proof's `key` is that parent's current `member.recovery.key` (kind `words`), or the
  family's current `family.recovery.serverKey` (kind `hub`), which is null unless a parent turned
  server help on;
- the proof hasn't expired at the change's clock, and claims at most an hour;
- its nonce is on no device record in the log, so a proof is used once.

The proof is `{kind, member, key, nonce, expires, sig}`: `sig` is `key`'s Ed25519 signature over
`"den/recovery/v1" 0x00 | canonical JSON [family, kind, member, device pubkey, nonce, expires]`,
with a 16-byte random nonce. Like the change's own signature, it is checked when the change
arrives, before it is stored (`Den.ingest`); a forged proof is refused and never stored. The
serving device that admits the join also refuses a proof already expired by its own clock.

A device sets its own clock, so whoever still holds old words, or a hub's key after the family
turned it off, could sign a recovery change dated before the key changed. So a change that
replaces a key (new words, server help off or another key) lists in `kept` the devices the old
key let in that its author holds, and a recovery change made with the old key and clocked before
the replacement counts only for those. The materializer finds replaced keys in its first pass and
applies them in its second, the way it applies revocation cutoffs, both from the log alone. A
device let in by the old key that the replacing parent never heard of is out, like changes of a
revoked device the revoker never held.

- **Recovery words** (works without the server's help). On the parent's own device, during
  family setup and on their page ("Recovery words"), Den shows 12 words: 128 random bits and a
  4-bit checksum written with the BIP-39 English list (den_net's `RecoveryWords`), so a mistyped
  word is caught at once. They stretch with Argon2id (8 MiB, 3 passes, 1 lane, 32 bytes, fixed
  salt `den/recovery-words/v1`) to the seed of an Ed25519 key, whose public half the parent's
  device writes into `member.recovery.key`. "Make new words" replaces it. On a new phone, "I lost
  my phone" takes the words (pasted with spaces, new lines, dashes, numbers or a title around
  them), stretches them, and pairs with the hub (pairing kind `recovery`, below); the hub says
  whose they are, the person says it's them, and the phone signs its own proof with the words'
  key and is in.
- **The hub's help**, only if the family opts in. A parent turns on "Let the hub help us get back
  in" (Settings, Family, their own device): it asks the hub for the public half of its server
  recovery key (`GET /api/v1/recovery/key`) and writes it into `family.recovery.serverKey`.
  Whoever runs the hub then runs `den_hub recover --person "Alex"`, which prints a one-time link
  and four words, good for one phone for 30 minutes. The new phone redeems them with its key
  (`POST /api/v1/recovery/redeem`, limited per client like invites); the hub signs a proof for
  that parent, that device, a fresh nonce and the code's expiry, and the phone joins over `/ws`
  with it. Turning server help off writes `serverKey: null`, after which the hub's key lets
  nobody in, backdated or not.

Every device sees it: History renders such a change as "Alex's new iPhone was let in with Alex's
recovery words" (or "by the hub's recovery"), and every other parent's own device shows it in
Needs you, with "Got it" or "That wasn't us" (an ordinary revocation), until someone there puts
it away. The parent's new phone offers "Remove your old phone" on their page. Recovery is never
an action: no MCP client, API token or assistant can set up, turn on or use it
(`not_exposed.dart`).

What whoever runs the hub can do: with server help **off**, read what the hub holds (every space,
as always) and stop it serving, but make no trust decision and let in no device, and a key the
family turned off stays useless; with server help **on**, also let in a phone as any parent, which
every device shows and any parent can remove.

### Record types and fields

Times are UTC milliseconds unless noted. Local dates are `YYYY-MM-DD` strings in the family's
time zone. Ids are 16-char base32 random unless noted. Icons are short pictogram keys
(`PictogramKeys` in `den_core`): chores `check`, `bed`, `tooth`, `broom`, `trash`, `recycle`,
`dishes`, `cooking`, `laundry`, `hanger`, `bath`, `shower`, `toilet`, `spray`, `pet`, `plant`,
`leaf`, `book`, `homework`, `backpack`, `music`, `shoes`, `car`, `mail`, `tools`, `pill`,
`science`; categories `calendar`, `school`, `sports`, `work`, `health`, `birthday`, `holiday`,
`family`, `travel`, `music`, `party`; rewards `gift`, `film`, `game`, `pizza`, `moon`, `money`,
`ticket`, `treat`; lists one per kind (`shopping`, `checklist`, `packing`, `meal`). A key a
client doesn't know draws nothing.

Removing a record sets `_deleted`; restoring it sets `_deleted` back to false, so undo is exact:
removing an event, chore or list leaves its exceptions, completions or items in place, unseen
while it's gone and back with it. Undo after removing one occurrence lifts its cancellation, and
after removing "this and following" it puts the repeat rule back and restores the changed
occurrences removed with it, in one commit (`Den.restoreEvent`); several items come back in one
commit too (`Den.restoreAll`).

| Type | Space | Fields |
| --- | --- | --- |
| `family` | `f` | `name`, `timezone` (IANA), `weekStart` (0 Sunday, 1 Monday), `founderDevice`, `capture` (`direct`\|`review`), `pointsEnabled`, `oversight` (map: memberId -> `{parentsSeePrivate: bool}`, and `<memberId>.rewardsNeedOk` and `<memberId>.ownPicture` -> bool or null; see "Parental controls"), `assistant` (`{enabled, members, kidDailyLimit, budgetCents}`: the in-app assistant, off until a parent turns it on; parents and the members listed may use it, never a little kid or a pre-reader; default 20 questions a day for a kid and $5 a month), `recovery` (`{serverKey, kept}`: the hub key the family lets help a parent back in, null while off; see "Recovery") |
| `member` | `f` | `name`, `role` (`parent`\|`adult`\|`kid`\|`guest`), `tier` (`preReader`\|`little`\|`big`\|`teen`\|null), `marker` (sky, grass, lavender, tangerine, aqua, coral, sunshine, bubblegum, in the order new people get them; older names are read as one of these), `picture` (a pack id such as `fox`, `initial`, or `photo:<id>` naming one of their `photo` records), `animal` (older versions' look, read as a picture when `picture` is unset), `birthday` (local date or null), `until` (a sitter's last day with access, a local date, or null), `grants` (list: `events`, `chores`, `lists`, `points`), `signIn` (`{kind: pin\|pattern\|none, salt, hash}` for shared screens), `order`, `recovery` (a parent's `{key, kept}`: their recovery key, base64url Ed25519, or null; see "Recovery") |
| `device` | `f` | `name`, `kind` (`phone`\|`tablet`\|`desktop`\|`browser`\|`hub`\|`display`), `pubkey` (base64url Ed25519), `xpub` (base64url X25519 for sealing), `member` (owner id, null for shared), `mode` (`personal`\|`shared`\|`hub`), `approved`, `approvedBy`, `revoked`, `revokedAfter` (written only with `revoked: true`: the highest counter of the device's changes the revoker held), `display` (`{layout: today\|week\|month\|lists\|photos, openCheckoff: bool}`), `recovery` (written once, by a device letting itself in: `{kind: words\|hub, member, key, nonce, expires, sig}`; see "Recovery") |
| `category` | `f` | `name`, `icon` |
| `event` | any | `title`, `notes`, `location`, `category`, `start`, `end`, `allDay`, `tz`, `rrule` (RFC 5545 RRULE without DTSTART, or null), `assignees` (member ids), `reminders` (minutes before, list), `source` (`{kind: manual\|ics\|device, ref, label}`), `rides` (list of `{leg: to\|from, driver: memberId\|null}`), `countdown` (bool) |
| `eventException` | same as event | id `"<eventId>@<occurrence>"`: `event`, `occurrence` (original start), `cancelled`, `patch` (map of event fields: `title`, `notes`, `location`, `category`, `start`, `end`, `allDay`, `assignees`, `reminders`, `rides`) |
| `chore` | any | `title`, `notes`, `icon`, `owner` (`{kind: member, id}`\|`{kind: anyone}`\|`{kind: rotation, ids, every: day\|week, anchor: local date}`), `schedule` (`{rrule, start: local date}` or `{once: local date}`), `dueTime` (`HH:mm` or null), `points`, `steps` (list of `{id, text, owner, points, icon}`, `icon` a chore pictogram key or absent), `reminders`, `active` |
| `completion` | same as chore | id `"<choreId>@<date>"`: `chore`, `date`, `done`, `doneBy`, `owner` (one-day swap; present and null means swapped to anyone) , `steps` (map stepId -> memberId who checked, `""` when checked by open check-off with no owner to credit, or null when unchecked), `points` (what the chore was worth when it was done), `stepPoints` (map stepId -> what the step was worth when checked). Done when `done`, or when every step is checked. The chore must exist and not be removed in the same space, except to remove the completion |
| `adjustment` | `f` | Append-only. `member`, `delta`, `reason`, `by` |
| `goal` | `f` | `title`, `mode` (`target`\|`race`), `target`, `members` (ids, or null for every kid), `start` (local date), `end` (local date or null), `repeat` (`none`\|`weekly`\|`monthly`), `reward` (text) |
| `reward` | `f` | `title`, `cost`, `icon`, `needsApproval`, `active` |
| `redemption` | `f` | `reward`, `member`, `cost` (copied at request time), `status` (`requested`\|`approved`\|`declined`), `decidedBy` |
| `list` | any | `title`, `icon`, `kind` (`shopping`\|`checklist`\|`packing`\|`meal`), `lifecycle` (`running`\|`dated`\|`event`), `needBy` (local date), `event` (id), `pinned`, `order` |
| `item` | same as list | `list`, `text`, `qty`, `store`, `checked`, `checkedBy`, `order` (fractional index string), `toGroceries` (meal items) |
| `subscription` | `p` | ICS feed: `url`, `label`, `category`, `assignee`, `space` for imported events, `include`, `exclude`, `skipAllDay`, `status` |
| `photo` | `f` | A person's photo: `member`, `mime` (`image/jpeg`\|`image/webp`), `data` (base64). The schema reads the format and size from the headers: a 256 px square of at most 40 KB, its `mime` matching its bytes. Never changed: a new picture is a new record |
| `connection` | `p` | AI or automation access: `label`, `kind` (`token`\|`oauth`), `scopes`, `member` (whose permissions it uses; null = parent-level), `tokenHash` (SHA-256 hex), `client` (OAuth client id), `status` (`pending`\|`active`\|`revoked`), `expires`. A hub may create `pending` OAuth connections and set `tokenHash` on approved ones; only a parent's device may set `active` or change scopes. The hub writes a `pending` one only after a parent's own device admits the sign-in request (a request needs no credentials, so the hub holds it until then), and turns down pending ones nobody approved within 15 minutes |
| `signInTries` | `f` | Append-only, from a shared display about itself, with no actor: `device` (the display), `member` (whose PIN or pattern), `tries` (wrong in a row there). The display writes one at every tenth wrong try; a parent's own device says so in Needs you, and History shows it ("Kitchen display counted 10 wrong tries at Alex's PIN"). Nothing else may write one, and it is never changed |

**Points are derived, not stored.** A done completion awards the chore's points to the day's owner
(`completion.owner`, else the rotation's owner that day, else the chore owner, else `doneBy`) and
each checked step's points to the step's owner, else whoever checked it. A chore or step is worth
what the completion recorded when it was done (`points`, `stepPoints.<id>`, written by the change
that marks it done or checks the step), so a new price never changes what was already earned; a
completion with no recorded worth (from before Den kept it) is worth the current price, and a
recorded worth older than the completion's `done` never pays more than the current price. Only
someone who may manage points records more than the price at the time. Totals add
`adjustment.delta` and subtract approved redemptions' `cost`. Concurrent devices can't double
award, and undoing a chore undoes its points with no compensating rows. Each line is dated by the
change behind it (when `done` or the step was set, the adjustment made, the redemption approved),
but a chore or step line never later than the end of the completion's own day (in the family's
time zone): finishing an old day's chore late, or moving a chore to another space (which writes
its completions again), doesn't count toward this week's goals. When a chore moved while an
offline device checked off the old copy, the same chore and day can have a completion in both
spaces; it is paid once, from the space where the chore still lives.
A goal counts chore, step and adjustment lines whose time falls, in the family's time zone, in its
window: `start` to `end` inclusive, or the current week (by `weekStart`) or month for repeating
goals. A member reaches a goal when their running total crosses the target and stays there;
deductions can un-cross it, and a race goes to the earliest such crossing.

Recurrence is expanded in the event's own `tz` (the family's when unset) as wall-clock time, then
each occurrence is converted to UTC, so a 7:00 AM series stays at 7:00 AM across DST. All-day
events start and end at local midnight in that zone. An occurrence lasts what the event does on
the wall clock: an all-day occurrence spans as many local days as the event (so the 23-hour day
the clocks spring forward doesn't spill into the next), and a timed one ends at the same
wall-clock length after its start in the event's zone. Supported RRULE parts: `FREQ`
(`DAILY`\|`WEEKLY`\|`MONTHLY`\|`YEARLY`), `INTERVAL`, `COUNT`, `UNTIL`, `BYDAY` (with ordinals such
as `2TU`), `BYMONTHDAY`, `BYMONTH`, `BYSETPOS`, `WKST`; others are refused by the schema. Editing
"this and following" ends the original series just before the occurrence (`UNTIL`, or a shortened
`COUNT`) and starts a new event there; editing "all" with a new time shifts the whole series,
and its exceptions, by the same wall-clock delta.

**History is derived.** Every valid change renders as an entry: who (actor name, or the device
name), on which device, when, what record, and each field's old and new value. A viewer sees only
entries for records in spaces they hold.

**Where a change came from.** A change that capture made carries `_from`:
`{kind: photo|screenshot|pdf|email|message|link|voice|typed|assistant, reader}`, where `reader`
names the model that read it ("Claude", "Apple Intelligence") and is absent when Den's own reader
did. Any device may write it; the schema checks its shape. History shows it beside the device:
"from a photo, read by Claude". What the in-app assistant changes carries
`{kind: assistant, reader: "Claude"}` ("from the assistant (Claude)"): `Den.attributed(origin,
body)` marks every change committed from its zone, except removals (which carry nothing else)
and changes that name their own origin. Like `_via` it is bookkeeping, never a field diff, and
moving a record to another space drops it.

### Permissions

| Action | Parent | Adult | Kid | Guest | Shared display |
| --- | --- | --- | --- | --- | --- |
| Read space `f` | yes | yes | yes | yes | yes |
| Read `p` | yes | no | no | no | no |
| Read `m:X` | yes if policy allows, and X | X | X | X | no |
| Events, lists: create, edit | yes | yes | grant `events`/`lists` | no | as the verified member |
| Chores: create, edit | yes | yes | grant `chores` | no | as the verified member |
| Complete a chore or step they own, or an "anyone" chore | yes | yes | yes | yes | yes, open check-off if enabled |
| Complete someone else's chore | yes | yes | no | no | as the verified member |
| Swap a chore for a day | yes | yes | yes (their own) | no | as the verified member |
| Check list items | yes | yes | yes | yes | yes |
| Points: adjust, goals, rewards, decide redemptions, set what a chore or step is worth | yes | no | grant `points` | no | as a verified parent |
| Request a redemption | yes | yes | yes (for themselves; granted at once when a parent turned off their "Rewards need my OK") | no | as the verified member |
| Change their own picture (a photo too) | yes | yes | when a parent allows it (teens by default) | yes | as the verified member |
| Members, devices, family settings, approve or revoke devices | yes (trust decisions on their own device only, see "Genesis and trust") | no | no | no | no |

The same `can()` function runs in the UI (to hide what you can't do), on every replica when
validating, and in the hub for API and MCP calls. Validation adds the context `can()` can't see:

- A personal device acts only for its owner. A shared display acts for any member who verified on
  it, or for nobody (then only open check-off, when its `display.openCheckoff` is on), and never
  administers the family. A hub acts for a token's member, or for nobody: then it has parent-level
  permissions except family administration and activating or re-scoping connections, and it
  records the caller's label in `_via` (only hubs may write `_via`). Whoever it acts for, a change
  with `_via` never makes a trust decision (see "Genesis and trust"); the hub must record `_via` on
  every write it makes for an API or MCP caller.
- Setting what a chore or step is worth (a new chore or step with points, or a new price) needs
  the points permission as well as the chores one; recording a completion's worth above the
  price at the time does too.
- Writes into `p` need a parent or a hub; writes into `m:X` need X, a parent the oversight policy
  allows, or a hub.
- Kids complete only chores they own that day, "anyone" chores, and steps they own (checking the
  last one may complete the chore); they swap only their own chores and name only themselves as
  `doneBy`, step checker or reward requester. A redemption is created `requested`, or `approved`
  when its reward needs no approval or the requester's `oversight.<id>.rewardsNeedOk` is false
  (either is enough); only points managers decide it.
- Someone who may not manage the family changes only their own `picture`, and a kid only while
  `Family.ownsPicture` allows it; a `photo` record follows the same rule, and a picture naming
  `photo:<id>` must name one of that person's.
- Nobody gives or takes their own points or decides their own reward request (a points manager
  asking for themselves waits for someone else like anyone). Balances can't be checked here, since
  they derive from completions in spaces a replica may not hold, so `Den` checks them: a request
  is refused when the balance less the requester's requests still waiting is short, and approving
  one is refused when the balance no longer covers it.
- A shared display may add a `signInTries` record about itself, for nobody; no other device may,
  and nobody changes one.
- Members may change their own `signIn`. The family always keeps at least one parent. On a shared
  display a parent with no PIN or pattern never verifies (`Den.verifySignIn`), so once a family
  has a shared display its parents need one to act there; the app asks for one when a parent
  makes a device a shared display.
- A wrong PIN or pattern makes that person's next try on the same screen wait 20 seconds (on a
  shared display, and on a parent's phone handed to a kid). The screen keeps the count on the
  device, so restarting Den doesn't skip the wait, and at every tenth wrong try in a row a shared
  display adds a `signInTries` record: a parent's own device says so in Needs you ("Someone tried
  Alex's PIN on Kitchen display 10 times") and History shows it. What remains: `signIn` is in
  `f`, so every family device holds the hash (PBKDF2, 20,000 rounds), and a determined teen with
  a laptop and a family device's data could still find a 4-digit PIN or a 4-animal pattern
  offline. The stakes are bounded: as that person on a shared screen they can give stars, approve
  rewards and change chores, all of which History shows as done there, and never make a trust
  decision.

## Parental controls

Four settings a parent sets on a person's page, each enforced where Den can enforce it.

**Rewards without asking** (`oversight.<kid>.rewardsNeedOk`, default true). Off, a kid's request
for a reward is `approved` when made, if their balance less their requests still waiting covers
it (`Den.requestReward`; validation can't check a balance). A reward marked "no asking"
(`needsApproval: false`) is the other way to the same thing: no OK is needed if either says so.
It gives the kid nothing else: validity still refuses a kid deciding any request (their own
included) or giving or taking stars, since those need `Grant.points`, which the switch never
grants. Turning the switch back on also takes away `Grant.points` if a kid had it.

**A sitter's last day** (`member.until`, a local date in the family's time zone). A sitter's
clock can't be trusted, so three things enforce it, none of them on the sitter's device:

1. A parent's own device with Den open removes the devices of every sitter whose last day has
   passed (`Den.endExpiredAccess`, run by the app's `AccessWatch` whenever people change and
   every quarter hour): the usual revocation with `revokedAfter`, and new keys for every space
   they held. Needs you says so ("Sam's access ended Sunday", until put away), and so does
   History ("removed Sam's phone: Sam's access ended Sunday"). If no parent's device opens Den,
   nothing is revoked, and the sitter keeps the keys they had.
2. Every device serving sync stops syncing with a sitter's device once the day has passed by the
   serving device's clock (`Den.accessEnded`): a session ends with `access-ended`, at once or at
   the next change; the hub also refuses its signed requests and sends it no Web Push. This is a
   serving decision, not a change in the log, so it needs no parent and lifts itself if a parent
   sets a later day. Until a parent's device removes it, the sitter's device still holds the
   family space's key and could read new relay mailbox posts.
3. The sitter's own app shows "Your access ended" once its clock passes the day, or once it is
   removed. Only this part trusts the sitter's clock, and it enforces nothing.

A parent can set a later day, or end access now (`Den.endAccessNow`: yesterday becomes the last
day and the devices are removed at once). A removed device stays removed: after a later day is
set the sitter is invited again, which the page says.

**Telling a teen their privacy changed.** `parentsSeePrivate` decides who receives the space
`m:<id>`: parents' devices hold it only while it is true (a device never receives records it
can't read). `Den.privacyChange(id)` finds, in the log, the latest change that turned it one way
or the other; that person's Today shows "Mom changed this: parents can now see things you mark
Just me" until they put it away (remembered on that device), and History says the same. What
happens to the data:

- Turned off (parents may see again): the records stay where they are, in `m:<id>` with their
  ids; that space simply becomes one parents' devices hold. Through a hub, parents' devices are
  sent its whole history and its key at once (sync works per space, so the counters they skipped
  aren't taken as held). Without a hub, a device holding the space (the teen's, or a hub using
  the relay) notices the change on its next mailbox round, posts the space's whole history once
  (older than the 30 days the mailbox keeps) and leaves its key in each parent device's inbox.
  A device first notes how privacy stands when it first runs this version, so a change made
  before then isn't re-shared this way.
- Turned on (private): only what the teen marks Just me from then on is kept from parents.
  Parents' devices stop receiving the space and stop showing it, but keep in their logs what they
  already received: what they saw can't be unseen, and the confirm card says so. The space key
  isn't rotated; parents' devices are trusted not to read a space they no longer receive.
- Moving the records to another space wouldn't do: `p` hides them from the teen and `f` shows
  them to everyone.

A limit found on the way and left as it was: with no hub, a teen's device that joins while
privacy is already on never gets its own space's key (only a device that may hold a space passes
its key on, and parents' devices don't hold it then), so its Just me items stay on that device.

**Photos.** A person's picture can be `photo:<id>`: a `photo` record in `f`, so every device of
the family and nothing else has it, synced and sealed like any record. The device that takes or
picks it makes it small first: in a browser, a file input taking `image/*` (on an iPhone or iPad
it offers Take Photo and Photo Library; Camera adds `capture`), drawn center-cropped onto a 256 px
canvas and encoded as a JPEG under 40 KB (`web/den_web.js`); on a phone the system camera or
library (`image_picker`), on a computer the file chooser, then cropped and encoded in Dart
(`package:image`, off the UI thread). `DenAvatar` draws it in the person's ring, the silhouette
until it arrives. A parent sets anyone's; a person their own; a kid only while
`oversight.<kid>.ownPicture` allows it, which defaults to yes for a teen and no for a younger kid.
Every photo stays in the log for good; the cap keeps that small.

**Older versions.** Every new field is optional. A version from before these settings refuses,
as invalid, the changes that carry them (`oversight.<id>.<setting>`, `until`, `photo` records),
so on such a device a kid's instant reward doesn't count and a photo isn't drawn (the member's
`photo:<id>` passes its picture check there and draws the initial) until it updates; then it
replays the log and counts them. Privacy keeps its old shape (`oversight.<id>:
{parentsSeePrivate}`), so older devices still follow it.

## Network

### Sessions

Every connection (device to hub, device to device, through a relay tunnel or not) starts with a
handshake inside the WebSocket:

1. Client sends `hello {v: 1, family, device, pubkey, eph}` where `eph` is a fresh X25519 public
   key.
2. Server replies `hello {device, pubkey, eph, sig}`, `sig` = Ed25519 over the transcript hash
   (SHA-256 of both hellos).
3. Client sends `auth {sig}` over the same transcript.
4. Both derive `k_c2s` and `k_s2c` with HKDF-SHA256 from X25519(eph, eph'), salt = transcript
   hash. Every later frame is AES-256-GCM with a 96-bit nonce made of a direction byte and a
   64-bit counter that must strictly increase; a repeated or older counter closes the session.

Fresh ephemeral keys per session give forward secrecy. A device the other side doesn't know as
approved gets only the pairing messages below. A device serving sessions (the hub, a phone during
pairing) gives devices it doesn't know as approved a few places of their own (8 by default,
counting handshakes in progress), apart from the approved devices' places, and 30 seconds to
prove an invite or code; a device that proved one may wait 15 minutes for a parent's approval.

A session frame carries at most 1 MiB of plaintext; a larger frame closes the session before it
is decrypted. Servers built on den_net's WebSocket helpers (the hub's `/ws`) and the relay read
each WebSocket frame's header as it arrives and close the connection as soon as a frame, or the
fragments of one message, announce more than their limit, so nothing oversized is buffered.
Clients (dart:io and browser WebSockets) have no such hook and buffer each whole message they
receive; the session's limit then applies.

### Sync messages (inside the session)

- `have {vv}`: my version vector, per space I'm entitled to.
- `changes {list}`: changes the peer lacks, filtered to spaces the peer's member may read.
- `push {list}`: live changes as they're made.
- `keys {space, epoch, key, by, revoked, sig}`: space keys with their maker's statement, sent to
  a newly approved device, and to the remaining devices after a revocation rotates them (sealed
  to the device's `xpub` and signed by the sending device when sent through the relay).

### Pairing

- **QR code** (default): `den://join?f=<familyId>&fk=<founderPubkey>&d=<inviterDevice>&k=<inviterPubkey>&s=<128-bit secret>&h=<hub URLs>&r=<relay URL>&x=<expiry>`. The joining device connects, presents `HMAC-SHA256(secret, its pubkey)`, and writes its join request. The inviting device shows "Approve <name>?" and a parent approves. The QR carries the key, so nothing in the middle can substitute it.
- **Spoken code** (no camera, over the phone): 4 words from a 2048-word list (44 bits), valid 10
  minutes, burned after 5 wrong tries. Both sides first stretch the code with Argon2id (4 MiB,
  3 passes, 1 lane, 32 bytes, fixed salt `den/spoken-code/v2`): the rendezvous slot is
  HMAC-SHA256(stretched, `den/rendezvous/v2/code`), and each side proves the code with
  HMAC-SHA256(stretched, label | transcript hash | its key), the joiner first. Every guess at a
  code, by a relay holding its slot or by a device holding a proof, costs one Argon2id run, so
  searching the 2^44 codes within a code's life is far beyond reach; a joiner stretches its code
  once. The joiner trusts nothing the other side sends (no family, no changes, no "approved")
  until that side's proof checks out, so a stranger answering on the network can't pose as the
  family. Both screens then show 3 matching words derived from the session transcript; the
  parent approves only if they match. A relay that swapped keys would produce different words.
- **Invite by message** (no camera, no simultaneous screens; the default where the family has a
  hub): a parent's own device makes an invite naming the hub (`createHubInvite`) and signs it
  as an `InviteGrant` with context `invite`, or `invite:<memberId>` for one person. The hub
  keeps it, until it expires (3 days from the app, a week at most), under 4 random words from
  the same list, and the parent sends a link (`https://<hub>/#/join/<word>-<word>-<word>-<word>`)
  with the words through the share sheet. Whoever has the words gets the invite back
  (`POST /api/v1/invites/redeem`), joins over the hub's `/ws` pinning the hub's key, and asks
  to be that person's device; a parent approves with one tap on their own device. Wrong words count against every
  invite: 10 in 10 minutes and the hub stops answering for a while. The hub drops an invite
  whose parent device has since been revoked or no longer belongs to a parent.
- **Recovery words** ("I lost my phone"): the joiner connects to a device that serves sessions
  (the hub) with no family, and sends `pair {kind: recovery, key, proof}`: `key` is hex SHA-256
  of its recovery key's public half, `proof` that key's signature over `den/pair/v1/recovery` 0x00
  | transcript hash | its own key. The serving side finds the parent whose `member.recovery.key`
  hashes to it, checks the signature, and answers `pair_ok` with the family, its founder key,
  that parent's id, name, color and picture, and its own proof: HMAC-SHA256 keyed by the
  recovery key's public half over `den/pair/v1/recovery-host` 0x00 | transcript hash | its key.
  Only the family's devices hold that key, so a stranger answering can't pose as the family; the
  joiner trusts nothing before it checks out. After the person confirms, the joiner writes its
  recovery change (`Den.requestRecovery`, which this device can't check yet: it holds none of the
  log) and sends it as its `join`; the serving side lets it in at once. With the hub's help, the
  joiner joins with the invite and proof `POST /api/v1/recovery/redeem` gave it instead.
- **Waiting for approval** survives the app closing: the joining device remembers the device it
  joined through and, while unapproved, connects to it again (pinned to that device id). It
  asks nothing on those connections, so it needs no new invite: the device it waits on tells it
  `approved` when a parent approves, or simply syncs with it once it is. A connection that
  proves nothing lasts 30 seconds, so a waiting device reconnects with the client's backoff
  (at most 2 minutes apart); the approval reaches it on the next connection at the latest. A
  device turned away is told so (`join_rejected`, at once when it connects after the fact),
  stops asking, and remembers it; a new invite on a fresh device id is the way back in.

A device's keys and its log belong together. A device opens its keys only with a log that holds
its family (`familyId` in the metadata); keys without one (storage cleared or evicted, a device
that left its family) and a log without its keys are replaced by fresh keys and an empty log, and
the device joins again. Reusing approved keys over a fresh log would restart the change counter
under ids the family already holds. A background refresh never starts a device over.

Every join request comes with a fresh proof of an invite or code, including a device asking
again about a request already in the log. Declining a request revokes it where the declining
device may (a parent's own device), and the device declining it refuses that device from then
on, so a declined device can't keep asking.

### Relay

`den_relay` offers three things, all over HTTPS/WSS:

- **Tunnel**: a hub keeps `WSS /tunnel/<hubDeviceId>` open, authenticated by signing the relay's
  challenge; clients open `WSS /connect/<hubDeviceId>` and the relay pipes frames. The session
  handshake above runs end to end through it.
- **Mailbox**: for families with no hub online. `POST /mailbox/<id>` appends a sealed blob;
  `GET /mailbox/<id>?after=<cursor>` reads. The id is HMAC(space key, "mailbox:<epoch>"), the blob
  is XChaCha20-Poly1305 under the space key with the signed change inside. Persistent with a
  30-day TTL, size caps, and rate limits per client and per mailbox. A device that rotates a key
  leaves it, sealed, in the inbox of each device that may hold the space, once per device; a
  delivery the relay refuses (full, rate limited, unreachable) is retried for that device alone
  after a minute, doubling to six hours, and never holds up the other deliveries or the posting.
- **Rendezvous** for pairing without a hub: a short-lived slot keyed by the invite secret's hash,
  or by the stretched spoken code.

A client, for every limit and share, is an IPv4 address or the /64 an IPv6 address is in. Besides
the relay-wide caps, each client has its own share, so no one client can deny service to the
others: mailbox bytes it stored (256 MiB) and mailboxes it created (1,000) while they hold blobs,
hub tunnels (16), streams through any one hub's tunnel (16 of its 64), and rendezvous hosts
waiting (8). Requests over a share are refused (`507` with `cap: client`, `503` before a
WebSocket upgrade).

Relays keep no accounts and log no content. Families can run their own; the default is
`relay.den.family` (hosted service, placeholder name).

### Phone calendars

A parent's phone can bring in calendars it already holds (EventKit on iOS, the Calendar Provider on
Android), the way around Google and Microsoft sign-ins. Each picked calendar goes to Everyone
(`f`), Parents (`p`) or Just me (`m:<parent>`); every occurrence from 14 days back to 180 days
ahead becomes a read-only event assigned to that parent, with no reminders of its own (the phone
already alerts), and `source: {kind: device, ref: "<deviceId>/<calendarId>/<eventId>", label:
<calendar name>}`, where an occurrence of a repeating event carries `<eventId>@<timestamp>`. The
device id in the ref keeps two phones from touching each other's events. Each pass, at start, on
returning to the app, every 15 minutes while it runs and in the background refresh, updates what changed, moves a calendar's events when its
audience changes (same ids), and removes events deleted on the phone within the window it read and
every event of a calendar no longer brought in. Without calendar access nothing is removed. The
picks stay on the phone (shared preferences, keyed to the family).

## Hub API (for browsers' sync, Home Assistant, scripts)

All under `/api/v1`, JSON, bearer token in `Authorization`. Tokens are shown once, stored as
SHA-256 hashes, carry scopes and an optional expiry, and are attributed by label in History.

Scopes: `read`, `calendar`, `chores`, `lists`, `points`, `admin`. `read` covers every GET.

| Method and path | Scope | What |
| --- | --- | --- |
| `GET /health` | none | `{ok, version}` |
| `GET /api/v1/today?date=` | read | Events, chores by person, pinned lists, gaps |
| `GET /api/v1/members` | read | Members (no sign-in hashes) |
| `GET /api/v1/events?start=&end=` | read | Expanded occurrences |
| `POST /api/v1/events`, `PATCH /api/v1/events/{id}`, `DELETE ...` | calendar | `scope=one\|following\|all`, `occurrence=` |
| `GET /api/v1/chores?date=` | read | Chores for a day with completion and steps |
| `POST /api/v1/chores/{id}/complete` `{date, done}` | chores | |
| `POST /api/v1/chores/{id}/steps/{stepId}` `{date, checked}` | chores | |
| `GET /api/v1/lists`, `POST /api/v1/lists/{id}/items`, `PATCH /api/v1/items/{id}`, `DELETE ...` | lists | |
| `GET /api/v1/points` | read | Totals, goals, standings, rewards |
| `POST /api/v1/points/adjust` | points | |
| `GET /api/v1/history?q=&limit=` | read | |
| `GET /api/v1/search?q=` | read | |
| `GET /api/v1/stream` | read | Server-sent events: `changed {types}` after every applied change |
| `GET /api/v1/actions`, `POST /api/v1/actions/{name}` | any token; each action's scopes | Every action MCP offers, by the same name and schema (see "Actions"); `?preview=1`, `Idempotency-Key`, two-step `confirm`, receipts and `undo`. The write routes above are adapters over these |
| `GET`/`PUT /api/v1/capture/reader` | signed by a device (`PUT`: a parent's own device) | The family's capture reader, never with its key |
| `POST /api/v1/capture/read` | signed by a device whose member may add things | Reads what was shared with the family's reader; returns den_capture's JSON |
| `POST /api/v1/invites` | an `InviteGrant` from a parent's own device | Keeps the invite under four words; returns them and a link |
| `POST /api/v1/invites/redeem` | the four words | The invite, who it is for, the family's name |
| `GET`/`PUT`/`DELETE /api/v1/push`, `POST /api/v1/push/test` | signed by a personal device | The hub's VAPID key; this device's Web Push subscription; a test notification |
| `GET /ics/<token>/family.ics` | read token in path | Read-only ICS feed for other calendar apps |
| `GET /ws` | session handshake | Device sync |
| `POST /mcp` | bearer or OAuth | MCP Streamable HTTP: 2026-07-28 (stateless, headers checked against the body) and the session-based versions before it |
| OAuth: `/.well-known/oauth-authorization-server`, `/.well-known/oauth-protected-resource[/mcp]`, `/oauth/register`, `/oauth/authorize`, `/oauth/token` | | OAuth 2.1 with PKCE for remote MCP clients such as claude.ai: client ID metadata documents, registration, or clients a parent sets up; `resource` checked; `iss` on every redirect |
| `GET /api/v1/connections/requests`, `POST /api/v1/connections/requests/{id}` | signed by a parent's own device | Sign-in requests waiting at the hub (client name, redirect host, a code to match); admitting one writes its `pending` connection |
| `GET`/`POST /api/v1/connections/clients`, `DELETE /api/v1/connections/clients/{id}` | signed by a parent's own device | OAuth clients a parent sets up for assistants that can't register (Alexa+); the secret is shown once |
| `GET`/`PUT /api/v1/assistant`, `POST /api/v1/assistant/model` | signed by a device; `PUT` by a parent's own | The in-app assistant's provider and key, kept on the hub; model requests forwarded under `family.assistant` and the month's budget |
| `POST /api/v1/link/window` | signed by a parent's own device | Opens "Add a device" for 10 minutes; in the public posture browsers can ask to link only then |
| `GET /api/v1/recovery/key` | signed by a parent's own device | The hub's server recovery key, for "Let the hub help us get back in" |
| `POST /api/v1/recovery/tickets` | `den_hub recover` on the hub's machine (a secret in the data directory) | A one-time link and four words for one parent, 30 minutes, only while the family has server help on |
| `POST /api/v1/recovery/redeem` | the four words and the new device's key | The hub's recovery proof for that device and an invite to join with it |

The hub is a device in the family: it holds its own key and every space, signs the changes it
makes for API and MCP callers with `actor` set to the token's member (or null with the token
label recorded in `fields._via`). A token with no member reads at parent level, so it honors the
oversight policy like a parent's device: nothing from a member's space whose `parentsSeePrivate`
is false reaches it, not even in derived views (points lines, Today's gaps, store names), which
the hub filters because it computes them over every space it holds.

## Actions

`den_actions` defines every verb once, for the app, the hub's REST API (`/api/v1/actions`), MCP and
the in-app assistant. An `ActionSpec` has a dotted name (`events.update`) and the MCP and REST name
(`update_event`), a description for models, an input schema in the portable subset every
function-calling API takes (an object at the top, one type per value, string enums, `items` on
every array, no `anyOf`, `additionalProperties: false` only at the top) and an output schema,
the token scopes that may call it, what the person must be allowed (`can()`; it hides the action,
and the engine still decides each change), its effect (read, write, destructive), whether it is
idempotent, who confirms it, the `Den` methods it calls, and an example that works on the demo
family.

`ActionRunner.run(context, name, args, mode)` checks the surface, the scopes and `can()`, checks
and reshapes the input against the schema, then:

- `RunMode.preview` (or `preview: true`) runs it on `Den.fork()` and answers with the history
  entries it would make and warnings (new overlaps or missing drivers, duplicates);
- `RunMode.run` asks first when the spec says so: `Confirm.server` actions (removals, a whole
  series, more than 5 items) answer with a preview and a token, and only a second call with
  `confirm: <token>` from the same caller and the same input runs; `Confirm.client` actions are
  the client's to ask about (MCP clients from the hints; the assistant asks for a tap when the
  call touches someone else's things or a whole series);
- `RunMode.confirmed` runs it (the person tapped yes; the older REST routes).

Every write runs inside `Den.recording(undoOnError: true)`, so a write that fails half way leaves
nothing behind, and answers with a `Receipt {id, summary, undoable, tool, changes}`. `undo` takes
a receipt back with `Den.undo`, which writes the field-level inverse of each change from what it
replaced: what it made is removed, what it removed comes back, map entries one at a time,
adjustments get one the other way; fields someone changed since are left and reported, and
adding or removing people, device and AI-access changes and reward requests can't be undone.
Receipts belong to their caller and last while the runner does.

Coverage is enforced by tests: `den_actions/test/coverage_test.dart` reads every public write
method of `Den` from its source and fails unless each is called by some action or listed in
`not_exposed.dart` with a reason (never both), then runs every example through a `Den` that
records its calls and checks they stay within the spec's `engine` and that the answer fits its
output schema; `den_hub/test/mcp_parity_test.dart` checks MCP against the specs.
Not exposed, by design: trust decisions (devices, AI access, roles, permissions, sign-in,
removing people, oversight, a sitter's last day and ending it, recovery keys and the hub's help),
founding, joining, recovering or leaving a family, sync and keys, the hub's own bookkeeping, and
adding a photo (made small on the device that takes it; MCP and the assistant see
`picture: "photo:<id>"` and a sitter's `until`, and change pictures only to the pack or an
initial with `set_picture`).

## MCP

The hub serves MCP over Streamable HTTP at `/mcp` and over stdio with `den_hub mcp`, as an adapter
over den_actions: `tools/list` is the specs a token may use (its scopes, and `can()` for its
member, so a kid's assistant sees about a dozen tools), each with `inputSchema`, `outputSchema` and
annotations (`readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint: false`);
`tools/call` runs them with the token's member acting, answering with one speakable text and
`structuredContent`. Names resolve to ids, listing valid choices on a miss. Tool set:
`get_overview`, `get_family`, `list_events`, `list_chores`, `get_lists`, `get_points`, `search`,
`get_history`, `create_event`, `update_event`, `delete_event`, `set_ride`, `create_chore`,
`update_chore`, `delete_chore`, `complete_chore`, `swap_chore`, `create_list`, `update_list`,
`delete_list`, `add_items`, `update_items`, `remove_items`, `adjust_points`, `save_goal`,
`delete_goal`, `save_reward`, `request_reward`, `decide_reward_request`, `add_from_text`, `undo`,
`save_category`, `delete_category`, `update_family_settings`, `save_member`, `set_picture`,
`save_calendar_feed`, `remove_calendar_feed`. The 2025 names (`get_today`, `get_week`,
`list_members`, `list_lists`, `list_rewards`, `check_step`, `check_item`, `remove_item`,
`clear_checked`, `create_goal`, `decide_redemption`) still run for one release, unlisted. REST
and MCP share one runner, so a connection's receipts and confirmations work on either.

Both eras of MCP share the endpoint. A request whose `params._meta` names its protocol version
(2026-07-28) stands alone: no session, its `MCP-Protocol-Version`, `Mcp-Method` and `Mcp-Name`
headers must match the body, `server/discover` answers the versions and capabilities, and lists
and reads say how long to keep them (`ttlMs`, `cacheScope`). `initialize` still opens a session
for 2025-11-25 and earlier. A change that needs a yes asks through the client when it can show a
form (MRTR: an `input_required` result whose `requestState` is the runner's confirmation token,
which stays on the hub, bound to the connection, tool and input, for ten minutes and once);
otherwise the `confirm` two-step. Resources (`den://today`, `den://week`, `den://family`,
`den://lists`, `den://chores`, `den://points`, and templates for one list, day or person) are the
read actions' answers; prompts ("Plan the week", "Make a shopping list") are offered when their
tools are; `subscriptions/listen` streams `notifications/resources/updated` for the resources a
client follows.

Addresses callers give the hub (calendar feeds, client metadata documents) are fetched through
`NetGuard`, which resolves each connection's host once, refuses loopback, private, link-local,
carrier-grade NAT, unique local and metadata addresses (IPv4 inside IPv6 judged as IPv4), and
connects to the address it checked, so DNS rebinding can't slip between the check and the
connection; redirects are checked again. The operator can admit a home network
(`DEN_FETCH_ALLOW`).

## Home Assistant

`custom_components/den` (HACS): config flow by zeroconf (`_den._tcp`) or URL plus token.
Entities: a `calendar` per member and one for the family; a `todo` per list (create, check,
rename, delete items); `sensor` per member for points and chores left today; a `sensor` for the
next event. Services: `den.complete_chore`, `den.add_item`, `den.adjust_points`. Events on the
HA bus: `den_chore_completed`, `den_item_checked`, `den_event_starting`. Live updates come from
`/api/v1/stream`. Home Assistant's own MCP client can use the hub's `/mcp` for Assist.

## Capture

`den_capture` turns what a family shares into a draft, checks it, and writes what they choose.

1. **Input.** Typed or spoken words (on-device speech recognition), something shared from another
   app (text, an email, a link, images, PDFs), or a photo from the camera.
2. **A reader** returns one JSON shape (`CaptureWire.schema`: events with dates, times and a
   structured repeat; chores with owners or turns; items with qty, store and list; reminders;
   unclear notes). Readers, in the family's order: the device's own model (Apple Foundation
   Models on iOS and macOS 26, Gemini Nano through ML Kit's Prompt API on supported Android),
   then Den's own rules (pure Dart, everywhere); a model on a home computer (Ollama, often on the
   hub's machine); Claude with a parent's API key (structured output, photos and PDFs read
   directly). A reader that can't see images gets the text the device found in them (Vision,
   ML Kit text recognition). Nothing leaves the device unless a parent connected a reader that
   runs elsewhere; the key stays in this device's secure storage and never enters the log.
   A parent can instead set the reader up once on the hub (`/api/v1/capture`, docs/hub-api.md)
   for every device, kids' tablets included when they may add things: the device signs each
   request with its own key (`DeviceRequest` in den_net: approved device, addressed to this hub,
   fresh, never replayed, acting member checked), the hub reads as that member sees the family,
   and the key stays in the hub's data directory. Devices try the hub's reader after their own,
   or first when the family chose that.
3. **Resolution** (`draftFrom`) matches names to members ("me" is whoever is sharing), items to
   lists (the groceries list unless one is named; a named list the family lacks is proposed),
   repeats to RRULEs aligned to their first real day, and categories by icon. Unknown names,
   missing days and guesses become issues on their entry.
4. **Checking** (`checkDraft`) builds the exact fields each write will make and runs den_core's
   `checkFields` and `can()` for the acting member, then flags what's already over or already on
   the calendar or list. Nothing is written yet.
5. **Writing** (`writeDraft`) adds the chosen entries through `Den` as the acting member, each
   change carrying `_from`. With the family's `capture` setting `direct`, entries that need no
   look are added at once with Undo and the rest wait; with `review`, everything waits in the
   tray. Reminders are written as a one-day chore with a reminder at its time.

## Notifications

Reminders are computed from synced data and scheduled as local notifications on each device, so
they work offline with no server. Each device keeps the next 48 hours with the OS (at most 60,
under iOS's limit), planned again at start, after every applied change and on a timer while the
app runs: a personal device holds its owner's reminders, a shared display or hub everyone's, with
items outside `f` shown only as "A reminder from Den". The notification id is a hash of
`ReminderDue.key`, so planning again replaces a reminder instead of adding a second one; a tap
opens `/event/<id>?at=<occurrence>` or `/chore/<id>?date=<date>`.

Phones also refresh with Den closed: a periodic background task (`family.den.refresh`, about
hourly; Android WorkManager, iOS BGAppRefreshTask) connects to the hub for a few seconds to catch
up, brings in the phone's calendars, plans the reminders again from all of it, and lets what it
wrote go out before disconnecting. Only one engine may hold a device's change log in a process,
since two could reuse a change counter: the holder registers a port named `den.engine` with the
process's `IsolateNameServer`. A background task that finds the app holding it asks the app to
refresh instead; the app at start waits for a background task to finish; a holder that stopped
answering pings is taken over.

The hub additionally sends pushes for live events (a message, an approval waiting) through a
pluggable notifier: Home Assistant's `notify` service, ntfy, or the hosted push relay.

Browsers can't schedule notifications, so there the hub sends them with **Web Push** (a Home
Screen web app on iOS 16.4 and later, or any browser with Web Push). The hub makes a P-256 VAPID
key pair once and keeps it with each device's subscription in `<data>/hub/push.json` (its
user only). A personal device turns reminders on with one tap (the browser subscribes with the
hub's public key, then `PUT /api/v1/push`, signed by the device like its other requests). Each
reminder the hub's reminder service sends also goes to the subscribed devices of the people it is
for who can read its space, encrypted for each browser (RFC 8291, `aes128gcm`) and authorized
with an ES256 VAPID JWT (RFC 8292), so the push service carries only ciphertext. The hub also
nudges: a device asking to join (parents), a reward asked for (whoever decides rewards), a chore
given to someone for today or tomorrow (them). Pushes go only to known push services' hosts. The
service worker shows each push and a tap opens its route (`/event/<id>?at=`, `/chore/<id>?date=`,
`/today`, `/points`).

## The app

`app/lib` is cut by what changes together:

```
main.dart          boot only
app/               den_app.dart, router.dart (composes the features' routes), redirect.dart,
                   shell.dart, app_state.dart, den_scope.dart, actions.dart, format.dart,
                   words.dart, family_reads.dart, side_panel.dart, navigation.dart
design/            tokens, theme, type, motion, layout, pictures, pictograms; widgets.dart,
                   feedback.dart, forms/ (forms.dart), pickers/
platform/          capabilities.dart, storage/, sync/, notifications/, background/, calendars/,
                   capture/, photos/, web/, time_zone.dart
features/<bucket>/ screens/, widgets/, state/, words/, routes.dart, <bucket>.dart
                   today, calendar, chores, rewards, lists, add, assistant, family,
                   onboarding, shared_screens, settings, advanced
```

- `design/` imports Flutter, Phosphor and den_core's model types, never `Den`, `AppState`,
  go_router, `platform/` or a feature.
- `platform/` never imports a feature. Every "is this a browser" or "which operating system"
  question is a named getter in `platform/capabilities.dart`.
- A feature reaches another only through its barrel, `<bucket>.dart` (and the calendar's words
  through `calendar_words.dart`), and its pages by their paths. Each feature has `routes.dart`;
  `app/router.dart` only composes them.
- `words/` is plain Dart (no Flutter, no `BuildContext`): words take `FamilyReads`, the reads
  `AppState` mixes in, so the hub and an assistant can say things the way the screens do.

**Writes.** Every change the app makes is a den_actions action (see "Actions"), run by
`AppActions` (`app/actions.dart`) with `Surface.app` as the person using the device; screens ask
their own questions first, so it runs confirmed. Screens call their feature's actions in
`state/` (`ChoreActions`, `ListActions`, `RewardActions`, `EventActions`, `FamilyActions`), never
the engine. The writes no action offers on purpose go to the engine from `state/` only: trust
decisions (`TrustActions`, `ConnectionActions`), who is acting on a shared screen
(`SignInActions`), adding a photo (`PictureActions`) and founding a family (`OnboardingActions`);
what Add read is written by
den_capture inside `AppActions.record`. Undo takes back a write's receipt with `Den.undo`.
`app/test/actions_only_test.dart` fails on any other direct write, so every app action is also a
REST, MCP and assistant action by construction.

**Rebuilds.** `AppState` reports what each change touched (record types from `Den.onChange`,
who is acting, the theme and wall settings). `DenScope` is an `InheritedModel` on those:
`context.watch(types)` rebuilds a widget only when one of them (or who's who: family, members,
devices, acting) changes, and `context.view(model)` also keeps a computed view (`TodayModel`,
`ChoresModel`, `ListsModel`, `PointsModel`, `WeekModel`, `OccurrencesModel`) until what it reads
changes or the day turns. `context.app` still rebuilds on everything; the wall and the kids'
screens use it, since they show everything. The router's redirect runs again only when who's who
or the wall setting changes, and the app itself rebuilds only for the theme and the wall setting.

**The AI helper** (`features/assistant`, off by default; DESIGN.md, "AI helper"). Add sends a
question or a change to `/ask` (a sheet, or a panel from 840 pt) with an `AskRequest`, which also
holds the conversation, an `AskSession`, for as long as the route lives and no longer. The
session runs den_assistant's `AssistantLoop` on the device: its tools are den_actions' specs
this person may call (`assistantTools`), run by the session's own `ActionRunner` as
`Surface.assistant` through `actionExecutor`, so writes are signed by this device with the
person's own permissions and marked `{kind: assistant, reader}` for History; receipts are what
Undo and "undo that" take back. Each turn's system prompt is `ContextPacker` over an
`AssistantSnapshot` built from the app's own views (`TodayModel`, the next seven days, what the
person may do, their recent History). The model is den_assistant's adapter for the hub's
provider with `ModelEndpoint.hub`: every request goes to `POST /api/v1/assistant/model`, signed
with `DeviceRequest` like capture's, on the web (where the CSP allows only the hub) and in the
native apps alike, so no device holds a key. `GET /api/v1/assistant` says first whether this
person may ask, and the hub's refusals (`403`, `429 daily_limit`, `402`, `502`) come back as
`ModelException.code` for the words people see. Closing Ask closes the session: a turn still
running changes nothing more.

## The web app

The hub serves the app (Flutter, built with `--no-web-resources-cdn --csp`: CanvasKit and the
fonts come from the hub). It is made to live on an iPhone's Home Screen, served over HTTPS by a
proxy in front of the hub, where it has the hub as its own origin.

- **Storage.** The change log and metadata live in IndexedDB (`den` database: `changes` keyed by
  change id, `meta` holding the metadata and the engine's snapshot), the device keys in the
  browser's keychain (flutter_secure_storage's web backend; plain page storage where the page
  isn't a secure context). The app asks for persistent storage. A Home Screen app on iOS has
  storage of its own, apart from Safari's, so Safari on an iPhone or iPad shows how to add Den to
  the Home Screen before starting or joining a family.
- **One engine per browser.** Tabs share the log; a Web Lock (`den.engine`) lets one tab write
  it, and another tab waits until it closes.
- **Opening and updating.** `web/sw.js`, registered by `web/den_web.js` as
  `sw.js?v=<build>`, keeps every file the app needs to start in a cache named for its build and
  answers the app shell from it, so Den opens at once and with no connection, from local data,
  then syncs. Each opening (and coming back after a minute away) asks the hub which build it
  serves; a different one installs whole beside the old one, checked to belong to that build,
  and takes over when Den next opens with no window on the old one (or on coming back after ten
  minutes away, with a fresh page), never under a page that runs the old one. The hub's own paths
  (`/api`, `/ws`, `/mcp`, `/oauth`, `/ics`, `/health`, `/.well-known`) are never cached.
- **Founding from a browser.** A browser served by a fresh hub starts the family itself and
  takes the hub in with the setup code it printed (the same flow as from a phone,
  `/api/v1/hub/setup`), approving it on its own when the hub reports the same matching words:
  the page came from that hub, so there's nobody in between to compare against.
- **What the browser can't do** is left out rather than offered: scanning, phone calendars, the
  share extension and on-device speech. Photos and PDFs come through the browser's file picker
  (which offers the camera), the share sheet goes through the Web Share API, reminders through
  Web Push. A person's photo comes through a file input too, made small on a canvas in the page
  (see "Parental controls").

## Security fixes from Sett, by design

| Sett finding | Den mechanism | Test |
| --- | --- | --- |
| A requester could approve itself | Approval valid only when signed by another approved parent device | `den_core` validity tests |
| 2,700 connect codes, IP-keyed limit | QR with a 128-bit secret; spoken codes of 44 bits, 5 tries, 10 minutes, stretched with Argon2id | `den_net` pairing tests |
| Relay could sit in the middle | QR carries the key; spoken codes confirmed by matching words | `den_net` SAS test |
| No replay protection | Unique change ids, per-session counters, signed changes | `den_net` session tests |
| One static key both ways, no forward secrecy | Per-session ephemeral X25519, separate keys per direction | `den_net` session tests |
| Plaintext API tokens with full authority | Hashed, scoped, expiring tokens | `den_hub` token tests |
| Private titles leaked through History and search | Spaces: devices never receive records they can't read | `den_core` space tests |
| Public member list | No unauthenticated data endpoints besides `/health` and pairing | `den_hub` tests |
| Unencrypted backups with every secret | Backups sealed with a passphrase (Argon2id, XChaCha20-Poly1305) | `den_net` backup test |
| In-process master header | None exists | — |
