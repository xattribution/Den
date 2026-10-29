# Den

The family's calendar, chores, lists and points, on the family's own devices.

![Den's Today on an iPad and a phone: what needs you (a ride nobody is driving, a reward to approve, a late chore), today's events, and chores by person](docs/screens/today-ipad-and-phone.png)

Every phone keeps the whole family, encrypted, and works without a connection. A **hub**, one
small always-on server you run, keeps everyone in sync while phones sleep, serves Den as a web
app the family adds to their iPhone Home Screens, and runs the extras: reminders, calendar feeds,
Home Assistant, and AI assistants over MCP. The family's data lives on its own devices and its
own hub.

## Run it for your family

The recommended way is a private server: a VPS that only the family reaches, from their homes or
through Tailscale, at one address, with nothing else on the internet getting an answer. It needs a
domain on Cloudflare, a DDNS name for each home and a Tailscale account
([docs/hosting.md](docs/hosting.md#private-home-networks-plus-tailscale) has every step, and
updates, backups and moving servers):

```sh
git clone https://github.com/xattribution/den.git && cd den/deploy/private
sudo ./install.sh        # asks for the domain, a Cloudflare token and the homes' DDNS names
docker compose exec hub /app/bin/den_hub setup-code
```

Then open `https://den.example.com` in Safari on a parent's iPhone, at home or with Tailscale on,
add it to the Home Screen, tap **Start a family** and type the setup code.

Other ways to run it:

- **A public server**, with Docker and a domain pointing at it: `deploy/hosted/`
  ([setup A](docs/hosting.md#install-setup-a)). The family opens it from anywhere with no app,
  and so can anyone else try to.
- **A computer at home**, on the home network: `deploy/compose.yaml`
  ([setup D](docs/hosting.md#setup-d-a-computer-at-home)).
- **An old Android tablet or a computer with the Den app**: Settings, Advanced, Hub and sync,
  "Keep the family online". The hub runs inside the app.
- **Just phones**, with no hub: one parent starts a family and invites the others; phones sync
  with each other when they meet on the same Wi-Fi.

**Add anything by sharing it.** Tap Add and type, snap or say it ("soccer every Wednesday at 5
for Leo"), or share a flyer photo, an email, a link or a PDF to Den. Den reads on the phone first,
and nothing leaves it unless a parent connects a reader: a model on the hub, or Claude with their
own API key.

**Ask.** The optional AI helper, off until a parent turns it on (Settings, AI helper), answers
questions and makes changes from Add, with Undo. Its key stays on the hub.

**Moving from Sett.** The hub brings in a Sett family with `den_hub import-sett`
([docs/hosting.md](docs/hosting.md#bring-in-a-family-from-sett)).

## What's here

| Path | What |
| --- | --- |
| `app/` | The Flutter app for iPhone, iPad, Android, Mac, Windows, Linux and the web |
| `packages/den_core/` | The engine: data model, signed change log, spaces, permissions, recurrence, chores, points, history |
| `packages/den_net/` | Encrypted sessions, sync, pairing, key rotation, relay client, encrypted backups |
| `packages/den_capture/` | Capture: readers, resolution to the family, checks against den_core, writes with undo |
| `packages/den_hub/` | The hub library: HTTP API, MCP with OAuth, Home Assistant bridge, reminders, calendar feeds, mDNS |
| `packages/den_hub_cli/` | The `den_hub` command: serve, setup code, status, backup and restore, MCP over stdio, Sett import |
| `packages/den_relay/` | The relay: tunnel, mailbox and pairing rendezvous |
| `packages/den_sett_import/` | Reads Sett's `coord.db` |
| `integrations/homeassistant/` | The Home Assistant integration, published from [`xattribution/den-homeassistant`](https://github.com/xattribution/den-homeassistant) for HACS |
| `deploy/` | Docker images and compose files: `private/` for a server only the family reaches (with its firewall and install script), `hosted/` for a public server, `compose.yaml` for a computer at home, `relay/` |
| `docs/hosting.md` | Self-hosting: the private setup and the others, commands, updates, backups, moving, maintenance |
| `docs/hub-api.md` | The hub's REST, stream and mDNS contract |
| `ARCHITECTURE.md` | The contract every package builds against |
| `DESIGN.md` | The design system every screen follows |

## Develop

Requirements: Flutter 3.38 (includes Dart 3.10).

```bash
cd packages/den_core && dart test
cd app && flutter run -d chrome --dart-define=DEN_DEMO=true
```

`DEN_DEMO=true` starts with a demo family so every screen has something on it. Screenshot tests
render each screen (and the design gallery in `app/test/design`); review the images after any UI
change. The committed images are rendered on CI: label the pull request `screenshots` and the
screenshots workflow pushes them to the branch `screenshots/<branch>`, then bring them in:

```bash
git fetch origin screenshots/<branch>:refs/remotes/origin/screenshots/<branch>
git checkout origin/screenshots/<branch> -- app/test
```

Tests never compare pixels, so rendering locally (`cd app && flutter test --update-goldens`) is
for a quick look only. See DESIGN.md, "Screenshots".

The hub from source:

```bash
cd packages/den_hub_cli && dart run bin/den_hub.dart serve --web ../../app/build/web
```

## License

AGPL-3.0 for the app, hub and relay; MIT for `den_core`.
