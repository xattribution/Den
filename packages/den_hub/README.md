# den_hub

The Den hub: the family's always-on device. One port (47733) serves device sync (`/ws`), the
HTTP API and event stream (`/api/v1`, exactly [docs/hub-api.md](../../docs/hub-api.md)), MCP
(`/mcp`) with OAuth 2.1 for remote clients, calendar feeds in and out, reminders through Home
Assistant and ntfy, mDNS (`_den._tcp`), and the web app.

## Library

```dart
final hub = await DenHub.start(den, const HubConfig(dataDir: '/data', webDir: '/app/web'));
// ...
await hub.stop();
```

`den` is an open `Den` (the hub's own device, in hub mode). The library uses `dart:io` and no
CLI code, so the Den app can run a hub in-process on desktop and Android. `HubConfig`: `port`,
`host`, `dataDir` (the hub's own state; the change log is the `Den`'s storage), `webDir`,
`relay`, `name`, `homeAssistantUrl` and `homeAssistantToken`, `notify` (per member, by id or
name: Home Assistant notify service and ntfy topic), `publicUrl`, `allowedOrigins`,
`trustedProxies`, `public`, `contentSecurityPolicy`, `mailbox`, `mdns`, `log`, `onSetupCode`.
Logs never carry tokens, PINs, invite secrets or change contents. Hosting a hub on a server
behind HTTPS is in [docs/hosting.md](../../docs/hosting.md).

## Command line

The command line lives in `packages/den_hub_cli`, so this library carries no SQLite and the app
can run the hub in-process. In that package, `dart build cli` (not `dart compile exe`:
den_sett_import links SQLite through a build hook) makes `bundle/bin/den_hub` with `bundle/lib/`
beside it.

| Command | |
| --- | --- |
| `serve` (default) | Env `DEN_DATA` (default `./den-data`), `DEN_WEB`, `DEN_PORT`, `DEN_HOST`, `DEN_RELAY`, `DEN_NAME`, `DEN_HA_URL`, `DEN_HA_TOKEN`, `DEN_PUBLIC_URL`, `DEN_ALLOWED_ORIGINS`, `DEN_TRUSTED_PROXIES` (reverse proxies whose `X-Forwarded-*` headers count: addresses or CIDRs), `DEN_PUBLIC` (`1`: reachable from the internet; default on for an `https` `DEN_PUBLIC_URL`), `DEN_CSP` (replaces the web app's Content-Security-Policy), `DEN_MAILBOX`, `DEN_MDNS` (default off in the public posture), `DEN_LOG`, `DEN_NOTIFY` (JSON, or `notify.json` in the data directory) |
| `mcp --token T` | MCP over stdio. Bridges to a running hub's `/mcp`, else serves from the data directory |
| `import-sett coord.db --as NAME` | Imports Sett as that parent through the hub device (changes say "via Sett import") |
| `setup-code` | A fresh hub's setup code |
| `status` | What the hub is doing |
| `backup --out FILE --passphrase-env VAR` | Keys, the change log, the hub's own state and `notify.json`, sealed with den_net's backup format. Works while the hub runs (`docker compose exec hub /app/bin/den_hub backup ...`): it reads the log's metadata before the log and cuts the log after its last complete line, so the copy is consistent without the hub's lock |
| `restore --in FILE --passphrase-env VAR [--force]` | Refuses while a hub runs on the directory (stop it, then `docker compose run --rm hub restore ...`); `--force` first removes the hub that is there. Afterwards, let the family's devices connect before changing anything: what the hub wrote after the backup comes back from them, and the hub's change counter moves past it |

Data directory: `keys.json` (device keys, owner-only), `log/` (change log), `hub/` (reminders
sent, OAuth clients and refresh-token hashes, the capture reader, feed caches), `notify.json`
(optional reminder targets), `hub.lock` (one process at a time).

## Adding a hub to a family

A fresh hub has no family. It prints a one-time setup code (`ABCD-EFGH`, from
`23456789ABCDEFGHJKMNPQRSTVWXYZ`) to its log and to `hub/setup-code`; reading it proves access
to the hub, so a stranger on the LAN can't claim it.

1. The parent's phone makes an ordinary invite (`node.createInvite()`) and calls
   `POST /api/v1/hub/setup {"code", "invite", "direct"?}`. Each address gets five wrong codes, then
   waits a minute (doubling with each further wrong code, up to an hour); the code never changes
   because of wrong tries, so nobody else on the network can make it change under its owner.
2. With the invite's hub URLs or relay, the hub dials the phone (`openInviteChannel`: relay
   rendezvous when the phone hosts one). With `"direct": true` (or neither), the phone opens
   the WebSocket `GET /api/v1/hub/setup/ws` and serves its side there (`node.serve(socket)`);
   the hub pins the inviter's key from the invite, so only that phone can complete the session.
3. The hub writes its join request (`mode: hub`) and the phone shows it as a pending join; a
   parent approves it (`node.approve(join, mode: DeviceMode.hub)`). `GET /api/v1/hub/status`
   (no token, [docs/hub-api.md](../../docs/hub-api.md#get-apiv1hubstatus)) reports `paired`,
   `device`, `name`, `version`, `setup_needed`, `stage` (`waiting_for_code`, `joining`,
   `waiting_for_approval`, `syncing`, `ready`) and, while the session with the phone is up, its
   `matching_words`. The hub logs the same words and `den_hub status` prints them, so a parent
   can compare them with the three the phone shows before approving.

Errors: `403 permission_denied` with `details.tries_left`, `429 rate_limited` (with `Retry-After`)
while that address waits, `409 already_set_up`, `409 busy`.

## Linking a browser

1. The browser calls `POST /api/v1/link` and shows `uri` (`den://link?hub=<hub id>&slot=<slot>&u=<hub URL>`)
   as a QR code. It keeps `secret`.
2. A parent's phone scans it, makes an invite naming the hub (`node.createHubInvite(hubId)`),
   signs it (`InviteGrant.sign(invite, keys: den.keys, context: 'link:<slot>')`) and posts
   `grant.toJson()` to `POST /api/v1/link/{slot}`. The hub accepts grants signed by an
   approved, unrevoked personal device owned by a parent, for this family and naming this hub,
   and adds the invite to its own invite book.
3. The browser polls `GET /api/v1/link/{slot}` with `X-Den-Link-Secret`, gets the invite, and
   joins over `/ws` with `joinWithInvite`. The phone sees the pending device and approves it.

Slots last 10 minutes (32 at most). Errors: `404` (unknown, expired or wrong secret), `403`
(grant refused), `409 already_linked`, `429 rate_limited`.

In the public posture (a hub reachable from the internet, `DEN_PUBLIC=1` or an `https`
`DEN_PUBLIC_URL`), step 1 works only while a parent has "Add a device" open: their phone sends a
signed `POST /api/v1/link/window` ([docs/hub-api.md](../../docs/hub-api.md#post-apiv1linkwindow))
first, and the browser otherwise gets `403 link_closed`.

## MCP and OAuth

`/mcp` is Streamable HTTP with JSON responses: `initialize` (2025-11-25, 2025-06-18,
2025-03-26, 2024-11-05), `ping`, `tools/list` (filtered to the token's scopes), `tools/call`,
sessions by `Mcp-Session-Id`, `GET` answers 405. Browser `Origin`s must be listed, or be the
hub itself on an IP, `localhost`, `.local` name or the public URL (DNS-rebinding protection).
A missing token gets `401` with `WWW-Authenticate: Bearer resource_metadata=".../.well-known/oauth-protected-resource"`.

OAuth: `/.well-known/oauth-protected-resource`, `/.well-known/oauth-authorization-server`,
`/oauth/register` (RFC 7591; 10 an hour per address, unused registrations forgotten after a
day), `/oauth/authorize` (PKCE S256 required; holds the request in the hub, writing nothing to
the family's log, and shows "Approve the client in the Den app", the host its sign-in returns
to and a code; a parent's app lists it with `GET /api/v1/connections/requests`, admits it with
`POST /api/v1/connections/requests/{id}`, which writes the pending connection, then approves
that as before ([docs/hub-api.md](../../docs/hub-api.md#apps-asking-to-connect-oauth)); declined
or 15 minutes without an answer redirects with `access_denied`), `/oauth/token` (authorization
code with PKCE, refresh-token rotation with reuse detection). Access tokens last an hour and are
stored only as hashes in the connection record; refresh tokens (90 days) only as hashes in
`hub/oauth.json`.

## Calendar feeds

In: every `subscription` is fetched every 30 minutes and when it changes (15 s, 10 MB,
`webcal:` as `https:`, ETag and Last-Modified), parsed (folding, TZID including Windows names,
dates, DURATION, RRULE, EXDATE, RECURRENCE-ID, STATUS:CANCELLED, X-WR-CALNAME), filtered
(include and exclude words in titles, skip all-day, series that ended over 90 days ago), and
written by the hub with `source {kind: ics, ref: UID, label}` into the subscription's space.
Its `status` says how it went ("12 events, updated 3:42 PM", or "12 events (2 Den couldn't
read), updated 3:42 PM" when some events had dates Den can't place; those are skipped, never
the whole feed). Which UID became which event is saved as a sync goes, and a sync that starts
over finds the feed's events by `source.ref`, so a hub stopped mid-sync never adds an event
twice (and removes copies an older hub left).

Out: `GET /ics/<token>/family.ics` and `GET /ics/<token>/<memberId>.ics` (that member's events
and everyone's; `?everyone=0` for only theirs), with RRULE, EXDATE, RECURRENCE-ID and VTIMEZONE.
