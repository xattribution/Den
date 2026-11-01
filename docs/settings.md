# Where Den's settings live

The rule: **nobody edits a file to turn something on or to fix something.** Features are set up
in the Den app, on a parent's phone, and take effect at once. What is left in `.env` and the
compose files is plumbing that `install.sh` (or the compose file itself) writes once and nobody
touches, plus a short list of things that can't be set from a phone yet, each with its reason.

Each setting below is in one of three classes:

- **(a) plumbing**: written by `install.sh`, `families.sh` or the compose file; nobody touches it.
- **(b) moved**: someone used to have to edit it for a feature; now it is in the app, a default,
  or found by itself. An old `.env` line still there is ignored, and the hub's log names it once
  at start (never its value).
- **(c) dead**: deleted.

The one-command install (`deploy/install.sh`, [install-technical.md](install-technical.md)) has
no `.env` at all. Its compose file is generated on each run, from constants in the script and
what it finds on the computer. What the family can change (the tunnel token, "Update now",
manual updates) lives in files in the hub's data directory, which the hub writes. The tables
below are for the older setups.

A setting that stays a file setting although someone might change it says why.

## The hub (`den_hub serve`)

| Setting | Class | Where it is now, or why it stays |
| --- | --- | --- |
| `DEN_GOOGLE_CLIENT_ID`, `DEN_GOOGLE_CLIENT_SECRET` | (b) | In the app: Settings, Advanced, **Sign in with Google or Apple**, on a parent's own phone in the server's own family. Kept in `hub/sign-in.json` (owner-only, in backups), never shown again. Nobody had set them, so an old value is not imported: it is ignored and named in the log |
| `DEN_APPLE_SERVICES_ID`, `DEN_APPLE_TEAM_ID`, `DEN_APPLE_KEY_ID`, `DEN_APPLE_KEY_FILE` | (b) | The same screen: the three ids, and the `.p8` picked as a file or pasted. No key file to mount |
| `DEN_HOST_PUSH` | (b) | A default: every family on a Den host also hands out the host's push key, so someone in two families on one server gets both families' reminders in one Home Screen app ([hosting.md](hosting.md#one-app-several-families) says why that is safe). A browser holding one family keeps that family's own key |
| `DEN_HA_URL`, `DEN_HA_TOKEN` | (c) | The hub's own Home Assistant notifier is gone. Home Assistant is set up in the app (Settings, Advanced, **Home Assistant**): its Den integration asks the hub with a token the app makes, and fires `den_event_starting` at each reminder, which an automation sends to phones ([the integration's README](../integrations/homeassistant/README.md), "Send Den reminders to phones"). No compose file passed these through |
| `DEN_NOTIFY`, `notify.json` | (c) | Per-person Home Assistant services and ntfy topics, a hand-edited file. Phones and computers plan their own reminders; browsers get them by Web Push; Home Assistant as above. Backups still carry an old `notify.json`, so an old backup restores whole, but nothing reads it |
| `DEN_DATA`, `DEN_WEB`, `DEN_PORT`, `DEN_HOST` | (a) | Set by the image and the compose files |
| `DEN_PUBLIC_URL` | (a) | `https://` and `DEN_DOMAIN`, from the compose file. The domain itself is asked once by `install.sh` |
| `DEN_PUBLIC`, `DEN_MDNS`, `DEN_TRUSTED_PROXIES` | (a) | Fixed by each compose file for its setup (the public posture, no mDNS on a server, the setup's own proxy) |
| `DEN_PEER_HUBS` | (a) | Written by `families.sh` (`install.sh add-family --container`) while any family has a hub container of its own; families on the one Den host need none |
| `DEN_NAME` | (a) | The hub's name only until it joins a family; after that, its device record's, renamed in the app |
| `DEN_LOG` | (a) | How much the hub writes to its log: for looking into a problem at the server, not a feature |
| `DEN_HOST_RETRY` | (a) | Seconds between tries at a family that didn't open (30): a tuning knob nobody needs |
| `DEN_FETCH_ALLOW` | stays | Lets the hub fetch calendars from private networks. It opens a hole in the guard that keeps a calendar link (anyone in any family on the server can add one) from reaching the server's own machine and network, so it is the server operator's to open, at the server. On the private and hosted setups the hub is on a server where no home calendar is reachable anyway; it matters only for a hub at home (setup D). Moving it into the app needs a "this calendar is on your home network: let the hub read it?" step for the server's own family, a follow-up |
| `DEN_ALLOWED_ORIGINS` | stays | Extra browser origins for `/mcp` and OAuth. The ones Den works with (`claude.ai`, `claude.com`) are built in; this is for someone wiring up a web client Den doesn't know, a developer's escape hatch |
| `DEN_CSP` | stays | Replaces the web app's Content-Security-Policy, for a web build someone changed to load from a CDN: a developer's escape hatch, never needed for a feature |
| `DEN_RELAY`, `DEN_MAILBOX` | stays | A relay tunnel to reach a hub at home from anywhere (setup D). No setup in `deploy/` runs one; reaching the hub from anywhere is what the Cloudflare Tunnel phase brings, which replaces it |
| `DEN_TOKEN` | (a) | `den_hub mcp --token`: a token the app made, for a local MCP client's command line |
| `DEN_BACKUP_PASSPHRASE` | (a) | Made by `install.sh`; the backup service reads it |

## The private setup (`deploy/private/.env`, `install.sh`)

| Setting | Class | Where it is now, or why it stays |
| --- | --- | --- |
| `DEN_DOMAIN`, `CLOUDFLARE_API_TOKEN` | (a) for now | Asked once by `install.sh`. The Cloudflare Tunnel phase replaces both |
| `DEN_HOMES`, `DEN_HOME_V6_PREFIX`, `DEN_ALLOW_EXTRA` | stays, for now | The server's firewall (den-allowlist, outside the hub), asked once by `install.sh`. A hub can't open its own server's firewall from a phone, by design. The Cloudflare Tunnel phase removes the allowlist |
| `DEN_SSH_FROM_HOMES`, `DEN_SSH_ALLOW` | stays | SSH to the server: the operator's, at a terminal by definition. `install.sh` writes `DEN_SSH_ALLOW` itself |
| `DEN_BACKUP_KEEP` | stays | How many backups to keep (14), a default nobody needs to change |
| `DEN_IMAGE` | stays | Running a published release instead of building: an operator's choice about the server, not a family feature |
| `DEN_PORT` | (a) | The hub's port on the server (47733) |
| `DEN_FAMILY_<NAME>`, `COMPOSE_FILE`, `DEN_HOSTED_FAMILIES` | (a) | Written by `install.sh add-family`, `remove-family` and `merge-families` |
| `DEN_COMMIT` | (a) | Computed by `install.sh` from the checkout, for Settings, About |
| `DEN_ANY_OS` | stays | `install.sh` on an operating system it wasn't written for: a one-off override at the command line |
| `DEN_HOST_PUSH` | (b) | See above; no longer in `env.example` or `compose.yaml` |

## The hosted setup (`deploy/hosted/.env`)

| Setting | Class | Where it is now, or why it stays |
| --- | --- | --- |
| `DEN_DOMAIN` | (a) for now | The family's address, set once |
| `COMPOSE_PROFILES`, `TUNNEL_TOKEN` | stays, for now | Which front door runs (Caddy or a Cloudflare Tunnel) and the tunnel's token: chosen once when the server is set up. The Cloudflare Tunnel phase makes this the default |
| `DEN_BACKUP_PASSPHRASE`, `DEN_BACKUP_KEEP`, `DEN_IMAGE`, `DEN_PORT`, `DEN_NAME` | as above | |
| `FAMILY_A_*`, `FAMILY_B_*` (two-families example) | (a) | The two families' addresses, set once |

## What the in-app settings accept, knowingly

- **The host's push key is shared by the families on the host.** A browser subscription made
  with it can be pushed to by any family on the host that knows the subscription. A family only
  learns one when its own approved device registers it in a signed request, and no answer ever
  shows one, so this matters only if a subscription leaks (someone with that browser, or with the
  server's disk). Then another family on the same host could send that browser its own
  reminders, nothing more: no data reaches it, and each push names the family it is from. That
  is accepted, so that someone in two families on one server gets both families' reminders in
  one Home Screen app.
- **The sign-in setup screen shows every family's address on the host** to the parents of the
  host's own family: Google and Apple need each one registered as a way back. Whoever runs the
  server knows them already (`install.sh families`). Other families' parents see none of it.
- **Secrets travel only over HTTPS.** The hub takes the sign-in settings only over HTTPS (at a
  trusted proxy that says so) or from its own machine, and the app sends them only to the hub's
  https addresses it was given, never to one that answered on the home network.

## Existing installs

`git pull && sudo ./install.sh` needs no edits. An old `.env` line for any (b) or (c) setting
above is ignored, and the hub's log says once at start which ones and what took their place, so
they can be taken out whenever it suits. Nothing is imported from them: the sign-in settings had
never been set anywhere, `DEN_HOST_PUSH`'s best value is now the default, and the Home Assistant
and ntfy notifiers no longer exist.
