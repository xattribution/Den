# Den hub HTTP API, version 1

The wire contract for `den_hub`'s REST API and event stream, as listed in
[ARCHITECTURE.md, "Hub API"](../ARCHITECTURE.md#hub-api-for-browsers-sync-home-assistant-scripts).
The hub implements exactly this file; the Home Assistant integration
(`integrations/homeassistant`) and any script in any language build against it. If code and this
file disagree, fix one of them in the same change.

Device sync (`/ws`), MCP (`/mcp`), OAuth and the ICS feed are specified elsewhere; this file
covers `/health`, everything under `/api/v1`, and the mDNS advertisement.

## Contents

- [Conventions](#conventions)
- [Errors](#errors)
- [Discovery (mDNS)](#discovery-mdns)
- [Shared objects](#shared-objects)
- Endpoints:
  [`GET /health`](#get-health) ·
  [`GET /api/v1/members`](#get-apiv1members) ·
  [`GET /api/v1/today`](#get-apiv1today) ·
  [`GET /api/v1/events`](#get-apiv1events) ·
  [`POST /api/v1/events`](#post-apiv1events) ·
  [`PATCH /api/v1/events/{id}`](#patch-apiv1eventsid) ·
  [`DELETE /api/v1/events/{id}`](#delete-apiv1eventsid) ·
  [`GET /api/v1/chores`](#get-apiv1chores) ·
  [`POST /api/v1/chores/{id}/complete`](#post-apiv1choresidcomplete) ·
  [`POST /api/v1/chores/{id}/steps/{stepId}`](#post-apiv1choresidstepsstepid) ·
  [`GET /api/v1/lists`](#get-apiv1lists) ·
  [`POST /api/v1/lists/{id}/items`](#post-apiv1listsiditems) ·
  [`PATCH /api/v1/items/{id}`](#patch-apiv1itemsid) ·
  [`DELETE /api/v1/items/{id}`](#delete-apiv1itemsid) ·
  [`GET /api/v1/points`](#get-apiv1points) ·
  [`POST /api/v1/points/adjust`](#post-apiv1pointsadjust) ·
  [`GET /api/v1/history`](#get-apiv1history) ·
  [`GET /api/v1/search`](#get-apiv1search) ·
  [`GET /api/v1/stream`](#get-apiv1stream-server-sent-events) ·
  [`GET /api/v1/hub/status`](#get-apiv1hubstatus)
- [Actions: everything MCP and the app can do](#actions-everything-mcp-and-the-app-can-do):
  [`GET /api/v1/actions`](#get-apiv1actions) ·
  [`POST /api/v1/actions/{name}`](#post-apiv1actionsname)
- [Capture: reading for every device](#capture-reading-for-every-device)
- [Invites by message](#invites-by-message)
- [Web Push: reminders in browsers](#web-push-reminders-in-browsers)

## Conventions

**Base URL.** `http://<hub>:47733`. A hub that terminates TLS itself serves the same paths over
`https://` and says so in its mDNS TXT record (`tls=1`).

**Authentication.** Every `/api/v1` request carries `Authorization: Bearer <token>`. Tokens are
created by a parent in the Den app under **Settings → AI & automations**, shown once, and stored by
the hub as SHA-256 hashes (the `connection` record). The hub resolves the bearer token with
`Den.connectionForToken`; a missing, unknown, revoked or expired token gets `401`.

**Scopes.** `read`, `calendar`, `chores`, `lists`, `points`, `admin`.

| Scope | Allows |
| --- | --- |
| `read` | Every `GET` under `/api/v1`, including `/api/v1/stream` |
| `calendar` | `POST`, `PATCH`, `DELETE` on `/api/v1/events` |
| `chores` | `POST /api/v1/chores/...` |
| `lists` | `POST /api/v1/lists/{id}/items`, `PATCH` and `DELETE /api/v1/items/{id}` |
| `points` | `POST /api/v1/points/adjust` |
| `admin` | Implies every other scope; also the actions for the family's settings, people and calendar subscriptions |

`GET /api/v1/actions` takes any valid token, and each `POST /api/v1/actions/{name}` needs one of
that action's scopes ([Actions](#actions-everything-mcp-and-the-app-can-do)).

Scopes gate what a token may *attempt*. Every write is then checked with den_core's `can()` for the
token's member (`connection.member`); a token with no member acts with parent-level permissions
and its changes are signed with `actor: null` and the token's label in `fields._via`. Reads are
filtered to the spaces the token's member may read (`canRead`); a token with no member reads what
a parent reads, which honors the family's oversight policy: a member whose
`oversight.parentsSeePrivate` is `false` keeps their "Just me" space from it, including the titles
den_core puts in derived views (points lines, Today's gaps, store names). A record in a space the
token can't read does not exist as far as the API is concerned (`404`, never `403`).

**Bodies.** Requests with a body send `Content-Type: application/json` (UTF-8), at most 256 KiB.
Responses are `application/json; charset=utf-8`, except the event stream. Unknown request fields
are ignored. In a `PATCH` body an absent field is left alone and `null` clears a nullable field.

**Names.** JSON keys are `snake_case`. Record field names from the change log (`dueTime`,
`toGroceries`) are translated (`due_time`, `to_groceries`); the only place raw record field names
appear is `diffs[].field` in history entries, which reports the change log as it is.

**Ids** are the record ids from the change log: 16-character base32 strings, except completion ids
(`"<choreId>@<YYYY-MM-DD>"`) and step ids (chosen by the chore's author, unique within the chore).
The API takes ids, never names; clients resolve names themselves from `/api/v1/members` and
`/api/v1/lists` (the MCP server is the place that resolves names).

**Times.**

- An *instant* in a response is two fields: `<name>` as ISO 8601 with the family time zone's
  offset at that instant (`"2026-10-20T17:30:00-05:00"`, seconds always present, no fraction) and
  `<name>_ms` as integer UTC milliseconds (`1792535400000`). Both are always present together (or
  both `null`).
- A *local date* is `YYYY-MM-DD` in the family's time zone (`family.timezone`). "Today" means today
  in that zone.
- An instant in a request (query or body) may be given as an integer of UTC milliseconds, as ISO
  8601 with an offset or `Z`, or as ISO 8601 without an offset, which is read in the family's time
  zone (for event bodies: in the event's `tz`). Where a request field also accepts a local date it
  says so; a local date used as an instant means midnight at the start of that day in the family's
  time zone. In query strings a `+` in an offset must be sent as `%2B`; the hub also treats a
  space in that position as `+`, since a raw `+` decodes to a space.

**Spaces and audience.** Records that can be private carry `space` (`"f"`, `"p"` or
`"m:<memberId>"`) and a derived `audience`: `"everyone"` for `f`, `"parents"` for `p`,
`"private"` for `m:<memberId>`. Creating such a record takes an optional `space` (default `"f"`);
the token's member must be able to read the space it writes to.

**Success responses.** `200` with a JSON object; `201` with the created object for creates. Writes
that neither create nor return a record answer `200 {"ok": true}`. Every collection is wrapped in an
object (`{"members": [...]}`), never a bare array.

## Errors

Every error, at every status, has this body:

```json
{
  "error": {
    "code": "insufficient_scope",
    "message": "This token doesn't have the \"lists\" scope.",
    "details": {"scope": "lists"}
  }
}
```

| Field | Type | |
| --- | --- | --- |
| `code` | string | Stable, machine-readable, from the table below |
| `message` | string | Written for people, safe to show in a UI |
| `details` | object, optional | Extra structured data named per code below |

| Status | `code` | When | `details` |
| --- | --- | --- | --- |
| 400 | `invalid_input` | Malformed JSON, a missing or wrong-typed field, a value outside its enum or length, an unparseable time, or den_core's `InvalidInput` | `field` (string) when one field is at fault |
| 401 | `unauthorized` | No `Authorization` header, or the token is unknown, revoked or expired. Also sends `WWW-Authenticate: Bearer` | |
| 403 | `insufficient_scope` | The token lacks the scope the endpoint needs | `scope` (string) |
| 403 | `permission_denied` | den_core's `can()` refused the token's member (`PermissionDenied`) | |
| 404 | `not_found` | No such route, or no such record the token can read | `type` and `id` when a record was asked for |
| 404 | `unknown_action` | `POST /api/v1/actions/{name}` names no action | |
| 405 | `method_not_allowed` | Known path, wrong method. Also sends `Allow` | |
| 409 | `read_only` | Editing or deleting an event imported from a subscribed calendar (`source.kind` is not `manual`) | |
| 409 | `idempotency_conflict` | An `Idempotency-Key` used again for a different action or input | |
| 408 | `timeout` | The body took more than 60 seconds to arrive | |
| 413 | `too_large` | Body over 256 KiB (refused by its `Content-Length` before it is read) | |
| 429 | `rate_limited` | Too many requests from this client (below). Also sends `Retry-After` | `retry_after` (seconds) |
| 500 | `internal` | Anything unexpected. The message carries no stack trace | |
| 503 | `not_ready` | The hub hasn't joined or created a family yet, isn't approved yet, or is still loading its log | |

### Limits per client

The hub counts what each client does, by IP address (an IPv6 address by its /64), and answers
`429 rate_limited` past these budgets:

| What | Budget |
| --- | --- |
| Requests with neither a token nor a device signature (health, status, the web app's files, OAuth metadata and polling) | 600 a minute. Requests from this machine itself (loopback, not through a proxy) aren't counted |
| Tokens or device signatures that don't work, link codes that don't match | 30 in 5 minutes; then every authenticated request from that client gets `429` until the budget refills |
| Browser link slots and link grants | 20 in 10 minutes |
| Wrong setup codes | 5, then that client waits a minute, doubling to an hour with each further wrong code |
| OAuth: registrations, sign-in requests, token requests | 10 an hour, 10 in 15 minutes, 60 in 5 minutes |
| WebSocket connections (`/ws`, `/api/v1/hub/setup/ws`) | 120 new a minute, 64 open at once. A message may be 2 MiB (a session frame, base64 encoded); a frame announcing more closes the socket as its header arrives, before any of it is buffered |

### Behind a reverse proxy

The hub believes `X-Forwarded-For`, `X-Forwarded-Proto` and `X-Forwarded-Host` only from the
proxies listed in `DEN_TRUSTED_PROXIES` (addresses or CIDR networks, comma separated). From those,
the client is the right-most `X-Forwarded-For` address that isn't itself a trusted proxy, and the
public URL (OAuth metadata, link codes, the web app's WebSocket origin) takes the forwarded scheme
and host unless `DEN_PUBLIC_URL` is set. From anyone else the headers are ignored, so a client
can't choose its own address or the hub's public URL; the hub logs a warning the first time an
unlisted proxy sends them.

### Security headers

Every answer carries `X-Content-Type-Options: nosniff` and `Referrer-Policy: no-referrer`, and
`Strict-Transport-Security: max-age=31536000` when the request came over HTTPS (through a trusted
proxy, or by an `https` `DEN_PUBLIC_URL`). JSON answers carry
`Content-Security-Policy: default-src 'none'; frame-ancestors 'none'`. Pages carry
`X-Frame-Options: DENY` and `Cross-Origin-Opener-Policy: same-origin`.

The web app (the Flutter build in `DEN_WEB`) is served with this policy, where `<ws origin>` is
the hub's own `ws://` or `wss://` origin and the hashes are those of any inline `<script>` in
`index.html`:

```text
default-src 'self'; script-src 'self' 'wasm-unsafe-eval' <inline script hashes>;
style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:;
connect-src 'self' <ws origin>; media-src 'self' data: blob:; worker-src 'self' blob:;
manifest-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'
```

So the build must load nothing from a CDN: CanvasKit from the hub (`flutter build web --csp
--dart-define=FLUTTER_WEB_CANVASKIT_URL=canvaskit/`), fonts bundled, and Flutter's fallback
fonts (`fontFallbackBaseUrl`, by default `https://fonts.gstatic.com/s/`) self-hosted or left out.
`DEN_CSP` replaces the whole policy for a build that needs more. Files whose names carry a content
hash (`main.dart.3f2a9c1b.js`) are sent with `Cache-Control: public, max-age=31536000, immutable`;
everything else, `index.html` and the service worker included, with `no-cache` (revalidated with
`Last-Modified`, a `304` when unchanged).

### Public posture

A hub reachable from the internet runs in the public posture (`DEN_PUBLIC=1`, and by default
whenever `DEN_PUBLIC_URL` is `https`): `/health` answers only `ok`, `api` and `ready`;
`/api/v1/hub/status` of a hub already in a family answers only `{"paired": true, "setup_needed":
false, "stage": "ready"}`; `POST /api/v1/link` works only while a parent has opened "Add a device"
(`POST /api/v1/link/window`, below) or the owner ran `den_hub open-linking` on the server; and
mDNS is off unless `DEN_MDNS=1`.

## Discovery (mDNS)

The hub advertises one DNS-SD service while it serves HTTP:

- Service type `_den._tcp.local.`, instance name the hub device's name (`"Kitchen hub"`), port
  `47733` (or the configured port), on every interface it serves.
- TXT record, all values strings:

| Key | Required | Value |
| --- | --- | --- |
| `id` | yes | The hub's device id (the same as `device` from `/health`). Clients use it as the hub's unique id |
| `name` | yes | The hub device's name |
| `version` | yes | `den_hub` version, semver (`"0.1.0"`) |
| `api` | yes | `"1"`, the major version of this API |
| `f` | yes | The family id, so a device ignores hubs of other families on the same network |
| `tls` | no | `"1"` when the advertised port speaks HTTPS; absent or `"0"` means plain HTTP |

The TXT record carries no family name, member names or other family data beyond the family id,
which is a random identifier.

## Shared objects

These objects appear in several responses. Field types: `string`, `int` (JSON integer), `bool`,
`instant` (the `<name>` + `<name>_ms` pair above), `date` (local date string), `?` = nullable.

### Family

```json
{
  "id": "FKQ2M4X7B3N5C6TW",
  "name": "The Kotvas",
  "timezone": "America/Chicago",
  "week_start": 0,
  "points_enabled": true
}
```

`timezone` is IANA; `week_start` is 0 for Sunday, 1 for Monday.

### Member

From den_core's `Member`; sign-in salts and hashes are never sent.

```json
{
  "id": "M5LEOW3H7ZQ2D4VC",
  "name": "Leo",
  "role": "kid",
  "tier": "big",
  "marker": "tangerine",
  "picture": "owl",
  "animal": "bird",
  "birthday": "2017-04-02",
  "grants": ["lists"],
  "order": 2
}
```

| Field | Type | |
| --- | --- | --- |
| `role` | string | `parent` \| `adult` \| `kid` \| `guest` |
| `tier` | string? | `preReader` \| `little` \| `big` \| `teen` |
| `marker` | string | `sky` `grass` `lavender` `tangerine` `aqua` `coral` `sunshine` `bubblegum`, the order new people get them in. Older names are read as one of these (`blue` as `sky`, `orange` as `tangerine`, and so on). |
| `picture` | string | A picture from the app's pack by id (`fox`, `whale`, `rocket`, ...; den_core's `Picture.pack`), or `initial` for the first letter of their name |
| `animal` | string | What older versions showed (`cat` `dog` `rabbit` `bird` `butterfly` `fish` `horse` `cow` `bug`); a member without a picture shows the matching one |
| `birthday` | date? | |
| `grants` | string[] | Subset of `events`, `chores`, `lists`, `points` |
| `order` | int | Display order; members arrays are sorted by it |

### Category

```json
{"id": "CAT2SPORT5QK4MXN", "name": "Sports", "icon": "ball"}
```

### Event

A series (or a single event) as stored, from den_core's `Event`. `start`/`end` are the first
occurrence.

```json
{
  "id": "E2SOCCER7QK4MXN3",
  "title": "Soccer practice",
  "notes": "Bring shin guards",
  "location": "Field 3",
  "category": "CAT2SPORT5QK4MXN",
  "all_day": false,
  "start": "2026-10-13T17:30:00-05:00",
  "start_ms": 1791930600000,
  "end": "2026-10-13T18:30:00-05:00",
  "end_ms": 1791934200000,
  "start_date": null,
  "end_date": null,
  "tz": "America/Chicago",
  "rrule": "FREQ=WEEKLY;BYDAY=TU",
  "assignees": ["M5LEOW3H7ZQ2D4VC"],
  "reminders": [30],
  "rides": [{"leg": "to", "driver": null}, {"leg": "from", "driver": "M4DADR2J6YP3C7UB"}],
  "countdown": false,
  "source": {"kind": "manual", "label": null},
  "read_only": false,
  "space": "f",
  "audience": "everyone"
}
```

| Field | Type | |
| --- | --- | --- |
| `category` | string? | Category id |
| `all_day` | bool | |
| `start`, `end` | instant | For all-day events: midnight starting `start_date` and midnight starting `end_date`, in `tz` |
| `start_date`, `end_date` | date? | All-day events only: first day, and the day after the last (exclusive, as in iCalendar). `null` for timed events |
| `tz` | string | IANA zone the event was written in |
| `rrule` | string? | RFC 5545 RRULE without DTSTART; `null` when it doesn't repeat |
| `assignees` | string[] | Member ids; empty means everyone |
| `reminders` | int[] | Minutes before the start |
| `rides` | object[] | `{leg: "to" \| "from", driver: memberId?}` |
| `source` | object | `{kind: "manual" \| "ics" \| "device", label: string?}` |
| `read_only` | bool | `true` when `source.kind` is not `manual`; writes answer `409 read_only` |

### Occurrence

One occurrence of an event inside a window, with exceptions applied (den_core's `Occurrence`). It
has every Event field with this occurrence's values, except that `id` is replaced by these:

```json
{
  "uid": "E2SOCCER7QK4MXN3@1792535400000",
  "event_id": "E2SOCCER7QK4MXN3",
  "occurrence": 1792535400000,
  "recurring": true,
  "edited": false,
  "title": "Soccer practice",
  "start": "2026-10-20T17:30:00-05:00",
  "start_ms": 1792535400000,
  "end": "2026-10-20T18:30:00-05:00",
  "end_ms": 1792539000000,
  "...": "every other Event field"
}
```

| Field | Type | |
| --- | --- | --- |
| `uid` | string | `"<event_id>@<occurrence>"`; unique and stable for this occurrence |
| `event_id` | string | The series' id: address `PATCH`/`DELETE /api/v1/events/{event_id}` with it |
| `occurrence` | int | UTC ms of this occurrence's **original** start in the series, before any one-off move. Pass it back as `occurrence=` to edit or delete this occurrence. For an event that doesn't repeat it equals the event's `start_ms` |
| `recurring` | bool | The series has an `rrule` |
| `edited` | bool | This occurrence was changed on its own (an `eventException` applies) |

`occurrence` is always the occurrence's original start in its series (den_core's
`Occurrence.seriesStart`), even when an exception moved it.

### ChoreDay

A chore as it stands on one local date (den_core's `ChoreDay`).

```json
{
  "id": "C2FEEDCAT5QK4MXN",
  "completion_id": "C2FEEDCAT5QK4MXN@2026-10-17",
  "date": "2026-10-17",
  "title": "Feed the cat",
  "notes": "",
  "icon": "paw",
  "owner": "M5LEOW3H7ZQ2D4VC",
  "owner_rule": {"kind": "rotation", "ids": ["M5LEOW3H7ZQ2D4VC", "M6IVYX4G2AR5E3WD"], "every": "week", "anchor": "2026-01-05"},
  "swapped": false,
  "schedule": {"rrule": "FREQ=DAILY", "start": "2026-01-05"},
  "recurring": true,
  "due_time": "17:00",
  "due": "2026-10-17T17:00:00-05:00",
  "due_ms": 1792274400000,
  "done": false,
  "done_by": null,
  "late": false,
  "points": 5,
  "points_available": 7,
  "steps": [
    {"id": "s1", "text": "Fill the water bowl", "owner": null, "points": 1, "checked": true, "checked_by": "M5LEOW3H7ZQ2D4VC"},
    {"id": "s2", "text": "One scoop of food", "owner": null, "points": 1, "checked": false, "checked_by": null}
  ],
  "steps_done": 1,
  "step_count": 2,
  "space": "f",
  "audience": "everyone"
}
```

| Field | Type | |
| --- | --- | --- |
| `id` | string | Chore id |
| `completion_id` | string | `"<id>@<date>"`, the completion record's id whether or not it exists yet |
| `owner` | string? | Who it belongs to on this date after rotations and swaps; `null` means anyone |
| `owner_rule` | object | The chore's configured owner: `{kind: "member", id}`, `{kind: "anyone"}` or `{kind: "rotation", ids, every: "day" \| "week", anchor: date}` |
| `swapped` | bool | A one-day swap set `owner` for this date |
| `schedule` | object | `{rrule, start: date}` or `{once: date}` |
| `recurring` | bool | `schedule` has an `rrule` |
| `due_time` | string? | `HH:mm` local |
| `due` | instant? | `date` at `due_time` in the family time zone; `null` without a due time |
| `done_by` | string? | Member who completed it |
| `late` | bool | Past its due time today, or from an earlier day, and not done |
| `points` | int | Points for completing the chore itself |
| `points_available` | int | `points` plus every step's points |
| `steps[].owner` | string? | Member a step belongs to; `null` means no one in particular (its points go to whoever checks it) |
| `steps[].checked_by` | string? | Member who checked it; `null` when unchecked (or checked by open check-off) |

### ListView and Item

A list with its live items in display order (den_core's `ListView`, `DenList`, `Item`).

```json
{
  "id": "L2GROCERY5QK4MXN",
  "title": "Groceries",
  "icon": "cart",
  "kind": "shopping",
  "lifecycle": "running",
  "need_by": null,
  "event": null,
  "pinned": true,
  "order": "m",
  "space": "f",
  "audience": "everyone",
  "open": 2,
  "open_by_store": {"Costco": 1, "": 1},
  "items": [
    {
      "id": "I2MILK7QK4MXN3TB",
      "list": "L2GROCERY5QK4MXN",
      "text": "Milk",
      "qty": "2 gal",
      "store": "Costco",
      "checked": false,
      "checked_by": null,
      "order": "m",
      "to_groceries": false
    }
  ]
}
```

| Field | Type | |
| --- | --- | --- |
| `kind` | string | `shopping` \| `checklist` \| `packing` \| `meal` |
| `lifecycle` | string | `running` \| `dated` \| `event` |
| `need_by` | date? | Dated lists |
| `event` | string? | Event id for event lists |
| `order` | string | Fractional index; lists and items are already sorted by it |
| `open` | int | Unchecked items |
| `open_by_store` | object | Store name → unchecked count; items without a store count under `""` |
| `items` | Item[] | Checked items included, in display order |
| `items[].qty`, `items[].store` | string? | Free text |
| `items[].checked_by` | string? | |
| `items[].to_groceries` | bool | Meal list items that also go to the groceries list |

## Endpoints

### `GET /health`

Scope: none (no `Authorization` needed). Never returns family data.

```json
{
  "ok": true,
  "version": "0.1.0",
  "api": 1,
  "device": "D7HUB2QK4MXN3T5W",
  "name": "Kitchen hub",
  "ready": true
}
```

| Field | Type | |
| --- | --- | --- |
| `ok` | bool | The process is serving |
| `version` | string | `den_hub` version |
| `api` | int | `1` |
| `device` | string | The hub's device id; the same value as mDNS TXT `id` |
| `name` | string | The hub device's name |
| `ready` | bool | The hub is in a family, approved, and its log is loaded. While `false`, `/api/v1` answers `503 not_ready` |

In the public posture `version`, `device` and `name` are left out: `{"ok": true, "api": 1, "ready": true}`.

### `GET /api/v1/members`

Scope: `read`. The family, the members, the categories, who this hub is, and what the calling token
may do. Clients call this first: it validates the token and gives everything needed to resolve
names to ids.

```json
{
  "hub": {"device": "D7HUB2QK4MXN3T5W", "name": "Kitchen hub", "version": "0.1.0"},
  "family": {"id": "FKQ2M4X7B3N5C6TW", "name": "The Kotvas", "timezone": "America/Chicago", "week_start": 0, "points_enabled": true},
  "token": {
    "label": "Home Assistant",
    "member": null,
    "scopes": ["read", "calendar", "chores", "lists", "points"],
    "expires": null,
    "expires_ms": null
  },
  "members": [
    {"id": "M3MOMQ7K2XN4B5TA", "name": "Mom", "role": "parent", "tier": null, "marker": "aqua", "picture": "butterfly", "animal": "butterfly", "birthday": null, "grants": [], "order": 0},
    {"id": "M5LEOW3H7ZQ2D4VC", "name": "Leo", "role": "kid", "tier": "big", "marker": "tangerine", "picture": "owl", "animal": "bird", "birthday": "2017-04-02", "grants": ["lists"], "order": 2}
  ],
  "categories": [{"id": "CAT2SPORT5QK4MXN", "name": "Sports", "icon": "ball"}]
}
```

| Field | Type | |
| --- | --- | --- |
| `hub` | object | `device`, `name`, `version` as in `/health` |
| `family` | Family | |
| `token.label` | string | The connection's label |
| `token.member` | string? | Whose permissions the token uses; `null` is parent-level |
| `token.scopes` | string[] | Scopes as granted (`admin` is listed as `admin`, not expanded) |
| `token.expires` | instant? | |
| `members` | Member[] | Removed members excluded, sorted by `order` |
| `categories` | Category[] | |

### `GET /api/v1/today`

Scope: `read`. Den's Today screen in one call (den_core's `TodayView`).

Query: `date` (local date, optional, default today).

| Field | Type | |
| --- | --- | --- |
| `date` | date | The day shown |
| `timezone` | string | The family's time zone |
| `events` | Occurrence[] | Occurrences overlapping the day, sorted by start |
| `chores` | ChoreDay[] | As `GET /api/v1/chores?date=` returns them |
| `chore_summary` | object | The `summary` object of `GET /api/v1/chores` |
| `lists` | ListView[] | Pinned lists, dated lists due that day, and lists linked to that day's events |
| `gaps` | object[] | What needs attention, below |

```json
{
  "date": "2026-10-20",
  "timezone": "America/Chicago",
  "events": [],
  "chores": [],
  "chore_summary": {"total": 0, "done": 0, "left": 0, "anyone": {"total": 0, "done": 0, "left": 0}, "by_member": {}},
  "lists": [],
  "gaps": [
    {
      "kind": "no_driver",
      "message": "Nobody is driving Leo to soccer",
      "occurrences": ["E2SOCCER7QK4MXN3@1792535400000"],
      "members": ["M5LEOW3H7ZQ2D4VC"]
    }
  ]
}
```

(Arrays shortened; a real response for that date would hold the soccer occurrence in `events`.)

`gaps[].kind` is `no_driver` \| `overlap` \| `unowned`; `gaps[].message` is written for people;
`gaps[].occurrences` are `uid`s of entries in `events` (an `unowned` gap has none and names the
chore in its message); `gaps[].members` are the member ids involved.

### `GET /api/v1/events`

Scope: `read`. Occurrences overlapping a window, expanded and with exceptions applied, sorted by
start then title.

Query:

| Param | Type | Default | |
| --- | --- | --- | --- |
| `start` | instant or local date | today's midnight | Window start, inclusive |
| `end` | instant or local date | `start` + 7 days | Window end, exclusive. At most 400 days after `start`, else `400 invalid_input` |
| `member` | string | | Only occurrences whose `assignees` include this member |
| `include_everyone` | bool (`true`/`false`) | `false` | With `member`: also include occurrences with no assignees |
| `limit` | int 1–2000 | 2000 | Return at most this many, earliest first |

An occurrence overlaps when `start_ms < window end` and `end_ms > window start` (an occurrence with
`start_ms == end_ms` overlaps when `window start <= start_ms < window end`).

```json
{
  "start": "2026-10-17T00:00:00-05:00",
  "start_ms": 1792213200000,
  "end": "2026-10-24T00:00:00-05:00",
  "end_ms": 1792818000000,
  "timezone": "America/Chicago",
  "truncated": false,
  "events": [
    {
      "uid": "E2SOCCER7QK4MXN3@1792535400000",
      "event_id": "E2SOCCER7QK4MXN3",
      "occurrence": 1792535400000,
      "recurring": true,
      "edited": false,
      "title": "Soccer practice",
      "notes": "Bring shin guards",
      "location": "Field 3",
      "category": "CAT2SPORT5QK4MXN",
      "all_day": false,
      "start": "2026-10-20T17:30:00-05:00",
      "start_ms": 1792535400000,
      "end": "2026-10-20T18:30:00-05:00",
      "end_ms": 1792539000000,
      "start_date": null,
      "end_date": null,
      "tz": "America/Chicago",
      "rrule": "FREQ=WEEKLY;BYDAY=TU",
      "assignees": ["M5LEOW3H7ZQ2D4VC"],
      "reminders": [30],
      "rides": [{"leg": "to", "driver": null}, {"leg": "from", "driver": "M4DADR2J6YP3C7UB"}],
      "countdown": false,
      "source": {"kind": "manual", "label": null},
      "read_only": false,
      "space": "f",
      "audience": "everyone"
    },
    {
      "uid": "E4PICTURE2RJ6YP3@1792558800000",
      "event_id": "E4PICTURE2RJ6YP3",
      "occurrence": 1792558800000,
      "recurring": false,
      "edited": false,
      "title": "Picture day",
      "notes": "",
      "location": "",
      "category": null,
      "all_day": true,
      "start": "2026-10-21T00:00:00-05:00",
      "start_ms": 1792558800000,
      "end": "2026-10-22T00:00:00-05:00",
      "end_ms": 1792645200000,
      "start_date": "2026-10-21",
      "end_date": "2026-10-22",
      "tz": "America/Chicago",
      "rrule": null,
      "assignees": [],
      "reminders": [],
      "rides": [],
      "countdown": true,
      "source": {"kind": "ics", "label": "School calendar"},
      "read_only": true,
      "space": "f",
      "audience": "everyone"
    }
  ]
}
```

`truncated` is `true` when `limit` cut the list short.

### `POST /api/v1/events`

Scope: `calendar`. Creates an event (den_core `addEvent`).

Body:

| Field | Type | Required | |
| --- | --- | --- | --- |
| `title` | string, 1–200 | yes | |
| `all_day` | bool | no, `false` | |
| `start` | instant; local date when `all_day` | yes | |
| `end` | instant; local date (exclusive) when `all_day` | no | Default: `start` + 1 hour, or the day after `start` for all-day. Must not be before `start` |
| `tz` | string (IANA) | no | Default the family's time zone; also the zone offset-less times are read in |
| `rrule` | string? | no | RFC 5545 RRULE without DTSTART (`"FREQ=WEEKLY;BYDAY=TU"`) |
| `assignees` | string[] | no, `[]` | Member ids; empty means everyone |
| `category` | string? | no | Category id |
| `location`, `notes` | string | no, `""` | |
| `reminders` | int[] | no, `[]` | Minutes before the start, each 0–40320 |
| `rides` | object[] | no, `[]` | `{leg: "to" \| "from", driver: memberId?}` |
| `countdown` | bool | no, `false` | |
| `space` | string | no, `"f"` | `f`, `p` or `m:<memberId>` |

```json
{
  "title": "Dentist",
  "start": "2026-10-20T15:00:00-05:00",
  "end": "2026-10-20T16:00:00-05:00",
  "assignees": ["M6IVYX4G2AR5E3WD"],
  "reminders": [60]
}
```

Response `201`: `{"event": Event}` with the new event.

### `PATCH /api/v1/events/{id}`

Scope: `calendar`. Changes an event, one occurrence, or this and following occurrences (den_core
`updateEvent`). `{id}` is the series id (`event_id`).

Query:

| Param | Type | Default | |
| --- | --- | --- | --- |
| `scope` | `one` \| `following` \| `all` | `all` | How far the change reaches on a repeating event |
| `occurrence` | instant | | The occurrence's `occurrence` value. Required for `one` and `following` on a repeating event; optional with `all` |

Body: any subset of the `POST` fields except `space`. Absent fields are unchanged; `null` clears
`rrule` (stops repeating) or `category`.

Rules:

- On an event that doesn't repeat, `scope` is ignored and the change applies to the event.
- `scope=one` writes an `eventException` for that occurrence; `rrule` in the body is
  `400 invalid_input`.
- `scope=following` ends the series before `occurrence` and starts a new series there with the
  change applied. When `occurrence` is the series' first occurrence it is the same as `all`.
- A new `start` with `scope=all` shifts every occurrence by the same delta: the new `start` minus
  the start of the addressed occurrence (`occurrence` when given, else the series' first start).
  `end` given with it sets the duration; `start` without `end` keeps the duration.
- Switching `all_day` requires `start` (and optionally `end`) in the new form.

```http
PATCH /api/v1/events/E2SOCCER7QK4MXN3?scope=one&occurrence=1792535400000
```

```json
{"start": "2026-10-20T18:00:00-05:00", "end": "2026-10-20T19:00:00-05:00", "location": "Field 5"}
```

Response `200`: `{"ok": true}`. Errors: `409 read_only` for imported events; `400 invalid_input`
(with `details.field: "occurrence"`) when `occurrence` is missing or isn't an occurrence of the
series.

### `DELETE /api/v1/events/{id}`

Scope: `calendar`. Deletes an event, one occurrence, or this and following (den_core
`deleteEvent`). Query `scope` and `occurrence` exactly as for `PATCH`; no body.

```http
DELETE /api/v1/events/E2SOCCER7QK4MXN3?scope=following&occurrence=1792535400000
```

Response `200`: `{"ok": true}`. Errors: `409 read_only`, `404 not_found`, `400 invalid_input` as
for `PATCH`.

### `GET /api/v1/chores`

Scope: `read`. Chores for a day with completion and steps (den_core `choresOn`): every chore
scheduled that day plus earlier one-off chores still not done.

Query:

| Param | Type | Default | |
| --- | --- | --- | --- |
| `date` | local date | today | |
| `member` | string | | Only chores whose `owner` that day is this member (excludes "anyone" chores) |

Sorted by `due_time` (chores without one last), then title.

```json
{
  "date": "2026-10-17",
  "timezone": "America/Chicago",
  "chores": [
    {
      "id": "C2FEEDCAT5QK4MXN",
      "completion_id": "C2FEEDCAT5QK4MXN@2026-10-17",
      "date": "2026-10-17",
      "title": "Feed the cat",
      "notes": "",
      "icon": "paw",
      "owner": "M5LEOW3H7ZQ2D4VC",
      "owner_rule": {"kind": "rotation", "ids": ["M5LEOW3H7ZQ2D4VC", "M6IVYX4G2AR5E3WD"], "every": "week", "anchor": "2026-01-05"},
      "swapped": false,
      "schedule": {"rrule": "FREQ=DAILY", "start": "2026-01-05"},
      "recurring": true,
      "due_time": "17:00",
      "due": "2026-10-17T17:00:00-05:00",
      "due_ms": 1792274400000,
      "done": false,
      "done_by": null,
      "late": false,
      "points": 5,
      "points_available": 7,
      "steps": [
        {"id": "s1", "text": "Fill the water bowl", "owner": null, "points": 1, "checked": true, "checked_by": "M5LEOW3H7ZQ2D4VC"},
        {"id": "s2", "text": "One scoop of food", "owner": null, "points": 1, "checked": false, "checked_by": null}
      ],
      "steps_done": 1,
      "step_count": 2,
      "space": "f",
      "audience": "everyone"
    },
    {
      "id": "C3DISHES6RJ6YP2T",
      "completion_id": "C3DISHES6RJ6YP2T@2026-10-17",
      "date": "2026-10-17",
      "title": "Empty the dishwasher",
      "notes": "",
      "icon": "dish",
      "owner": null,
      "owner_rule": {"kind": "anyone"},
      "swapped": false,
      "schedule": {"rrule": "FREQ=DAILY", "start": "2026-01-05"},
      "recurring": true,
      "due_time": null,
      "due": null,
      "due_ms": null,
      "done": true,
      "done_by": "M6IVYX4G2AR5E3WD",
      "late": false,
      "points": 3,
      "points_available": 3,
      "steps": [],
      "steps_done": 0,
      "step_count": 0,
      "space": "f",
      "audience": "everyone"
    }
  ],
  "summary": {
    "total": 2,
    "done": 1,
    "left": 1,
    "anyone": {"total": 1, "done": 1, "left": 0},
    "by_member": {
      "M5LEOW3H7ZQ2D4VC": {"total": 1, "done": 0, "left": 1}
    }
  }
}
```

`summary` counts the returned chores: `by_member` is keyed by `owner` and has an entry for every
member who owns at least one returned chore; `anyone` counts chores with no owner.

### `POST /api/v1/chores/{id}/complete`

Scope: `chores`. Marks a chore done or not done on a date (den_core `setChoreDone`): done also
checks every step, keeping whoever already checked each; not done clears them.

Body:

| Field | Type | Default | |
| --- | --- | --- | --- |
| `date` | local date | today | |
| `done` | bool | `true` | |
| `member` | string? | the token's member | Who did it, recorded as `done_by` (and so who earns an "anyone" chore's points). Naming someone other than the token's own member needs permission to complete their chore (`completeAnyChore`); a token with no member may name anyone. `null` (or a member-less token without `member`) records no one |

```json
{"date": "2026-10-17", "done": true, "member": "M5LEOW3H7ZQ2D4VC"}
```

Response `200`: `{"chore": ChoreDay}` for that date after the change. `404 not_found` when the chore
doesn't exist or isn't scheduled on `date`.

### `POST /api/v1/chores/{id}/steps/{stepId}`

Scope: `chores`. Checks or unchecks one step (den_core `setStep`): checking the last step completes
the chore; unchecking any step of a done chore reopens it.

Body:

| Field | Type | Default | |
| --- | --- | --- | --- |
| `date` | local date | today | |
| `checked` | bool | `true` | |
| `member` | string? | the token's member | Who checked it; same rules as `complete` |

```json
{"date": "2026-10-17", "checked": true}
```

Response `200`: `{"chore": ChoreDay}`. `404 not_found` for an unknown chore or step.

### `GET /api/v1/lists`

Scope: `read`. Every list the token can read, in display order, with items.

```json
{
  "lists": [
    {
      "id": "L2GROCERY5QK4MXN",
      "title": "Groceries",
      "icon": "cart",
      "kind": "shopping",
      "lifecycle": "running",
      "need_by": null,
      "event": null,
      "pinned": true,
      "order": "m",
      "space": "f",
      "audience": "everyone",
      "open": 1,
      "open_by_store": {"Costco": 1},
      "items": [
        {"id": "I2MILK7QK4MXN3TB", "list": "L2GROCERY5QK4MXN", "text": "Milk", "qty": "2 gal", "store": "Costco", "checked": false, "checked_by": null, "order": "m", "to_groceries": false},
        {"id": "I3EGGS5RJ6YP2TQA", "list": "L2GROCERY5QK4MXN", "text": "Eggs", "qty": null, "store": null, "checked": true, "checked_by": "M3MOMQ7K2XN4B5TA", "order": "t", "to_groceries": false}
      ]
    }
  ],
  "stores": ["Costco", "Target"]
}
```

`stores` are store names used on items of the returned lists, most used first (as den_core
`stores` counts them).

### `POST /api/v1/lists/{id}/items`

Scope: `lists`. Adds one or several items at the end of a list (den_core `addItem`).

Body, one item:

| Field | Type | Required | |
| --- | --- | --- | --- |
| `text` | string, 1–200 | yes | |
| `qty` | string?, ≤ 40 | no | |
| `store` | string?, ≤ 60 | no | |
| `to_groceries` | bool | no, `false` | Meal lists: also add to the first pinned shopping list |

```json
{"text": "Milk", "qty": "2 gal", "store": "Costco"}
```

Response `201`: `{"item": Item}`.

Body, several items: `{"items": [<one-item body>, ...]}` (1–100 entries, added in order).
Response `201`: `{"items": [Item, ...]}`.

### `PATCH /api/v1/items/{id}`

Scope: `lists`. Changes, checks, or moves an item (den_core `updateItem`, `setItemChecked`,
`moveItem`).

Body, any subset:

| Field | Type | |
| --- | --- | --- |
| `text` | string, 1–200 | Rename |
| `qty` | string? | `null` clears |
| `store` | string? | `null` clears |
| `checked` | bool | Check or uncheck; sets or clears `checked_by` to the token's member |
| `move` | object | `{"after": itemId?, "before": itemId?}`: the neighbors to place it between. `after: null` means the top, `before: null` the bottom. Give one or both; with one, the hub takes the other from the list's current order (ignoring the moved item). Neighbors must be in the same list |

```json
{"checked": true}
```

```json
{"move": {"after": "I3EGGS5RJ6YP2TQA"}}
```

Response `200`: `{"item": Item}` after the change.

### `DELETE /api/v1/items/{id}`

Scope: `lists`. Removes an item (den_core `removeItem`). Response `200`: `{"ok": true}`.

### `GET /api/v1/points`

Scope: `read`. Totals, goals with standings, recent lines, rewards and pending redemptions
(den_core `PointsSummary`). When the family has points turned off, `enabled` is `false` and the
other fields are still present (empty or zero).

Query: `recent` (int 0–200, default 50) limits `recent`.

```json
{
  "enabled": true,
  "totals": {"M5LEOW3H7ZQ2D4VC": 42, "M6IVYX4G2AR5E3WD": 37},
  "goals": [
    {
      "id": "G2MOVIE5QK4MXN3T",
      "title": "Movie night pick",
      "mode": "race",
      "target": 50,
      "members": null,
      "start": "2026-10-12",
      "end": null,
      "repeat": "weekly",
      "reward": "Pick Friday's movie",
      "window_start": "2026-10-12",
      "window_end": "2026-10-19",
      "winner": null,
      "standings": [
        {"member": "M5LEOW3H7ZQ2D4VC", "earned": 31, "reached": null, "reached_ms": null},
        {"member": "M6IVYX4G2AR5E3WD", "earned": 28, "reached": null, "reached_ms": null}
      ]
    }
  ],
  "recent": [
    {"member": "M6IVYX4G2AR5E3WD", "delta": 3, "reason": "Empty the dishwasher", "source": "chore", "ref": "C3DISHES6RJ6YP2T@2026-10-17", "when": "2026-10-17T07:42:10-05:00", "when_ms": 1792240930000}
  ],
  "rewards": [
    {"id": "R2ICECREAM5QK4MX", "title": "Ice cream trip", "cost": 100, "icon": "gift", "needs_approval": true, "active": true}
  ],
  "pending": [
    {"id": "X2REDEEM5QK4MXN3", "reward": "R2ICECREAM5QK4MX", "member": "M5LEOW3H7ZQ2D4VC", "cost": 100, "status": "requested", "requested": "2026-10-17T08:15:00-05:00", "requested_ms": 1792242900000}
  ]
}
```

| Field | Type | |
| --- | --- | --- |
| `totals` | object | Member id → current balance (earned + adjustments − approved redemptions), for every member the token can see, including zeros. Balances count every point a member earned; `recent` leaves out lines from chores in spaces the token can't read, since their `reason` is the chore's title |
| `goals[].members` | string[]? | `null` means every kid |
| `goals[].window_start`, `window_end` | date, date? | The measured window (end exclusive, `null` when open-ended) |
| `goals[].winner` | string? | Races: the first member to reach the target |
| `goals[].standings[].reached` | instant? | When the running total first crossed the target and stayed there |
| `recent[]` | object | Newest first. `source` is `chore` \| `step` \| `adjustment` \| `reward`; `ref` is the completion, adjustment or redemption id |
| `pending[]` | object | Redemptions with `status: "requested"` |

### `POST /api/v1/points/adjust`

Scope: `points`. Gives or takes points (den_core `adjustPoints`, an append-only `adjustment`).

Body:

| Field | Type | Required | |
| --- | --- | --- | --- |
| `member` | string | yes | Member id |
| `delta` | int, non-zero, −10000…10000 | yes | |
| `reason` | string, 1–200 | yes | Shown in Den's points history |

```json
{"member": "M5LEOW3H7ZQ2D4VC", "delta": 5, "reason": "Helped carry the groceries"}
```

Response `201`:

```json
{
  "adjustment": {"id": "A2ADJUST5QK4MXN3", "member": "M5LEOW3H7ZQ2D4VC", "delta": 5, "reason": "Helped carry the groceries", "by": null},
  "balance": 47
}
```

`by` is the token's member (`null` for a member-less token); `balance` is the member's new total.
`400 invalid_input` when points are turned off for the family.

### `GET /api/v1/history`

Scope: `read`. Valid changes rendered for people, newest first (den_core `history`), filtered to
spaces the token can read.

Query: `q` (text search over titles, names and values), `member` (actor id), `type` (record type),
`limit` (1–200, default 50).

```json
{
  "entries": [
    {
      "when": "2026-10-17T15:04:05-05:00",
      "when_ms": 1792267445000,
      "hlc": "1792267445000-0000-D7HUB2QK4MXN3T5W",
      "actor": null,
      "actor_name": "Kitchen hub",
      "device": "D7HUB2QK4MXN3T5W",
      "device_name": "Kitchen hub",
      "via": "Home Assistant",
      "type": "item",
      "rid": "I2MILK7QK4MXN3TB",
      "title": "Milk",
      "verb": "checked",
      "space": "f",
      "diffs": [{"field": "checked", "before": false, "after": true}]
    }
  ]
}
```

`verb` is one of `added`, `changed`, `removed`, `completed`, `reopened`, `checked`, `unchecked`,
`approved`, `swapped`, `requested`, `gave`, `took`. `diffs[].before`/`after` are raw JSON values.

### `GET /api/v1/search`

Scope: `read`. Search across events, chores, lists, items and members (den_core `search`).

Query: `q` (required, 1–200 chars), `limit` (1–100, default 50).

```json
{
  "results": [
    {"type": "event", "id": "E2SOCCER7QK4MXN3", "title": "Soccer practice", "detail": "Tuesdays 5:30 PM", "when": "2026-10-20T17:30:00-05:00", "when_ms": 1792535400000},
    {"type": "item", "id": "I2MILK7QK4MXN3TB", "title": "Milk", "detail": "Groceries", "when": null, "when_ms": null}
  ]
}
```

### `GET /api/v1/stream` (server-sent events)

Scope: `read`. A [server-sent events](https://html.spec.whatwg.org/multipage/server-sent-events.html)
stream that says when data changed, so clients refetch instead of polling.

Request: `GET /api/v1/stream` with `Authorization: Bearer <token>` and
`Accept: text/event-stream`. Errors before the stream starts use the normal JSON error bodies
(`401`, `403`, `503`).

Response headers: `200`, `Content-Type: text/event-stream; charset=utf-8`,
`Cache-Control: no-cache`, `X-Accel-Buffering: no`. The body is UTF-8 lines separated by `\n`;
each event is `event:`, optional `id:`, and one `data:` line holding compact JSON, followed by a
blank line.

The stream opens with a `retry` hint and a `hello` event:

```text
retry: 5000

event: hello
data: {"hub":"D7HUB2QK4MXN3T5W","version":"0.1.0","time":"2026-10-17T15:04:00-05:00","time_ms":1792267440000}

```

Then, after every batch of applied changes (a local write, an API or MCP write, or changes synced in
from another device) that touches at least one record the token can read:

```text
event: changed
id: 1792267445000-0000-D7HUB2QK4MXN3T5W
data: {"types":["item"],"records":[{"type":"item","id":"I2MILK7QK4MXN3TB","space":"f"}],"actor":null,"via":"Home Assistant","time":"2026-10-17T15:04:05-05:00","time_ms":1792267445000}

```

| `changed` field | Type | |
| --- | --- | --- |
| `types` | string[] | Record types that changed, de-duplicated (`event`, `eventException`, `chore`, `completion`, `adjustment`, `goal`, `reward`, `redemption`, `list`, `item`, `member`, `family`, `category`, `device`, `subscription`, `connection`), only for records the token can read. Never empty |
| `records` | object[] | `{type, id, space}` for each changed record the token can read, at most 100 |
| `truncated` | bool, optional | Present and `true` when `records` was cut at 100 |
| `actor` | string? | Acting member of the newest change in the batch |
| `via` | string? | Token or MCP label when the newest change came through the hub's API or MCP |
| `time` | instant | When the batch was applied |

`id:` is the HLC of the newest change in the batch.

Keep-alive: the hub writes a comment line `: ping` followed by a blank line every 20 seconds.
Clients should treat 60 seconds without any bytes as a dead connection and reconnect.

Rules:

- The hub may coalesce changes applied within 250 ms into one `changed` event (union of `types`
  and `records`).
- The hub sends nothing for changes the token can't read; a parent's private event never shows up
  in a kid-scoped token's stream, not even as a type.
- There is no replay: the hub ignores `Last-Event-ID`. After connecting or reconnecting, clients
  refetch whatever they display, then apply `changed` events from then on.
- When the token is revoked or expires, or the hub shuts down, the hub may send
  `event: goodbye` with `data: {"reason": "token_revoked" | "token_expired" | "shutdown"}` before
  closing. A reconnect with a revoked token gets `401`.
- Clients reconnect with exponential backoff (for example 1 s doubling to 60 s, with jitter) and
  honor `retry:`.

Suggested refetch by type, for clients that cache:

| Types | Refetch |
| --- | --- |
| `event`, `eventException`, `category` | `/api/v1/events` (and `/api/v1/today`) |
| `chore`, `completion` | `/api/v1/chores`, `/api/v1/points` (points derive from completions) |
| `adjustment`, `goal`, `reward`, `redemption` | `/api/v1/points` |
| `list`, `item` | `/api/v1/lists` |
| `member`, `family` | `/api/v1/members`, then everything (names, time zone, points switch) |


## Actions: everything MCP and the app can do

`/api/v1/actions` runs den_actions (`packages/den_actions`): the same actions the MCP server offers
as tools, by the same names, with the same JSON Schemas, permissions, confirmations and receipts.
They take people, events, chores, lists, items and rewards by name or by id. The write routes
above are older adapters over a few of them and answer as they always have.

Who may run what: a token needs one of the action's scopes, and its member must be allowed what
the action needs (`can()`); a token with no member acts at a parent's level except for the
family's people and settings. den_core still decides every change. What only a parent decides on
their own device (roles, permissions and sign-in, removing people, devices, AI access, who sees
whose private things) is never an action; `packages/den_actions/lib/src/not_exposed.dart` lists
each engine operation no action offers, with the reason.

| Action | Effect | Scopes | Needs | Confirmation |
| --- | --- | --- | --- | --- |
| `get_overview` (today, or `start` + `days`; also what waits for a parent) | read | `read` | | |
| `get_family` (people, categories, settings, what this token may do) | read | `read` | | |
| `list_events` | read | `read` | | |
| `list_chores` (one day, or `definitions`) | read | `read` | | |
| `get_lists` | read | `read` | | |
| `get_points` | read | `read` | | |
| `search` | read | `read` | | |
| `get_history` | read | `read` | | |
| `create_event` | write | `calendar` | `editEvents` | |
| `update_event` (also `who_can_see`) | destructive | `calendar` | `editEvents` | server, for a whole series |
| `delete_event` | destructive | `calendar` | `editEvents` | server, for a whole series |
| `set_ride` | write | `calendar` | `editEvents` | |
| `create_chore` | write | `chores` | `editChores` (a price needs `managePoints`) | |
| `update_chore` | destructive | `chores` | `editChores` | client |
| `delete_chore` | destructive | `chores` | `editChores` | server |
| `complete_chore` (or one `step`) | write | `chores` | `completeOwnChore` | |
| `swap_chore` | write | `chores` | `swapChore` | |
| `create_list` | write | `lists` | `editLists` | |
| `update_list` | destructive | `lists` | `editLists` | client |
| `delete_list` | destructive | `lists` | `editLists` | server |
| `add_items` | write | `lists` | `editLists` | |
| `update_items` (check, text, qty, store, move) | write | `lists` | `checkItems` (more than checking needs `editLists`) | |
| `remove_items` (or every checked one) | destructive | `lists` | `editLists` | server, over 5 items |
| `adjust_points` | destructive | `points` | `managePoints` | client |
| `save_goal` | destructive | `points` | `managePoints` | client |
| `delete_goal` | destructive | `points` | `managePoints` | server |
| `save_reward` | destructive | `points` | `managePoints` | client |
| `request_reward` | write | `points` | `requestReward` | |
| `decide_reward_request` | destructive | `points` | `managePoints` | client |
| `add_from_text` | write | `calendar`, `chores` or `lists` | any of `editEvents`, `editChores`, `editLists` | client |
| `undo` | destructive | `calendar`, `chores`, `lists` or `points` | what the change it takes back needed | |
| `save_category` | destructive | `calendar` | `editEvents` | client |
| `delete_category` | destructive | `calendar` | `editEvents` | server |
| `update_family_settings` | destructive | `admin` | `manageFamily` | client |
| `save_member` (not roles, permissions or sign-in) | destructive | `admin` | `manageFamily` | client |
| `save_calendar_feed` (https on the public web) | destructive | `admin` | `manageFamily` | server |
| `remove_calendar_feed` | destructive | `admin` | `manageFamily` | server |

"Client" confirmation is the caller's to ask (MCP clients do from the tool's hints, the in-app
assistant asks for a tap when the call touches someone else's things or a whole series).
"Server" confirmation is the two-step below. Older MCP names still run, unlisted, for one
release: `get_today` and `get_week` (`get_overview`), `list_members` (`get_family`), `list_lists`
(`get_lists`), `list_rewards` (`get_points`), `check_step` (`complete_chore` with `step`),
`check_item` (`update_items`), `remove_item` and `clear_checked` (`remove_items`), `create_goal`
(`save_goal`), `decide_redemption` (`decide_reward_request`).

### `GET /api/v1/actions`

Any valid token. The actions it may run:

```json
{
  "actions": [
    {
      "name": "add_items",
      "id": "lists.add_items",
      "title": "Add items to a list",
      "description": "Adds items to the end of a list.",
      "scopes": ["lists"],
      "effect": "write",
      "idempotent": false,
      "confirm": "none",
      "input_schema": {"type": "object", "properties": {"list": {"type": "string"}, "items": {"type": "array"}}},
      "output_schema": {"type": "object", "properties": {"items": {"type": "array"}, "receipt": {"type": "object"}}}
    }
  ]
}
```

`input_schema` stays in the subset every function-calling API takes (one type per value, string
enums, no `anyOf`, `additionalProperties: false` only at the top). Times are ISO 8601 with an
offset, without one (read in the family's zone), or dates.

### `POST /api/v1/actions/{name}`

Runs an action. The body is its input as a JSON object; keys it doesn't name are refused.

| Query or header | |
| --- | --- |
| `?preview=1` | Changes nothing: runs the action on an in-memory copy of the family and answers with what would change (`result.preview`), with warnings such as a new overlap, a ride with no driver, or something already on the list |
| `Idempotency-Key: <text>` | A retry with the same key and input within 24 hours answers as the first try did, with `Idempotent-Replayed: true`, and changes nothing more. The same key with another input is `409 idempotency_conflict` |

`200`:

```json
{
  "status": "done",
  "text": "Added Oat milk, Coffee filters to Groceries.",
  "result": {"added": [{"type": "item", "id": "01J...", "title": "Oat milk"}], "left": [], "unclear": [], "reader": "Den"},
  "receipt": {"id": "r_mT3...", "summary": "Added Oat milk, Coffee filters to Groceries.", "undoable": true, "tool": "add_from_text", "changes": ["4K2...:118", "4K2...:119"]}
}
```

| `status` | |
| --- | --- |
| `done` | It ran. `text` is one or two sentences to show or say; `result` matches the action's `output_schema`; writes carry a `receipt` (also in `result.receipt`) |
| `preview` | Nothing changed; `result.preview` is `{summary, question, changes: [{type, id, title, verb, fields}], warnings}` |
| `needs_confirmation` | Nothing changed: the action needs a yes first. `result.confirm` is `{token, question, expires_ms}` and `result.preview` what would change. Ask the person `question`, then send the same input again with `"confirm": "<token>"` within 10 minutes |

Errors use the usual body: `400 invalid_input` (with `details.field`), `403 insufficient_scope`,
`403 permission_denied`, `404 not_found` (a name that matches nothing; the message lists the
choices) or `unknown_action`, `409 read_only`.

**Undo.** `POST /api/v1/actions/undo` with `{"receipt": "<id>"}` takes back what that write did,
field by field: what it made is removed, what it removed comes back, fields get their old values,
and points given get an adjustment the other way. Fields someone changed since stay as they are
and are listed in `result.skipped`. `{}` takes back the token's last change. A token can undo only
its own receipts, which last while the hub runs (the latest 500); `{"type": "chore", "id":
"<id>"}` puts back any removed record the token may edit (`"occurrence"` with an event puts back
one removed occurrence). Undo answers with a receipt too, which takes the undo back.

**From Siri and other voice assistants.** `add_from_text` reads what someone said or wrote, the
way the app's Add does (`{"text": "soccer every Wednesday at 5 for Leo"}`), with the reader a
parent chose for the hub (Claude or a model at home), else Den's own rules. It adds what it's
sure of and lists the rest in `result.left` (`"include_unsure": true` adds that too); `"list"`
puts the items on one list. See `packages/den_hub/README.md`, "Siri Shortcuts".

## Hub setup and browser linking

These endpoints let a fresh hub join a family and let a browser link to it. `GET
/api/v1/hub/status` is specified here; `POST /api/v1/hub/setup`, `GET /api/v1/hub/setup/ws`,
`POST /api/v1/link`, `POST /api/v1/link/{slot}` and `GET /api/v1/link/{slot}` are specified in
`packages/den_hub/README.md`.

### `GET /api/v1/hub/status`

No token. Where the hub is in joining a family, for the app's "Add a hub" screen and
`den_hub status`.

```json
{
  "paired": false,
  "device": "h7q2kx4m9pa3tbv6",
  "name": "Closet hub",
  "version": "0.1.0",
  "setup_needed": false,
  "stage": "waiting_for_approval",
  "matching_words": ["lantern", "meadow", "copper"]
}
```

| Field | |
| --- | --- |
| `paired` | In a family and approved |
| `device` | The hub's device id |
| `name` | The hub's name |
| `version` | `den_hub`'s version |
| `setup_needed` | No family and no join under way: a parent's phone can send the setup code |
| `stage` | `waiting_for_code`, `joining`, `waiting_for_approval`, `syncing` or `ready` |
| `matching_words` | Present only while the pairing session with the inviting phone is up (`joining` through `syncing`): the three words both ends derive from that session's transcript (den_net's matching words). The phone shows its own three; a parent approves only if they're the same. The hub also logs them at info level and `den_hub status` prints them |
| `last_error` | Why the last join didn't finish (`timed-out`, `unreachable`, or the phone's reason), until the hub is ready |

In the public posture a hub already in a family answers only `paired`, `setup_needed` and
`stage`.

### `POST /api/v1/link/window`

Signed by a parent's own device ([`DeviceRequest`](#capture-reading-for-every-device), not a
shared display), no body. Opens "Add a device" for 10 minutes: in the public posture,
`POST /api/v1/link` (a new browser asking for a link code) answers `403 link_closed` unless a
parent opened it. Answer: `{"open_until": "<ISO 8601>", "open_until_ms": 1792535400000}`. On a
home network linking is always open and this is harmless to call.

The words are not a secret: a relay or anything else in the middle that ran two sessions would
produce two transcripts, so the two ends would show different words. This answer travels over
plain HTTP on the home network, so it backs up, and doesn't replace, comparing with the hub's log
when the network itself isn't trusted.

## Apps asking to connect (OAuth)

A remote MCP client (claude.ai, ChatGPT) signs in with OAuth 2.1 (`/oauth/register`,
`/oauth/authorize`, `/oauth/token`; see `packages/den_hub/README.md`). Those endpoints need no
credentials, so a sign-in request stays in the hub's memory and nothing reaches the family's log
until a parent acts. The sign-in page shows the app's name, the host its sign-in returns to
(`claude.ai`), what it asked for, and a code (`K7QP-M4XD`). A parent's app lists the waiting
requests with the same code and lets the right one in; the hub then writes a `pending` connection
(labelled `"<client name> (<redirect host>)"`) that the parent approves with den_core's
`approveConnection`, choosing scopes and whose permissions it uses, exactly as before. Requests
expire after 15 minutes (the sign-in page then returns `access_denied`), at most 20 wait at once,
one address can start 10 in 15 minutes, and the hub turns down pending connections nobody
approved within 15 minutes.

Both endpoints are signed by a parent's own device ([`DeviceRequest`](#capture-reading-for-every-device),
not a shared display); anyone else gets `401` or `403 permission_denied`.

### `GET /api/v1/connections/requests`

The requests waiting for a parent, newest first:

```json
{
  "requests": [
    {
      "id": "q7ZK3m1VbT0aYc2E",
      "code": "K7QP-M4XD",
      "client_name": "Claude",
      "redirect_host": "claude.ai",
      "scopes": ["read", "calendar", "chores", "lists", "points"],
      "connection": null,
      "requested": "2026-10-20T22:30:00.000Z",
      "requested_ms": 1792535400000,
      "expires": "2026-10-20T22:45:00.000Z",
      "expires_ms": 1792536300000
    }
  ]
}
```

`client_name` is whatever the app registered with; `redirect_host` is where its sign-in returns
and can't be made up, so show both, and the `code`, which the person signing in sees on their
screen. `connection` is the pending connection's id once a parent admitted it.

### `POST /api/v1/connections/requests/{id}`

Body `{"decision": "admit"}` or `{"decision": "decline"}`. Admitting writes the pending
connection (or returns the one already written) and answers
`{"connection": "<connection id>", "request": {...}}`; the parent's app then approves that
connection once it has synced (`Den.approveConnection(id, scopes:, member:)`), or revokes it.
Declining answers `{"ok": true}` and sends the app back with `access_denied`. `404 not_found` for
an unknown or expired request, `409 declined` once it was declined.

## Capture: reading for every device

A parent sets up one reader on the hub (Claude with an API key, or a model at home through
Ollama) and every approved device in the family uses it: a device sends what someone shared and
gets back the same JSON every capture reader returns (`CaptureWire.schema` in
`packages/den_capture`). The device then resolves it to the family, checks it against den_core and
writes it as its own acting member; the hub writes nothing.

These endpoints take no token. Every request is signed with the device's own key
(`DeviceRequest` in `packages/den_net`):

| Header | Value |
| --- | --- |
| `X-Den-Device` | The device id |
| `X-Den-Time` | UTC milliseconds; refused more than 5 minutes from the hub's clock |
| `X-Den-Nonce` | Random; refused if the hub has seen it |
| `X-Den-Actor` | The member acting on the device, when it names one |
| `X-Den-Signature` | base64url Ed25519 over `"den/device-request/v1" 0x00` and the canonical JSON `[method, path with query, time, nonce, hex SHA-256 of the body, device, actor, hub device id]` |
| `X-Den-Body-SHA256` | Recommended: the lowercase hex SHA-256 of the body, the same value the signature covers. With it the hub checks the signature from the headers alone and turns a forged request away before reading its body |

The hub accepts a request only from an approved, unrevoked device of its family, addressed to
itself. A request with `X-Den-Body-SHA256` is verified before its body is read (`401` when the
signature is wrong; the hub keeps none of the body, discarding it as it arrives, and the answer
may come only once the client has sent it). Without it the hub can check only the headers that
need no body (signed, fresh, naming an approved device) before reading, so it reads such bodies one per
client and two at a time, answering `429 busy` (`details.retry`: true) past that, and verifies
the signature once the body is in. Bodies are capped (64 KiB for `PUT`, 30 MB for
`/api/v1/capture/read`, refused by `Content-Length` before reading) and must arrive within
3 minutes. A personal device acts for its owner and no one else; a shared display for the member
signed in on it, or nobody; a hub-mode device for its owner. Anything else is `401 unauthorized`.

### `GET /api/v1/capture/reader`

Any device. What the hub reads with; the key is never in it.

```json
{
  "kind": "claude",
  "reader": {"id": "claude", "name": "Claude", "place": "provider",
             "inputs": ["text", "image", "pdf"], "history_name": "Claude"},
  "device_first": true,
  "model": "claude-opus-5-5",
  "address": null,
  "key_saved": true
}
```

`kind` is `none`, `claude` or `home`; `reader` is null when nothing is set up. `place` is
`provider` when what's shared leaves the house, `home` when it stays. `device_first` asks each
device to read on its own first and ask the hub only for what it can't read or finds nothing in.

### `PUT /api/v1/capture/reader`

A parent's own device (not a shared display). Body:

```json
{"kind": "claude", "key": "sk-ant-...", "model": "claude-sonnet-5-5", "device_first": true}
{"kind": "home", "address": "127.0.0.1:11434", "model": "llama3.2", "device_first": true}
{"kind": "none"}
```

Without `key`, a Claude reader keeps the key the hub already has. `none` forgets the key. The key
is kept in `<data>/hub/capture.json`, readable by the hub's user only; it is never in the
family's log, an answer or the hub's log. Answers like `GET`. `403 permission_denied` for anyone
else; `400 invalid_input` for a key that doesn't start with `sk-ant-`, a model Den doesn't offer,
or a home address that isn't one.

### `POST /api/v1/capture/read`

A device whose acting member may add events, chores or list items. Body (at most 30 MB):

```json
{"kind": "photo", "text": "", "subject": null, "link": null,
 "files": [{"mime_type": "image/jpeg", "name": "IMG_4471.jpg", "data": "<base64>"}]}
```

`kind` is one of `photo`, `screenshot`, `pdf`, `email`, `message`, `link`, `voice`, `typed`. Files
the hub's reader can't take (photos for a home model) are dropped; a device sends the text it
found in them instead. The hub reads as the acting member sees the family (their lists, not a
parent's private ones). Answer:

```json
{"wire": {"events": [], "chores": [], "items": [], "reminders": [], "unclear": []},
 "reader": {"id": "claude", "name": "Claude", "place": "provider", "inputs": ["text", "image", "pdf"], "history_name": "Claude"}}
```

Errors: `403 permission_denied` ("Sign in on this screen to add things", "Leo can't add anything
Den reads"), `409 no_reader` when nothing is set up, `429 busy` (`details.retry`: true) when four
reads are already running, `502 reader_failed` with the reader's own reason and `details.retry`.

## Invites by message

A parent invites someone (a partner, a grandparent, a kid's iPad) from anywhere, and they join
later, with no camera and with the parent's phone asleep: the hub keeps the invite and admits
the device on the parent's behalf. A parent still approves every device that asks.

These endpoints take no token. Creating an invite carries its own proof, an `InviteGrant`
(`packages/den_net`): the invite names this hub as the inviting device and is signed by a
parent's own approved device.

### `POST /api/v1/invites`

Body: `InviteGrant.toJson()`, with `context` `invite` (anyone) or `invite:<memberId>` (an invite
for that person; the device that uses it asks to be theirs).

```json
{"invite": "den://join?f=...&d=<hub>&k=<hub key>&s=...&h=wss%3A%2F%2Fden.example.com%2Fws&x=1793750400",
 "device": "D3ALEXPHONE7QK4MX", "context": "invite:M5ZOE7QK4MXN3TB2", "sig": "<base64url Ed25519>"}
```

The hub keeps it under four random words from Den's word list (44 bits) until the invite
expires, in `<data>/hub/invites.json` (its user only), so a restart doesn't lose it. Answer
`201`:

```json
{
  "code": "maple river canoe tiger",
  "words": ["maple", "river", "canoe", "tiger"],
  "link": "https://den.example.com/#/join/maple-river-canoe-tiger",
  "expires": "2026-10-31T17:00:00.000Z",
  "expires_ms": 1793466000000,
  "member": "M5ZOE7QK4MXN3TB2"
}
```

`link` is built on the hub's public URL (`DEN_PUBLIC_URL`), else the address the request came
to. Errors: `400 invalid_input` (not a grant, a context other than these, no such member, an
invite lasting over a week), `403 permission_denied` (not signed by a parent's own device of this
family, or not naming this hub), `429 rate_limited` (50 invites waiting), `503 not_ready`.

### `POST /api/v1/invites/redeem`

Body `{"code": "maple river canoe tiger"}`, typed any way people type it (case, commas, hyphens;
each word may be its first four letters). Answer `200`:

```json
{
  "invite": "den://join?...",
  "member": "M5ZOE7QK4MXN3TB2",
  "member_name": "Zoe",
  "family": "The Carters",
  "expires": "2026-10-31T17:00:00.000Z",
  "expires_ms": 1793466000000
}
```

The hub starts accepting the invite on `/ws` (see ARCHITECTURE.md, "Pairing"); the device joins
with it there, pinning the hub's key from the invite. An invite works for every device that uses
it until it expires; each one still needs a parent's approval. Errors: `400 invalid_input` (not
four words from the list), `404 not_found` (no such invite, expired, or its parent's device was
revoked since), `429 rate_limited` with `Retry-After` (10 wrong codes in 10 minutes from anywhere, against every
invite; and per client, redeeming counts against the browser link budget and a wrong code
against the failed-tries budget, see [Limits per client](#limits-per-client)), `503 not_ready`.
Redeeming needs no open "Add a device" window in the public posture: the invite is a parent's
consent already.

## Web Push: reminders in browsers

Den in a browser (on an iPhone, a Home Screen web app on iOS 16.4 or later) gets its reminders
and nudges from the hub through Web Push. The hub's VAPID key pair (P-256, RFC 8292) is made on
first use and kept with the subscriptions in `<data>/hub/push.json`, readable by the hub's user
only. Requests are signed with the device's own key, as for capture (`DeviceRequest`).

### `GET /api/v1/push`

Any approved device. `{"key": "<base64url uncompressed P-256 public key>", "subscribed": false}`:
the key is the browser's `applicationServerKey`; `subscribed` says whether this device gets
pushes.

### `PUT /api/v1/push`

A personal device (shared screens show reminders themselves). Body: the browser's
`PushSubscription.toJSON()`:

```json
{"endpoint": "https://web.push.apple.com/QGuQyavXutnMH...", "keys": {"p256dh": "BCVx...", "auth": "BTBZ..."}}
```

`endpoint` must be https on a known push service (`push.apple.com`, `fcm.googleapis.com`,
`push.services.mozilla.com`, `notify.windows.com`), so the hub never posts to an address of a
device's choosing. Answers like `GET`. Errors: `400 invalid_input` (`details.field` `endpoint` or
`keys`), `401 unauthorized`, `403 permission_denied` (not a personal device).

### `DELETE /api/v1/push`

No more pushes to this device. Answers like `GET`.

### `POST /api/v1/push/test`

One notification to this device ("Reminders are on"), to see them arrive. `200 {"ok": true}`;
`404 not_found` when the device hasn't subscribed; `502 push_failed` when the push service
refused it (a subscription it says is gone, `404`/`410`, is forgotten).

### What the hub sends

Each push is one `aes128gcm` record (RFC 8291) with `Authorization: vapid t=<ES256 JWT>,
k=<key>` (`aud` the push service's origin, `exp` 12 hours, `sub` the hub's https address), `TTL`
and `Urgency`. The plaintext is JSON the service worker shows:

```json
{"title": "Soccer practice", "body": "5:30 PM, Field 3", "route": "/event/E2SOCCER7QK4MXN3?at=1792535400000", "tag": "event:E2SOCCER7QK4MXN3:1792535400000:30"}
```

- Reminders: each reminder the hub's reminder service sends (see "Notifications" in
  ARCHITECTURE.md) goes to the subscribed devices of the people it is for who can read it, `TTL`
  one hour, `Urgency: high`.
- Nudges, each once: a device asking to join, to parents (`/today`); a reward asked for, to
  whoever decides rewards (`/points`); a chore given to someone for today or tomorrow, to them
  ("Your turn", `/chore/<id>?date=`).
