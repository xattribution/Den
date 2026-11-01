# The one-command install, for whoever runs releases

This page is for Jared, not for James. James's whole manual is one line:

```sh
curl -fsSL https://get.kotvas.app | sudo sh -s -- --token eyJhIjoi...
```

That line works on any 64-bit Linux computer (an old PC, a mini PC, a Raspberry Pi 4 or 5 with
the 64-bit Raspberry Pi OS, a VPS), and nobody edits a file at any point. Leave out `--token`
and the token gets pasted later: on the first setup page in the browser, at the terminal
prompt (on a server on the internet), or with `sudo den tunnel`. The script is
[`deploy/install.sh`](../deploy/install.sh). Once installed, it is also the server's `den`
command. The older setups in [hosting.md](hosting.md) (private, hosted, at home) still work,
and are now the advanced paths.

- [What James sees](#what-james-sees)
- [On the server](#on-the-server)
- [Who can reach it](#who-can-reach-it)
- [The tunnel](#the-tunnel)
- [Updates and the way back](#updates-and-the-way-back)
- [What the hub reads and writes](#what-the-hub-reads-and-writes) (the contract with den_hub)
- [Releasing](#releasing)
- [Where the script is served from](#where-the-script-is-served-from)
- [Moving the VPS to the new installer](#moving-the-vps-to-the-new-installer)
- [Tests](#tests) and [Checked on a real machine](#checked-on-a-real-machine)

## What James sees

On a computer at home (here Docker was already installed; on a fresh one, `[1/5]` adds the line
`installing Docker (a few minutes)` first):

```text
Den installer

This computer: Ubuntu 24.04.3 LTS, 64-bit Intel/AMD, 7.6 GB memory, 200 GB free
Network: 192.168.1.50 (home network)

[1/5] Docker
      ready: Docker 28.5.1

[2/5] Den's files
      in /opt/den (the family's data: /opt/den/data)

[3/5] Den itself
      downloading (about 200 MB)

[4/5] Starting Den
      running: Den v1.0.0

[5/5] Nightly updates
      on: around 3:30 every night; if an update doesn't start, Den goes back by itself

Den is running.

Next: make your family. Open this link on your phone or computer
(on the same Wi-Fi as this computer), or scan the code with your phone's camera:

    http://192.168.1.50:47733/#/setup/3JKN-BEKA/3uhgitwjccsopjlo

    (a QR code of that link)

On this computer itself:     http://localhost:47733/#/setup/3JKN-BEKA/3uhgitwjccsopjlo

The link works once. A new one, any time until the family is made:  sudo den setup-link

Is it all right? sudo den status        Something wrong? Run the same install command again.
```

With `--token` (or a token pasted at the prompt), it says `Connecting the tunnel...` and then
`Reachable from anywhere at https://den.kotvas.app.`. The QR code then carries the https link,
which works from anywhere, and the home-network link is printed under it. On a server on the
internet with no token yet, it asks for one; if it gets none, it says to run `sudo den tunnel`
first, because until then nothing but the server itself can open Den.

Every stop says what to do next, in plain words, and ends by saying to send a photo of the
screen to whoever gave you the link. Some examples: a 32-bit Raspberry Pi OS ("put Raspberry Pi
OS (64-bit) on its card with Raspberry Pi Imager"), too little memory or disk, no internet,
Podman pretending to be Docker (it gives the `--replace-podman` command), and port 47733 already
in use ("if it's an older Den, stop it first").

| Command (with sudo) | What it does |
| --- | --- |
| the install line again, or `den` | Repairs and updates: rewrites the compose file and the units, starts what's stopped, then updates (with the way back) |
| `den status` | Running? Family made? Reachable from anywhere, and at which address? Updates on, and the last result? How big is the data, and how much disk is free? |
| `den setup-link` | Restarts the hub for a fresh one-time code, and prints the link and QR code, until the family is made |
| `den tunnel [TOKEN]` / `den tunnel off` | Saves or forgets the tunnel token (the connector picks the change up in seconds) |
| `den update` | Updates now, whatever the policy says |
| `den logs` | `docker compose logs -f` for the hub and the connector |
| `den reset` | Asks for RESET to be typed, deletes `/opt/den/data`, starts empty, prints a new setup link |
| `den uninstall` | Asks first; removes the containers, images, units and the command, and keeps the data unless told otherwise. Docker stays |
| `--dry-run` | On any of the above: says what it would do, and changes nothing |

Options for you, not for James: `--lan` and `--local-only` (overrule [the network
guess](#who-can-reach-it); the choice is remembered), `--image ghcr.io/xattribution/den:v1.2.0`
(run and follow that tag; also remembered; `--image ghcr.io/xattribution/den:stable` goes back
to the default), `--yes` (ask nothing: uninstall then keeps the data, and reset refuses).

## On the server

| Path | What |
| --- | --- |
| `/opt/den/compose.yaml` | Generated on every run; nothing reads an `.env`. Project `denhub`, services `hub` and `tunnel`, network `den` (172.30.74.0/24), both from the image `den:current` with `pull_policy: never` |
| `/opt/den/data` | The family's data, bind-mounted at `/data` (`:z` for SELinux) in both containers. Owner 10001 (the image's `den` user), mode 0700. A bind mount rather than a named volume, so that it's one obvious folder to back up or delete, and so that the host's updater and `den` can read and write the hub's files without `docker exec` |
| `/opt/den/den`, `/usr/local/bin/den` | The installer, copied out of the image that runs (`/app/install.sh`), so the command and the image are always the same release |
| `/opt/den/state/` | Root's: `bad-image` (the id of an update that failed), `data-before-update/` (only while an update runs), `network-mode` and `image` (only if `--lan`, `--local-only` or `--image` was given) |
| `/etc/systemd/system/den.service` | `docker compose up -d` at boot, so that Den comes back even when an interrupted update left it stopped (Docker's `unless-stopped` alone wouldn't) |
| `den-update.timer`, `den-update.service`, `den-update.path` | [Updates](#updates-and-the-way-back) |

The port (47733), the uid, the subnet and the project name are constants in the script. The
image tags are `den:current` (what runs) and `den:previous` (the way back), set from
`ghcr.io/xattribution/den:stable`, which the updater pulls.

Distributions: Ubuntu, Debian, Raspberry Pi OS 64-bit and their relatives (Mint, Pop!_OS,
Zorin, LMDE) get Docker's apt repository; Fedora, RHEL, Rocky, Alma, CentOS Stream and Oracle
Linux get Docker's dnf repository (the `.repo` file is downloaded, so it doesn't matter whether
dnf is version 4 or 5); Arch gets `pacman -Syu docker docker-compose` (the whole system, since
partial updates are how Arch breaks); openSUSE Leap and Tumbleweed get
`zypper install docker docker-compose`. A Docker that is already installed is used as it is,
and gets Compose added if it lacks it (from the distribution, or else Docker's own build checked
against its sha256). Refused, each with what to do instead: 32-bit anything (including a 32-bit
system on a 64-bit Pi kernel, found with `getconf LONG_BIT`), other processors, CentOS 7,
openSUSE MicroOS, Alpine, less than about 1 GB of memory or 2 GB of free disk.

Podman: Podman alone doesn't do here (compose, health checks and restart-at-boot all differ),
so the installer installs Docker beside it. If `docker` is Podman's stand-in (podman-docker), or
dnf won't put Docker next to Podman (RHEL 8's runc), it stops and gives the
`--replace-podman` command, which removes podman-docker and installs with `--allowerasing`.

## Who can reach it

Nothing on the server opens a port to the internet. The tunnel calls out to Cloudflare.

- **A computer at home** (`lan`): the hub's port is published on `0.0.0.0:47733`, which is
  IPv4 only, so the home network can open the first setup page. A home router doesn't forward
  that port. IPv6 isn't published.
- **A server on the internet** (`local`): published on `127.0.0.1:47733` only. The family comes
  in through the tunnel, and you reach it with `ssh -L 47733:127.0.0.1:47733`.

The guess: `local` if any interface has a public IPv4 address, or the default route's source
address is public, or the DMI vendor is a known cloud (Amazon EC2, Google, DigitalOcean,
Hetzner, Linode/Akamai, Vultr, OVH, Scaleway, Oracle, Alibaba), which catches clouds that keep
a private address behind their NAT. Otherwise `lan`. Tailscale's 100.64/10 and Docker's bridges
count as private.

Inside, the hub runs with `DEN_PUBLIC=1` (the public posture, always, since the tunnel makes it
reachable), `DEN_MDNS=0`, and `DEN_TRUSTED_PROXIES=172.30.74.0/24`. That last one is so the
connector's `X-Forwarded-*` headers count. cloudflared is in its own container on purpose: on
the hub's loopback, every request from the internet would look to the hub like one from its own
machine (`host.dart`'s loopback checks). Both containers drop all capabilities and run with
`no-new-privileges`.

## The tunnel

Once, in Cloudflare (Zero Trust, Networks, Tunnels): **Create a tunnel**, Cloudflared, name it
(say `den-james`), and copy the token: it's the `eyJ...` in the command Cloudflare shows. Under
**Public hostnames**, add one: subdomain and domain (`den.kotvas.app`, or one per family), service
type **HTTP**, URL **`hub:47733`**. It must be `hub`, the compose service's name: `localhost`
would be the connector's own container. If the name already has a DNS record (the old private
setup's `A` record), delete that record first, since the tunnel makes its own CNAME. Then give
James the install line with `--token`.

The connector is [`deploy/hub/den-connector.sh`](../deploy/hub/den-connector.sh), the `tunnel`
service's entrypoint, from the hub's own image (cloudflared 2026.10.0 is copied in from
`cloudflare/cloudflared`). Every 3 seconds it:

- reads `<data>/hub/tunnel-token`, keeping only the `eyJ...` word (so a pasted
  `cloudflared service install eyJ...` works too);
- if that's new, (re)starts `cloudflared tunnel --no-autoupdate --metrics 0.0.0.0:20241 run`,
  with the token in `TUNNEL_TOKEN` (in the environment, not on the command line, where `ps`
  would show it);
- if the file is gone, stops cloudflared;
- if cloudflared has exited, starts it again after 5, 10, 20, ... up to 60 seconds, and turns
  its last log lines into words ("Cloudflare didn't accept the tunnel token...", "Can't reach
  Cloudflare...");
- asks cloudflared's `/ready` (how many connections) and `/config` (the public hostname and its
  service, which it checks is `http://hub:47733`), and writes `tunnel-status.json`.

So nobody restarts anything: writing the token is enough. That was chosen over the hub running
cloudflared as a child process because of the loopback problem above, and because a crash or an
update of either one doesn't take the other down. It was chosen over the official cloudflared
image because that image is distroless, with no shell to wait and watch with.

## Updates and the way back

The mechanism is a systemd timer and the script itself. It isn't an updater container with the
Docker socket, because systemd is on every distribution the installer supports, so the timer
costs no extra process, image or socket, and `journalctl -u den-update` has its log. An updater
container would itself need updating, and would hold the keys to the whole machine.

- `den-update.timer`: every night at 03:30, plus up to 45 minutes at random. It's `Persistent`, so
  a computer that was off catches up when it starts.
- `den-update.path`: starts the same service as soon as `<data>/hub/update-request` exists (the
  app's "Update now").
- `den-update.service` runs `/opt/den/den update --from-timer`.

What `update` does, holding a lock (`/opt/den/.lock`) so that it and the installer never
overlap:

1. Deletes `update-request` if it's there (a person asked, so the policy and the bad-image memory
   don't apply). Writes `update.json` `checking`.
2. `docker pull ghcr.io/xattribution/den:stable`. Offline: `failed`, and it tries the next night.
3. The same image id as `den:current`: `up-to-date`. The id in `state/bad-image`, and nobody
   asked: it stays (`rolled-back`). `update-policy` is `manual`, and nobody asked: `available`.
4. Otherwise, `den:current` becomes `den:previous` (the old previous image is removed), it writes
   `updating`, stops both containers, copies `/opt/den/data` to `state/data-before-update` (if
   there's room for it), tags the new image `den:current`, and starts it.
5. Healthy within 4 minutes (the image's own `HEALTHCHECK`, `GET /health`): `updated`, with
   "Updated to vX.Y.Z". The data copy is deleted, and the `den` command is refreshed from the new
   image.
6. Not healthy: stop, put the data copy back (a new version may have migrated it), tag
   `den:previous` as `den:current` again, start, remember the bad image id, and write
   `rolled-back` ("v1.1.0 didn't start, so Den went back to v1.0.0..."). The next stable release
   is tried as usual.

## What the hub reads and writes

The contract between the server's packaging and den_hub (the first-boot page, Settings,
Backups). Every path is in the hub's data directory (`/data` in the container,
`/opt/den/data` on the server). Each file is one line.

| File | Written by | Read by | What |
| --- | --- | --- | --- |
| `hub/tunnel-token` | the hub (first-boot page), `den tunnel`, the installer's `--token` | the connector | The token, owner-only, written to a temporary file and renamed into place. Deleting it stops the tunnel |
| `hub/tunnel-status.json` | the connector, every 3 s | the hub, `den status` | `{"state":"waiting\|starting\|connected\|error","hostname":"den.kotvas.app"\|null,"service":"http://hub:47733"\|null,"connections":4,"message":"plain words","since":"…Z","updated":"…Z"}`; stale if `updated` is more than 30 s old (the connector isn't running) |
| cloudflared's metrics | cloudflared | the hub | `http://tunnel:20241/ready` and `/config` on the compose network (`DEN_CONNECTOR_METRICS` in the hub's environment; `DEN_CONNECTOR=cloudflared` says a connector exists) |
| `hub/address` | the hub (from the tunnel's hostname, or typed on the first-boot page) | `serve` (when `DEN_PUBLIC_URL` isn't set), the installer's links | The family's address, `https://den.kotvas.app` or the bare name |
| `hub/update.json` | the host's updater | the hub | `{"state":"checking\|updating\|updated\|up-to-date\|available\|rolled-back\|failed","message":"Updated to v1.2.0","current":"v1.2.0","available":"v1.2.0","previous":"v1.1.0","channel":"stable","policy":"auto\|manual","checked":"…Z","updated":"…Z"}`, owner 10001, mode 0600 |
| `hub/update-request` | the hub ("Update now") | the host (`den-update.path`) | Any content. The update starts within seconds and deletes the file. The hub restarts during it |
| `hub/update-policy` | the hub (if it offers a choice) | the host | `manual`: the nightly run only downloads and reports `available`. Anything else, or no file: `auto` |

The compose file sets no `DEN_PUBLIC_URL`: the address is only known once the tunnel connects
(`hostname` above), so the hub takes it from there or keeps its own. The installer prints its
links with `den_hub setup-link --bare --url <address>` (the link on the first line, then the QR
code; exit 3 once the family is made). The home-network link is plain `http://`, which isn't a
secure context in browsers (no `crypto.subtle`, no service worker), so the first-boot page
should work without them, or hand over to the https address for making the family.

The image also carries rclone 1.75.2 (`/usr/local/bin/rclone`, SMB built in, no other packages
needed) for backups to a NAS, `/app/VERSION`, and the label
`org.opencontainers.image.version`. The hub is on a bridge network, not the host's. So an mDNS
search for a NAS doesn't reach the home network, and the Backups screen asks for the NAS's
name or address instead. SMB itself goes out through Docker's NAT as usual. Host networking
would make the search work, but it would put the hub on the same loopback as anything else on
the computer, and would publish its port on every interface, IPv6 too.

## Releasing

`tools/release.sh` runs on your x86_64 Linux machine (the VPS or the desktop), with Docker. It
uses no GitHub Actions.

```sh
tools/release.sh v1.0.0              # build both platforms, push v1.0.0 and stable
tools/release.sh v1.1.0 --no-stable  # push v1.1.0 only; try it on one server:
                                     #   sudo den --image ghcr.io/xattribution/den:v1.1.0
tools/release.sh --promote v1.1.0    # then point stable at it (no rebuild)
tools/release.sh v1.1.0 --dry-run    # what it would do
```

What it does: checks that the checkout is clean (`--allow-dirty` to override), that you're
signed in to ghcr.io (if not, it prints the one-time steps: a classic token with
`write:packages`, then `docker login ghcr.io`), makes a `docker-container` buildx builder
`den-release`, installs QEMU's arm64 handler if the builder can't run arm64, and then runs one
`docker buildx build --platform linux/amd64,linux/arm64 -f deploy/hub/Dockerfile --push` with
`DEN_VERSION` and `DEN_COMMIT`. After that, it checks the platforms, and checks that the
package can be pulled without signing in. If it can't, it prints how to make it public: the
package's settings, Change visibility, Public; and if GitHub doesn't offer that, the
organization's Settings, Packages. Finally it tags the commit `release/vX.Y.Z` locally. The tag
isn't `v*`, because pushing a `v*` tag starts the paid release workflow in `ci.yml`.

The web app compiles once, on the build machine (`FROM --platform=$BUILDPLATFORM`), because it
is the same for both platforms. The hub compiles once per platform. Cross-compiling the hub
doesn't work yet: `dart compile exe --target-arch arm64` refuses packages with build hooks (it
says "'dart compile' does not support build hooks"; sqlite3's, through den_sett_import), and
`dart build cli`, which runs the hooks, has no `--target-arch` in Dart 3.10. So the ARM hub
compiles under QEMU. Expect 15 to 25 minutes in all. To make it faster, add a real ARM machine
to the builder (`docker buildx create --append --name den-release --platform linux/arm64
ssh://you@a-pi`), and release.sh uses it as it is. When `dart build cli` learns to
cross-compile, the hub stage can move to `$BUILDPLATFORM` too.

`deploy/hub/Dockerfile` still builds from source for one platform as before
(`docker build -f deploy/hub/Dockerfile .`, and the old compose files' `--build`). It is now
somewhat bigger, with cloudflared and rclone in it.

## Where the script is served from

The repository is private, so its raw GitHub URL doesn't work for James, and a container
registry can't serve a script. The recommendation is **`https://get.kotvas.app` as a Cloudflare
redirect rule to a release asset on a small public repository**:

1. Make a public repository, `xattribution/den-install`, holding only a README (and the
   license). It never gets code.
2. Each release uploads `deploy/install.sh` to a release there:
   `tools/release.sh vX.Y.Z --publish-script` (that's `gh release create vX.Y.Z deploy/install.sh
   --repo xattribution/den-install`). Tags there don't start this repository's CI.
3. In Cloudflare, for kotvas.app: a proxied DNS record `get` (an `AAAA` to `100::` is the usual
   placeholder), and a Redirect Rule: hostname equals `get.kotvas.app`, a static 302 to
   `https://github.com/xattribution/den-install/releases/latest/download/install.sh`.
   `curl -fsSL` follows it.

Why this way: no server to keep up, the script and the image come out of the same release, the
URL never changes, and if kotvas.app is ever in trouble the GitHub URL works by itself. A
Cloudflare Pages project serving the one file would work as well, at the price of one more
deploy step per release. The script keeps the address it prints in one constant
(`DEN_GET_URL`).

## Moving the VPS to the new installer

From the private setup (`deploy/private`) to this one, starting from a blank slate on the same
VPS, with the same address, `den.kotvas.app`.

1. **A backup, off the server.** `cd ~/den/deploy/private && sudo docker compose run --rm backup`,
   then `scp` the newest `backups/*.denbackup` to your computer. Keep the passphrase
   (`grep PASSPHRASE .env`).
2. **The tunnel**, as in [The tunnel](#the-tunnel), with the public hostname `den.kotvas.app` →
   `HTTP hub:47733`. Delete the old `A` record for `den.kotvas.app` first, and the Tailscale
   split-DNS nameserver for it, since the name now resolves to Cloudflare everywhere.
3. **The old stack down.** `sudo docker compose down` in `deploy/private` (it frees port 47733;
   its volume stays until you delete it). The nftables table and Tailscale can stay, for SSH
   over Tailscale (phase 5 of [the account-first plan](auth/ACCOUNT_FIRST_REVIEW.md)): the table
   drops inbound traffic only, and the tunnel goes out. To retire them as well:
   `sudo systemctl disable --now den-allowlist.timer den-firewall.service && sudo nft delete table inet den_fw`,
   but only once SSH works the way you want without them.
4. **Install:** `curl -fsSL https://get.kotvas.app | sudo sh -s -- --token eyJ...`
   (until the script is published: `sudo sh deploy/install.sh --token eyJ...` from a checkout).
   It sees a public address, so it publishes only on 127.0.0.1, and it ends with the https setup
   link.
5. **The family back.** Either restore the backup from the first setup page (once the hub side
   has it), or by hand, before anyone makes a family:
   `sudo cp den-....denbackup /opt/den/data/ && sudo chown 10001:10001 /opt/den/data/den-*.denbackup`,
   then `cd /opt/den && sudo docker compose stop hub && sudo docker compose run --rm --no-deps -e
   DEN_BACKUP_PASSPHRASE='<passphrase>' --entrypoint /app/bin/den_hub hub restore --in
   /data/den-....denbackup --passphrase-env DEN_BACKUP_PASSPHRASE --force && sudo docker compose
   up -d`. Then open Den on a phone that has been in use (as in [Restore](hosting.md#restore)).
   Or start the hub empty and let a parent's phone bring the family to it
   ([Reset the hub, keep the family](hosting.md#reset-the-hub-keep-the-family)).
6. **Check:** `sudo den status` says `From anywhere: yes, https://den.kotvas.app`, and a phone
   off Wi-Fi with Tailscale off opens it.
7. Later, delete the old volume (`docker volume ls`, `den_den-hub`) and `~/den/deploy/private/.env`.

## Tests

`bash deploy/test/install_test.sh` needs no Docker daemon, VM or network. It runs the installer
in a sandbox (a PATH of chosen real tools plus mocks for `uname`, `getconf`, `df`, `ip`, `id`,
`systemctl` and `docker`), with fake `/etc/os-release`, `/proc/meminfo` and DMI files, and
checks:

- the distribution and processor decisions for 26 os-release files (Ubuntu 22.04 and 24.04,
  Debian 12 and 13, Raspberry Pi OS 32 and 64-bit, Fedora x86 and ARM, RHEL, Rocky, Alma,
  CentOS 7, Arch x86 and ARM, Leap, Tumbleweed, MicroOS, Mint, Pop!_OS, LMDE, Alpine, 32-bit
  x86, 32-bit ARM, a 32-bit system on a 64-bit kernel, RISC-V);
- memory and disk limits, the home or internet guess (with Tailscale, Docker bridges, a cloud
  NAT, a remembered `--lan`), private address ranges, and tokens cleaned from pasted commands;
- the generated compose file (and `docker compose config` on it, where the CLI exists);
- `--dry-run` from start to end for Ubuntu (no Docker), Debian (Docker; docker.io without
  Compose), Raspberry Pi OS, Fedora, Rocky, RHEL with podman-docker (and `--replace-podman`),
  Arch, openSUSE and a VPS (with and without `--token`), checking that it changes no file and
  runs no systemctl;
- updates against a mocked docker that keeps images, tags and health in files: nothing new;
  a healthy update; an unhealthy one that goes back, data included, and isn't tried again;
  manual policy plus "Update now"; offline; and the file modes;
- the connector against a fake cloudflared: waiting, connected with the hostname, a token from a
  pasted command, the wrong service, a refused token with backoff, a token that changes and then
  goes away, and the status file's mode;
- shellcheck on every script, and dash parsing both POSIX ones.

### Checked on a real machine

These need real Docker, systemd, Cloudflare and hardware, which the tests can't stand in for:

- [ ] `tools/release.sh v0.9.0-rc.1` on the x86 machine: both platforms build (the arm64 hub
      under QEMU, and how long it takes), and the push lands. Then make the package public and
      check `docker pull ghcr.io/xattribution/den:v0.9.0-rc.1` signed out, on amd64 and arm64.
- [ ] In the image, on both platforms: `cloudflared --version`, `rclone version`,
      `rclone help backends | grep smb`, `/app/bin/den_hub --help`, and the sqlite library
      loading (`den_hub import-sett` on a small coord.db).
- [ ] A fresh Ubuntu 24.04 VPS: `curl … | sudo sh -s -- --token …`. Docker installs, the
      compose file is published on 127.0.0.1 only (`ss -ltn`, plus an outside `nc -z` that fails),
      the tunnel connects, the https link and QR work, and the family can be made from a phone.
- [ ] A Raspberry Pi 4 or 5 on Raspberry Pi OS 64-bit (bookworm or trixie): the install, and the
      home-network link from a phone on the same Wi-Fi.
- [ ] At least one of each family: Debian 12, Fedora 42 (SELinux enforcing: the `:z` mount),
      Rocky or Alma 9, Arch, openSUSE Tumbleweed. The Docker install for each, and `docker info`
      afterwards.
- [ ] The Raspberry Pi OS 32-bit message, on a real Pi.
- [ ] Running the installer a second time: nothing breaks, and "looking for a newer version"
      shows up.
- [ ] A reboot: `den.service` brings Den back, and the connector reconnects.
- [ ] An update: push a new `stable`, run `sudo den update`, and the hub shows the new version.
      Then a deliberately broken image (say, a `HEALTHCHECK` that fails), pushed as `stable` to
      a test tag with `--image`: it rolls back within about 4 minutes, with the data intact.
- [ ] The nightly timer fires (`systemctl list-timers den-update.timer`), and
      `touch /opt/den/data/hub/update-request` starts an update within seconds.
- [ ] `den tunnel off` and `den tunnel <token>`: the connector stops and starts again with no
      restart.
- [ ] `den reset` (typing RESET) and `den uninstall` (keep, then not keep).
- [ ] cloudflared's `/config` shape: `curl http://tunnel:20241/config` from the hub container
      has `ingress[0].hostname` and `service`.
- [ ] The first-boot page over `http://<LAN-IP>:47733` in iOS Safari and in Android Chrome, once
      the hub side has it.
- [ ] The move of the VPS, [above](#moving-the-vps-to-the-new-installer).
