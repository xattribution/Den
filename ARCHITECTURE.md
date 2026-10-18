# Den architecture

The contract every package builds against. If code and this file disagree, fix one of them in
the same change.

## Packages

| Path | Language | What |
| --- | --- | --- |
| `packages/den_core` | Dart (pure, no `dart:io` in `lib/den_core.dart`) | Data model, hybrid logical clock, signed change log, materializer, permissions, recurrence, chores, points, history, queries, the `Den` engine facade, storage interface |
| `packages/den_net` | Dart | Device handshake and encrypted sessions, sync protocol, pairing (QR invites, spoken codes, matching words), relay client, encrypted backups |
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
keys sorted recursively and no whitespace.

**Merging.** Each field of a record takes the value from the valid change with the greatest HLC
that set it (last-writer-wins per field). HLC order is `(millis, counter, deviceId)`, with the
change id as the final tiebreak. A record is deleted when its winning `_deleted` is true. Merging
is commutative and idempotent: every device that holds the same set of changes computes the same
state.

A field named `"<field>.<key>"` sets one entry of a map field, so concurrent edits of different
entries merge instead of overwriting each other. Den writes `completion.steps` (`steps.<stepId>`),
`eventException.patch` (`patch.<eventField>`, null clears an override) and `family.oversight`
(`oversight.<memberId>`) this way; a write of the whole map replaces it.

A record is identified by `(space, type, id)`: a change's validity depends only on its own space
and `f`, which every replica holding it also holds. Changing who can see an event, chore or list
writes a copy (and its exceptions, completions or items) with the same id into the new space and
removes the old one.

**Validity.** A change counts only if, replayed in HLC order:

1. Its signature verifies against the author device's public key.
2. The author device is approved and not revoked at that HLC, except the genesis changes and a
   device's own pending join record (below).
3. The acting member may make it (permissions below), and the device may act for that member.
4. Its fields pass the type's schema (types, lengths, enums).

Invalid changes stay in the log so every replica agrees on what was rejected, but they never
affect state. The materializer re-sorts and replays from scratch when a change arrives older than
the newest one applied; family-sized logs make that cheap.

Signatures are checked when a change arrives, before it is stored. A change whose signature fails
is refused and never stored, so a forged copy can't occupy the genuine change's id. A device's key
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
the device's `mode` and `member`. **A device can never approve itself**: a change approving device
X signed by device X is invalid (Sett's self-approval bug, closed by construction), and no device
may change its own `approved`, `approvedBy` or `member`, or un-revoke itself. A device may revoke
itself. A parent acting on their own approved device (its owner, or a parent who verified on it)
may change that device's `mode`, `name` and `display`: this is how "Keep the family online" turns
a parent's tablet into the hub; nobody else may change a device's mode from the device itself,
and a personal device always needs an owner. Changes signed after a device's revocation (by HLC)
are invalid.

Each space has a key for sealing changes on the relay, with an epoch. The founder's device makes
the first keys at genesis and a parent's device makes one for each member it adds. When a parent's
device revokes another device (directly or by removing its member), it rotates the key of every
space that device held: a new random key, epoch plus one. Older epochs are kept for reading what
was sealed with them. A device that leaves its family wipes its log and metadata and starts over
as a fresh device; it joins again with new keys, since the family remembers devices it declined
or removed.

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
while it's gone and back with it.

| Type | Space | Fields |
| --- | --- | --- |
| `family` | `f` | `name`, `timezone` (IANA), `weekStart` (0 Sunday, 1 Monday), `founderDevice`, `capture` (`direct`\|`review`), `pointsEnabled`, `oversight` (map memberId -> `{parentsSeePrivate: bool}`) |
| `member` | `f` | `name`, `role` (`parent`\|`adult`\|`kid`\|`guest`), `tier` (`preReader`\|`little`\|`big`\|`teen`\|null), `marker` (blue, green, orange, pink, teal, plum, brown, olive, sky, slate), `animal` (cat, dog, rabbit, bird, butterfly, fish, horse, cow, bug), `birthday` (local date or null), `grants` (list: `events`, `chores`, `lists`, `points`), `signIn` (`{kind: pin\|pattern\|none, salt, hash}` for shared screens), `order` |
| `device` | `f` | `name`, `kind` (`phone`\|`tablet`\|`desktop`\|`browser`\|`hub`\|`display`), `pubkey` (base64url Ed25519), `xpub` (base64url X25519 for sealing), `member` (owner id, null for shared), `mode` (`personal`\|`shared`\|`hub`), `approved`, `approvedBy`, `revoked`, `display` (`{layout: today\|week\|month\|lists\|photos, openCheckoff: bool}`) |
| `category` | `f` | `name`, `icon` |
| `event` | any | `title`, `notes`, `location`, `category`, `start`, `end`, `allDay`, `tz`, `rrule` (RFC 5545 RRULE without DTSTART, or null), `assignees` (member ids), `reminders` (minutes before, list), `source` (`{kind: manual\|ics\|device, ref, label}`), `rides` (list of `{leg: to\|from, driver: memberId\|null}`), `countdown` (bool) |
| `eventException` | same as event | id `"<eventId>@<occurrence>"`: `event`, `occurrence` (original start), `cancelled`, `patch` (map of event fields: `title`, `notes`, `location`, `category`, `start`, `end`, `allDay`, `assignees`, `reminders`, `rides`) |
| `chore` | any | `title`, `notes`, `icon`, `owner` (`{kind: member, id}`\|`{kind: anyone}`\|`{kind: rotation, ids, every: day\|week, anchor: local date}`), `schedule` (`{rrule, start: local date}` or `{once: local date}`), `dueTime` (`HH:mm` or null), `points`, `steps` (list of `{id, text, owner, points, icon}`, `icon` a chore pictogram key or absent), `reminders`, `active` |
| `completion` | same as chore | id `"<choreId>@<date>"`: `chore`, `date`, `done`, `doneBy`, `owner` (one-day swap; present and null means swapped to anyone) , `steps` (map stepId -> memberId who checked, `""` when checked by open check-off with no owner to credit, or null when unchecked). Done when `done`, or when every step is checked |
| `adjustment` | `f` | Append-only. `member`, `delta`, `reason`, `by` |
| `goal` | `f` | `title`, `mode` (`target`\|`race`), `target`, `members` (ids, or null for every kid), `start` (local date), `end` (local date or null), `repeat` (`none`\|`weekly`\|`monthly`), `reward` (text) |
| `reward` | `f` | `title`, `cost`, `icon`, `needsApproval`, `active` |
| `redemption` | `f` | `reward`, `member`, `cost` (copied at request time), `status` (`requested`\|`approved`\|`declined`), `decidedBy` |
| `list` | any | `title`, `icon`, `kind` (`shopping`\|`checklist`\|`packing`\|`meal`), `lifecycle` (`running`\|`dated`\|`event`), `needBy` (local date), `event` (id), `pinned`, `order` |
| `item` | same as list | `list`, `text`, `qty`, `store`, `checked`, `checkedBy`, `order` (fractional index string), `toGroceries` (meal items) |
| `subscription` | `p` | ICS feed: `url`, `label`, `category`, `assignee`, `space` for imported events, `include`, `exclude`, `skipAllDay`, `status` |
| `connection` | `p` | AI or automation access: `label`, `kind` (`token`\|`oauth`), `scopes`, `member` (whose permissions it uses; null = parent-level), `tokenHash` (SHA-256 hex), `client` (OAuth client id), `status` (`pending`\|`active`\|`revoked`), `expires`. A hub may create `pending` OAuth connections and set `tokenHash` on approved ones; only a parent's device may set `active` or change scopes |

**Points are derived, not stored.** A done completion awards the chore's points to the day's owner
(`completion.owner`, else the rotation's owner that day, else the chore owner, else `doneBy`) and
each checked step's points to the step's owner, else whoever checked it. Totals add
`adjustment.delta` and subtract approved redemptions' `cost`. Concurrent devices can't double
award, and undoing a chore undoes its points with no compensating rows. Each line is dated by the
change behind it (when `done` or the step was set, the adjustment made, the redemption approved).
A goal counts chore, step and adjustment lines whose time falls, in the family's time zone, in its
window: `start` to `end` inclusive, or the current week (by `weekStart`) or month for repeating
goals. A member reaches a goal when their running total crosses the target and stays there;
deductions can un-cross it, and a race goes to the earliest such crossing.

Recurrence is expanded in the event's own `tz` (the family's when unset) as wall-clock time, then
each occurrence is converted to UTC, so a 7:00 AM series stays at 7:00 AM across DST. All-day
events start and end at local midnight in that zone. Supported RRULE parts: `FREQ`
(`DAILY`\|`WEEKLY`\|`MONTHLY`\|`YEARLY`), `INTERVAL`, `COUNT`, `UNTIL`, `BYDAY` (with ordinals such
as `2TU`), `BYMONTHDAY`, `BYMONTH`, `BYSETPOS`, `WKST`; others are refused by the schema. Editing
"this and following" ends the original series just before the occurrence (`UNTIL`, or a shortened
`COUNT`) and starts a new event there; editing "all" with a new time shifts the whole series,
and its exceptions, by the same wall-clock delta.

**History is derived.** Every valid change renders as an entry: who (actor name, or the device
name), on which device, when, what record, and each field's old and new value. A viewer sees only
entries for records in spaces they hold.

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
| Points: adjust, goals, rewards, decide redemptions | yes | no | grant `points` | no | as a verified parent |
| Request a redemption | yes | yes | yes (for themselves) | no | as the verified member |
| Members, devices, family settings, approve or revoke devices | yes | no | no | no | no |

The same `can()` function runs in the UI (to hide what you can't do), on every replica when
validating, and in the hub for API and MCP calls. Validation adds the context `can()` can't see:

- A personal device acts only for its owner. A shared display acts for any member who verified on
  it, or for nobody (then only open check-off, when its `display.openCheckoff` is on), and never
  administers the family. A hub acts for a token's member, or for nobody: then it has parent-level
  permissions except family administration and activating or re-scoping connections, and it
  records the caller's label in `_via` (only hubs may write `_via`).
- Writes into `p` need a parent or a hub; writes into `m:X` need X, a parent the oversight policy
  allows, or a hub.
- Kids complete only chores they own that day, "anyone" chores, and steps they own (checking the
  last one may complete the chore); they swap only their own chores and name only themselves as
  `doneBy`, step checker or reward requester. A redemption is created `requested`, or `approved`
  when its reward needs no approval; only points managers decide it.
- Members may change their own `signIn`. The family always keeps at least one parent.

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
approved gets only the pairing messages below.

### Sync messages (inside the session)

- `have {vv}`: my version vector, per space I'm entitled to.
- `changes {list}`: changes the peer lacks, filtered to spaces the peer's member may read.
- `push {list}`: live changes as they're made.
- `keys {space, epoch, key}`: space keys sent to a newly approved device, and to the remaining
  devices after a revocation rotates them (sealed to its `xpub` and signed by a parent device when
  sent through the relay).

### Pairing

- **QR code** (default): `den://join?f=<familyId>&fk=<founderPubkey>&d=<inviterDevice>&k=<inviterPubkey>&s=<128-bit secret>&h=<hub URLs>&r=<relay URL>&x=<expiry>`. The joining device connects, presents `HMAC-SHA256(secret, its pubkey)`, and writes its join request. The inviting device shows "Approve <name>?" and a parent approves. The QR carries the key, so nothing in the middle can substitute it.
- **Spoken code** (no camera, over the phone): 4 words from a 2048-word list (44 bits), valid 10
  minutes, burned after 5 wrong tries. Both screens then show 3 matching words derived from the
  session transcript; the parent approves only if they match. A relay that swapped keys would
  produce different words.

### Relay

`den_relay` offers three things, all over HTTPS/WSS:

- **Tunnel**: a hub keeps `WSS /tunnel/<hubDeviceId>` open, authenticated by signing the relay's
  challenge; clients open `WSS /connect/<hubDeviceId>` and the relay pipes frames. The session
  handshake above runs end to end through it.
- **Mailbox**: for families with no hub online. `POST /mailbox/<id>` appends a sealed blob;
  `GET /mailbox/<id>?after=<cursor>` reads. The id is HMAC(space key, "mailbox:<epoch>"), the blob
  is XChaCha20-Poly1305 under the space key with the signed change inside. Persistent with a
  30-day TTL, size caps, and rate limits per IP and per mailbox.
- **Rendezvous** for pairing without a hub: a short-lived slot keyed by the invite secret's hash.

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
returning to the app and every 15 minutes, updates what changed, moves a calendar's events when its
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
| `GET /ics/<token>/family.ics` | read token in path | Read-only ICS feed for other calendar apps |
| `GET /ws` | session handshake | Device sync |
| `POST /mcp` | bearer or OAuth | MCP Streamable HTTP |
| OAuth: `/.well-known/oauth-authorization-server`, `/.well-known/oauth-protected-resource`, `/oauth/register`, `/oauth/authorize`, `/oauth/token` | | OAuth 2.1 with PKCE and dynamic client registration, for remote MCP clients such as claude.ai |

The hub is a device in the family: it holds its own key and every space, signs the changes it
makes for API and MCP callers with `actor` set to the token's member (or null with the token
label recorded in `fields._via`).

## MCP

The hub serves MCP over Streamable HTTP at `/mcp` and over stdio with `den_hub mcp`. Tools carry
annotations (`readOnlyHint`, `destructiveHint`) and resolve names to ids, listing valid choices on
a miss. Tool set: `get_today`, `get_week`, `search`, `get_history`, `list_members`, `list_events`,
`create_event`, `update_event`, `delete_event`, `list_chores`, `create_chore`, `update_chore`,
`complete_chore`, `check_step`, `swap_chore`, `list_lists`, `create_list`, `add_items`,
`check_item`, `remove_item`, `clear_checked`, `get_points`, `adjust_points`, `create_goal`,
`list_rewards`, `request_reward`, `decide_redemption`. Every call is checked with `can()` under
the token's scopes and member.

## Home Assistant

`custom_components/den` (HACS): config flow by zeroconf (`_den._tcp`) or URL plus token.
Entities: a `calendar` per member and one for the family; a `todo` per list (create, check,
rename, delete items); `sensor` per member for points and chores left today; a `sensor` for the
next event. Services: `den.complete_chore`, `den.add_item`, `den.adjust_points`. Events on the
HA bus: `den_chore_completed`, `den_item_checked`, `den_event_starting`. Live updates come from
`/api/v1/stream`. Home Assistant's own MCP client can use the hub's `/mcp` for Assist.

## Notifications

Reminders are computed from synced data and scheduled as local notifications on each device, so
they work offline with no server. Each device keeps the next 48 hours with the OS (at most 60,
under iOS's limit), planned again at start, after every applied change and on a timer while the
app runs: a personal device holds its owner's reminders, a shared display or hub everyone's, with
items outside `f` shown only as "A reminder from Den". The notification id is a hash of
`ReminderDue.key`, so planning again replaces a reminder instead of adding a second one; a tap
opens `/event/<id>?at=<occurrence>` or `/chore/<id>?date=<date>`. The hub additionally sends pushes for live events (a message, an
approval waiting) through a pluggable notifier: Home Assistant's `notify` service, ntfy, or the
hosted push relay.

## Security fixes from Sett, by design

| Sett finding | Den mechanism | Test |
| --- | --- | --- |
| A requester could approve itself | Approval valid only when signed by another approved parent device | `den_core` validity tests |
| 2,700 connect codes, IP-keyed limit | QR with a 128-bit secret; spoken codes of 44 bits, 5 tries, 10 minutes | `den_net` pairing tests |
| Relay could sit in the middle | QR carries the key; spoken codes confirmed by matching words | `den_net` SAS test |
| No replay protection | Unique change ids, per-session counters, signed changes | `den_net` session tests |
| One static key both ways, no forward secrecy | Per-session ephemeral X25519, separate keys per direction | `den_net` session tests |
| Plaintext API tokens with full authority | Hashed, scoped, expiring tokens | `den_hub` token tests |
| Private titles leaked through History and search | Spaces: devices never receive records they can't read | `den_core` space tests |
| Public member list | No unauthenticated data endpoints besides `/health` and pairing | `den_hub` tests |
| Unencrypted backups with every secret | Backups sealed with a passphrase (Argon2id, XChaCha20-Poly1305) | `den_net` backup test |
| In-process master header | None exists | — |
