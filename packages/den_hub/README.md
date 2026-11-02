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
| `serve` (default) | Env `DEN_DATA` (default `./den-data`), `DEN_WEB`, `DEN_PORT`, `DEN_HOST`, `DEN_RELAY`, `DEN_NAME`, `DEN_HA_URL`, `DEN_HA_TOKEN`, `DEN_PUBLIC_URL`, `DEN_ALLOWED_ORIGINS`, `DEN_TRUSTED_PROXIES` (reverse proxies whose `X-Forwarded-*` headers count: addresses or CIDRs), `DEN_PUBLIC` (`1`: reachable from the internet; default on for an `https` `DEN_PUBLIC_URL`), `DEN_CSP` (replaces the web app's Content-Security-Policy), `DEN_MAILBOX`, `DEN_MDNS` (default off in the public posture), `DEN_LOG`, `DEN_NOTIFY` (JSON, or `notify.json` in the data directory), `DEN_FETCH_ALLOW` (private networks calendar feeds may come from: addresses or CIDRs), `DEN_PEER_HUBS` (the other families' addresses on this server, whose shared calendars come through this machine's own reverse proxy) |
| `mcp --token T` | MCP over stdio. Bridges to a running hub's `/mcp`, else serves from the data directory |
| `import-sett coord.db --as NAME` | Imports Sett as that parent through the hub device (changes say "via Sett import") |
| `setup-code` | A fresh hub's setup code |
| `setup-link [--url U]` | A fresh hub's setup link (`https://<hub>/#/setup/<code>/<hub device id>`, on `--url` or `DEN_PUBLIC_URL`) and a QR code for the first parent's phone, which then needs nothing typed or compared. See docs/hub-api.md, "The setup link" |
| `open-linking [--minutes N]` | In the public posture, lets browsers ask for a link code for N minutes (default 10), as if a parent had opened "Show a code on the computer instead" in the app |
| `status` | What the hub is doing |
| `recover --person NAME` | A parent lost their phone and no other parent's is left: prints a one-time link and four words that let in one phone as that parent for 30 minutes, only if the family turned on "Let the hub help us get back in" (otherwise it says how). `docker compose exec hub /app/bin/den_hub recover --person "Alex"`. See docs/hub-api.md, "Getting back in" |
| `backup --out FILE --passphrase-env VAR` | Keys, the change log, the hub's own state and `notify.json`, sealed with den_net's backup format. Works while the hub runs (`docker compose exec hub /app/bin/den_hub backup ...`): it reads the log's metadata before the log and cuts the log after its last complete line, so the copy is consistent without the hub's lock |
| `restore --in FILE --passphrase-env VAR [--force]` | Refuses while a hub runs on the directory (stop it, then `docker compose run --rm hub restore ...`); `--force` first removes the hub that is there. It leaves `hub/restored.json`: until an approved device of the family has synced with it, the hub writes nothing of its own (calendar feeds and the OAuth sweep wait; API and MCP writes and OAuth tokens answer `503 catching_up` with `Retry-After`), so what it wrote after the backup comes back from the devices first and its change counter moves past it. `status` says `Catching up after a restore` until then |

Data directory: `keys.json` (device keys, owner-only), `log/` (change log), `hub/` (reminders
sent, OAuth clients and the hashes of the access and refresh tokens issued to them (never in the
family's log), the capture reader, the assistant's provider and key
in `assistant.json` and its usage in `assistant_usage.json`, feed caches, invites waiting in
`invites.json`, the Web Push key and subscriptions in `push.json`), `notify.json` (optional
reminder targets), `hub.lock` (one process at a time).

## Invites and reminders for browsers

A parent's device leaves the hub an invite to send as a message (`/api/v1/invites`): the hub
keeps it under the slot of the words the phone picked (or four words of its own) and admits
whoever redeems them; an invite that carries an invite key lets the device in at once (den_net's
`pair` kind `key`), any other waits for a parent to approve. Browsers get
reminders and nudges by Web Push (`/api/v1/push`, RFC 8291 and 8292, P-256 through
pointycastle). Both are specified in [docs/hub-api.md](../../docs/hub-api.md#invites-by-message).

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
`DEN_PUBLIC_URL`), step 1 works only while a parent has "A browser on a computer" open (Settings → Advanced → Hub and sync): their phone sends a
signed `POST /api/v1/link/window` ([docs/hub-api.md](../../docs/hub-api.md#post-apiv1linkwindow))
first (or the owner runs `den_hub open-linking` on the server), and the browser otherwise gets
`403 link_closed`.

## MCP and OAuth

`/mcp` is Streamable HTTP, for both eras of MCP on one endpoint:

- **2026-07-28**, stateless: every request carries `io.modelcontextprotocol/protocolVersion` and
  `.../clientCapabilities` in `params._meta`, and the `MCP-Protocol-Version`, `Mcp-Method` and
  `Mcp-Name` headers (Base64 `=?base64?...?=` form allowed) must match the body, else
  `400` with `-32020`; a version Den doesn't speak is `400` with `-32022` and the supported list;
  an unknown method is `404`; a notification is `202`. No sessions (an `Mcp-Session-Id` is
  ignored). `server/discover`; `ttlMs` and `cacheScope` on `server/discover` (public, an hour),
  `tools/list`, `resources/list`, `resources/templates/list`, `prompts/list` (private, five
  minutes) and `resources/read` (private, 0); results carry `resultType` and the server's name
  in `_meta`. `subscriptions/listen` holds a server-sent event stream open: it acknowledges the
  `resourceSubscriptions` the token may read and sends `notifications/resources/updated` when one
  changes (list-changed notifications aren't offered; Den's lists don't change while it runs).
- **2025-11-25, 2025-06-18, 2025-03-26, 2024-11-05**: `initialize` opens a session kept by
  `Mcp-Session-Id` (`DELETE` ends it), as before.

`tools/list` shows den_actions' specs the token may use (its scopes, and what its member is
allowed); `tools/call` runs them. A change that needs a yes (deleting a list, a whole series)
asks through the client when a 2026-07-28 request declares `elicitation` (form): the result is
`input_required` with one yes-or-no form, and its `requestState` is the runner's confirmation
token, which stays on the hub, bound to the connection, the tool and this exact input, for ten
minutes and one use; the client's retry with `inputResponses` runs it or says nothing changed.
Other clients get the question as the tool's result and call again with `"confirm": "<token>"`.
The tools, confirmations and receipts are in
[docs/hub-api.md, "Actions"](../../docs/hub-api.md#actions-everything-mcp-and-the-app-can-do);
REST's `/api/v1/actions` runs the same ones with the same runner.

Resources, answered by the read actions as the token's member sees them (JSON):
`den://today`, `den://week`, `den://family`, `den://lists`, `den://chores`, `den://points`, and
the templates `den://lists/{list}`, `den://days/{date}`, `den://people/{person}/today`. Prompts,
offered when the token may use every tool they name: `whats_today`, `plan_week`,
`shopping_list` (`meals`, `list`), `chores_left`, `add_from_message` (`text`).

Browser `Origin`s must be listed, or be the hub itself on an IP, `localhost`, `.local` name or
the public URL (DNS-rebinding protection). A missing token gets `401` with
`WWW-Authenticate: Bearer resource_metadata=".../.well-known/oauth-protected-resource/mcp",
scope="read calendar chores lists points"`.

OAuth: `/.well-known/oauth-protected-resource` (and `/mcp` after it),
`/.well-known/oauth-authorization-server` (with `client_id_metadata_document_supported` and
`authorization_response_iss_parameter_supported`), three ways to be a client:

- **A client ID metadata document**, which MCP prefers: a `client_id` that is an https address
  with a path is fetched (through the guarded client below, no redirects, at most 5 KB, kept as
  its `Cache-Control` says, five minutes to a day) and must name itself, a `client_name` and its
  `redirect_uris`; only public clients (`token_endpoint_auth_method` `none`).
- **Registration** (`/oauth/register`, RFC 7591, kept for clients without documents; 10 an hour
  per address, unused registrations forgotten after a day).
- **A client a parent sets up** in the Den app for an assistant that can do neither (Alexa+):
  `POST /api/v1/connections/clients` from a parent's own phone answers a `client_id` and
  `client_secret` (shown once) with the addresses to enter beside them
  ([docs/hub-api.md](../../docs/hub-api.md#apps-asking-to-connect-oauth)).

`/oauth/authorize` needs PKCE S256 and holds the request in the hub, writing nothing to the
family's log. It shows "Approve the client in the Den app", the host its sign-in returns to (and,
when that is this computer, says any program here could be asking) and a code; a parent's app
lists it with `GET /api/v1/connections/requests`, admits it with
`POST /api/v1/connections/requests/{id}`, which writes the pending connection, then approves that
as before; declined or 15 minutes without an answer redirects with `access_denied`. Redirect
addresses match exactly, except loopback `http` ones, which match on any port (RFC 8252). A
`resource` (RFC 8707) must be the hub or its `/mcp`, at `/oauth/authorize` and `/oauth/token`
(`invalid_target` otherwise), and every redirect carries `iss`. `/oauth/token` does the
authorization code with PKCE and refresh-token rotation with reuse detection. Access tokens last
an hour and refresh tokens 90 days; both are stored only as hashes in `hub/oauth.json` (owner-only,
in backups), never in the family's log, so an hourly token doesn't become a synced change. A hub
moves the access token hash an older hub wrote into a connection record there once, and clears it
from the log. Which paths must be public for each assistant is in
[docs/hosting.md](../../docs/hosting.md#connecting-ai-assistants).

## Fetching what callers give the hub

Calendar feeds and client metadata documents are addresses someone else chose, so the hub
fetches them through `NetGuard`: each connection looks its host up once, refuses it when any
answer is loopback, private, link-local, carrier-grade NAT, unique local IPv6, a cloud metadata
address, multicast or reserved (IPv4 inside IPv6 is judged as IPv4), and connects to the address
it checked, so a name can't answer differently between the check and the connection. Redirects
are new connections, checked again. `DEN_FETCH_ALLOW` (addresses or CIDRs) lets the operator
admit a calendar server on the home network. The hub's own `DEN_PUBLIC_URL` and the names in
`DEN_PEER_HUBS` (the other families on the same server) may also lead to this machine's loopback,
where the server's reverse proxy answers for every family, so one family can fetch another's
shared calendar: only over `https`, on the port the address names, with the certificate checked
for the name; any other name, `http`, another port or an IP address is judged as above. What the
operator configures (Home Assistant, ntfy, the capture reader, the assistant's provider) isn't
guarded.

## The assistant through the hub

The in-app assistant's model requests can go through the hub, so phones and the web app never
hold a provider's key: a parent sets the provider and key (`PUT /api/v1/assistant`, or "use the
capture key"), devices POST requests in the provider's own format to
`/api/v1/assistant/model`, and the hub holds them to the family's rules (`family.assistant`: on
or off, who may use it, a kid's daily questions, no photos for kids) and the month's budget
(warns at 80%, stops at 100%) before forwarding them with the key. The key is in
`hub/assistant.json` (owner-only); no conversation is kept and none is logged. See
[docs/hub-api.md](../../docs/hub-api.md#the-assistant-the-key-stays-on-the-hub).

## Siri Shortcuts

A Shortcut on an iPhone can add to Den by voice ("Hey Siri, add to Den: milk and eggs") with
`POST /api/v1/actions/add_from_text`. It runs on the phone, so it works through the private
proxy too; the hub needn't be on the public internet.

1. A parent makes a token in the Den app under Settings → Advanced → AI and automations → Make a token: label it "Siri",
   choose whose it is (so History says who added things, and the person's own permissions apply),
   and give it the `lists`, `calendar` and `chores` scopes (or only `lists` for a shopping-only
   Shortcut). Copy the token; it's shown once.
2. In Shortcuts, make a new Shortcut named "Add to Den" with these actions:
   - **Dictate Text** (or **Ask for Input**, for typing).
   - **Get Contents of URL**: URL `https://<your hub>/api/v1/actions/add_from_text`, Method `POST`,
     Headers `Authorization: Bearer <token>`, Request Body **JSON** with `text` set to the
     Dictated Text (add `list` set to `Groceries` to send every item there).
   - **Get Dictionary Value** `text` from the Contents of URL.
   - **Speak Text** (or **Show Result**) with that value.
3. Say "Hey Siri, Add to Den", then "soccer every Wednesday at 5 for Leo" or "milk, eggs and
   bread". Siri reads back what Den added, and what it left for a person to look at in the app
   (something already on the list, a name nobody has).

The answer's `receipt.id` takes it back: a second Shortcut, "Undo Den", POSTs `{}` to
`/api/v1/actions/undo` with the same token, which undoes that token's last change. Any other
action works the same way, such as `{"list": "Groceries"}` to `get_lists` for a "What's on the
grocery list?" Shortcut that speaks `text`.

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

Out: `GET /ics/<secret>/family.ics` and `GET /ics/<secret>/<memberId>.ics` (that member's events
and everyone's; `?everyone=0` for only theirs), with RRULE, EXDATE, RECURRENCE-ID and VTIMEZONE.
The secret is a calendar link's (`/api/v1/feeds`), never an API token: a token pasted into a
calendar would be a key to the whole API in someone else's settings.
