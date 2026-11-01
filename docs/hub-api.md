# Den hub HTTP API, version 1

The wire contract for `den_hub`'s REST API and event stream, as listed in
[ARCHITECTURE.md, "Hub API"](../ARCHITECTURE.md#hub-api-for-browsers-sync-home-assistant-scripts).
The hub implements exactly this file; the Home Assistant integration
(`integrations/homeassistant`) and any script in any language build against it. If code and this
file disagree, fix one of them in the same change.

Device sync (`/ws`), MCP (`/mcp`), OAuth and the ICS feed are specified elsewhere; this file
covers `/health`, everything under `/api/v1` (including the calendar links that open the ICS
feed), and the mDNS advertisement.

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
- [Apps asking to connect (OAuth)](#apps-asking-to-connect-oauth):
  [`GET /api/v1/connections/requests`](#get-apiv1connectionsrequests) ·
  [`POST /api/v1/connections/requests/{id}`](#post-apiv1connectionsrequestsid) ·
  [`GET /api/v1/connections/clients`](#get-apiv1connectionsclients) ·
  [`POST /api/v1/connections/clients`](#post-apiv1connectionsclients) ·
  [`DELETE /api/v1/connections/clients/{id}`](#delete-apiv1connectionsclientsid)
- [Capture: reading for every device](#capture-reading-for-every-device)
- [The assistant: the key stays on the hub](#the-assistant-the-key-stays-on-the-hub):
  [`GET /api/v1/assistant`](#get-apiv1assistant) ·
  [`PUT /api/v1/assistant`](#put-apiv1assistant) ·
  [`POST /api/v1/assistant/model`](#post-apiv1assistantmodel)
- [Invites by message](#invites-by-message)
- [Kitchen screens that join with a code](#kitchen-screens-that-join-with-a-code)
- [Calendar links: Den in a phone's calendar](#calendar-links-den-in-a-phones-calendar):
  [`GET /api/v1/feeds`](#get-apiv1feeds) ·
  [`POST /api/v1/feeds`](#post-apiv1feeds) ·
  [`DELETE /api/v1/feeds/{id}`](#delete-apiv1feedsid) ·
  [A calendar for another family](#a-calendar-for-another-family-sharedics-and-watch)
- [Getting back in: server-assisted recovery](#getting-back-in-server-assisted-recovery):
  [`GET /api/v1/recovery/key`](#get-apiv1recoverykey) ·
  [`POST /api/v1/recovery/tickets`](#post-apiv1recoverytickets) ·
  [`POST /api/v1/recovery/redeem`](#post-apiv1recoveryredeem)
- [Signing in with Google and Apple](#signing-in-with-google-and-apple):
  [`GET /auth/oidc/{provider}/start`](#get-authoidcproviderstart) ·
  [`GET /auth/oidc/{provider}/callback`](#get-authoidcprovidercallback-and-post-authoidcapplecallback) ·
  [`POST /auth/logout`](#post-authlogout) ·
  [`GET /api/v1/me`](#get-apiv1me) ·
  [Binding an account](#binding-an-account)
- [Web Push: reminders in browsers](#web-push-reminders-in-browsers)
- [One host, several families](#one-host-several-families)

## Conventions

**Base URL.** `http://<hub>:47733`. A hub that terminates TLS itself serves the same paths over
`https://` and says so in its mDNS TXT record (`tls=1`).

**Authentication.** Every `/api/v1` request carries `Authorization: Bearer <token>`. Tokens are
created by a parent in the Den app under **Settings → Advanced → AI and automations**, shown once, and stored by
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

Scopes gate what a token may *attempt*. Every token acts as someone: the person a parent chose when
making or approving it, by default that parent (`connection.member`). Every write is then checked
with den_core's `can()` for that person, and its changes are signed with them as `actor` and the
token's label in `fields._via`. A connection made before every connection acted as someone has no
`member`: it acts as the parent who approved it (the owner of the device that made it active,
`Den.connectionActsAs`), and when that parent is no longer a parent in the family it only reads
(its scopes count as `read`). Reads are filtered to the spaces the token's person may read
(`canRead`); one that acts for nobody reads what a parent reads, which honors the family's
oversight policy: a member whose
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
  in that zone, wherever the caller is: chores fall due and stars count on the family's days. A
  connection may say where its person lives (`connection.tz`, set when a parent approves it or
  later); then, and when a read action is given `timezone`, the action's `text` says which zone
  its times are in ("Today in Chicago: ...", "Times are Chicago time."), and history's times are
  in that zone. Actions also read dates and times in words: "today", "tomorrow", "Friday", "next
  Friday" (the one in next week), "in 3 days", "next Friday 3pm", "tomorrow at 9:30".
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
| 400 | `not_added` | `add_from_text` added nothing; the message says why for each thing it found | `added`, `left` (`{title, reason, unsure, denied}`), `unclear`, `reader` |
| 409 | `idempotency_conflict` | An `Idempotency-Key` used again for a different action or input | |
| 408 | `timeout` | The body took more than 60 seconds to arrive | |
| 413 | `too_large` | Body over 256 KiB (refused by its `Content-Length` before it is read) | |
| 429 | `rate_limited` | Too many requests from this client (below). Also sends `Retry-After` | `retry_after` (seconds) |
| 500 | `internal` | Anything unexpected. The message carries no stack trace | |
| 503 | `not_ready` | The hub hasn't joined or created a family yet, isn't approved yet, or is still loading its log | |
| 503 | `catching_up` | A write (any scope but `read`, an action that changes something, an MCP tool call that does, an OAuth token) while the hub catches up after `den_hub restore`: it writes nothing of its own until a phone or tablet of the family has synced with it. Reads and previews still work. Also sends `Retry-After` | `retry_after` (seconds) |

### Limits per client

The hub counts what each client does, by IP address (an IPv6 address by its /64), and answers
`429 rate_limited` past these budgets:

| What | Budget |
| --- | --- |
| Requests without a working token or device signature (health, status, the web app's files, OAuth metadata and polling, and any request whose token the hub doesn't know or whose signature doesn't verify; a device signature counts as working only with `X-Den-Body-SHA256`, which lets the hub check it before the body) | 600 a minute. Requests from this machine itself (loopback, not through a proxy) aren't counted |
| Tokens or device signatures that don't work, link codes that don't match, a kitchen screen's secret that doesn't match | 30 in 5 minutes; then every authenticated request from that client gets `429` until the budget refills |
| Browser link slots and link grants, invite and recovery redemptions, kitchen screens' codes | 20 in 10 minutes |
| Wrong setup codes | 5, then that client waits a minute, doubling to an hour with each further wrong code |
| Wrong invite words or slots, wrong recovery codes | 10 in 10 minutes for each (and 200 in 10 minutes from all clients together) |
| Wrong kitchen screen codes (a parent's phone) | 10 in 10 minutes from one client, and 50 for the whole family |
| Kitchen screens waiting with a code | 3 from one client, 20 for the family |
| Invite keys on `/ws` that name nothing (`pair` kind `key`) | 10 in 10 minutes from one client, 200 from all clients together; then `pair_fail` `rate-limited` |
| Devices on `/ws` that aren't approved yet (proving an invite or code, or waiting for a parent) | 4 at once, of 64 for everyone |
| OAuth: registrations, sign-in requests, token requests | 10 an hour, 10 in 15 minutes, 60 in 5 minutes |
| Signing in with Google or Apple: every `/auth/*` request (starting, coming back, signing out) | 30 in 10 minutes; a sign-in takes two (Google) or three (Apple). Past it, a page with `429` and `Retry-After` |
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
  "points_enabled": true,
  "colors": "bright"
}
```

`timezone` is IANA; `week_start` is 0 for Sunday, 1 for Monday. `colors` is the family's color
pack (`bright`, `deep`, `soft` or `bold`): the shades of people's colors everyone sees, while each
member keeps their `marker`.

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
  "until": null,
  "grants": ["lists"],
  "order": 2
}
```

| Field | Type | |
| --- | --- | --- |
| `role` | string | `parent` \| `adult` \| `kid` \| `guest` |
| `tier` | string? | `preReader` \| `little` \| `big` \| `teen` |
| `marker` | string | `sky` `grass` `lavender` `tangerine` `aqua` `coral` `sunshine` `bubblegum`, the order new people get them in. Older names are read as one of these (`blue` as `sky`, `orange` as `tangerine`, and so on). |
| `picture` | string | A picture from the app's pack by id (`fox`, `whale`, `rocket`, ...; den_core's `Picture.pack`), `initial` for the first letter of their name, or `photo:<id>` when they have a photo (photos are added only in the Den app, and their bytes aren't served here) |
| `animal` | string | What older versions showed (`cat` `dog` `rabbit` `bird` `butterfly` `fish` `horse` `cow` `bug`); a member without a picture shows the matching one |
| `birthday` | date? | |
| `until` | date? | For a sitter: the last day they have access (set only in the Den app, on a parent's own device) |
| `grants` | string[] | Subset of `events`, `chores`, `lists`, `points` |
| `order` | int | Display order; members arrays are sorted by it |

The Google or Apple account bound to someone (`member.account`,
[below](#signing-in-with-google-and-apple)) isn't part of it.

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
  "family": {"id": "FKQ2M4X7B3N5C6TW", "name": "The Kotvas", "timezone": "America/Chicago", "week_start": 0, "points_enabled": true, "colors": "bright"},
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
| `token.member` | string? | Who the token acts as (for an older connection that names nobody, the parent who approved it); `null` for one that acts for nobody and only reads |
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

`gaps[].kind` is `no_driver` \| `driver_busy` (one driver with two rides less than half an hour apart,
from different places) \| `overlap` \| `unowned`; `gaps[].message` is written for people;
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

Scope: `read`. Search across events, chores, lists, items and members (den_core `search`): the
whole query in a title (best), place or notes, or every word somewhere in a record, the people it
is for included; words of four letters or more forgive a letter or two.

Query: `q` (required, 1–200 chars), `limit` (1–100, default 50), `include_removed` (`true` adds
removed things History still has, with `detail` `"History"`; default `false`).

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
the action needs (`can()`); a token that acts for nobody runs only reads. den_core still decides
every change. What only a parent decides on
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
| `set_picture` (the pack or an initial; a person their own, a kid when allowed) | write | `admin` | | |
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
| `done` | It ran. `text` is one or two sentences to show or say, then a "Note:" line for each of `result.warnings` (a time the clocks skip, a driver now in two places, a name the family already has, a date already past); `result` matches the action's `output_schema`; writes carry a `receipt` (also in `result.receipt`). A write that changed nothing (a chore already done, an item already on the list) has none |
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
one removed occurrence). Undo answers with a receipt too, which takes the undo back. `?preview=1`
(or `"preview": true`) shows what undo would do and leaves the receipt usable.

**Asking first.** Besides removals and changes to a whole series, these answer
`needs_confirmation` before anything changes: a list, a chore (for the same owner), a reward or a
category with a name the family already has, in any case; giving or taking 100 stars or more at
once (`bigAdjustment` in den_actions), or taking someone below zero; and a parent marking a chore
done for a day still to come (a kid can't). An item already on a list and not checked off isn't
added again (`result.already`); its quantity says how many.

**Names that repeat.** Where several things share a name, actions tell them apart before saying
the name is ambiguous: events by the date or time given (`occurrence`), then, for one repeat split
by "this and following", by the part still to come; chores by whose they are ("Elsie's make bed",
"make bed for Elsie", `person`, then the person the token acts as). The choices an ambiguous name
lists say whose each is.

**From Siri and other voice assistants.** `add_from_text` reads what someone said or wrote, the
way the app's Add does (`{"text": "soccer every Wednesday at 5 for Leo"}`), with the reader a
parent chose for the hub (Claude or a model at home), else Den's own rules. It adds what it's
sure of and lists the rest in `result.left` (`"include_unsure": true` adds that too); `"list"`
puts the items on one list. "Me" is the person the token acts as. When it adds nothing it fails
with `400 not_added` (over MCP, `isError: true`), saying why. See `packages/den_hub/README.md`,
"Siri Shortcuts".

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
| `stage` | `waiting_for_code`, `joining`, `waiting_for_approval`, `syncing`, `ready`, or `removed`: a parent removed this hub from the family (Hub and sync, the hub's **Remove**), and a phone that refused it told it so when it connected. Only a reset brings it back, as a new device |
| `removed` | With `stage` `removed`: what to tell its owner, also in the hub's log ("This hub was removed from the family on Oct 28; reset it to add it again"). The date is in the family's time zone |
| `matching_words` | Present only while the pairing session with the inviting phone is up (`joining` through `syncing`): the three words both ends derive from that session's transcript (den_net's matching words). The phone shows its own three; a parent approves only if they're the same. The hub also logs them at info level and `den_hub status` prints them |
| `last_error` | Why the last join didn't finish (`timed-out`, `unreachable`, or the phone's reason), until the hub is ready |

In the public posture a hub already in a family answers only `paired`, `setup_needed` and
`stage`.

### The setup link

`den_hub setup-link` (and the private setup's `install.sh`, at its end) prints a fresh hub's
setup link, `https://den.example.com/#/setup/<setup code>/<hub device id>`, with a QR code to
scan with the first parent's iPhone; the hub's log shows it beside the setup code when it has a
public URL (`DEN_PUBLIC_URL`). It carries the setup code, which the phone sends to
`POST /api/v1/hub/setup` as before (the hub knows the phone by it), and the hub's device id, the
hash of its key: the phone takes in only a hub whose status names that id and whose pairing
session proves that key, so nothing is compared by eye and no words are shown. In the fragment,
which browsers never send. The setup code alone keeps working.

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

A remote MCP client (claude.ai, ChatGPT) signs in with OAuth 2.1 (`/oauth/authorize`,
`/oauth/token`; see `packages/den_hub/README.md`). It is known to the hub by a client ID metadata
document (an https `client_id` the hub reads), by registering (`/oauth/register`), or as a client
a parent set up for it ([below](#post-apiv1connectionsclients)). Those endpoints need no
credentials, so a sign-in request stays in the hub's memory and nothing reaches the family's log
until a parent acts. The sign-in page shows the app's name, the host its sign-in returns to
(`claude.ai`), what it asked for, and a code (`K7QP-M4XD`). A parent's app lists the waiting
requests with the same code and lets the right one in; the hub then writes a `pending` connection
(labelled `"<client name> (<redirect host>)"`) that the parent approves with den_core's
`approveConnection`, choosing scopes and whose permissions it uses, exactly as before. Requests
expire after 15 minutes (the sign-in page then returns `access_denied`), at most 20 wait at once,
one address can start 10 in 15 minutes, and the hub turns down pending connections nobody
approved within 15 minutes. The access tokens (an hour each) and refresh tokens the hub then
issues are kept as hashes in its own state (`<data>/hub/oauth.json`, its user only, in backups),
never in the family's log, which keeps only the connection itself: who it is for, its scopes,
whether it is on. A parent turning it off ends its tokens at once.

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
      "redirect_loopback": false,
      "client_kind": "document",
      "client_document_host": "claude.ai",
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

`client_name` is whatever the app registered with or its document says; `redirect_host` is where
its sign-in returns and can't be made up, so show both, and the `code`, which the person signing
in sees on their screen. `redirect_loopback` is true when the sign-in returns to the person's own
computer (`localhost`), where any program could be listening: say so. `client_kind` is
`document` (with `client_document_host`, where the app describes itself), `registered` or
`static` (a client a parent set up). `connection` is the pending connection's id once a parent
admitted it.

### `POST /api/v1/connections/requests/{id}`

Body `{"decision": "admit"}` or `{"decision": "decline"}`. Admitting writes the pending
connection (or returns the one already written) and answers
`{"connection": "<connection id>", "request": {...}}`; the parent's app then approves that
connection once it has synced (`Den.approveConnection(id, scopes:, member:)`), or revokes it.
Declining answers `{"ok": true}` and sends the app back with `access_denied`. `404 not_found` for
an unknown or expired request, `409 declined` once it was declined.

### `GET /api/v1/connections/clients`

The clients parents set up, oldest first, never with their secrets:

```json
{"clients": [{"client_id": "Xb1...", "name": "Alexa", "redirect_uris": ["https://alexa.amazon.com/api/skill/link/M3IHEJ1OZMSGZ3"],
              "created": "2026-10-28T15:00:00.000Z"}]}
```

### `POST /api/v1/connections/clients`

For an assistant that can't register itself or publish a client document and takes a client id
and secret instead (Alexa+). Body `{"name": "Alexa", "redirect_uris": ["https://..."]}`: the
name (1 to 60 characters) and the addresses the assistant's console lists (https, at most 10).
Answer `201`, the only time the secret is shown:

```json
{
  "client_id": "Xb1...",
  "name": "Alexa",
  "redirect_uris": ["https://alexa.amazon.com/api/skill/link/M3IHEJ1OZMSGZ3"],
  "created": "2026-10-28T15:00:00.000Z",
  "client_secret": "den_...",
  "authorization_endpoint": "https://den.example.com/oauth/authorize",
  "token_endpoint": "https://den.example.com/oauth/token",
  "token_endpoint_auth_methods": ["client_secret_basic", "client_secret_post"],
  "resource": "https://den.example.com/mcp",
  "scopes": ["read", "calendar", "chores", "lists", "points"]
}
```

Signing in with it still needs PKCE and a parent's approval like any app. It isn't forgotten
until a parent removes it. `400 invalid_input` for a bad name or address, `409 too_many` past 20.

### `DELETE /api/v1/connections/clients/{id}`

Removes a client a parent set up: its refresh tokens stop working and the hub ends the
connections it made. Answer `{"ok": true, "connections_ended": 1}`; `404 not_found` for anything
else.

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
| `X-Den-Hub` | The hub device id the request is addressed to, the same id the signature covers. A Den host serving several families hands the request to that family's hub by it once the signature checks out there from the headers (with `X-Den-Body-SHA256`) ([One host, several families](#one-host-several-families)); otherwise, the family whose address the request came to. den_net's `DeviceRequest.sign` sends it, and the body hash |

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

What this API calls **a parent's own device** (setting the reader or the assistant's key, apps
waiting to connect and the apps parents set up, opening Add a device, the hub's recovery key) is
a personal device whose owner is a parent, or a hub-mode device acting for its owner who is a
parent (a parent's tablet or computer keeping the family online). A shared display never is, and
neither is a hub that belongs to nobody or names someone other than its owner: `403
permission_denied`.

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

Every read the hub's reader makes counts against the family's AI limits in `family.assistant`,
the same ones as the assistant's (see `GET /api/v1/assistant`): what Claude's reads cost adds to
the month, and a kid's reads count toward their `kidDailyLimit`. Reads by apps and assistants
(`add_from_text` over the API or MCP) go through the same reader and budget; once it is spent,
Den's own reader reads for them instead.

Errors: `403 permission_denied` ("Sign in on this screen to add things", "Leo can't add anything
Den reads"), `409 no_reader` when nothing is set up, `429 daily_limit` when a kid has used up
their day, `402 budget_spent` once Claude's reads and the assistant have spent the month's
budget, `429 busy` (`details.retry`: true) when four reads are already running, `502
reader_failed` with the reader's own reason and `details.retry`.

## The assistant: the key stays on the hub

The in-app assistant (den_assistant) can send its model requests through the hub, so phones and
the web app never hold a provider's key. A parent's own phone sets the provider and key here;
the family's rules are in the log as `family.assistant` (`{"enabled", "members", "kidDailyLimit",
"budgetCents"}`, written by a parent's own device with `Den.updateFamily`, never by a shared
screen or anything acting through the hub). It is off until a parent turns it on there and sets a
provider here. Requests are signed like capture's ([`DeviceRequest`](#capture-reading-for-every-device)).

### `GET /api/v1/assistant`

Any device in the family. The key is never in it.

```json
{
  "provider": "anthropic",
  "speaker": "Claude",
  "data_goes_to": "Anthropic",
  "models": [{"model": "claude-haiku-5-5", "label": "Claude Haiku 5.5", "size": "small", "images": true,
              "context_tokens": 1000000}],
  "key_saved": true,
  "key_from": "own",
  "policy": {"enabled": true, "members": ["<member id>"], "kidDailyLimit": 20, "budgetCents": 500},
  "you": {"allowed": true, "used_today": 3, "captures_today": 1, "daily_limit": 20},
  "this_month": {"month": "2026-10", "spent_cents": 120, "budget_cents": 500, "warn": false, "stopped": false,
                 "captures": {"reads": 14, "spent_cents": 35, "stopped": false}}
}
```

`provider` is `anthropic`, `openai`, `gemini`, `xai`, `ollama` (a model at home, with
`base_url`), or null. `key_from` is `own` or `capture` (the Claude key saved for the capture
reader). `you` is for the person signing the request: whether they may use it and, for a kid,
what they used of today's limit (`used_today`: questions and the captures the hub read for them,
which count together; `captures_today` of those). `this_month.spent_cents` is the assistant's and
the capture reader's together, `captures` the reader's share and how many reads it made.
`this_month.warn` is true from 80% of the budget and `stopped` at 100% (for the assistant;
`captures.stopped` for Claude reading captures); a model at home costs nothing.

### `PUT /api/v1/assistant`

A parent's own device. Body:

```json
{"provider": "anthropic", "key": "sk-ant-...", "models": ["claude-haiku-5-5", "claude-sonnet-5-5"]}
{"provider": "anthropic", "use_capture_key": true}
{"provider": "ollama", "base_url": "http://192.168.1.20:11434", "models": ["qwen3:8b"]}
{"provider": null}
```

Without `key` the hub keeps the key it has for the same provider; `use_capture_key` reads the
capture reader's Claude key whenever it is needed rather than copying it; `models` defaults to
the provider's small and large models; `null` turns it off on the hub and forgets the key. The
key is kept in `<data>/hub/assistant.json`, readable by the hub's user only, and is never in the
family's log, an answer or the hub's log. Answers like `GET`. `403 permission_denied` for anyone
else; `400 invalid_input` for a provider Den doesn't know, a key that isn't one, or no key.

### `POST /api/v1/assistant/model`

Any device whose person the family's rules allow. The body is one request in the provider's own
format, exactly as den_assistant's adapter writes it (at most 12 MB), with headers
`X-Den-Provider` (the provider it is written for) and `X-Den-Model`. The hub checks it with
den_assistant's `ModelProxy` (the provider and models it runs), then:

| Refusal | When |
| --- | --- |
| `403 assistant_off` | The family hasn't turned the assistant on |
| `403 not_allowed` | Not for this person: a parent didn't switch it on for them, or they are a little kid or a pre-reader |
| `403 not_set_up`, `403 no_key` | No provider, or no key, on the hub |
| `403 refused` | Another provider or a model the hub doesn't offer ("update this device") |
| `403 too_long` | No output cap, or more than 8,192 tokens (2,048 for a kid) |
| `403 no_photos` | A kid's request with a photo |
| `429 daily_limit` | A kid used `kidDailyLimit` today. Every request from a kid's device counts, and so does every capture the hub read for them, except a request answering tool calls the hub itself forwarded to that kid in a turn it already counted (at most eight such requests per turn, within ten minutes, each call answered once). A request whose provider names no call ids (a model at home, Gemini without ids) counts |
| `402 budget_spent` | This month's estimated cost, the capture reader's included, reached `budgetCents` |
| `429 busy` | Six requests are already going to the provider |
| `502 provider_unreachable` | The provider couldn't be reached (`details.retry`) |

Otherwise it forwards the body unchanged with the key and answers the provider's status and body
unchanged, with `X-Den-Budget-Spent-Cents` and `X-Den-Budget-Cents`. The cost is estimated from
the provider's token counts and den_assistant's prices; the hub logs once when the month passes
80%. It keeps no content and logs none.

## Invites by message

A parent invites someone (a partner, a grandparent, a kid's iPad) from anywhere, and they join
later, with no camera and with the parent's phone asleep: the hub keeps the invite and admits
the device on the parent's behalf.

The app's invites let the person in at once: the parent's phone writes an invite key into the
family's log (ARCHITECTURE.md, "Invite keys") and the invite carries the key, so the device
that opens it lets itself in and nobody taps Approve. With "Let them in right away" off, or for
an invite that names nobody, a parent approves the device that asks, as before.

These endpoints take no token. Creating an invite carries its own proof, an `InviteGrant`
(`packages/den_net`): the invite names this hub as the inviting device and is signed by a
parent's own approved device.

### `POST /api/v1/invites`

Body: `InviteGrant.toJson()`, with `context` `invite` (anyone) or `invite:<memberId>` (an invite
for that person; the device that uses it asks to be theirs), and two optional fields:

| Field | |
| --- | --- |
| `slot` | The app's own words: 64 hex characters, den_net's `InviteWords.slot`, Argon2id of the four words the parent's phone picked, then HMAC-SHA256. The hub keeps the invite under it and never learns the words |
| `key` | With `slot` and a named person: the invite key's public half. The hub checks that the family's log holds that key for that person, live; until the parent's phone has synced it the answer is `409 not_synced` (try again in a moment) |

With a `slot` the answer is `201` with `{"slot", "base", "expires", "expires_ms", "member",
"preapproved"}`: the app builds the link on `base` with its own words
(`<base>/#/join/<w>-<w>-<w>-<w>`). Without one, the hub picks the words as below.

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

Body `{"slot": "<64 hex>"}` (the app stretches the words itself), or
`{"code": "maple river canoe tiger"}`, typed any way people type it (case, commas, hyphens; each
word may be its first four letters). A `code` the hub keeps no invite under is stretched to its
slot on the hub, so words typed into an older app still find the app's own invites. Words the
hub picked itself (for an older app that sent no slot) are kept with their slot too, so the app
asks for every invite by its slot alone: it sends the words themselves only to an older hub that
answers a slot with `400 invalid_input`, never to one that answers `404` (it holds no such
invite, and the words carry the invite's key). Answer `200`:

```json
{
  "invite": "den://join?...",
  "key": "<the invite key's public half, base64url>",
  "preapproved": true,
  "member": "M5ZOE7QK4MXN3TB2",
  "member_name": "Zoe",
  "member_marker": "coral",
  "member_picture": "fox",
  "family": "The Carters",
  "expires": "2026-10-31T17:00:00.000Z",
  "expires_ms": 1793466000000
}
```

With `preapproved` (the family's log holds the invite's key, live and unused), the device joins
over `/ws` with the key (`pair` kind `key`, below) and lets itself in. Otherwise the hub starts
accepting the invite on `/ws` (see ARCHITECTURE.md, "Pairing"); the device joins with it there,
pinning the hub's key from the invite, and waits for a parent. An invite is for one person,
once: it stops working (`404`, "used already") when its key let a device in, when a parent
approves a device that joined with it, or once three devices have joined with it without one
being approved (a second device, or Den started over, before anyone approved; a code that leaked
puts no more than three requests in front of a parent). Errors: `400 invalid_input` (not four
words from the list, or not a slot), `404 not_found` (no such invite, expired, or its parent's
device was revoked since), `429 rate_limited` with `Retry-After` (10 wrong codes or slots in 10
minutes from one client, against every invite, or 200 from all clients together; and per client,
redeeming counts against the browser link budget and a wrong code against the failed-tries
budget, see [Limits per client](#limits-per-client)), `503 not_ready`.

### Joining with an invite key on `/ws`

Not an HTTP endpoint, but the hub's part of it: after the session handshake, a device with an
invite key sends `pair {kind: "key", invite: <the key's record id>, proof}` (den_net's
admission.dart: the key's signature over the session's transcript and the device's key). The hub
(or any device serving the family) finds the key in the family's log, checks it can still let a
device in and the signature, and answers `pair_ok` with the family, its founder key, what the key
admits (`admit: {mode, member, expires}`) and its own proof, an HMAC keyed by the key's public
half. The device then sends its `join`: one change to its own device record, approved, carrying
the key's proof (ARCHITECTURE.md, "Invite keys"). Keys that name nothing count against the
client (see [Limits per client](#limits-per-client)).
Redeeming needs no open "Add a device" window in the public posture: the invite is a parent's
consent already.

## Kitchen screens that join with a code

A tablet or old laptop opened at the family's address shows a short code; a parent types it on
her own phone (Settings, Kitchen screen, Add a screen) and approves the screen there
(ARCHITECTURE.md, "Pairing", "Kitchen screen code"). The hub only carries messages between the
two: it never writes the screen's request or its approval, and nothing it keeps lets anyone in.

The screen picks the code, 8 characters of Crockford's base32 (40 bits, `K7QM-3RXA`), and both
ends stretch it with Argon2id (den_net's `ScreenCode`): the hub sees only its `slot` (64 hex) and
two tags, HMAC-SHA256 under a key from the same stretch, so it can't learn the code or put
another key under it. Waiting screens live in the hub's memory only, 10 minutes each, at most 20
for the family and 3 per client. A code is the family's: it is found only among the screens that
asked at this family's address.

The screen's requests take no token or signature (it has no family yet); they carry the `secret`
the hub gave it. The parent's are signed by a parent's own device ([Capture](#capture-reading-for-every-device)
has the headers); anyone else is `403 permission_denied`, unsigned `401`.

| Method and path | Who | What |
| --- | --- | --- |
| `POST /api/v1/screens/code` `{slot, pubkey, xpub, name, kind, tag}` | The screen | Keeps it waiting for 10 minutes; `201 {secret, expires, expires_ms}`. `tag` is the code's over `[pubkey, xpub, name, kind]`. `409 conflict` (that slot is taken: pick another code), `409 known_device` (the family knows this device already), `429 rate_limited` (the client's share or the family's cap, and the browser link budget, see [Limits per client](#limits-per-client)), `503 not_ready` |
| `POST /api/v1/screens/find` `{slot}` | A parent's own device | `{slot, device, pubkey, xpub, name, kind, tag, expires_ms}` for the phone to check the tag before it asks. `404 not_found` alike for a wrong code, one another parent took and one that ran out; `429 rate_limited` after 10 wrong codes in 10 minutes from one client, or 50 for the whole family |
| `POST /api/v1/screens/accept` `{slot, family, founder, hub, name, tag}` | A parent's own device | After she said Add: what the screen joins with (this family, its founder's key, this hub, the name she chose) and the phone's tag over `[family, founder, hub, pubkey, name]`. From then on only this device goes on with the code. `400` when they aren't this family's |
| `POST /api/v1/screens/code/status` `{slot, secret}` | The screen | `waiting`; `accepted` or `requested` with `family, founder, hub, name, tag`; `approved` or `declined` once the family's log says so. `404` once the code ran out or was settled (30 seconds after) |
| `POST /api/v1/screens/code/join` `{slot, secret, change}` | The screen | Its own signed join request: its device record, by itself, for nobody, `approved: false`, `mode: shared`, the key the code was bound to and nothing else (den_net's `isScreenJoinRequest`). Kept, never written. `400` for any other change, `409 not_accepted` before a parent took the code |
| `POST /api/v1/screens/request` `{slot}` | The parent's device that took the code | `accepted` (no request yet), `requested` with `change`, or `approved`. The phone checks the change again, writes it into the family's log with its own approval (shared, nobody's) and syncs both to the hub |

## Calendar links: Den in a phone's calendar

"Show Den in iPhone Calendar": a parent's own device makes a read-only address for the
family's calendar, or for one person's, and the phone's calendar app subscribes to it
(`webcal://`). The address opens one ICS feed and nothing else. It is not an API token: it can't
reach `/api/v1`, MCP or any other feed. Nor does an API token open a feed (`401`): pasted into a
calendar app or service, it would be a key to the whole API in someone else's settings.

A link for another family (`feed: "shared"`) is different: it reads as the family, not as its
maker, and holds the family's Everyone events only
([A calendar for another family](#a-calendar-for-another-family-sharedics-and-watch)). Every
other feed reads with the permissions of the parent who made the link, exactly as the ICS feed
does for a token acting as that parent: their own "Just me" events are in it, a kid's or a
teen's private events only while the family's oversight lets parents see them (and they drop
out when it stops), and `parents` events for parents. A person's link holds the events they're
in and the events for everyone (`?everyone=0`: only theirs). A link stops working when a parent
turns it off, when the parent who made it leaves the family, or when the device it was made on
is removed (a lost phone's links end with it; links made before the hub kept the device end only
with their maker).

The hub keeps only a SHA-256 hash of each link's secret, with who made it and for what, in
`<data>/hub/feed_links.json` (its user only); the address itself is shown once, when it is made.
At most 50 links at once. The endpoints take no token; requests are signed by a parent's own
device ([`DeviceRequest`](#capture-reading-for-every-device), not a shared display), and anyone
else gets `401` or `403 permission_denied`.

### `GET /api/v1/feeds`

The family's links, newest first, never their addresses:

```json
{"feeds": [{"id": "Qm9iWm9lRmVlZA", "label": "Alex's iPhone", "feed": "family", "feed_name": "The Carters",
            "made_by": "M5ALEX7QK4MXN3TB", "made_by_name": "Alex",
            "made": "2026-10-28T15:00:00.000Z", "made_ms": 1793199600000}]}
```

`feed` is `family`, `shared` (for another family; `feed_name` is the family's name), or the
member id whose events the link holds (`feed_name` is then their name).

### `POST /api/v1/feeds`

Body `{"feed": "family", "label": "Alex's iPhone"}`: `feed` is `family` (the default),
`shared` (a link for another family: `.../shared.ics`), or a member id; `label` (1 to 60
characters) says where the calendar goes, or which family it's for. Answer `201`, the only
time the address is shown:

```json
{
  "id": "Qm9iWm9lRmVlZA",
  "label": "Alex's iPhone",
  "feed": "family",
  "feed_name": "The Carters",
  "made_by": "M5ALEX7QK4MXN3TB",
  "made_by_name": "Alex",
  "made": "2026-10-28T15:00:00.000Z",
  "made_ms": 1793199600000,
  "url": "https://den.example.com/ics/denfeed_q3Jx.../family.ics",
  "webcal": "webcal://den.example.com/ics/denfeed_q3Jx.../family.ics"
}
```

Both are built on the hub's public URL (`DEN_PUBLIC_URL`), else the address the request came
to; a phone's calendar fetches it from wherever it is, so the hub has to be reachable there
(over HTTPS) for the calendar to stay up to date. `GET` on the address answers
`text/calendar` as the ICS feed does, with a weak `ETag` (the same events give the same ETag:
the file's `DTSTAMP` is left out of it) and `304` to an `If-None-Match` that names it; on
another file under the same secret, `404`; once the link is off, `401`. The UIDs in a family's
or a person's feed are `<eventId>@den`, as they always were (a calendar app knows an event by
its UID). Errors: `400 invalid_input` (no such member, a missing or long label),
`409 too_many` (50 links), `503 not_ready`.

### `DELETE /api/v1/feeds/{id}`

Turns a link off: `{"ok": true}`, and calendars subscribed to it stop updating at their next
refresh (they keep what they last fetched until the person removes the subscription).
`404 not_found` for an unknown id. A hub watching a shared link hears `revoked` at once.

### A calendar for another family: `shared.ics` and `watch`

One way and read-only: family A makes a `shared` link and gives its address to family B, whose
parent adds it like any calendar by link (Settings, Calendars). B's hub copies A's events into
B's own log, read-only, and keeps them up to date.

`GET /ics/<secret>/shared.ics` holds the family's **Everyone** events (space `f`) with their
full details: titles, times, places, notes, repeats and changed or cancelled occurrences, and
categories. Never Parents-only or Just-me events, whoever made the link, and never events the
family itself copied in from a Den feed (an imported event whose `source.ref` is a Den UID,
`@<familyId>.den` or `@den`), so a family's events never come back to it (A → B → A) or travel
on to a third family (A → B → C). A school's calendar the family brought into Everyone is
theirs, and is shared. UIDs are `<eventId>@<familyId>.den`; a hub that fetches any feed leaves
out events whose UID ends in its own `@<familyId>.den`. `ETag` and `304` as above.

`GET /ics/<secret>/watch` (server-sent events, the same secret; `404` for a link that isn't
`shared`, `401` once it's off): the subscriber's hub keeps it open instead of polling.

```
retry: 10000

event: hello
data: {"etag":"W/\"5f0c...\""}

event: changed
data: {"etag":"W/\"9a2e...\""}

event: revoked
data: {}
```

- `hello` comes first, with the feed's ETag now: a subscriber whose last fetch had another ETag
  missed a change and fetches.
- `changed` comes about a second after the family's events, exceptions, categories or name
  change (changes in that second are one `changed`), and only when the shared feed's ETag is
  no longer the one the watchers were last told: a Parents-only edit or an imported event never
  makes one.
- `revoked` comes when a parent turns the link off, or when it stops working because its maker
  left the family or the device it was made on was removed; then the stream closes.
- A comment (`: ping`) every 25 seconds keeps it open through proxies; the answer carries
  `Cache-Control: no-cache, no-transform` so a compressing proxy passes events on at once.
- At most 4 streams per link (a fifth closes the oldest) and 200 per hub (`429` beyond).

The subscriber's hub recognizes a Den share by its address (`/ics/denfeed_.../shared.ics`),
keeps the watch open (reconnecting after a drop, waiting longer after each failure, up to 5
minutes), fetches on `changed` (a conditional GET), and also fetches every 15 minutes in case a
stream can't stay open. On `revoked`, or `401` from the feed, it removes every event it copied
from that share and sets the subscription's status to "The Kotvas family stopped sharing their
calendar", which the family's parents see under it in Settings, Calendars. Any other calendar
that stops working keeps what it had and says the link doesn't work.

## Getting back in: server-assisted recovery

When a parent's phone is lost and no other parent's device is left to approve a new one, the
parent gets back in with their 12 recovery words, which need nothing from the hub but a place to
connect (`/ws`, pairing kind `recovery`, ARCHITECTURE.md, "Recovery"). These endpoints are the
other way in, **only for a family that turned it on**: in Settings, Family, "Let the hub help us
get back in", on a parent's own phone. Whoever runs the hub can then let in a new phone for a
parent; every device of the family shows that it happened.

The hub's server recovery key is an Ed25519 key pair made on first use and kept in
`<data>/hub/recovery.json` (its user only, in backups). It lets nobody in until a parent's own
device writes its public half into the family record (`family.recovery.serverKey`), and nobody
once a parent takes it out again.

### `GET /api/v1/recovery/key`

Signed by a parent's own device (`DeviceRequest`, as for capture). Answer `200`
`{"key": "<base64url Ed25519 public key>", "on": false}`, where `on` says whether the family
record already names this key. Errors: `401 unauthorized` (unsigned, or not a device of this
family), `403 permission_denied` (not a parent's own device), `409 unavailable` (a hub with no
data directory, which couldn't keep the key), `503 not_ready`.

### `POST /api/v1/recovery/tickets`

What `den_hub recover --person "Alex"` calls on the running hub. Only that command can: the
request comes from the hub's own machine (loopback, not through a proxy) and carries
`X-Den-Recovery-Secret`, a secret the hub writes to `<data>/hub/recovery-cli` (its user only)
each time it starts. Body `{"person": "Alex"}`: the parent's name in Den (case doesn't matter).
Answer `201`:

```json
{
  "words": ["maple", "river", "canoe", "tiger"],
  "code": "maple river canoe tiger",
  "link": "https://den.example.com/#/recover/maple-river-canoe-tiger",
  "member": "M3ALEX7QK4MXN3TB",
  "member_name": "Alex",
  "expires": "2026-10-28T15:42:00.000Z",
  "expires_ms": 1793202120000
}
```

The code works once, for one phone, for 30 minutes. The hub keeps only its hash, in
`<data>/hub/recovery-tickets.json` (left out of backups), at most 10 at a time. `link` is built
on `DEN_PUBLIC_URL`, and is `null` without one. Errors: `403 permission_denied` (not the
command), `403 off` (the family hasn't turned server help on; the message says how), `400
nobody` (no one by that name; the message lists the parents), `400 not_parent`, `429 busy`, `503
not_ready`. With no hub running, the command makes the code in the data directory itself, and
the hub honors it when it starts.

### `POST /api/v1/recovery/redeem`

Body `{"code": "maple river canoe tiger", "pubkey": "<the new device's Ed25519 key>"}`, the code
typed any way people type it. Answer `200`:

```json
{
  "invite": "den://join?f=...&d=<hub>&k=<hub key>&s=...&x=1793202120",
  "member": "M3ALEX7QK4MXN3TB",
  "member_name": "Alex",
  "family": "The Carters",
  "proof": {"kind": "hub", "member": "M3ALEX7QK4MXN3TB", "key": "<server key>",
            "nonce": "<16 random bytes>", "expires": 1793202120000, "sig": "<base64url Ed25519>"},
  "expires": "2026-10-28T15:42:00.000Z",
  "expires_ms": 1793202120000
}
```

`proof` is the hub's signature, with its server recovery key, over `"den/recovery/v1" 0x00 |
canonical JSON [family, "hub", member, device pubkey, nonce, expires]` (den_core's
`RecoveryProof`). The device joins over `/ws` with the invite, pinning the hub's key, and asks
with a change to its own device record that carries the proof; the hub and every other device
let it in as that parent's own device, at once, only while `family.recovery.serverKey` is this
key. The first redemption binds the code to that device key: the same device asking again (a
dropped connection) gets the same proof, any other gets `404`. Errors: `400 invalid_input` (not
four words, not a key), `403 permission_denied` (the family turned server help off since; the
code is dropped), `404 not_found` (wrong, used, expired, or no longer for a parent), `429
rate_limited` with `Retry-After` (10 wrong codes in 10 minutes from one client, or 200 from all
clients together; and per client,
the same budget as invites and browser links, see [Limits per client](#limits-per-client)),
`503 not_ready`.

## Signing in with Google and Apple

A parent's Google or Apple account signs in to the hub, in a browser, as their member: phase 1
of [docs/auth/ACCOUNT_FIRST_REVIEW.md](auth/ACCOUNT_FIRST_REVIEW.md). Nothing else about devices
changes yet; a browser that is signed in can read `GET /api/v1/me` and no more. These routes
answer only while a provider is on ([Setting up signing in with Google and
Apple](#setting-up-signing-in-with-google-and-apple), from a parent's phone) **and** the family's
public URL is an `https` address, where the provider sends people back. Otherwise every path in
this section answers `404` like any path the hub doesn't know, and nothing else changes. A
provider that isn't on (Apple, say) answers none of its routes either. Turning one on or off takes
effect with the next request: nothing restarts.

**Who an account is.** `member.account` is `{"provider": "google" | "apple", "hash": "<64 hex>",
"hub", "key", "nonce", "expires", "sig"}`. `hash` is lowercase hex HMAC-SHA256, keyed by the UTF-8 bytes of the family id, over
`"den/account/v1" 0x00 provider 0x00 sub`, where `sub` is the provider's own lasting id for the
account (den_core's `accountHash`). Never the email: a sign-in matches a member by provider and
`sub` alone, so the same person with a new address is still them, and another account with their
address is not. Keyed by the family, the same person in two families has two unrelated hashes. The
rest is the hub's proof that the account really signed in for this member (den_core's
`AccountProof`): its device `hub`, with key `key`, signs `"den/account-proof/v1" 0x00 | canonical
JSON [family, member, provider, hash, hub, nonce, expires]`. A `sub` can be looked up and the
family id is on every device, so without it anyone could compute someone else's hash. The record
is written only by the parent themselves, on their own personal device (ARCHITECTURE.md,
"Accounts"): never by the hub, an app or assistant through it, or a shared screen. In this phase
only a member who is a parent now signs in: someone made something else keeps a dormant binding
that signs in as nobody. Two members with the same account (bound while apart) both keep it, and it
signs in as neither until one takes it away.

**Sessions.** A browser that signs in gets `__Host-den_session`, a random 256-bit value
(`Secure; HttpOnly; SameSite=Lax; Path=/`, no `Domain`, `Max-Age` 12 hours). The hub keeps only its
SHA-256, in memory: a restart signs everyone out. Each sign-in makes a new session and ends the one
the browser had; a session ends at once when its member no longer has the account it signed in
with (unbound, bound to another account, removed) or stops being a parent. A cookie sent twice
counts as none.

### `GET /auth/oidc/{provider}/start`

`provider` is `google` or `apple`. Answers `302` to the provider's sign-in, with
`response_type=code`, `scope=openid email`, `state`, `nonce` and PKCE (`code_challenge_method=S256`;
the verifier never leaves the hub but for the token endpoint), `redirect_uri` the hub's
`DEN_PUBLIC_URL` + `/auth/oidc/{provider}/callback`, and for Apple `response_mode=form_post`. It
sets `__Host-den_signin` (`Secure; HttpOnly; SameSite=Lax; Path=/; Max-Age=600`), which ties the
sign-in to this browser: it finishes only there, within 10 minutes, once.

With `?bind=<ticket>` (a [binding](#binding-an-account)'s start link) it starts nothing: it
answers `200` with a page that says "This makes the Google account you choose sign in as Alex in
the Carters' Den. Continue only if you are Alex.", no script, every name escaped, and one form
(`form-action 'self'`) whose Continue posts the ticket back. So a link preview or a scanner that
fetches the link spoils nothing. A ticket that expired, was used, or isn't this hub's answers a
`400` page.

`POST /auth/oidc/{provider}/start` `bind=<ticket>` (`application/x-www-form-urlencoded`) is that
Continue: `Origin` must be exactly the hub's public origin (else a `403` page). It starts the
binding's sign-in as above. A ticket starts one sign-in: a second post answers `400` and spoils
the binding, so neither browser binds anything, however close together the two came.

The provider's endpoints come from its discovery document
(`<issuer>/.well-known/openid-configuration`, whose `issuer` must be exactly the provider's,
endpoints `https`), fetched through NetGuard and kept a day; a provider that can't be reached
answers a `503` page with `Retry-After`, and isn't asked again for 45 seconds.

Sign-ins on their way are kept on the hub for 10 minutes. One client keeps at most 4 plain ones (a
fifth ends its oldest); past 5000 in all the oldest plain one ends; a binding's sign-in is never
ended this way. Nobody is turned away.

### `GET /auth/oidc/{provider}/callback` and `POST /auth/oidc/apple/callback`

Where the provider sends the browser back. Google redirects with `code` and `state` (and `iss`,
RFC 9207, which must be Google's when present). Apple posts a form: the `POST` must come from
Apple's origin (or name none), the body `application/x-www-form-urlencoded`, at most 16 KiB; the
hub keeps the code with its sign-in and answers `303` to `GET .../callback?state=...`, because a
`SameSite=Lax` cookie stays behind on a post from another site and comes along on that `GET`. A
second post for one sign-in spoils it. The `id_token` and `user` Apple posts are ignored: the hub
believes only the ID token it gets from the token endpoint itself.

The `state` is used up when it comes back, whatever happens next, and must come back to the
browser holding the sign-in's cookie. The hub exchanges the code (with the PKCE verifier; Apple's
client secret is an ES256 JWT it signs with the `.p8` key, good for 5 minutes) and checks the ID
token: RS256 only (`none`, HS256 and every other `alg` are refused before any key is looked at;
`crit` is refused), signed by a key in the provider's key set (fetched through NetGuard, kept by
its `Cache-Control` between 5 minutes and a day, fetched again for an unknown key id at most once
every 30 seconds), `iss` exactly the provider's (Google's tokens may name
`https://accounts.google.com` or `accounts.google.com`, the two Google documents), `aud` exactly
the hub's client id and nothing else, `azp` the same when present, `exp`, `iat` (no older than 10
minutes) and `nbf` within 60 seconds, `nonce` this sign-in's, and an email that is there, verified
(`email_verified` true, or Apple's `"true"`) and not one of Apple's Hide My Email addresses
(`@privaterelay.appleid.com`, or `is_private_email`). Every answer is a page (`text/html`,
`Cache-Control: no-store`, no script) and clears `__Host-den_signin`:

| Outcome | Status |
| --- | --- |
| Signed in as the parent the account is bound to: sets `__Host-den_session` | `200` |
| The account is bound to nobody in this family (or to someone who isn't a parent now, or to two people), **or the hub isn't in a family yet**: the same page, byte for byte, with the same headers, after the same work (the code exchanged and the token checked), and nothing made: no session, no record, nothing in the family's log. In phase 3 "no invite" answers the same | `403` |
| A Hide My Email address (the page says how to share the real one); an email that isn't verified | `403` |
| The sign-in expired, was used already, or came back to another browser | `400` |
| The token or the answer didn't check out (forged, another key, another nonce or audience) | `400` |
| The person cancelled at the provider (`error`) | `400` |
| A binding finished: the page says to go back to Den on the phone | `200` |
| A binding whose account already signs in as someone else in the family | `409` |
| The provider couldn't be reached | `503`, `Retry-After` |
| Past the [`/auth` budget](#limits-per-client) | `429`, `Retry-After` |

### `POST /auth/logout`

Ends this browser's session. Only from Den's own pages: `Origin` must be exactly the hub's public
origin, or the answer is `403 permission_denied` and the session stays. Answer `200 {"ok": true}`,
clearing `__Host-den_session`.

### `GET /api/v1/me`

Who this browser is signed in as, by its session cookie. Answer `200`:

```json
{
  "member": {"id": "M3ALEX7QK4MXN3TB", "name": "Alex", "role": "parent"},
  "provider": "google",
  "family": {"id": "F7QK4MXN3TBM3ALEX", "name": "Carter family"},
  "signed_in_ms": 1793202120000,
  "expires_ms": 1793245320000
}
```

`401 unauthorized` without a working session.

### Binding an account

A parent binds their own account from a device they already use, their own personal phone; there
is no other way in this phase, and no new way into the family. The phone does it in four steps, and
writes `member.account` itself: the hub only checks the sign-in, and can never write that record.

1. `POST /api/v1/account/bindings {"provider": "google"}`, signed by the parent's own personal
   device (`DeviceRequest`, as for capture; a kid's phone, a shared screen or a hub-mode device is
   `403 permission_denied`, a provider the hub doesn't offer `400 invalid_input`). Answer `201
   {"id", "provider", "start_url", "expires_ms"}`. `id` is what the phone reads the result back
   by; `start_url` (`.../auth/oidc/google/start?bind=<ticket>`) carries a different random value,
   so the link can't read the result. At most 3 at once per phone (`429 rate_limited`), 100 per hub
   (`429 busy`); each lasts 10 minutes.
2. The phone opens `start_url` in the browser (only when it is on one of the hub's own `https`
   addresses the phone knows), the parent presses Continue on the page it shows, and signs in.
3. `GET /api/v1/account/bindings/{id}`, signed by the same phone for the same parent (anyone else:
   `404 not_found`): `{"state": "waiting"}`, `{"state": "failed", "message": "..."}`, or
   `{"state": "done", "account": {"provider", "hash", "hub", "key", "nonce", "expires", "sig"},
   "email": "alex@example.com"}`: the account with the hub's proof, good for an hour. A binding is
   finished once (a second sign-in spoils it), and a result or a failure is given once; then the
   binding is gone (`404`).
4. The phone shows which account it was and, on the parent's OK, writes
   `member.account = account` on their own member. Every replica checks the proof's signature as
   the change arrives, and refuses it from anywhere but the parent's own personal device, or with a
   proof that isn't from an approved hub of the family at that place in the log, or expired at the
   change's clock.

A session cookie plays no part in this: it can neither start a binding nor read one. A sign-in
comes back once, to the browser that began it, and a start link used twice binds nothing.
`GET /api/v1/account/providers`, signed the same way, answers `{"providers": [{"id": "google",
"name": "Google"}]}`: what the hub offers.

## Setting up signing in with Google and Apple

From the app (Settings, Advanced, **Sign in with Google or Apple**); nothing in the environment.
One set of providers serves every family on a Den host, as Google and Apple see one client with
each family's address registered as a place to come back to.

**Who.** Every request here is signed by a device (`DeviceRequest`) and must come from a parent
of the **host's own family** (the family in the host's data directory itself: the one
`install.sh` or `den_hub serve` set up, whoever runs the server) on their own **personal**
device. A kid, a shared screen, a parent's hub-mode device: `403 permission_denied`. A parent of
any other family on the host: `403 host_family_only`, for reading as well as changing, with no
more said. Unsigned, a token, a signature for another family's hub: `401`. There is no cookie, so
nothing here can be forged from another site; each signature covers the method, the path, the
body's hash, the hub it is for and a nonce used once.

**What is kept.** `<data>/hub/sign-in.json` of the host's own family: written owner-only from the
start (`hub/` 0700, the file 0600 before anything goes in, then renamed into place), in its
backups, never in the family's log. No answer ever holds a client id, a secret, a Team ID, a Key
ID or a key, and the hub's log says only who turned what on or off.

### `GET /api/v1/hub/sign-in`

```json
{
  "google": {"on": true, "set_at": 1793245320000, "set_by": "Alex",
             "redirect_urls": ["https://den.example.com/auth/oidc/google/callback",
                               "https://den-smith.example.com/auth/oidc/google/callback"]},
  "apple": {"on": false,
            "domains": ["den.example.com", "den-smith.example.com"],
            "return_urls": ["https://den.example.com/auth/oidc/apple/callback",
                            "https://den-smith.example.com/auth/oidc/apple/callback"]},
  "https": true
}
```

The addresses are every family's the host knows (those it serves and those `host.json` lists,
the host's own first), `https` ones only: each must be registered at Google (Authorized redirect
URIs) and at Apple (the Services ID's domains and return URLs). `https: false` (and
`without_https`, the families' names that aren't `https`): no family can sign in until it has an
https address.

### `PUT /api/v1/hub/sign-in/google`, `PUT /api/v1/hub/sign-in/apple`

Turns one on, or changes it: `{"client_id", "client_secret"}` for Google; `{"services_id",
"team_id", "key_id", "key"}` for Apple, `key` the `.p8` file's text. Before anything is kept the
hub checks the shape of each (`400 invalid_input` with the `field`: a Google client ID ends in
`.apps.googleusercontent.com`, Team and Key IDs are 10 letters and digits, the key a P-256 `.p8`),
reads the provider's discovery document, and exchanges a made-up code at its token endpoint with
the client: `invalid_client` there is `400 invalid_input` ("Google doesn't know that client ID and
secret together"), `unauthorized_client` `400` (not a web client), and only a `400 invalid_grant`
confirms the client: anything else (a page, a redirect, `429`, `redirect_uri_mismatch`, no JSON)
is `400 invalid_input` ("didn't confirm"), a provider that can't be reached `502
provider_unreachable`. Ten tries per client in ten minutes (`429 rate_limited`), as each asks the
provider. No https family address: `409 needs_https`. The request itself must come over HTTPS (at
a trusted proxy that says so in `X-Forwarded-Proto`) or from the hub's own machine; otherwise
`403 needs_https` before the body is read ("Open Den at its https address"). If the host's own
family stopped while the provider was asked, nothing is kept: `503 not_ready`. Turning a provider
on again, changing it or turning it off ends every session, sign-in on its way and binding that
began through it, in every family. Answers the same status as `GET`.

### `DELETE /api/v1/hub/sign-in/{google|apple}`

Turns it off and forgets what it was set up with. Answers the status.

## Web Push: reminders in browsers

Den in a browser (on an iPhone, a Home Screen web app on iOS 16.4 or later) gets its reminders
and nudges from the hub through Web Push. The hub's VAPID key pair (P-256, RFC 8292) is made on
first use and kept with the subscriptions in `<data>/hub/push.json`, readable by the hub's user
only. Requests are signed with the device's own key, as for capture (`DeviceRequest`).

### `GET /api/v1/push`

Any approved device. `{"key": "<base64url uncompressed P-256 public key>", "subscribed": false}`:
the key is the browser's `applicationServerKey`; `subscribed` says whether this device gets
pushes. It is always this family's own key, on a Den host too, whatever address the request came
to: no family's subscriptions are ever signed with another family's key. The hub records the key
with the subscription.

On a Den host, where every family also hands out the host's own key (see
[Several families in one app](#several-families-in-one-app)), the answer also has `host_key`, and,
once this device subscribed, `with`: `"host"` or `"family"`, the key its subscription was made
with.

### `PUT /api/v1/push`

A personal device (shared screens show reminders themselves). Body: the browser's
`PushSubscription.toJSON()`:

```json
{"endpoint": "https://web.push.apple.com/QGuQyavXutnMH...", "keys": {"p256dh": "BCVx...", "auth": "BTBZ..."}}
```

`endpoint` must be https on a known push service (`push.apple.com`, `fcm.googleapis.com`,
`push.services.mozilla.com`, `notify.windows.com`), so the hub never posts to an address of a
device's choosing. An optional `key` names the `applicationServerKey` the browser subscribed
with: this family's own (the default), or the host's `host_key` when the family opts into it. Any
other key, another family's included, is refused. Answers like `GET`. Errors: `400 invalid_input`
(`details.field` `endpoint`, `keys` or `key`), `401 unauthorized`, `403 permission_denied` (not a
personal device).

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
- To a subscription made with the host's key, every push also names the family: `family` (its
  id) and `label` (its name). The service worker titles it "Smith family: Soccer practice" and a
  tap opens `/l/<family><route>`, that family's page in an app holding several.

### Several families in one app

A browser holds one push subscription, bound to one `applicationServerKey`. One Home Screen app
at one address holding several families of a Den host (FAMILY-LINKS-PLAN §3.5) therefore needs
one key that every one of those families sends with, while no family may ever send with another
family's key. The host keeps one of its own for that, `<data>/host/push.json` (its user only:
`host/` is made 0700 and the key file 0600 before the key is written; a host that can't make
them so, or can't read the key it has, refuses to start the families that use it rather than
quietly making another; no family's key), and every family on the host uses it (an app embedding
the hub may turn that off per family, `HubConfig.hostPush`):

- the family hands out `host_key` beside its own `key`;
- the app, holding several families that all hand out the same `host_key`, subscribes once with
  it and `PUT`s that subscription to each family (signed by that family's device, routed by
  `X-Den-Hub`), naming `key`;
- the family records which key each subscription was made with, and signs each with that key
  only: the host's for those made with it, its own for the rest;
- a family that stops opting in signs its host-key subscriptions with nothing (they read as not
  subscribed, and the app subscribes again), never with its own key in the host key's place.

Single-family apps and families that don't opt in are exactly as before.

## One host, several families

A Den host is one `den_hub` process serving several families (docs/hosting.md, "Several
families"). Each family keeps its own hub: its own device keys and id, engine, data directory,
tokens, calendar links, invites, OAuth clients and Web Push key, and its own address (its
public URL), which its links, sign-in pages and OAuth metadata name, as a hub of its own did.
Everything in this file is unchanged for each family; the host only decides which family a
request is for, and that family then checks whatever the request carries against its own
records alone.

| A request | Goes to |
| --- | --- |
| `GET /ws` | The family the client's hello names (read before any family answers it). A hello that names none (a spoken-code or recovery-words joiner): the address's family |
| Signed by a device | The hub `X-Den-Hub` names, once the signature checks out there from the headers alone (`X-Den-Body-SHA256`); otherwise the address's family, like any request, so made-up headers reach nothing an address doesn't |
| A bearer token (the API, `/api/v1/stream`, `/mcp`) | The address's family; at an address that is no family's, the one family whose token it is |
| `/ics/<secret>/...` | The address's family; at an address that is no family's, the one family whose link it is |
| `POST /api/v1/invites/redeem`, `POST /api/v1/recovery/redeem` | The one family that keeps those words or that slot: words are unique per host, so they work at any family's address |
| `POST /api/v1/recovery/tickets` | The family whose secret `den_hub recover` shows |
| `GET`/`POST /api/v1/link/{slot}` | The family that gave the browser that link code |
| `POST /api/v1/invites` | The hub the grant's invite names |
| `POST /api/v1/hub/setup` | The address's family only (the setup link names it); at an address that is no family's, `404 no_family` |
| `POST /api/v1/screens/code...` (a kitchen screen with no family) | The address's family only: a screen's code is found only by that family's parents, whose signed requests go to their own hub, so a parent of another family on the host finds nothing, the same as a wrong code |
| `/auth/*`, `GET /api/v1/me` | The address's family only: each family's sign-in comes back to its own address (its own redirect), with cookies only that address holds (`__Host-`). At an address that is no family's, `404 no_family`, before any sign-in starts |
| Anything else | The address's family |

"The address's family" is the family whose public URL names the request's host (`Host`, or a
trusted proxy's `X-Forwarded-Host`). A host configured for one family (a hub of its own, or
`den_hub serve` on a host that has never had another family) answers at any address, as a hub
always has. That is configuration, never how many families happen to be open, and a host that
has had another family (taken off since, or deleted) never goes back: an address a family had
never reaches the first family. With several, a request that names no family, at an address that
is none of theirs, gets `404` with `error.code` `no_family`, never another family's answer.

An address the host is configured to serve whose family isn't open yet (the host is starting, or
the family didn't open and is tried again every 30 seconds) answers `503` with `error.code`
`not_ready` and `Retry-After`, whatever the request; a hello naming no family there is closed.
A calendar's subscribers keep their copies through it (only `401` means a family stopped
sharing). `GET /health` at an address that is no family's says only `{"ok", "api", "ready"}`,
and `waiting`, how many families aren't open. It fails (`503`) while the host starts, until every
family has had its first try at opening; after that it answers `200`, so one family that won't
open keeps no one else waiting (`den_hub families` and `den_hub status` say which, and why). The
web app is the same at every address, with that address in its Content-Security-Policy.

Rate limits, failed tries and wrong invite or recovery words count per client across the whole
host, so spreading tries over families' addresses buys none. The limit on wrong words for
everyone together grows with the number of families, so a few clients can't keep every family
from joining.

A family's hub reading another family's calendar link on the same host (`GET` of
`/ics/<secret>/<file>` and its watch stream, at that family's https address) is answered in the
host's own process, as a request from outside carrying only its secret, counted under the
reading hub's own limits: no DNS, proxy or `DEN_PEER_HUBS` is involved. Only the calendar feeds
a family subscribes to are read that way; every other request a hub makes (an OAuth client's
metadata document included, whatever address it names) goes out through NetGuard.

### The command line's endpoints

`den_hub add-family`, `adopt`, `remove-family` and `families` ask the running host under
`/api/v1/host`, only from the host's own machine (loopback, with none of the headers a proxy or
CDN adds: any `X-Forwarded-*`, `Forwarded`, `Via`, `X-Real-IP`, `CF-Connecting-IP`,
`True-Client-IP` and the like) and only with `X-Den-Host-Secret`, the secret the host writes to
`<data>/host/cli-secret` each time it starts; anything else is `403 permission_denied`. (A request
whose `Host` or `X-Forwarded-Proto` makes no address is `400` anywhere on the host.)

| Method and path | What |
| --- | --- |
| `GET /api/v1/host` | `{"families": [{"id", "first", "public_url", "device", "family", "family_name", "ready", "stage", "setup_code"}], "waiting": [{"id", "public_url", "error", "retry_seconds"}]}`: `waiting` lists the families in `host.json` that aren't open, and why |
| `POST /api/v1/host/families {"public_url", "id"?}` | A new family at that address, waiting for its first parent's phone (`setup_code`, `device`); an address a family was taken off brings that family back (`id` says which, when more than one was: else `409 ambiguous` with `details.ids`). `409 conflict` for an address any family on the host has, open or not |
| `POST /api/v1/host/logs {"id", "public_url", "adopted_from"}` | Serves the hub `den_hub adopt` copied into `logs/<id>/`. `409 conflict` when the host already serves its hub, its family or its address |
| `DELETE /api/v1/host/families/{id or address}` | Stops serving that family; its data stays |
| `DELETE /api/v1/host/families/{id or address}?delete_data=1` | Stops serving it and deletes its data and its record, in the running host. A family still on the host only by its id (`409 in_use` by its address); `409 busy` when something (a backup) has its data open |
