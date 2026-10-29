# Hosting a hub on a server

For running Den for a family whose phones should reach it from anywhere: one hub per family, in
a container on a server you run, behind HTTPS. The hub serves the web app itself, so the family
opens one address in Safari, adds it to the home screen, and from then on it behaves like an
app. Nothing else (no App Store build, no relay, no account) is needed.

For a hub on a computer at home, on the home network only, `deploy/compose.yaml` (or the
`docker run` below) is all there is.

## What you need

- A server with Docker and Docker Compose, reachable from the internet on ports 80 and 443 (or
  one of the tunnels under [Other ways in](#other-ways-in), which need no open ports).
- A domain name per family whose DNS points at the server (`den.example.com`, an `A` record, and
  `AAAA` if the server has IPv6).
- This repository on the server (the compose files build the hub image from it; that takes a
  while the first time, since it also builds the web app).

## One family, with Caddy for HTTPS

```sh
cp deploy/hosted/env.example deploy/hosted/.env     # set DEN_DOMAIN=den.example.com
docker compose -f deploy/hosted/compose.yaml --profile caddy up -d
docker compose -f deploy/hosted/compose.yaml logs hub | grep "Setup code"
```

[`deploy/hosted/compose.yaml`](../deploy/hosted/compose.yaml) runs two containers on a private
Docker network (`172.30.73.0/24`):

- **hub**: the Den hub with its data in the `den-hub` volume. It publishes nothing to the
  internet; it listens on the Docker network and on the server's `127.0.0.1:47733` only.
  `DEN_PUBLIC_URL=https://<your domain>` (OAuth and link codes use it, and since it is `https`
  the hub runs in the public posture), `DEN_TRUSTED_PROXIES=172.30.73.0/24` (the hub believes
  `X-Forwarded-*` only from that network), `DEN_MDNS=0`.
- **caddy** (profile `caddy`): answers on 80 and 443, gets and renews the certificate itself, and
  proxies to the hub ([`deploy/hosted/Caddyfile`](../deploy/hosted/Caddyfile)). WebSockets and the
  event stream pass straight through.

Then, on a parent's iPhone, open `https://den.example.com` in Safari, add Den to the Home Screen
(Share, **Add to Home Screen**; Safari shows the steps) and open it from there. Choose **Start a
family** and type the setup code from the log under **Your hub** in the same form: the iPhone
takes the hub in once both show the same three matching words (they're in the hub's log too).
Invite the others by message from **Add people** (**Send invite**): a link and four words; they
open the link, add Den to their Home Screen the same way, and a parent taps **Approve** on Today.

### The public posture

A hub whose `DEN_PUBLIC_URL` is `https` (or with `DEN_PUBLIC=1`) assumes strangers can reach it:

- `/health` answers only `{"ok": true, "api": 1, "ready": true}`, and `/api/v1/hub/status` of a
  hub already in a family says only that it is paired. The setup endpoints work only until the hub
  is in a family, and each address gets five wrong setup codes before it has to wait.
- A new browser can ask for a link code only while a parent has **A browser on a computer** open in the app (Settings → Advanced → Hub and sync)
  (which tells the hub), or for a few minutes after you run, on the server:
  `docker compose -f deploy/hosted/compose.yaml exec hub /app/bin/den_hub open-linking`.
  Invites by message need neither: the invite is a parent's consent already.
- Everything a stranger can reach is limited per address (docs/hub-api.md, "Limits per client"),
  OAuth sign-in requests from AI assistants stay in the hub until a parent lets them in, and every
  answer carries security headers: HSTS, a Content-Security-Policy for the web app that loads
  nothing from a CDN, no framing, no referrer.
- mDNS is off.

### Updating

```sh
git pull
docker compose -f deploy/hosted/compose.yaml --profile caddy up -d --build
```

The web app's `index.html` and service worker are sent `no-cache`, so phones pick up the new
version the next time Den opens.

### Backups

The backup is sealed with a passphrase (Argon2id, XChaCha20-Poly1305) and works while the hub
runs:

```sh
export DEN_BACKUP_PASSPHRASE='a long passphrase you keep elsewhere'
docker compose -f deploy/hosted/compose.yaml exec -e DEN_BACKUP_PASSPHRASE hub \
  /app/bin/den_hub backup --out /data/den.denbackup --passphrase-env DEN_BACKUP_PASSPHRASE
docker compose -f deploy/hosted/compose.yaml cp hub:/data/den.denbackup ./den-$(date +%F).denbackup
```

It holds the hub's keys, the family's change log, the hub's own state (OAuth clients, the capture
reader's key, feeds) and `notify.json`. To restore, stop the hub and run the restore in a one-off
container on the same volume:

```sh
docker compose -f deploy/hosted/compose.yaml stop hub
docker compose -f deploy/hosted/compose.yaml run --rm -e DEN_BACKUP_PASSPHRASE \
  -v "$PWD/den-2026-10-28.denbackup:/restore.denbackup:ro" hub \
  restore --in /restore.denbackup --passphrase-env DEN_BACKUP_PASSPHRASE --force
docker compose -f deploy/hosted/compose.yaml start hub
```

Then let the family open Den on their phones before anyone changes anything through scripts or
assistants: whatever the hub wrote after the backup is still on those phones, and the hub takes it
back from them as they sync.

## Two families on one server

[`deploy/hosted/two-families.yaml`](../deploy/hosted/two-families.yaml) runs one hub container
per family, each with its own data volume (`den-family-a`, `den-family-b`), its own `DEN_PORT`
(47733, 47735) and its own domain, and one Caddy that routes by hostname
([`Caddyfile.two-families`](../deploy/hosted/Caddyfile.two-families)):

```sh
cp deploy/hosted/env.two-families.example deploy/hosted/.env   # FAMILY_A_DOMAIN, FAMILY_B_DOMAIN
docker compose -f deploy/hosted/two-families.yaml up -d
docker compose -f deploy/hosted/two-families.yaml logs hub-a | grep "Setup code"
docker compose -f deploy/hosted/two-families.yaml logs hub-b | grep "Setup code"
```

The hubs share nothing but the server: different keys, logs and state, and a request for one
family's domain never reaches the other's hub. Each family starts its own family on its own
address and adds its own hub with its own setup code; you never need to be in either family. A
third family is another service like `hub-b` with the next port and volume, and another block in
the Caddyfile.

## Other ways in

Without the `caddy` profile the hub listens on the server's `127.0.0.1:47733` only. Requests that
come in there arrive from the Docker network's gateway, which `DEN_TRUSTED_PROXIES` already
trusts.

- **Cloudflare Tunnel**: no open ports, and Cloudflare holds the certificate. Create a tunnel in
  the Cloudflare dashboard with a public hostname `den.example.com` whose service is
  `http://hub:47733`, and run `cloudflared` as one more container on the `den` network (or on the
  server, pointed at `http://127.0.0.1:47733`). Cloudflare sends `X-Forwarded-For` and
  `X-Forwarded-Proto`; WebSockets work. Cloudflare sees the traffic in the clear at its edge
  (Den's sync is still end-to-end encrypted inside `/ws`).
- **Tailscale Funnel**: `tailscale funnel --bg 47733` on the server publishes
  `https://<machine>.<tailnet>.ts.net` to the internet with a certificate Tailscale manages; set
  `DEN_DOMAIN` to that name. **Tailscale Serve** (`tailscale serve --bg 47733`) is the same but
  only for devices on your tailnet, which then need the Tailscale app on every phone: private,
  but more to set up for a family.
- **Your own nginx or Traefik**: proxy to `127.0.0.1:47733` with `X-Forwarded-For`,
  `X-Forwarded-Proto` and `X-Forwarded-Host` set, WebSocket upgrades on `/ws`, and buffering off
  for `/api/v1/stream`. If the proxy runs in another container, add its network to
  `DEN_TRUSTED_PROXIES`.

The hub logs a warning when a proxy sends `X-Forwarded-For` from an address it doesn't trust;
until you list the proxy, every family member counts as one client against the limits.

## Connecting AI assistants

Claude, ChatGPT, Gemini, Grok and Alexa+ reach Den from their own servers over MCP with OAuth.
Only a few paths have to be on the public internet for that; the rest can stay behind a private
proxy (Tailscale Serve, a VPN, the home network), where the family's phones and the web app
already reach them.

| Path | Who calls it | Public? |
| --- | --- | --- |
| `POST /mcp` (and `OPTIONS /mcp`) | The assistant's servers, for every tool call | Yes |
| `GET /.well-known/oauth-protected-resource`, `GET /.well-known/oauth-protected-resource/mcp` | The assistant's servers, to find the sign-in (Alexa+ when you deploy) | Yes |
| `GET /.well-known/oauth-authorization-server` | The assistant's servers | Yes |
| `POST /oauth/token` | The assistant's servers: the first token and every refresh | Yes |
| `POST /oauth/register` | The assistant's servers, for assistants that register themselves (Gemini; Claude and ChatGPT when they don't use a client document) | Yes, unless every assistant you use has a client document or a client you set up |
| `GET /oauth/authorize`, `GET /oauth/authorize/status` | The browser of the person connecting (the waiting page polls the second) | Only where that browser is: on the phone or computer connecting, which may be anywhere |
| `/api/v1/*`, `/ws`, the web app | The family's devices, Siri Shortcuts, Home Assistant | No: keep them behind the private proxy if you can |
| `/ics/*` | Calendar apps subscribed to Den's feeds | Only if a calendar service fetches them from its own servers (Google Calendar does; Apple Calendar fetches from the device) |

With Caddy (above) everything is public, which works; the public posture's limits and the parent
approval of every sign-in apply either way. To expose only the assistants' paths, route those
paths to the hub on the public hostname and leave everything else to the private one.

The hub also fetches out: the client documents Claude and ChatGPT identify themselves with (from
`claude.ai` and `chatgpt.com`), and calendar feeds. Those fetches refuse addresses on the hub's
own machine and network; `DEN_FETCH_ALLOW` admits a calendar server at home.

Whichever assistant, the person connecting sees Den's sign-in page with a code, and a parent
approves the request in the Den app (Settings → Advanced → AI and automations, which also has these steps), choosing what it may do and
whose permissions it uses. The add-a-connector address is `https://den.example.com/mcp`.

- **Claude** (claude.ai, Desktop, mobile, Claude Code): add Den as a custom connector with that
  address. Claude identifies itself with a client document when the hub says it reads them
  (it does) and otherwise registers; the hosted apps return to
  `https://claude.ai/api/mcp/auth_callback`, Claude Code to a `localhost` port of its own, which
  the hub matches on any port (the sign-in page then says a program on this computer is asking).
  Claude's servers call from `160.79.104.0/21` and give each OAuth request 10 seconds. Claude
  needs the `401` and its `resource_metadata`, which Den sends.
  ([Anthropic: authentication for connectors](https://claude.com/docs/connectors/building/authentication.md))
- **ChatGPT** (developer mode, for Plus, Pro, Business, Enterprise and Edu): add Den as an app
  with OAuth. ChatGPT uses a client document (`https://chatgpt.com/oauth/.../client.json`) or
  registers, sends `resource` as the hub's address, and returns to
  `https://chatgpt.com/connector_platform_oauth_redirect` because Den sends `iss`. It asks before
  every write. ([OpenAI: developer mode](https://developers.openai.com/api/docs/guides/developer-mode),
  [Apps SDK: authentication](https://developers.openai.com/apps-sdk/build/auth))
- **Gemini** (18 or over, in the US, a personal Google Account, English): gemini.google.com →
  Settings → Connected Apps → Add a custom app. Gemini registers (or takes credentials by hand
  under "Advanced"), works on the web and mobile once added, and confirms every write.
  ([Google: custom apps for Gemini](https://support.google.com/gemini/answer/17209137))
- **Grok**: grok.com/connectors → New Connector → Custom, then sign in. Grok refuses servers on
  a private address, so the hub must be public. xAI's page doesn't say how Grok signs in; test it
  with your hub. ([xAI: Grok connectors](https://docs.x.ai/grok/connectors))
- **Alexa+** (the MCP toolkit, in preview): Alexa doesn't register clients, so a parent sets one
  up in the Den app (or `POST /api/v1/connections/clients` from their phone, with the redirect
  addresses the Alexa+ Developer Hub lists) and enters the client id and secret Den shows once in
  `alexa-ai configure-account-linking`. Alexa reads the rest from the metadata, needs PKCE and a
  refresh token with every access token (Den sends both), refreshes without `resource`, and wants
  a public privacy policy for the add-on. Re-deploy the add-on after changing the hub's address.
  ([Amazon: account linking for Alexa+ MCP add-ons](https://developer.amazon.com/docs/alexaplus/add-ons/mcp-toolkit-account-linking.html))

Removing an app in the Den app ends its tokens at once; removing a client a parent set up also
ends the connections it made.

## The simple case: one hub at home

```sh
docker build -f deploy/hub/Dockerfile -t den-hub .     # or use a released ghcr.io/xattribution/den-hub tag
docker run -d --name den-hub --restart unless-stopped --network host -v den-hub:/data den-hub
docker logs den-hub | grep "Setup code"
```

Host networking lets phones find the hub on the home network (mDNS). Nothing about the public
posture applies; set `DEN_PUBLIC_URL` and `DEN_TRUSTED_PROXIES` only if you later put a proxy in
front of it.

## Settings that matter for hosting

| Variable | What |
| --- | --- |
| `DEN_PUBLIC_URL` | `https://den.example.com`: OAuth metadata and link codes use it; an `https` URL turns on the public posture |
| `DEN_TRUSTED_PROXIES` | Addresses or CIDR networks whose `X-Forwarded-*` headers count |
| `DEN_PUBLIC` | `1` or `0` to force the public posture on or off |
| `DEN_MDNS` | `0` when hosted (the default in the public posture) |
| `DEN_PORT` | The port inside the container (one per family when several share a server) |
| `DEN_CSP` | Replaces the web app's Content-Security-Policy, for a web build that needs a CDN after all |
| `DEN_ALLOWED_ORIGINS` | Extra browser origins for `/mcp` and OAuth (`https://claude.ai` is allowed already) |
| `DEN_FETCH_ALLOW` | Private networks (addresses or CIDRs) the hub may fetch calendar feeds from; by default it fetches only from the public internet |

## For the family

Send this, with your family's address in it:

1. Open **https://den.example.com** in Safari on your iPhone.
2. Tap the **Share** button, then **Add to Home Screen**, then **Add**.
3. Open **Den** from your home screen and follow what it says on the screen.

## If a parent loses their phone

If another parent still has their phone, they let the new one in from Needs you, as usual.
When no parent's phone is left, there are two ways back in.

**Their recovery words.** Every parent saves 12 words when they start the family, or later on
their own page in Family ("Recovery words"). On the new phone, open the family's address in
Safari, add Den to the Home Screen and open it, choose **Join your family**, then **I lost my
phone**, and paste the words. Den shows whose they are; "Yes, let this phone in" and the phone is
theirs. The hub only carries the request: it can't make up words, and needs no setting for this.

**The hub's help, only if the family turned it on.** A parent can turn on Settings, Family, **Let
the hub help us get back in**. Then whoever runs the server can let a parent's new phone in:

```sh
docker compose exec hub /app/bin/den_hub recover --person "Alex"
```

(With the compose file above: `docker compose -f deploy/hosted/compose.yaml exec hub
/app/bin/den_hub recover --person "Alex"`. Without Docker: `den_hub recover --person "Alex"
--data <data directory>`.) The name is the parent's name in Den. It prints a link and four words
that let in one phone, once, for 30 minutes; send them to the parent, who opens the link on the
new phone (or chooses **I lost my phone** and types the four words). If the family hasn't turned
server help on, the command says so and lets nobody in.

What this means for whoever runs the server: with server help on, they could add a phone as any
parent; every device in the family shows when that happens ("Alex's new iPhone was let in by the
hub's recovery"), and any parent can remove it. With it off, they can't: turning it off makes the
hub's key useless, even for a request dated earlier. The key lives in the hub's data directory
(`hub/recovery.json`) and is in its backups. Either way, the parent's new phone then offers
**Remove your old phone** on their page.
