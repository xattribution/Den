# Self-hosting Den

The family's **hub** is one always-on Docker container. It serves the web app that everyone adds
to their iPhone Home Screen, keeps the family's devices in sync, and runs the API, MCP for AI
assistants, calendar feeds and reminders. One hub per family. Phones keep the whole family on
the device too, so Den keeps working while the hub is down; it just doesn't sync until it's back.

This guide assumes you're comfortable with SSH and a Linux shell. Every task is a command to
paste, run as root (or with `sudo`) on the server.

- [Choose a setup](#choose-a-setup)
- [Private: home networks plus Tailscale](#private-home-networks-plus-tailscale), the recommended
  setup: [who can reach it](#who-can-reach-this-server), [install](#install-private),
  [commands](#everyday-commands-private), [moving](#moving-a-private-server),
  [maintenance](#maintenance-private), [what's closed](#closed-on-purpose)
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
| **P** | **Private: home networks plus Tailscale** (recommended) | Only the family reaches it: from their homes, or from anywhere through Tailscale, at one address. Nothing else on the internet gets an answer |
| **A** | A VPS with a domain, HTTPS through the bundled Caddy | Public: the family opens `https://den.example.com` from anywhere, with no app, and so can anyone try to |
| **B** | A VPS behind a Cloudflare Tunnel | No open ports; Cloudflare holds the certificate and sees the traffic at its edge |
| **C** | Tailscale only | Only devices on your tailnet reach it, at its `ts.net` name; every phone needs the Tailscale app, at home too |
| **D** | A computer at home | On the home network, for the Den app (found by mDNS). For iPhones' Home Screen app, which needs HTTPS, run setup C on that computer instead |
| **E** | Several families on one server | A hub per family, each with its own address and data, behind one Caddy |

## Private: home networks plus Tailscale

The recommended setup (P). A server the internet can't see: the family reaches Den at
`https://den.example.com` from their homes, and from anywhere else through Tailscale. It's one
address everywhere, which matters: Safari ties a Home Screen app's storage to its address, so a
second address would be a second app, and a second device in the family.

- **At home**, the phone looks up `den.example.com` in public DNS, gets the server's public
  address, and the firewall lets it in because it comes from one of the family's homes. Each home
  keeps a DDNS name pointed at its address; the server looks them up every 3 minutes.
- **Away, with Tailscale on**, Tailscale's split DNS asks the server itself about
  `den.example.com`, the server answers with its Tailscale address, and the same request goes
  through the tunnel. Tailscale carries nothing else: it isn't a VPN for the rest of the phone.
- **The certificate** comes from Let's Encrypt through Cloudflare's DNS (the DNS-01 challenge),
  so port 80 never opens. Inside all that, Den's own sign-in stands as before: every device was let
  in by a parent, and the hub keeps [the public posture](#settings) anyway.

### Who can reach this server

> | Port | Open to | Why |
> | --- | --- | --- |
> | TCP 443: Den, through Caddy | Each home's current public address (its IPv4 address, and its IPv6 /64), from its DDNS name; the family's devices on Tailscale | Den itself |
> | UDP and TCP 53: dnsmasq | The family's devices on Tailscale (it listens on the server's Tailscale address only) | Sends `den.example.com` through the tunnel |
> | TCP 22: SSH | Admins on Tailscale. While you set up, also the address you installed from, until you've said SSH over Tailscale works | Looking after the server |
> | UDP 41641: Tailscale | Anyone, but WireGuard answers only devices of your tailnet: to everyone else it looks closed | Direct connections, instead of Tailscale's relays |
> | Everything else: port 80, the hub's port 47733 (on `127.0.0.1` only anyway), ping, any port a container ever publishes | Nobody. Dropped without an answer, IPv4 and IPv6 | |
>
> The name and the server's address are public (DNS, and the log every certificate goes in), but
> nothing answers there. One nftables table, `inet den_fw` with policy drop, decides; Docker's
> and Tailscale's rules sit beside it and can't open what it drops. On the tailnet, the policy in
> `tailscale-acl.hujson` lets the family reach this server's 443 and 53 and nothing else.
> `sudo den-allowlist --dry-run` shows what the firewall lets in right now.

### What you need (private)

- **A server**, as for the other setups ([What you need](#what-you-need)): 2 GB of memory,
  Ubuntu 24.04 or Debian 12. If the provider puts a firewall of its own in front of it, open TCP
  443 and UDP 41641 there (and TCP 22 while you set up), or leave it off: the server's own
  firewall is the one that decides.
- **A domain on Cloudflare** (its DNS, on any plan). Den gets a name in it, like
  `den.smith.family`.
- **A Cloudflare API token** for the certificate. In Cloudflare: My Profile, API Tokens, Create
  Token, Create Custom Token, with two permissions, **Zone / Zone / Read** and
  **Zone / DNS / Edit**, and Zone Resources **Include, Specific zone,** your domain. Caddy finds
  the zone with the first and writes the challenge's TXT record with the second.
- **A DDNS name for each home**, on Cloudflare as **DNS only** (grey cloud), kept pointed at the
  home's public address by something there: the router's DDNS client, Home Assistant's Cloudflare
  integration, a script on a computer that's always on. See [Home addresses](#home-addresses).
- **A Tailscale account.** The free Personal plan allows 6 users, each with as many devices as
  they like (since April 2026: [tailscale.com/pricing](https://tailscale.com/pricing)).
- **Your own computer on the tailnet**, for SSH.

### Before you install: the tailnet

1. Make a tailnet for the family at [tailscale.com](https://tailscale.com). If Den joins a tailnet
   you already use, merge the policy below into yours instead of replacing it.
2. In the admin console, **Access controls**: paste `deploy/private/tailscale-acl.hujson`, put
   the family's sign-in emails in `group:family` and yours in `group:admins`, and save. Tailscale
   runs the tests at its end as it saves.
3. **Users, Invite users**: invite everyone in the family ([users or sharing](#users-or-sharing)).
4. Install Tailscale on your computer and sign in.

### Install (private)

On the server, as a user with sudo, or as root:

```sh
git clone https://github.com/xattribution/den.git
cd den/deploy/private
sudo ./install.sh
```

(`git clone` asks for a token: see [Install (setup A)](#install-setup-a).) It asks for the
domain, the Cloudflare token and the homes' DDNS names, and prints a Tailscale link: open it and
sign in as yourself, so the server joins as `tag:den-server` (or run it as
`sudo TS_AUTHKEY=tskey-... ./install.sh` with an auth key for that tag). In order, it:

1. installs nftables, Docker (from Docker's repository) and Tailscale (with its install script);
2. writes `.env` (readable by root only), with a new backup passphrase: copy it into your
   password manager (`grep PASSPHRASE .env`);
3. joins the tailnet as `tag:den-server`, leaving the server's own DNS alone
   (`--accept-dns=false`), and turns on Tailscale's updates;
4. turns on nightly security updates, with a reboot at 04:30 (server time) when one needs it;
5. makes SSH key-only, once your account has a key (otherwise it leaves passwords on and says how
   to add one);
6. installs the firewall (`/etc/den/den_fw.nft`), `den-allowlist` and its timer. If you're
   connected over SSH from the internet, it asks you to try SSH over Tailscale first; unless you
   say it works, it keeps the address you're connected from allowed (`DEN_SSH_ALLOW` in `.env`).
   The session you're in stays up either way: the firewall keeps open connections;
7. builds and starts the hub, Caddy and dnsmasq (about 10 minutes the first time);
8. prints what's left, below.

Run it again any time, after `git pull` or a change to `.env`: it changes only what isn't right
yet. `sudo ./install.sh --check` says what it would do and changes nothing.

### After the install

1. **Public DNS.** In Cloudflare, an `A` record for `den.example.com` with the server's public
   IPv4 address, **DNS only** (an `AAAA` too, if you like: [Home addresses](#home-addresses)).
2. **Split DNS.** Tailscale admin console, **DNS**, **Nameservers**, **Add nameserver**,
   **Custom**: the server's Tailscale address (`tailscale ip -4`; install.sh prints it), with
   **Restrict to domain** on, for `den.example.com`. Only that name goes to the server: if it's
   ever down, the family's other lookups don't notice. Leave MagicDNS on, as it is by default.
3. **SSH over Tailscale.** From your computer, `ssh root@100.x.y.z` (or the server's name in the
   admin console). Once that works, take your address out of `DEN_SSH_ALLOW` in `.env`, if
   install.sh put it there, and run `sudo systemctl start den-allowlist`.
4. **A password, for the console.** If install.sh said your account has none, give it one
   (`sudo passwd root`, or your user): SSH won't take it, but the VPS provider's web console asks
   for it, and that console is the way in if the network ever isn't.
5. **The first parent**, at home (with Private Relay off for the home Wi-Fi) or anywhere with
   Tailscale on: the steps after the setup code in [Install (setup A)](#install-setup-a). Then send
   the family [their message](#for-the-family-private).

### Home addresses

- **DNS only.** A home's DDNS record must be grey cloud: proxied, it resolves to Cloudflare
  instead of the home. den-allowlist refuses Cloudflare's addresses and private ones, logs why,
  and that home keeps its last good addresses.
- **When a home's address changes**, its DDNS client updates the record and the server lets the
  new address in within about 3 minutes, plus the record's TTL (5 minutes for Cloudflare's
  "Auto"). Meanwhile Tailscale works. When a name can't be looked up at all, the home keeps its
  last good addresses, and the log says so.
- **IPv6.** Each device at home has its own IPv6 address in the home's /64, so the firewall lets
  in the whole /64 around the home's `AAAA` address (`DEN_HOME_V6_PREFIX` in `.env`). That
  needs the `AAAA` to come from a device on the home network (Home Assistant, a NAS, a computer);
  a router that publishes its own outside address puts a different /64 there. When IPv6 is
  dropped, Safari falls back to IPv4 within a moment, so a mismatch is slow, not broken. Simplest:
  give `den.example.com` only an `A` record, and everything at home uses IPv4.
- **Shared addresses.** Some internet providers put many customers behind one public IPv4
  address (carrier-grade NAT, common with mobile and satellite home internet). Allowing it would
  let those neighbours reach port 443 too, where Den's sign-in still stops them; better to leave
  that home out of `DEN_HOMES` and use Tailscale there, or its IPv6.
- **Changing the list:** edit `DEN_HOMES` in `.env`, then `sudo systemctl start den-allowlist`.
  A home with a fixed address and no DDNS name goes in `DEN_ALLOW_EXTRA`.

### Tailscale on the phones

Once per phone: install Tailscale from the App Store, sign in with the invited account, and
allow the VPN configuration. Then in the app, the profile picture, **VPN On Demand**: turn it on
and set Wi-Fi and Cellular to **Always**, so it connects by itself after restarts and network
changes. Leave Tailscale's DNS settings on, as they are by default: split DNS needs them.

What it costs: the VPN icon in the status bar, and a little battery. Tailscale carries only
traffic for the tailnet, Den and the lookup of its name; everything else goes as it always did,
unless someone picks an exit node. Don't (the policy allows none anyway).

#### Users or sharing

- **Users** (the fit for a family): everyone joins the tailnet (Users, Invite users). They get the
  tailnet's split DNS by themselves, and `group:family` covers them. Six users fit on the free
  plan, with any number of devices; a child without an account can sign in to Tailscale as a
  parent on their own device (in Den they're still themselves).
- **Sharing the machine** (Machines, the server's menu, Share) gives the server to someone who
  stays in their own tailnet, and must be its admin to accept. Their tailnet's DNS settings
  apply, not yours, so each of them adds the same split-DNS nameserver in their own admin
  console; in the policy, add `autogroup:shared` to the first grant's `src`. It fits a relative
  who already runs a tailnet of their own.

### For the family (private)

Send this, with your family's address in it:

1. **At home**, turn off iCloud Private Relay for the home Wi-Fi: Settings, Wi-Fi, tap the (i)
   next to the home network, and turn off **iCloud Private Relay** (on older iPhones, **Limit IP
   Address Tracking**). With it on, Safari's requests come from Apple's relay instead of from home, and
   Den won't open.
2. **For everywhere else**, install Tailscale from the App Store, sign in with the invitation you
   got, and turn on VPN On Demand (the profile picture, VPN On Demand, Wi-Fi and Cellular:
   Always).
3. Open **https://den.example.com** in Safari, at home or with Tailscale on. Tap **Share**, then
   **Add to Home Screen**, then **Add**, and open Den from the Home Screen.
4. **Calendar:** when you turn on **Show Den in iPhone Calendar**, and the iPhone shows where it
   adds the calendar, choose **On My iPhone**, not iCloud: iCloud would fetch it from Apple's
   servers, which can't reach your hub. (Added to iCloud already? Delete it in the Calendar app
   and turn it on again.)

### Everyday commands (private)

From `den/deploy/private`, with `sudo` (or as root). [Everyday commands](#everyday-commands),
[Updating](#updating), [Backups](#backups) and [Admin and reset](#admin-and-reset) work the same
from this folder, with your address in place of `https://den.example.com`; the firewall and
Tailscale stay as they are through a reset. What differs or adds:

| Task | Command |
| --- | --- |
| Health | `docker compose ps` (the hub should say `healthy`). `/health` answers only from the homes and over Tailscale |
| Logs | `docker compose logs -f --tail 100 hub` (`caddy` for the certificate, `dnsmasq` for lookups) |
| Who can reach the server now | `den-allowlist --dry-run` |
| The firewall's log: homes' new addresses, failed lookups | `journalctl -u den-allowlist -n 50` |
| After changing `DEN_HOMES`, `DEN_ALLOW_EXTRA` or the SSH settings in `.env` | `systemctl start den-allowlist` |
| The firewall as loaded | `nft list table inet den_fw` |
| Tailscale | `tailscale status` |
| Restore | As in [Restore](#restore); then open Den on a phone at home or with Tailscale on, as the hub waits for one to sync (`den_hub status` says `Catching up after a restore` until then) |
| Update | A backup and `docker tag den-hub den-hub:previous` as in [Updating](#updating), then `git pull` and `./install.sh`: it updates the firewall and its units too, and runs `docker compose up -d --build` |

**Backups off the server** go over Tailscale, as SSH is closed to the internet: with the
server's Tailscale name or address,
`scp 'root@den-server:den/deploy/private/backups/*.denbackup' ~/den-backups/`. The nightly
crontab line is the one in [Backups](#backups), with `deploy/private` in it.

### Moving a private server

The family keeps the address and the hub, as in [Moving to a new server](#moving-to-a-new-server);
the private setup also moves the names that point at the server. Your computer reaches the old
server over Tailscale, and the new one at its public address until it joins.

1. **The new server.** `git clone` as in [Install (private)](#install-private), then from your
   computer copy `.env` across:
   `scp -3 root@old-den:den/deploy/private/.env root@<new address>:den/deploy/private/.env`.
   On the new server, `sudo ./install.sh`: it joins the tailnet as `tag:den-server` too, sets up
   the firewall and starts an empty hub.
2. **Back up the old one**, with its hub stopped:
   `docker compose stop hub && docker compose run --rm backup`.
3. **Copy the backup**, from your computer, over Tailscale both ways now:
   `scp -3 'root@old-den:den/deploy/private/backups/den-*.denbackup' root@new-den:den/deploy/private/backups/`.
4. **Restore on the new one:** `docker compose stop hub`, then
   `docker compose run --rm backup restore backups/den-2026-10-28-0317.denbackup` (the newest),
   then `docker compose up -d`.
5. **Point the names at it:**
   - **Public DNS:** the `A` (and `AAAA`) record of `den.example.com`, to the new public address.
   - **Split DNS:** Tailscale admin console, DNS, the nameserver for `den.example.com`, to the new
     server's Tailscale address (`tailscale ip -4` there).
   - **The tailnet policy:** nothing to change while the new server carries `tag:den-server`
     (if it doesn't: Machines, its menu, Edit ACL tags). Once the old server is off, remove it
     (Machines, its menu, Remove), so the tag means one server again.
   - The homes' DDNS names and the Cloudflare token stay as they are.
6. **Open Den on a phone at home or with Tailscale on**, one that has been in use since the backup
   (the most recent is best), and let it sync: a restored hub writes nothing of its own until a
   phone has ([Restore](#restore)). Then `docker compose exec hub /app/bin/den_hub status` says
   `In a family and serving.` and no longer `Catching up after a restore`. Check from one phone
   at home and one with Tailscale on.
7. **Retire the old one:** `docker compose down` and `tailscale logout` there; delete it a few
   days later.

### Maintenance (private)

- **Updates** install themselves: security updates every night, with a reboot at 04:30 when one
  needs it (delete `/etc/apt/apt.conf.d/52den-unattended-upgrades` to reboot by hand instead),
  and Tailscale's own. After a reboot the firewall loads before the network, with the homes' last
  good addresses, and Den starts by itself. `apt update && apt upgrade -y` any time.
- **Certificates** renew through Cloudflare's DNS about a month ahead, with the token in `.env`.
  If the token is deleted or expires, `docker compose logs caddy` says so weeks before Safari
  would. The current certificate's dates, on the server:

  ```sh
  echo | openssl s_client -connect 127.0.0.1:443 -servername den.example.com 2>/dev/null | openssl x509 -noout -dates
  ```

- **Watching it:** an uptime monitor on the internet can't reach the server; one on the tailnet
  can watch `https://den.example.com/health`. Or `docker compose ps` now and then.
- Disk space, logs and time: as in [Server maintenance](#server-maintenance).

### Closed on purpose

- **No public `/health`.** Docker checks the hub every 30 seconds (`docker compose ps`); from the
  homes and over Tailscale, `/health` answers as usual.
- **AI assistants can't connect.** Claude, ChatGPT and the rest call `/mcp` from their own servers,
  and the firewall drops them. Den's own AI helper and the readers still work: the hub calls out.

To open only MCP and OAuth to one assistant later, keep the one name. The hub's OAuth metadata
names `https://den.example.com` for every endpoint (`DEN_PUBLIC_URL`), so a Tailscale Funnel or a
Cloudflare Tunnel on another name would send the assistant back to an address it can't reach;
and putting `den.example.com` itself behind Cloudflare's proxy or a tunnel would make the phones
at home arrive from Cloudflare instead of from home. What works is letting the assistant's
published addresses reach 443, for those paths only. For Claude, whose servers call from
`160.79.104.0/21` (check Anthropic's current list):

1. In `.env`, `DEN_ALLOW_EXTRA=160.79.104.0/21`; then `sudo systemctl start den-allowlist`.
2. In `Caddyfile`, inside the `{$DEN_DOMAIN}` block, before `reverse_proxy`:

   ```caddyfile
   @assistant_elsewhere {
   	remote_ip 160.79.104.0/21
   	not path /mcp /mcp/* /.well-known/oauth-* /oauth/token /oauth/register
   }
   respond @assistant_elsewhere 404
   ```

   then `docker compose restart caddy`.

The parent who connects it signs in at `/oauth/authorize` in their own browser, at home or over
Tailscale, and approves it in Den as usual ([Connecting AI assistants](#connecting-ai-assistants)).

### Troubleshooting (private)

**Den doesn't open at home.** iCloud Private Relay, most likely: off for the home Wi-Fi. Then,
does the firewall know the home's current address? `sudo den-allowlist --dry-run` lists what it
allows; compare it with the home's address (search "what is my IP" on a computer at home).
`journalctl -u den-allowlist` says when a home's name can't be looked up, is proxied, or moved.

**Den doesn't open with Tailscale on.** Is the phone connected (the Tailscale app says)? Does the
split-DNS nameserver have the server's current Tailscale address? From your computer on the
tailnet, `nslookup den.example.com 100.x.y.z` should answer with that same address. Then
`tailscale status` on the server, and the policy's grants (443 and 53). If only Safari fails
there, turn iCloud Private Relay off for that network to see whether it's the one answering
Safari's lookups instead of Tailscale.

**No certificate.** `docker compose logs caddy` says why; usually the token (both permissions, on
the right zone, in `CLOUDFLARE_API_TOKEN`; after changing it, `docker compose up -d`).

**Locked out of SSH.** Use the VPS provider's web console, with your account's password. From
there, put the address you're at in `DEN_SSH_ALLOW` in `.env` and run
`systemctl start den-allowlist`, or see what `tailscale status` says. To take the firewall away
entirely until you start the timer again:
`systemctl stop den-allowlist.timer && nft delete table inet den_fw`.

### Uninstall (private)

```sh
cd den/deploy/private
docker compose --profile '*' down -v --rmi all
docker image rm den-hub:previous     # if you kept one when updating
docker builder prune -af
systemctl disable --now den-allowlist.timer
systemctl disable den-firewall.service
nft delete table inet den_fw         # from here on, the server has no firewall
rm -f /etc/systemd/system/den-firewall.service /etc/systemd/system/den-allowlist.* /usr/local/sbin/den-allowlist
rm -rf /etc/den /var/lib/den
systemctl daemon-reload
tailscale logout                     # then remove the machine in the admin console
cd && rm -rf den
```

Key-only SSH and the update settings stay (`/etc/ssh/sshd_config.d/10-den.conf`,
`/etc/apt/apt.conf.d/52den-unattended-upgrades`); delete them too if the server goes on without
Den.

## What you need

For setups A to E. Setup P has [its own list](#what-you-need-private), and its install script
does the rest.

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

From `den/deploy/hosted` (setup P: from `den/deploy/private`, with
[a few more](#everyday-commands-private)):

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
`{"ok":true,"api":1,"ready":true}` once the hub is in a family (with setup P, only from the homes
and over Tailscale).

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
approval of every sign-in apply either way. With setup P none of them can connect until you open
these paths to them: [Closed on purpose](#closed-on-purpose). The hub also fetches out (Claude's and ChatGPT's
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
