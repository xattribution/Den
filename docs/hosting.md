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

Then, on a parent's iPhone, open `https://den.example.com` in Safari, choose **Start a family**,
and add the hub with the setup code from the log (**Family and devices**, **Add a device**, the
hub). The hub's log also prints three matching words while it joins; approve it on the phone only
if the phone shows the same three.

### The public posture

A hub whose `DEN_PUBLIC_URL` is `https` (or with `DEN_PUBLIC=1`) assumes strangers can reach it:

- `/health` answers only `{"ok": true, "api": 1, "ready": true}`, and `/api/v1/hub/status` of a
  hub already in a family says only that it is paired. The setup endpoints work only until the hub
  is in a family, and each address gets five wrong setup codes before it has to wait.
- A new browser can ask for a link code only while a parent has **Add a device** open in the app
  (which tells the hub), or for a few minutes after you run, on the server:
  `docker compose -f deploy/hosted/compose.yaml exec hub /app/bin/den_hub open-linking`.
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

## For the family

Send this, with your family's address in it:

1. Open **https://den.example.com** in Safari on your iPhone.
2. Tap the **Share** button, then **Add to Home Screen**, then **Add**.
3. Open **Den** from your home screen and follow what it says on the screen.
