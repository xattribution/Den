# Den

The family's calendar, chores, lists and points, on the family's own devices.

## Quick start

**Just phones.** Install Den on one parent's phone, tap "Start a family", add the kids, and invite
your partner with a QR code. Every phone keeps the whole family, encrypted, and the phones sync
with each other. Nothing to host.

**With a hub (recommended).** Any always-on device keeps the family online and runs the extras
(Home Assistant, AI access, calendar feeds, reminders while phones sleep):

- an old Android tablet: install Den, open Settings, and turn on "Keep the family online";
- a computer: the desktop app has the same switch;
- a NAS, mini PC or Raspberry Pi with Docker:

  ```bash
  docker run -d --name den-hub --restart unless-stopped \
    -p 47733:47733 -v den-hub:/data ghcr.io/xattribution/den-hub:latest
  ```

  Then open Den on your phone, go to Family → Devices → Add a device, and scan the code the hub
  shows at `http://<hub-address>:47733`.

**Away from home.** Phones reach the hub through a relay that only ever sees encrypted data. Use
the hosted relay, or run your own with `deploy/relay`.

## What's here

| Path | What |
| --- | --- |
| `app/` | The Flutter app for iPhone, iPad, Android, Mac, Windows, Linux and the web |
| `packages/den_core/` | The engine: data model, signed change log, permissions, recurrence, chores, points, history |
| `packages/den_net/` | Encrypted sessions, sync, pairing, relay client, encrypted backups |
| `packages/den_hub/` | The hub: HTTP API, MCP server, Home Assistant bridge, reminders, calendar feeds |
| `packages/den_relay/` | The relay: tunnel, mailbox and pairing rendezvous |
| `integrations/homeassistant/` | The Home Assistant integration (HACS) |
| `deploy/` | Docker images for the hub and the relay |
| `DESIGN.md` | The design system every screen follows |
| `ARCHITECTURE.md` | The contract every package builds against |

## Develop

Requirements: Flutter 3.38 (includes Dart 3.10).

```bash
cd packages/den_core && dart test
cd app && flutter run -d chrome --dart-define=DEN_DEMO=true
```

`DEN_DEMO=true` starts with a demo family so every screen has something on it. Screenshot tests
render each screen to `app/test/goldens`:

```bash
cd app && flutter test --update-goldens
```

## License

AGPL-3.0 for the app, hub and relay; MIT for `den_core`.
