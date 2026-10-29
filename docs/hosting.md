# Self-hosting Den

The family's **hub** is one always-on Docker container. It serves the web app that everyone adds
to their iPhone Home Screen, keeps the family's devices in sync, and runs the API, MCP for AI
assistants, calendar feeds and reminders. One hub per family. Phones keep the whole family on
the device too, so Den keeps working while the hub is down; it just doesn't sync until it's back.

This guide assumes you're comfortable with SSH and a Linux shell. Every task is a command to
paste, run as root (or with `sudo`) on the server.

- [Choose a setup](#choose-a-setup)
- [What you need](#what-you-need)
- [Install (setup A)](#install-setup-a): [B](#setup-b-cloudflare-tunnel), [C](#setup-c-tailscale),
  [D](#setup-d-a-computer-at-home), [E](#setup-e-several-families-on-one-server)
- [Everyday commands](#everyday-commands)
- [Updating](#updating)
- [Backups](#backups)
- [Moving to a new server](#moving-to-a-new-server)
- [Building on a small server](#building-on-a-small-server)
- [Server maintenance](#server-maintenance)
- [Admin and reset](#admin-and-reset)
- [Troubleshooting](#troubleshooting)
- [The AI helper](#the-ai-helper) and [connecting AI assistants](#connecting-ai-assistants)
- [Settings](#settings)

## Choose a setup

| | Setup | |
| --- | --- | --- |
| **A** | A VPS with a domain, HTTPS through the bundled Caddy | The main path: the family opens `https://den.example.com` from anywhere |
| **B** | A VPS behind a Cloudflare Tunnel | No open ports; Cloudflare holds the certificate and sees the traffic at its edge |
| **C** | Private, with Tailscale | Only devices on your tailnet reach it; every phone needs the Tailscale app |
| **D** | A computer at home | On the home network, for the Den app (found by mDNS). For iPhones' Home Screen app, which needs HTTPS, run setup C on that computer instead |
| **E** | Several families on one server | A hub per family, each with its own address and data, behind one Caddy |

## What you need

- **A server.** 2 GB of memory, 2 vCPUs (1 works, slower) and 25 GB of disk, with Ubuntu 24.04
  or Debian 12, x86 or ARM. The hub and Caddy use a few tens of MB; building the hub's image is
  what needs memory, about 1.2 GB at the peak
  ([Building on a small server](#building-on-a-small-server)). On a 1 GB server, add swap or
  build the image elsewhere.
- **A domain name** whose DNS points at the server: an `A` record for `den.example.com` with the
  server's IPv4 address, and `AAAA` for IPv6 if it has one. (Setup B needs the domain on
  Cloudflare instead; setup C needs none.)
- **Ports** 22 (SSH), 80 and 443 open to the internet. Setups B and C need only 22.
- **Docker** with Compose. On Ubuntu or Debian:

  ```sh
  curl -fsSL https://get.docker.com | sh
  ```

- **A firewall.** With ufw:

  ```sh
  ufw allow OpenSSH
  ufw allow 80/tcp
  ufw allow 443
  ufw enable
  ```

  Docker opens the ports it publishes ahead of ufw's rules. This setup publishes only 80 and 443
  to the internet; the hub's own port, 47733, listens on the server's `127.0.0.1` only.

## Install (setup A)

The repository is private: `git clone` asks for your GitHub user name and, as the password, a
token with read access to it (a fine-grained token with *Contents: Read-only* on
`xattribution/den`). `git config --global credential.helper store` saves it for `git pull`.

```sh
git clone https://github.com/xattribution/den.git
cd den/deploy/hosted
cp env.example .env
nano .env                    # set DEN_DOMAIN=den.example.com
echo "DEN_BACKUP_PASSPHRASE=$(openssl rand -base64 24)" >> .env
chmod 600 .env
docker compose up -d --build
```

The first `up` builds the hub's image from the checkout (about 10 minutes), then starts the hub
and Caddy, which gets the certificate for your domain by itself. Copy the backup passphrase
(`grep PASSPHRASE .env`) into your password manager now: a backup doesn't open without it.

Every command in this guide runs from `den/deploy/hosted`. `.env` picks what runs there
(`COMPOSE_PROFILES=caddy`), so they're all plain `docker compose ...`.

Get the setup code:

```sh
docker compose exec hub /app/bin/den_hub setup-code
```

Then, on a parent's iPhone:

1. Open `https://den.example.com` in Safari.
2. Tap Share, then **Add to Home Screen**, then **Add**, and open Den from the Home Screen.
3. Tap **Start a family**, and type the setup code under **Your hub**.
4. The phone shows three words. Approve only if the hub logged the same three:
   `docker compose logs hub | grep "Matching words"`.
5. Invite the others from **Add people** (**Send invite**): a link and four words. They open the
   link, add Den to their Home Screen the same way, and a parent taps **Approve** on Today.

[For the family](#for-the-family) has a message to send them.

### Setup B: Cloudflare Tunnel

In the Cloudflare dashboard (Zero Trust, Networks, Tunnels), create a tunnel, give it the public
hostname `den.example.com` with the service `http://hub:47733`, and copy its token. Then follow
the install above with these two lines in `.env`:

```sh
COMPOSE_PROFILES=tunnel
TUNNEL_TOKEN=<the token>
```

`cloudflared` runs as one more container next to the hub. No ports need to be open but SSH.
Cloudflare sees the traffic in the clear at its edge (Den's sync is still end-to-end encrypted
inside `/ws`).

### Setup C: Tailscale

Install Tailscale on the server (`curl -fsSL https://tailscale.com/install.sh | sh`, then
`tailscale up`) and turn on HTTPS certificates for your tailnet in its admin console. Then follow
the install above with these lines in `.env`, where the name is the server's on your tailnet:

```sh
DEN_DOMAIN=den-server.tail1234.ts.net
COMPOSE_PROFILES=
```

and, once the hub runs, publish it to your tailnet:

```sh
tailscale serve --bg 47733
```

Every phone needs the Tailscale app, signed in to your tailnet. (`tailscale funnel --bg 47733`
publishes it to the internet instead, with no app on the phones.)

### Setup D: a computer at home

```sh
git clone https://github.com/xattribution/den.git
cd den/deploy
docker compose up -d --build
docker compose exec hub /app/bin/den_hub setup-code
```

The hub uses the computer's network directly, so the Den app finds it by mDNS (Settings,
Advanced, Hub and sync, Add a device, **A hub**). The everyday commands below work the same from
`den/deploy`; backups need `DEN_BACKUP_PASSPHRASE` in a `.env` there. Safari's Home Screen app
needs HTTPS, so for iPhones run setup C on this computer instead.

### Setup E: several families on one server

```sh
cd den/deploy/hosted
cp env.two-families.example .env    # set FAMILY_A_DOMAIN and FAMILY_B_DOMAIN
echo "DEN_BACKUP_PASSPHRASE=$(openssl rand -base64 24)" >> .env
docker compose up -d --build
docker compose exec hub-a /app/bin/den_hub setup-code
docker compose exec hub-b /app/bin/den_hub setup-code
```

`.env` also names the compose file (`COMPOSE_FILE=two-families.yaml`), so the commands in this
guide work with `hub-a` or `hub-b` in place of `hub`, and `backup-a` or `backup-b` in place of
`backup`. The hubs share nothing but the server: different keys, data and addresses, and a
request for one family's domain never reaches the other's hub. You never need to be in either
family. A third family is another `hub-`, `backup-` and Caddyfile block like these, with the
next port.

## Everyday commands

From `den/deploy/hosted`:

| Task | Command |
| --- | --- |
| Status and health | `docker compose ps` (the hub should say `healthy`), then `docker compose exec hub /app/bin/den_hub status` |
| Logs | `docker compose logs -f --tail 100 hub` (Ctrl-C stops following; `caddy` for Caddy's) |
| The setup code | `docker compose exec hub /app/bin/den_hub setup-code` |
| Let browsers link for 10 minutes | `docker compose exec hub /app/bin/den_hub open-linking` |
| Stop | `docker compose stop` |
| Start | `docker compose start` |
| Restart | `docker compose restart` |
| Shut down completely | `docker compose down` (removes the containers; the family's data stays in its volume) |
| Start again after `down` | `docker compose up -d` |
| After a reboot | Nothing: Docker starts everything again by itself (`restart: unless-stopped`), unless you stopped it with `docker compose stop` |

From anywhere, `curl -fsS https://den.example.com/health` answers
`{"ok":true,"api":1,"ready":true}` once the hub is in a family.

## Updating

```sh
docker compose run --rm backup          # a backup first
docker tag den-hub den-hub:previous     # keep the version that runs now
git pull
docker compose up -d --build
```

Phones pick up the new web app the next time Den opens. To go back to the version you kept:

```sh
docker tag den-hub:previous den-hub
docker compose up -d
```

If the older version doesn't start with what the newer one wrote, restore the backup you made
before updating ([Restore](#restore)).

Every build leaves its cache behind (about 8 GB after the first). To free the space:

```sh
docker image prune -f        # old hub images nothing uses
docker builder prune -f      # the build cache; the next update then builds from scratch
```

### Published images

Once Den has releases, each `v*` tag publishes `ghcr.io/xattribution/den-hub` (x86 and ARM), and
the server doesn't need to build at all. The packages are private, so log in once with a token
that has `read:packages`, then name the release in `.env`:

```sh
echo <token> | docker login ghcr.io -u <your GitHub user> --password-stdin
echo "DEN_IMAGE=ghcr.io/xattribution/den-hub:v1.0.0" >> .env
docker compose up -d
```

`up` pulls the release if it isn't on the server yet. To update, change the version in `.env`
and run `docker compose up -d` again (without `--build`, which would build the checkout and give
it that name); to roll back, put the old version back.

## Backups

A backup holds the hub's keys, the family's whole change log, the hub's own state (connected
apps, the AI helper's and the reader's keys, feeds) and `notify.json`, sealed with
`DEN_BACKUP_PASSPHRASE` from `.env` (Argon2id, XChaCha20-Poly1305). It works while the hub runs:

```sh
docker compose run --rm backup
```

That writes `backups/den-<date>-<time>.denbackup` (UTC) and keeps the newest 14
(`DEN_BACKUP_KEEP` in `.env` changes that).

**Every night**, with `crontab -e`:

```sh
17 3 * * * cd /root/den/deploy/hosted && docker compose run --rm backup >> /var/log/den-backup.log 2>&1
```

**Off the server.** A backup on the server doesn't survive losing the server. From your own
computer:

```sh
mkdir -p ~/den-backups
scp 'root@den.example.com:den/deploy/hosted/backups/*.denbackup' ~/den-backups/
```

To keep that copy current, put this in your own computer's crontab (it needs rsync on both
ends):

```sh
rsync -a root@den.example.com:den/deploy/hosted/backups/ ~/den-backups/
```

**The passphrase** lives in `.env` on the server, readable only by root, and in your password
manager. Root on the server can read the hub's data anyway; the passphrase protects the copies
that leave it, and without it they're useless.

### Restore

```sh
docker compose stop hub
docker compose run --rm backup restore backups/den-2026-10-28-0317.denbackup
docker compose up -d
```

**Then open Den on a phone.** What the hub wrote after the backup (an event an assistant added,
a calendar feed's updates) isn't in the backup; it's on the family's phones. So a restored hub
writes nothing of its own until a phone or tablet in the family has synced with it: calendar
feeds wait, and assistants and scripts that try to change something are told "The hub is
catching up after a restore" and to try again in a minute. Open Den on a phone that has been in
use since the backup was made (the one used most recently is best) and let it sync. The hub
takes back what it wrote and carries on after it; the other phones catch up as they open.

To check, `docker compose exec hub /app/bin/den_hub status` says `Catching up after a restore`
until a phone has synced, and stops saying it once one has.

## Moving to a new server

The family keeps the same address and the same hub (its keys are in the backup), so nobody adds
Den again. While you move, Den keeps working on every phone from what it has; it shows that it
can't reach the hub, and what people change meanwhile syncs once the new server answers.

A day ahead, lower the DNS record's TTL to 300 seconds, so the switch takes minutes.

1. **Set up the new server**: [What you need](#what-you-need), then:

   ```sh
   git clone https://github.com/xattribution/den.git
   mkdir -p den/deploy/hosted/backups
   ```

   From your own computer, copy the settings across (`-3` copies between the two servers
   through your computer):

   ```sh
   scp -3 root@old-server:den/deploy/hosted/.env root@new-server:den/deploy/hosted/.env
   ```

   and build the image on the new server, before the old one stops (or `docker compose pull`
   with [published images](#published-images)):

   ```sh
   cd den/deploy/hosted
   docker compose build
   ```

2. **Back up the old server** with its hub stopped, so the backup is the last word:

   ```sh
   docker compose stop hub
   docker compose run --rm backup
   ```

3. **Copy the backup** from your own computer:

   ```sh
   scp -3 'root@old-server:den/deploy/hosted/backups/den-*.denbackup' root@new-server:den/deploy/hosted/backups/
   ```

4. **Restore on the new server** from the newest backup, and start it:

   ```sh
   docker compose run --rm backup restore backups/den-2026-10-28-0317.denbackup
   docker compose up -d
   ```

5. **Point DNS** at the new server: change the `A` (and `AAAA`) record to its address. Caddy gets
   the certificate as soon as the name reaches it; `docker compose logs -f caddy` shows it.

6. **Open Den on a phone** once `curl -fsS https://den.example.com/health` from your computer
   says `"ready":true`. A restored hub writes nothing of its own until a phone or tablet in the
   family has synced with it ([Restore](#restore)); until then calendar feeds wait and assistants
   are asked to try again. When the phone has synced,
   `docker compose exec hub /app/bin/den_hub status` says `In a family and serving.` and no
   longer says `Catching up after a restore`.

7. **Shut the old one down**: `docker compose down` there. Keep it a few days, then delete it.

**Copying the raw volume instead.** The backup is the way to move: it's encrypted, works while
the hub runs, and carries over between Den versions. A copy of the Docker volume itself is an
exact clone, byte for byte, but only between the same Den version on both servers, with the hub
stopped, and it isn't encrypted (it holds the hub's keys), so delete it once you're done. On the
old server:

```sh
docker compose down
docker compose run --rm -T --entrypoint tar backup czf - -C /data . > den-hub-volume.tgz
```

Copy `den-hub-volume.tgz` across, and on the new server (before its first `up`):

```sh
docker compose run --rm -T --entrypoint tar backup xzpf - -C /data < den-hub-volume.tgz
docker compose up -d
```

## Building on a small server

The hub's image compiles the web app inside Docker. Measured on 2 vCPUs: 7 to 8 minutes from
scratch (2 of them downloading Flutter's image), and about 1.2 GB of memory at the peak (1.5 GB
counting file cache), nearly all of it the web app's compiler. Capped at 1.3 GB with no swap,
the build still finished; capped at 800 MB, the compiler was killed. So:

- **2 GB of memory** builds it. Add 2 GB of swap anyway, for headroom.
- **1 GB of memory** runs the hub fine but can't build without swap. Add 4 GB of swap (the build
  then takes longer), or build on your own computer, or use [published images](#published-images).

Swap, once:

```sh
fallocate -l 4G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

A build that ran out of memory stops with `Target dart2js failed: ... exit code -9` and
`Failed to compile application for the Web`.

**Building on your own computer** (with Docker, from a clone of the repository) and sending the
image to the server:

```sh
docker build -f deploy/hub/Dockerfile -t den-hub .
docker save den-hub | gzip | ssh root@den.example.com docker load
```

On a Mac with Apple silicon, for an x86 server, build with `--platform linux/amd64`. The
compose file runs the image called `den-hub` as it finds it, so on the server start it without
`--build`:

```sh
docker compose up -d
```

Update the same way: `git pull` and the two commands above on your computer, then
`docker compose up -d` on the server.

## Server maintenance

**OS updates and reboots.**

```sh
apt update && apt upgrade -y
[ -f /var/run/reboot-required ] && reboot
```

Den comes back by itself after a reboot; `docker compose ps` confirms it. Ubuntu installs
security updates every night on its own (`unattended-upgrades`); Docker's own updates come
through `apt` too and restart the containers.

**Disk space.**

```sh
df -h /
docker system df
docker image prune -f && docker builder prune -f
```

**Logs.** Docker keeps at most 30 MB of logs per container here (`logging` in `compose.yaml`).
The system journal: `journalctl --vacuum-size=200M`.

**Certificates.** Caddy renews them by itself, about a month before they expire. To see the
current one's dates:

```sh
echo | openssl s_client -connect den.example.com:443 -servername den.example.com 2>/dev/null | openssl x509 -noout -dates
```

**Time.** Certificates, invites and link codes depend on the clock.
`timedatectl` should say `System clock synchronized: yes`; if it doesn't,
`timedatectl set-ntp true`.

**Health.** `docker compose ps` shows the hub `healthy` (Docker checks `/health` every
30 seconds). To be told when it isn't, point an uptime monitor at
`https://den.example.com/health`.

## Admin and reset

### A new setup code

Only a hub that isn't in a family yet has one. It prints a new one each time it starts:

```sh
docker compose exec hub /app/bin/den_hub setup-code
docker compose restart hub     # a fresh code, if the old one may have been seen
```

### Reset the hub, keep the family

The family lives on the phones too, so a hub can start over empty and get everything back from
them. Restoring a [backup](#restore) is better when you have one: the hub keeps its identity and
nothing on the phones changes. Without one:

```sh
docker compose down
docker volume rm den_den-hub
docker compose up -d
docker compose exec hub /app/bin/den_hub setup-code
```

Then, on a parent's phone: Settings, Advanced, Hub and sync, Add a device, **Another hub**, with
`https://den.example.com` and the new setup code. Compare the words and approve; the phone sends
the hub the whole family, and the other phones catch up through it, the ones that haven't heard
of the new hub yet too (it shows them the parent's approval).

The new hub is a new device, and the old one stays in the family until a parent removes it: an
approved device that holds a copy of everything the hub held, whose keys are in the old volume and
every backup of it. Remove it. The phone that added the new hub sees that the old one used the
same address and offers **Remove the old hub**. If you skipped it, remove it under Settings,
Advanced, Hub and sync, where each hub shows when this phone last saw it and when it was added;
the old one is the one not seen since the reset, and **Remove** takes it out of the family on
every device. Until then phones still sync, with whichever hub answers at the address. If the
family lets the hub help them get back in, the new hub has a new recovery key: see
[If a parent loses their phone](#if-a-parent-loses-their-phone).

### Factory reset

Deletes the hub, its certificates, the model and the backups on this server. The phones keep
their copy of the family.

```sh
docker compose --profile '*' down -v
rm -rf backups
docker compose up -d
```

### If a parent loses their phone

If another parent still has their phone, nothing special is needed: invite the new phone as
usual and that parent lets it in from Needs you. When no parent's phone is left, there are two
ways back in.

**With their recovery words** (nothing to do on the server). Each parent saves 12 words when
they start the family, or later on their own page in Family, **Recovery words**. On the new
phone:

1. Open `https://den.example.com` in Safari, add Den to the Home Screen and open it from there.
2. Choose **Join your family**, then **I lost my phone**.
3. Paste the 12 words as they were saved (numbers, new lines and the note's title are fine) and
   tap **Find me**.
4. Den shows whose words they are. **Yes, let this phone in**, and the phone is theirs at once.

The hub only carries the request: it can't make up words, and no setting is needed. In the Home
Screen web app the words are typed into the app the hub serves, so they are only as safe as the
server is (see below).

**With the hub's help, only if the family turned it on.** A parent turns on Settings, Family,
**Let the hub help us get back in** on their own phone. Then, from `den/deploy/hosted`:

```sh
docker compose exec hub /app/bin/den_hub recover --person "Alex"
```

The name is the parent's name in Den, in quotes. The command prints:

```text
A recovery code for Alex is ready. It lets in one phone, for the next 30 minutes (until 15:42 UTC).

Send Alex this link to open on the new phone:
  https://den.example.com/#/recover/maple-river-canoe-tiger

Or, in Den on the new phone, choose "I lost my phone" and type these four words:
  maple river canoe tiger

Every device in the family will show that Alex's new phone was let in by the hub.
```

Send Alex the link, or read out the four words. They let in one phone, once. The link is built
on `DEN_PUBLIC_URL`; without it the command prints only the words. If the family hasn't turned
server help on, the command says so and how, and lets nobody in.

**What this means for whoever runs the server.** With server help on, the admin could add a
phone as any parent; every device in the family shows when that happens ("Alex's new iPhone was
let in by the hub's recovery"), and any parent can remove it. With it off, the hub's key lets
nobody in, even for a request dated earlier. Root on the server can still read what the hub
holds, as always.

There is one more thing whoever controls the server can do, with server help on or off. The
Home Screen web app comes from the hub, and it holds each parent's key on their phone. So whoever
controls what the hub serves (root on the server, the hub's image, or Caddy and its certificate)
could serve a changed app that acts as any parent who opens it: approve a phone, change who is a
parent. The family's devices can't tell that apart from the parent. To keep that from happening,
keep the server patched and its logins to people you trust, and build the image from this
repository (or pull a published release). A parent who wants the stronger guarantee makes these
decisions (approving devices, roles, AI access, recovery) in the Den app installed on their
phone, tablet or computer, whose code doesn't come from the server.

The hub's server recovery key lives in its data volume (`hub/recovery.json`) and is in every
backup (`docker compose run --rm backup`), so a [restore](#restore) keeps server help working. A
hub [reset without a backup](#reset-the-hub-keep-the-family) makes a new key: a parent turns
**Let the hub help us get back in** off and on again.

Either way, the new phone then offers **Remove your old phone** on the parent's page in Family.

### Bring in a family from Sett

Copy Sett's `coord.db` into `den/deploy/hosted` on the server and keep it to root
(`chmod 600 coord.db`): it holds Sett's secrets. With the hub in a family, and the name of a
parent in it, hand the file to the hub's own user inside its data volume, import, and delete
both copies:

```sh
docker compose stop hub
docker compose run --rm -T --entrypoint sh hub -c 'umask 077 && cat > /data/coord.db' < coord.db
docker compose run --rm hub import-sett /data/coord.db --as Alex
docker compose run --rm --entrypoint rm hub -f /data/coord.db
docker compose start hub
rm coord.db
```

The copy in the volume is the hub user's alone (mode 600), so no other account on the server
can read it while it is there. The import says what it brought over and what it left behind;
the phones get it as they sync.

### Uninstall

```sh
docker compose --profile '*' down -v --rmi all
docker image rm den-hub:previous     # if you kept one when updating
docker builder prune -af
cd && rm -rf den
```

## Troubleshooting

**No certificate** (Safari says the connection isn't private, or can't connect).
`docker compose logs caddy` says why. Usually DNS: `getent hosts den.example.com` must print
this server's address. Or ports: from your own computer, `curl -I http://den.example.com` must
reach Caddy, so check ufw and any firewall at your VPS provider. Caddy keeps retrying;
`docker compose restart caddy` retries at once. Don't loop `down -v`: Let's Encrypt limits how
many certificates a name gets in a week.

**Phones can't connect.** `docker compose ps` (is the hub `healthy`?), `curl -fsS
https://den.example.com/health` from the phone's network, and the hub's log. Den shows the
problem in Settings, Advanced, Hub and sync.

**"Link closed"** ("A parent needs to open Add a device in Den first"). A hub on the internet
lets a new browser ask to link only while a parent has **A browser on a computer** open on their
phone (Settings, Advanced, Hub and sync), or for 10 minutes after
`docker compose exec hub /app/bin/den_hub open-linking`. Invites by message need neither.

**Rate limited** ("Too many tries from here", `429`). The hub limits what each address may do;
wait the time it says. If the whole family is limited at once, the hub sees one address for
everyone: a proxy it doesn't trust is in front of it, and `docker compose logs hub` warns about
`X-Forwarded-For`. Add that proxy to `DEN_TRUSTED_PROXIES`.

**Out of memory while building** (`Target dart2js failed: ... exit code -9`). Add swap, or build
elsewhere: [Building on a small server](#building-on-a-small-server).

**The setup code is lost.** `docker compose exec hub /app/bin/den_hub setup-code` prints it
again; it says so if the hub is already in a family.

**The hub was removed from the family.** A parent removed it (Hub and sync, **Remove**). The first
phone that reaches it refuses it and tells it so, and from then on `den_hub status` and the hub's
log say "This hub was removed from the family on Oct 28; reset it to add it again". It can't come
back with the same keys, so [reset the hub](#reset-the-hub-keep-the-family) and add it again.

## The AI helper

Den's own helper (Ask, in Add) is off until a parent turns it on from their phone: Settings,
**AI helper**, where they also enter the provider's key. The key lives on the hub (in its data,
so in its backups), never on the phones: every device asks through the hub, which needs to reach
the provider over HTTPS. Nothing to set on the server.

## Connecting AI assistants

Claude, ChatGPT, Gemini, Grok and Alexa+ reach Den from their own servers over MCP with OAuth.
The address to add is `https://den.example.com/mcp`. The person connecting sees Den's sign-in
page with a code, and a parent approves the request in the Den app (Settings, Advanced, AI and
automations, which also has these steps), choosing what it may do and whose permissions it uses.
Removing an app there ends its tokens at once.

- **Claude** (claude.ai, Desktop, mobile, Claude Code): add Den as a custom connector. Claude
  identifies itself with a client document or registers; its servers call from
  `160.79.104.0/21`. ([Anthropic: authentication for connectors](https://claude.com/docs/connectors/building/authentication.md))
- **ChatGPT** (developer mode, for Plus, Pro, Business, Enterprise and Edu): add Den as an app
  with OAuth. It asks before every write.
  ([OpenAI: developer mode](https://developers.openai.com/api/docs/guides/developer-mode))
- **Gemini** (18 or over, in the US, a personal Google Account, English): gemini.google.com,
  Settings, Connected Apps, Add a custom app.
  ([Google: custom apps for Gemini](https://support.google.com/gemini/answer/17209137))
- **Grok**: grok.com/connectors, New Connector, Custom, then sign in. Grok refuses servers on a
  private address, so this needs setup A or B. ([xAI: Grok connectors](https://docs.x.ai/grok/connectors))
- **Alexa+** (the MCP toolkit, in preview): Alexa doesn't register clients, so a parent sets one
  up in the Den app with the redirect addresses the Alexa+ Developer Hub lists, and enters the
  client id and secret Den shows once in `alexa-ai configure-account-linking`. Re-deploy the
  add-on after changing the hub's address.
  ([Amazon: account linking for Alexa+ MCP add-ons](https://developer.amazon.com/docs/alexaplus/add-ons/mcp-toolkit-account-linking.html))

Only these paths have to be public for the assistants; the rest can stay behind a private proxy
(Tailscale, a VPN), where the family's devices reach it:

| Path | Public? |
| --- | --- |
| `/mcp`, `/.well-known/oauth-*`, `/oauth/token`, `/oauth/register` | Yes: the assistants' servers call them |
| `/oauth/authorize` and its `/status` | Only where the browser of the person connecting is |
| `/api/v1/*`, `/ws`, the web app | No |
| `/ics/*` | Only for calendar services that fetch feeds from their own servers (Google Calendar does; Apple Calendar fetches from the device) |

With setup A or B everything is public, which works: the public posture's limits and a parent's
approval of every sign-in apply either way. The hub also fetches out (Claude's and ChatGPT's
client documents, calendar feeds), and refuses addresses on its own machine and network unless
`DEN_FETCH_ALLOW` admits them.

## Settings

The hosted compose file sets these from `.env`; the hub reads them from its environment.

| Variable | What |
| --- | --- |
| `DEN_DOMAIN` | (`.env`) The family's address. The hub's `DEN_PUBLIC_URL` becomes `https://` and this |
| `COMPOSE_PROFILES` | (`.env`) What runs next to the hub: `caddy`, `tunnel`, `model`, or nothing. After changing it, `docker compose --profile '*' down` and `docker compose up -d` |
| `DEN_BACKUP_PASSPHRASE`, `DEN_BACKUP_KEEP` | (`.env`) Seals backups; how many to keep (14) |
| `DEN_IMAGE` | (`.env`) A published release to run instead of building, `ghcr.io/xattribution/den-hub:v1.0.0` |
| `DEN_PUBLIC_URL` | The hub's public address: OAuth metadata and link codes use it; `https` turns on the public posture |
| `DEN_TRUSTED_PROXIES` | Addresses or CIDR networks whose `X-Forwarded-*` headers count (the compose network) |
| `DEN_PUBLIC` | `1` or `0` forces the public posture on or off |
| `DEN_MDNS` | `0` when hosted (the default in the public posture) |
| `DEN_PORT` | The port inside the container, 47733 (one per family when several share a server) |
| `DEN_NAME` | The hub's name in the app |
| `DEN_LOG` | `debug`, `info`, `warn` or `error` |
| `DEN_CSP` | Replaces the web app's Content-Security-Policy, for a web build that needs a CDN after all |
| `DEN_ALLOWED_ORIGINS` | Extra browser origins for `/mcp` and OAuth (`https://claude.ai` is allowed already) |
| `DEN_FETCH_ALLOW` | Private networks the hub may fetch calendar feeds from; by default only the public internet |

**The public posture.** A hub whose `DEN_PUBLIC_URL` is `https` assumes strangers can reach it:
`/health` and `/api/v1/hub/status` say almost nothing; setup works only until the hub is in a
family, with five wrong codes per address before it has to wait; a new browser may ask to link
only while a parent allows it; everything a stranger can reach is limited per address
([docs/hub-api.md](hub-api.md), "Limits per client"); every answer carries security headers (HSTS,
a Content-Security-Policy that loads nothing from a CDN, no framing); and mDNS is off.

**Your own proxy** (nginx, Traefik) instead of Caddy: leave `COMPOSE_PROFILES` empty and proxy to
`127.0.0.1:47733` with `X-Forwarded-For`, `-Proto` and `-Host` set, WebSocket upgrades on `/ws`,
and buffering off for `/api/v1/stream`. Requests to that port arrive from the compose network's
gateway, which `DEN_TRUSTED_PROXIES` already trusts.

**A model on the server** that the hub reads with: add `model` to `COMPOSE_PROFILES`
(`caddy,model`), then `docker compose up -d` and
`docker compose exec model ollama pull llama3.2`. On a parent's phone: Settings, Advanced, AI and
automations, Reading photos and messages, **A model at home**, on the hub, address
`model:11434`.

## For the family

Send this, with your family's address in it:

1. Open **https://den.example.com** in Safari on your iPhone.
2. Tap the **Share** button, then **Add to Home Screen**, then **Add**.
3. Open **Den** from your Home Screen and follow what it says.

To see Den's events in the iPhone Calendar app, turn on **Show Den in iPhone Calendar** in Den's
Settings.
