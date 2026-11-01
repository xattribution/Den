# Den: the technical side

For people who build Den or want to know how it works. Setting Den up for a family is in the
[README](../README.md); how the installer, the tunnel, updates and releases work is in
[install-technical.md](install-technical.md); the older ways to run a server are in
[hosting.md](hosting.md).

## What's here

| Path | What |
| --- | --- |
| `app/` | The Flutter app for iPhone, iPad, Android, Mac, Windows, Linux and the web |
| `packages/den_core/` | The engine: data model, signed change log, spaces, permissions, recurrence, chores, points, history |
| `packages/den_net/` | Encrypted sessions, sync, pairing, key rotation, relay client, encrypted backups |
| `packages/den_capture/` | Capture: readers, resolution to the family, checks against den_core, writes with undo |
| `packages/den_hub/` | The hub library: HTTP API, MCP with OAuth, Home Assistant bridge, reminders, calendar feeds, mDNS |
| `packages/den_hub_cli/` | The `den_hub` command: serve, setup code and link, status, backup and restore, MCP over stdio, Sett import |
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
change:

```bash
cd app && flutter test --update-goldens     # then look at app/test/**/goldens/*.png and commit
```

Before a pull request, run the same checks CI runs, on your own machine:

```bash
bash tool/local_ci.sh            # whatever your branch changed; or name targets: den_core app web images
```

CI on GitHub runs only on release tags, on a pull request labeled `run-ci`, or by hand from the
Actions tab, because Actions minutes cost money on a private repository. See DESIGN.md,
"Screenshots".

The hub from source:

```bash
cd packages/den_hub_cli && dart run bin/den_hub.dart serve --web ../../app/build/web
```

