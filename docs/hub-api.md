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
  [`GET /api/v1/stream`](#get-apiv1stream-server-sent-events)

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
| `admin` | Implies every other scope |

Scopes gate what a token may *attempt*. Every write is then checked with den_core's `can()` for the
token's member (`connection.member`); a token with no member acts with parent-level permissions
and its changes are signed with `actor: null` and the token's label in `fields._via`. Reads are
filtered to the spaces the token's member may read (`canRead`); a token with no member reads what
a parent reads. A record in a space the token can't read does not exist as far as the API is
concerned (`404`, never `403`).

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
| 405 | `method_not_allowed` | Known path, wrong method. Also sends `Allow` | |
| 409 | `read_only` | Editing or deleting an event imported from a subscribed calendar (`source.kind` is not `manual`) | |
| 413 | `too_large` | Body over 256 KiB | |
| 500 | `internal` | Anything unexpected. The message carries no stack trace | |
| 503 | `not_ready` | The hub hasn't joined or created a family yet, isn't approved yet, or is still loading its log | |

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
| `tls` | no | `"1"` when the advertised port speaks HTTPS; absent or `"0"` means plain HTTP |

The TXT record carries no family name, member names or other family data.

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
  "marker": "orange",
  "animal": "fox",
  "birthday": "2017-04-02",
  "grants": ["lists"],
  "order": 2
}
```

| Field | Type | |
| --- | --- | --- |
| `role` | string | `parent` \| `adult` \| `kid` \| `guest` |
| `tier` | string? | `preReader` \| `little` \| `big` \| `teen` |
| `marker` | string | `blue` `green` `orange` `pink` `teal` `plum` `brown` `olive` `sky` `slate` |
| `animal` | string | `cat` `dog` `rabbit` `fox` `owl` `fish` `horse` `bear` `turtle` |
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

Note for the hub: den_core's `Occurrence.seriesStart` currently returns the moved start; for an
occurrence moved by an exception, `occurrence` must be the exception's `occurrence` field.

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
    {"id": "M3MOMQ7K2XN4B5TA", "name": "Mom", "role": "parent", "tier": null, "marker": "teal", "animal": "owl", "birthday": null, "grants": [], "order": 0},
    {"id": "M5LEOW3H7ZQ2D4VC", "name": "Leo", "role": "kid", "tier": "big", "marker": "orange", "animal": "fox", "birthday": "2017-04-02", "grants": ["lists"], "order": 2}
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

`stores` are store names used on items, most used first (den_core `stores`).

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
| `totals` | object | Member id → current balance (earned + adjustments − approved redemptions), for every member the token can see, including zeros |
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
