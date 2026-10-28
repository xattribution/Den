# Den

The family's calendar, chores, lists and points, on the family's own devices.

![Den on Android: today's events with person colors, a ride nobody has taken, and chores by person](docs/screens/android-today.png)

## Quick start

**Just phones.** Install Den on one parent's phone, tap "Start a family", add the kids, and
invite your partner from Family → Devices → Add a device (a QR code, or four words to read out).
Every phone keeps the whole family, encrypted, and phones sync with each other when they meet on
the same Wi-Fi. Nothing to host.

**With a hub (recommended).** An always-on device keeps the family online while phones sleep and
runs the extras: Home Assistant, AI access over MCP, calendar feeds, reminders.

- An old Android tablet or a computer: install Den and turn on Settings → This device →
  "Keep the family online". The hub runs inside the app; on Android it keeps running in the
  background, with the notification "Den is keeping the family online", until you turn it off.
- A NAS, mini PC or Raspberry Pi with Docker:

  ```bash
  docker run -d --name den-hub --restart unless-stopped --network host \
    -v den-hub:/data ghcr.io/xattribution/den-hub:latest
  ```

  The hub prints a setup code in its log (`docker logs den-hub`). On a parent's phone, go to
  Family → Devices → Add a device → A hub, pick it from the list or type its address, and enter
  the code. The phone then shows three words and checks that the hub reports the same three
  (they're in its log too); approve it if they match. Any browser can then open
  `http://<hub-address>:47733` and link itself by showing a QR code for a parent's phone to scan.
- A server, behind HTTPS, for a family whose phones should reach it from anywhere through the
  web app on their home screen (one hub per family; several families can share a server):
  [docs/hosting.md](docs/hosting.md).

**Add anything by sharing it.** Tap Add and type, snap or say it ("soccer every Wednesday at 5
for Leo"), or share a flyer photo, a screenshot, an email, a link or a PDF to Den from any app.
Den proposes the events, chores, list items and reminders it found; what needs no look is added
right away with Undo, or everything waits for you under Settings → AI and automations → "Show me
first". Den reads on the phone first (Apple Intelligence or Gemini Nano where the phone has it,
and its own reader everywhere), and nothing leaves the phone unless a parent connects a reader
there: a model at home (`docker compose -f deploy/compose.yaml --profile model up -d model`,
then `ollama pull llama3.2`) or Claude with their own API key, kept in that phone's keychain; or
once on the hub for every device (Settings → AI and automations → The family's hub), where the
key stays on the hub and each device asks with a request signed by its own key.

**Away from home.** Phones reach the hub through a relay that only ever carries encrypted data.
Run your own with `deploy/relay`, then enter its address under Settings → This device → Relay.

**Moving from Sett.** `den_hub import-sett coord.db --as <your name>` brings members, events with
their exceptions, chores with steps and check-offs, lists, goals and point adjustments into the
hub's family.

## What's here

| Path | What |
| --- | --- |
| `app/` | The Flutter app for iPhone, iPad, Android, Mac, Windows, Linux and the web |
| `packages/den_core/` | The engine: data model, signed change log, spaces, permissions, recurrence, chores, points, history |
| `packages/den_net/` | Encrypted sessions, sync, pairing, key rotation, relay client, encrypted backups |
| `packages/den_capture/` | Capture: readers (Den's own, a home model, Claude), resolution to the family, checks against den_core, writes with undo |
| `packages/den_hub/` | The hub library: HTTP API, MCP with OAuth, Home Assistant bridge, reminders, calendar feeds, mDNS |
| `packages/den_hub_cli/` | The `den_hub` command: serve, MCP over stdio, Sett import, backup and restore |
| `packages/den_relay/` | The relay: tunnel, mailbox and pairing rendezvous |
| `packages/den_sett_import/` | Reads Sett's `coord.db` |
| `integrations/homeassistant/` | The Home Assistant integration (calendars, to-do lists, sensors, services, events) |
| `deploy/` | Docker images for the hub and the relay; `deploy/hosted/` for a hub on a server behind HTTPS (Caddy, one or two families) |
| `DESIGN.md` | The design system every screen follows |
| `ARCHITECTURE.md` | The contract every package builds against |
| `docs/hub-api.md` | The hub's REST, stream and mDNS contract |
| `docs/hosting.md` | Hosting hubs on a server behind HTTPS, for the web app on phones |

## Status

| Part | Tests | Verified on this machine |
| --- | --- | --- |
| Engine (`den_core`) | 186 | Analyzer clean |
| Networking (`den_net`) | 80 | Two and three devices syncing in memory, over WebSocket and through the relay; two parents revoking while out of touch settle on one key, through a hub and through the relay alone; a rotated key from a device whose approval arrives in the same relay round is taken |
| Capture (`den_capture`) | 86 | A school flyer's text becomes six calendar events on the phone alone and through a recorded Claude response, including the text ML Kit really found in it on Android, wrapped lines and all; what a notice asks families to bring is kept; typed and spoken sentences, emails, recorded Gemini Nano and Ollama answers |
| Relay | 20 | Tunnel, mailbox, rendezvous, rate limits |
| Hub and its command line | 58 + 5 | Compiled binary serves the web app and prints its setup code; a teen's phone reads through the hub's Claude with signed requests over loopback |
| Sett importer | 8 | A Sett schema v12 fixture |
| App | 263, with 174 screenshots and the Home Assistant brand images | Release APK on an Android emulator: reminders, phone calendars, the hub kept online in the background and after Den is closed from recent apps; a typed sentence; a flyer photo shared from Files, read by ML Kit into six events and undone; an email's text and a PDF shared in; History saying where each came from. Web build in a browser |
| Home Assistant integration | 85 | Home Assistant 2026.2 test harness; 30 of 30 contract checks against a live hub; v0.1.0's `den.zip` downloads from den-homeassistant's release with its manifest and brand images |

Windows, macOS, iOS and Linux app builds and the Docker images run in CI (`.github/workflows`).

HACS installs only from the root of a repository, so the Home Assistant integration is published
from its own, [`xattribution/den-homeassistant`](https://github.com/xattribution/den-homeassistant):
`integrations/homeassistant/scripts/prepare_hacs_repo.py` writes its files and CI builds its
release zip (see the integration's README). Its first release, v0.1.0, carries `den.zip`. To
install, add that repository to HACS as a custom repository of type Integration.

Known gaps:

- Phones refresh reminders in the background about hourly, but desktops only while Den runs. iOS
  can't read the device's keys while the phone is locked, so its background refresh waits for an
  unlocked moment. Browsers get no reminders.
- Capture's native parts have run only on an Android emulator, where Gemini Nano reports itself
  unavailable (the image has no AICore), so reading with the phone's own model is untested on a
  phone that has it. Apple Intelligence, Vision and the iOS share extension are written but not
  yet built (CI builds iOS and macOS on release tags), and signing the iOS app needs the App Group
  `group.family.den.denApp` on the developer account.

## Develop

Requirements: Flutter 3.38 (includes Dart 3.10).

```bash
cd packages/den_core && dart test
cd app && flutter run -d chrome --dart-define=DEN_DEMO=true
```

`DEN_DEMO=true` starts with a demo family so every screen has something on it. Screenshot tests
render each screen to `app/test/goldens`; review the images after any UI change:

```bash
cd app && flutter test --update-goldens
```

The hub from source:

```bash
cd packages/den_hub_cli && dart run bin/den_hub.dart serve --web ../../app/build/web
```

## License

AGPL-3.0 for the app, hub and relay; MIT for `den_core`.
