#!/usr/bin/env bash
# Den, private setup: makes a fresh Ubuntu 24.04 or 26.04, or Debian 12, server into the family's private
# hub, reachable only from the family's homes and over Tailscale (docs/hosting.md, "Private: home
# networks plus Tailscale"). From den/deploy/private:
#
#   sudo ./install.sh           do it; run it again any time (after git pull, after editing .env):
#                               each step looks first and changes only what isn't right yet
#   sudo ./install.sh --check   say what it would do, check what it can, and change nothing
#
# The steps, in order:
#   1. packages: nftables, python3, unattended-upgrades; Docker from Docker's own repository;
#      Tailscale from its install script
#   2. .env: asks for the domain, the Cloudflare token and the homes' DDNS names, and makes a
#      backup passphrase
#   3. Tailscale: joins the tailnet as tag:den-server, leaving this server's own DNS alone
#   4. updates: security updates every night, and a reboot at 04:30 when one needs it
#   5. SSH: keys only, no passwords (only once your account has a key)
#   6. the firewall: table inet den_fw, den-allowlist and its timer. SSH from the internet closes
#      only once you've said SSH over Tailscale works; until then the address you're connected
#      from stays allowed
#   7. Den: builds and starts the hub, Caddy and dnsmasq
#   8. prints what's left to do by hand
set -euo pipefail

CHECK=0
case "${1:-}" in
  "") ;;
  --check) CHECK=1 ;;
  -h | --help) sed -n '2,22p' "$0"; exit 0 ;;
  *) echo "Usage: sudo ./install.sh [--check]" >&2; exit 64 ;;
esac

cd "$(dirname "$(readlink -f "$0")")"
HERE=$PWD
INTERACTIVE=0
[ -t 0 ] && [ "$CHECK" = 0 ] && INTERACTIVE=1
LATER=()   # things to tell the owner at the end

step() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
later() { LATER+=("$*"); info "$*"; }
stop() { printf '\nStopped: %s\n' "$*" >&2; exit 1; }

# run CMD...: runs it and shows it; with --check, only shows it.
run() {
  if [ "$CHECK" = 1 ]; then info "would run: $*"; else info "\$ $*"; "$@"; fi
}

# put FILE MODE < content: writes FILE unless it already holds exactly that. Sets CHANGED.
put() {
  local file=$1 mode=$2 new
  new=$(cat; printf x)
  CHANGED=0
  if [ -f "$file" ] && [ "$(cat "$file"; printf x)" = "$new" ]; then
    info "unchanged: $file"
    return 0
  fi
  CHANGED=1
  if [ "$CHECK" = 1 ]; then info "would write: $file"; return 0; fi
  mkdir -p "$(dirname "$file")"
  printf '%s' "${new%x}" > "$file.den-new"
  chmod "$mode" "$file.den-new"
  mv "$file.den-new" "$file"
  info "wrote: $file"
}

# env_get KEY: KEY's value in .env (the last one, without quotes), or nothing.
env_get() {
  [ -f .env ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" .env | tail -n 1 |
    sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/" -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//'
}

# env_set KEY VALUE: sets KEY in .env, in place of its line (or of its "# KEY=" example).
env_set() {
  local key=$1 value=$2 escaped
  escaped=$(printf '%s' "$value" | sed 's/[\\&|]/\\&/g')
  if [ "$CHECK" = 1 ]; then info "would set $key in .env"; return 0; fi
  if grep -q "^$key=" .env; then
    sed -i "s|^$key=.*|$key=$escaped|" .env
  elif grep -q "^# $key=" .env; then
    sed -i "0,/^# $key=.*/s||$key=$escaped|" .env
  else
    printf '%s=%s\n' "$key" "$value" >> .env
  fi
}

in_network() { # in_network ADDRESS NETWORK: is the address in it?
  python3 -c 'import ipaddress, sys; sys.exit(ipaddress.ip_address(sys.argv[1]) not in ipaddress.ip_network(sys.argv[2]))' "$1" "$2" 2>/dev/null
}

# ---------------------------------------------------------------------------------------------
step "0. This server"

[ "$(id -u)" = 0 ] || stop "run it as root: sudo ./install.sh"
. /etc/os-release
case "$ID:$VERSION_ID" in
  ubuntu:24.04 | ubuntu:26.04 | debian:12) info "$PRETTY_NAME" ;;
  *)
    [ "${DEN_ANY_OS:-0}" = 1 ] || stop "this is written for Ubuntu 24.04 and 26.04 and Debian 12, and this is $PRETTY_NAME. To try anyway: sudo DEN_ANY_OS=1 ./install.sh"
    info "$PRETTY_NAME (not tested; going on because DEN_ANY_OS=1)"
    ;;
esac
[ "$CHECK" = 1 ] && info "--check: nothing on this server changes"

# ---------------------------------------------------------------------------------------------
step "1. Packages"

missing=()
for p in ca-certificates curl nftables python3 unattended-upgrades openssl iproute2; do
  dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
done
if [ ${#missing[@]} -gt 0 ]; then
  run apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
else
  info "nftables, python3, unattended-upgrades and the rest are installed"
fi

# Docker from Docker's own repository (docs.docker.com/engine/install), for Compose and current
# releases.
if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  info "Docker: $(docker --version)"
elif command -v docker >/dev/null; then
  stop "Docker is installed, but without Compose. Remove the distribution's package (apt-get remove docker.io) and run this again, or install docker-compose-plugin."
else
  run install -m 0755 -d /etc/apt/keyrings
  run curl -fsSL "https://download.docker.com/linux/$ID/gpg" -o /etc/apt/keyrings/docker.asc
  run chmod a+r /etc/apt/keyrings/docker.asc
  put /etc/apt/sources.list.d/docker.sources 644 <<EOF
Types: deb
URIs: https://download.docker.com/linux/$ID
Suites: $VERSION_CODENAME
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  run apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

# Tailscale from its own install script, which adds Tailscale's repository for this system.
if command -v tailscale >/dev/null; then
  info "Tailscale: $(tailscale version | head -n 1)"
else
  if [ "$CHECK" = 1 ]; then
    info "would run: curl -fsSL https://tailscale.com/install.sh | sh"
  else
    info "\$ curl -fsSL https://tailscale.com/install.sh | sh"
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
fi

# ---------------------------------------------------------------------------------------------
step "2. Settings (.env)"

if [ ! -f .env ]; then
  if [ "$CHECK" = 1 ]; then
    info "would copy env.example to .env and ask for the values below"
  else
    cp env.example .env
    info "made .env from env.example"
  fi
fi
[ -f .env ] && [ "$CHECK" = 0 ] && chmod 600 .env

missing=()

domain=$(env_get DEN_DOMAIN)
if [ -z "$domain" ] || [ "$domain" = den.example.com ]; then
  if [ "$INTERACTIVE" = 1 ]; then
    read -rp "   The address the family opens, on your Cloudflare domain (like den.smith.family): " domain
    domain=${domain#https://}; domain=${domain%%/*}
    [ -n "$domain" ] || stop "Den needs an address."
    env_set DEN_DOMAIN "$domain"
  else
    missing+=(DEN_DOMAIN)
  fi
fi

token=$(env_get CLOUDFLARE_API_TOKEN)
if [ -z "$token" ]; then
  if [ "$INTERACTIVE" = 1 ]; then
    info "A Cloudflare API token: dash.cloudflare.com, My Profile, API Tokens, Create Token, Create"
    info "Custom Token, with Zone / Zone / Read and Zone / DNS / Edit, for the zone of $domain only."
    read -rsp "   Paste the token (it isn't shown): " token
    echo
    [ -n "$token" ] || stop "Caddy needs the token to get the certificate."
    env_set CLOUDFLARE_API_TOKEN "$token"
  else
    missing+=(CLOUDFLARE_API_TOKEN)
  fi
fi

homes=$(env_get DEN_HOMES)
if [ -z "$homes" ] || [[ "$homes" == *home-one.example.com* ]]; then
  if [ "$INTERACTIVE" = 1 ]; then
    info "Each home's DDNS name: a name on Cloudflare (DNS only) that the home keeps pointed at its"
    info "public address, like home.smith.family. Leave it empty for Tailscale only."
    read -rp "   The homes' DDNS names, separated by spaces: " homes
    env_set DEN_HOMES "$homes"
  else
    missing+=(DEN_HOMES)
  fi
fi

if [ -z "$(env_get DEN_BACKUP_PASSPHRASE)" ]; then
  if [ "$CHECK" = 1 ]; then
    info "would make DEN_BACKUP_PASSPHRASE"
  else
    env_set DEN_BACKUP_PASSPHRASE "$(openssl rand -base64 24)"
    later "Made a backup passphrase. Copy it into your password manager now (grep PASSPHRASE .env): a backup doesn't open without it."
  fi
fi

if [ ${#missing[@]} -gt 0 ]; then
  if [ "$CHECK" = 1 ]; then
    info "missing from .env (asked for when run without --check): ${missing[*]}"
  else
    stop "set ${missing[*]} in .env (or run this in a terminal, where it asks), then run it again."
  fi
fi

if [ -n "$token" ] && [ -n "$domain" ]; then
  # Caddy needs the token to see the domain's zone (Zone:Read) and change its records (DNS:Edit).
  # Exit 1: the token is wrong; 3: Cloudflare couldn't be asked.
  set +e
  CF_TOKEN=$token python3 - "$domain" <<'PY'
import json, os, sys, urllib.error, urllib.request
def get(path):
    req = urllib.request.Request("https://api.cloudflare.com/client/v4" + path,
                                 headers={"Authorization": "Bearer " + os.environ["CF_TOKEN"]})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return json.load(e)
    except Exception as e:
        print("   Couldn't ask Cloudflare about the token (%s); Caddy will say if it's wrong." % e)
        sys.exit(3)
if not get("/user/tokens/verify").get("success"):
    print("   Cloudflare says the token isn't valid (or has expired).")
    sys.exit(1)
labels = sys.argv[1].split(".")
for i in range(len(labels) - 1):
    zone = ".".join(labels[i:])
    found = get("/zones?name=" + zone).get("result") or []
    if found:
        if not get("/zones/%s/dns_records?per_page=1" % found[0]["id"]).get("success"):
            print("   The token sees the zone %s but not its records: give it Zone / DNS / Edit." % zone)
            sys.exit(1)
        print("   The Cloudflare token sees the zone %s and its DNS records." % zone)
        sys.exit(0)
print("   The token sees no zone for %s: give it Zone / Zone / Read and Zone / DNS / Edit on it." % sys.argv[1])
sys.exit(1)
PY
  verdict=$?
  set -e
  if [ "$verdict" = 1 ] && [ "$CHECK" = 0 ]; then
    stop "fix CLOUDFLARE_API_TOKEN in .env, then run this again."
  fi
fi

# ---------------------------------------------------------------------------------------------
step "3. Tailscale"

ts_json() { tailscale status --json 2>/dev/null || true; }
ts_field() { # ts_field EXPR: a value from `tailscale status --json`
  ts_json | python3 -c "import json, sys
try: s = json.load(sys.stdin)
except Exception: s = {}
print($1)" 2>/dev/null || true
}

TS_IP=
if ! command -v tailscale >/dev/null; then
  info "would sign this server in to your tailnet as tag:den-server"
else
  state=$(ts_field 's.get("BackendState", "")')
  if [ "$state" != Running ]; then
    info "Signing this server in to your tailnet as tag:den-server. The tailnet policy"
    info "(tailscale-acl.hujson) must be in place first, with you in group:admins."
    info "It prints a link: open it and sign in as an admin. (Or: sudo TS_AUTHKEY=tskey-... ./install.sh)"
    up=(tailscale up --accept-dns=false --advertise-tags=tag:den-server)
    if [ "$CHECK" = 1 ]; then
      info "would run: ${up[*]}"
    elif ! "${up[@]}" ${TS_AUTHKEY:+--auth-key="$TS_AUTHKEY"}; then
      stop "Tailscale didn't take the server. Is tailscale-acl.hujson saved in the admin console (Access controls), with your sign-in email in group:admins?"
    fi
  else
    # The server's own lookups go to its provider's DNS, never through its own dnsmasq.
    run tailscale set --accept-dns=false
  fi
  # Tailscale updates itself (from its repository), so security fixes come without a visit.
  run tailscale set --auto-update=true || later "Tailscale didn't take --auto-update; update it with apt like the rest."
  TS_IP=$(tailscale ip -4 2>/dev/null | head -n 1 || true)
  if [ "$CHECK" = 0 ]; then
    [ -n "$TS_IP" ] || stop "Tailscale isn't up (tailscale status says why). Run this again once it is."
    tags=$(ts_field '" ".join(s.get("Self", {}).get("Tags") or [])')
    [[ " $tags " == *" tag:den-server "* ]] ||
      later "This server isn't tagged tag:den-server, so the tailnet policy gives nobody access to it. In the admin console, Machines, this server's menu, Edit ACL tags: add tag:den-server."
  fi
  info "This server on the tailnet: ${TS_IP:-not yet}"
fi

# ---------------------------------------------------------------------------------------------
step "4. Automatic updates"

put /etc/apt/apt.conf.d/20auto-upgrades 644 <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
put /etc/apt/apt.conf.d/52den-unattended-upgrades 644 <<'EOF'
// Den, private setup (deploy/private/install.sh): security updates install every night; when one
// needs a reboot (a new kernel), the server reboots at 04:30, server time. Den, the firewall and
// Tailscale come back by themselves.
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:30";
EOF

# ---------------------------------------------------------------------------------------------
step "5. SSH: keys only"

login_user=${SUDO_USER:-root}
login_home=$(getent passwd "$login_user" | cut -d: -f6 || true)
if grep -qE '(^|[[:space:]])(ssh-(ed25519|rsa)|ecdsa-sha2-nistp[0-9]+|sk-[a-z0-9@.-]+) AAAA' "$login_home/.ssh/authorized_keys" 2>/dev/null; then
  put /etc/ssh/sshd_config.d/10-den.conf 644 <<'EOF'
# Den, private setup (deploy/private/install.sh): sign in with a key only. This file sorts before
# the others in this folder (50-cloud-init.conf sets passwords on some images), and for sshd the
# first value it reads wins.
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
  if [ "$CHANGED" = 1 ] && [ "$CHECK" = 0 ]; then
    sshd -t || { rm -f /etc/ssh/sshd_config.d/10-den.conf; stop "sshd didn't accept the change; nothing changed."; }
    systemctl reload ssh.service 2>/dev/null || systemctl reload sshd.service 2>/dev/null || true
  fi
  sshd_now=$(sshd -T 2>/dev/null || true)   # what sshd will actually do
  if [ "$CHECK" = 0 ] && ! grep -qx 'passwordauthentication no' <<<"$sshd_now"; then
    later "SSH still accepts passwords: another file in /etc/ssh/sshd_config.d sorts first. grep -ri passwordauthentication /etc/ssh"
  fi
  info "$login_user has a key; passwords are off"
else
  later "SSH passwords stay on: $login_user has no key in $login_home/.ssh/authorized_keys. Add yours (ssh-copy-id $login_user@<server> from your computer), then run this again."
fi
# The provider's web console is the way back in if the network ever isn't, and it asks for a
# password: SSH never takes it (keys only), but the console does.
if [ "$(passwd -S "$login_user" 2>/dev/null | awk '{print $2}')" != P ]; then
  later "$login_user has no password, so the VPS provider's web console couldn't log you in if SSH ever fails. Give it one: sudo passwd $login_user (SSH still won't accept it; keys only)."
fi
SSH_PORT=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}' | head -n 1 || true)
SSH_PORT=${SSH_PORT:-22}

# ---------------------------------------------------------------------------------------------
step "6. The firewall"

# One ruleset, ours. ufw or firewalld would be a second one with its own idea of what's open.
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
  info "ufw is on; Den's firewall replaces it"
  run ufw disable
fi
if systemctl is-active --quiet firewalld 2>/dev/null; then
  info "firewalld is on; Den's firewall replaces it"
  run systemctl disable --now firewalld
fi
if systemctl is-enabled --quiet nftables.service 2>/dev/null; then
  later "nftables.service is enabled. Leave it alone or disable it: its /etc/nftables.conf starts with 'flush ruleset', which also wipes Docker's and Tailscale's rules if it's ever restarted."
fi

# Where is this SSH session from? sudo drops SSH_CONNECTION, so look in the processes above.
session=${SSH_CONNECTION:-}
pid=$$
while [ -z "$session" ] && [ "${pid:-1}" -gt 1 ]; do
  session=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^SSH_CONNECTION=//p' | head -n 1 || true)
  pid=$(awk '/^PPid:/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo 1)
done
client_ip=${session%% *}
ssh_allow=$(env_get DEN_SSH_ALLOW)
if [ -z "$session" ]; then
  info "Not over SSH (the provider's console?): SSH will be open over Tailscale only."
elif in_network "$client_ip" 100.64.0.0/10 || in_network "$client_ip" fd7a:115c:a1e0::/48; then
  info "You're connected over Tailscale ($client_ip): SSH will be open over Tailscale only."
elif [[ " $ssh_allow " == *" $client_ip "* ]]; then
  later "SSH stays open to $client_ip (DEN_SSH_ALLOW in .env) besides Tailscale. Once SSH over Tailscale works for you, take it out of .env and run: sudo systemctl start den-allowlist"
else
  info "You're connected from $client_ip, over the internet. This session stays up either way"
  info "(the firewall keeps connections that are already open), but new ones will need Tailscale."
  ok=n
  if [ "$INTERACTIVE" = 1 ] && [ -n "${TS_IP:-}" ]; then
    info "From a computer on your tailnet (as a member of group:admins), open a new terminal and try:"
    info "    ssh $login_user@$TS_IP"
    read -rp "   Did that sign you in? [y/N] " ok
  fi
  if [[ "$ok" == [yY]* ]]; then
    info "Good: SSH will be open over Tailscale only."
  else
    env_set DEN_SSH_ALLOW "${ssh_allow:+$ssh_allow }$client_ip"
    later "SSH stays open to $client_ip (DEN_SSH_ALLOW in .env) besides Tailscale, so you aren't locked out. Once ssh $login_user@${TS_IP:-<tailscale address>} works, take it out of .env and run: sudo systemctl start den-allowlist"
  fi
fi
later "If SSH ever fails, the VPS provider's web console still works: it doesn't go through the network."

put /etc/den/den_fw.nft 644 < <(sed "s/^define SSH_PORT = .*/define SSH_PORT = $SSH_PORT/" nftables/den_fw.nft)
table_changed=$CHANGED
put /usr/local/sbin/den-allowlist 755 < den-allowlist
for unit in den-firewall.service den-allowlist.service den-allowlist.timer; do
  put "/etc/systemd/system/$unit" 644 < "systemd/$unit"
done
if [ "$(readlink /etc/den/env 2>/dev/null || true)" != "$HERE/.env" ]; then
  run mkdir -p /etc/den
  run ln -sfn "$HERE/.env" /etc/den/env
fi

if [ "$CHECK" = 1 ]; then
  if nft -c -f <(sed "s/^define SSH_PORT = .*/define SSH_PORT = $SSH_PORT/" nftables/den_fw.nft) 2>/dev/null; then
    info "nft accepts the ruleset (nft -c)"
  else
    info "nft -c couldn't check the ruleset here (it needs root on a real kernel)"
  fi
  info "What it would let in now:"
  if [ -f .env ]; then
    ./den-allowlist --dry-run --config .env 2>&1 | sed 's/^/     /' || true
  else
    info "(nothing yet: .env doesn't exist)"
  fi
  run systemctl enable den-firewall.service den-allowlist.timer
  run systemctl restart den-firewall.service
  run systemctl start den-allowlist.service den-allowlist.timer
else
  nft -c -f /etc/den/den_fw.nft
  systemctl daemon-reload
  run systemctl enable den-firewall.service den-allowlist.timer
  if [ "$table_changed" = 1 ] || ! nft list table inet den_fw >/dev/null 2>&1; then
    run systemctl restart den-firewall.service
  fi
  run systemctl start den-allowlist.service
  run systemctl start den-allowlist.timer
  info "What it lets in now:"
  journalctl -u den-allowlist.service -n 20 --no-pager -o cat 2>/dev/null | sed 's/^/     /' || true
  /usr/local/sbin/den-allowlist --dry-run 2>&1 | sed -n '/^HTTPS\|^SSH\|^Tailscale/s/^/     /p' || true
fi

# ---------------------------------------------------------------------------------------------
step "7. Den"

mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
swap_kb=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
if [ -z "$(env_get DEN_IMAGE)" ] && [ "$((mem_kb + swap_kb))" -lt 1800000 ]; then
  later "Building the hub needs about 1.5 GB of memory, and this server has less (with swap). If the build stops with 'exit code -9', add swap (docs/hosting.md, \"Building on a small server\") and run this again."
fi
if [ "$CHECK" = 1 ]; then
  if command -v docker >/dev/null && [ -f .env ]; then
    if docker compose config --quiet; then
      info "compose.yaml and .env go together"
    else
      info "compose.yaml and .env don't go together yet: docker compose config says why, above"
    fi
  fi
  info "would run: docker compose up -d --build --wait"
else
  if [ -n "$(env_get DEN_IMAGE)" ]; then
    run docker compose build caddy dnsmasq
    run docker compose up -d --wait --wait-timeout 600
  else
    info "The first build of the hub takes about 10 minutes."
    run docker compose up -d --build --wait --wait-timeout 1200
  fi
  docker compose ps
fi

# ---------------------------------------------------------------------------------------------
step "8. What's left"

v4=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1 || true)
v6=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | sed -n 's/.* src \([0-9a-f:]*\).*/\1/p' | head -n 1 || true)
name=$(env_get DEN_DOMAIN)
name=${name:-den.example.com}
v4=${v4:-"<the server's public IPv4>"}
ts=${TS_IP:-"<the server's Tailscale address: tailscale ip -4>"}
aaaa=""
[ -n "$v6" ] && aaaa=$(printf '\n        AAAA  %s   %s   (optional: see docs/hosting.md, "Home addresses")' "$name" "$v6")
cat <<EOF

   1. Public DNS, in Cloudflare (your domain, DNS, Records), DNS only (grey cloud):
        A     $name   $v4$aaaa
      (If that A address starts with 10., 172.16-31. or 192.168., your provider puts the public
      address in front of the server: use the one its dashboard shows.)

   2. Tailscale admin console, DNS, Nameservers, Add nameserver, Custom:
        Nameserver $ts, Restrict to domain on, domain $name

   3. The first parent's iPhone, once 1 and 2 are done, at home (iCloud Private Relay off for the
      home Wi-Fi) or with Tailscale on: scan the code below with the Camera, add Den to the Home
      Screen as Safari shows, open it from there and tap Create family. Again any time:
        docker compose exec hub /app/bin/den_hub setup-link

   4. Who can reach this server, any time: sudo den-allowlist --dry-run
EOF
if [ ${#LATER[@]} -gt 0 ]; then
  printf '\n   And:\n'
  for line in "${LATER[@]}"; do printf '   - %s\n' "$line"; done
fi
echo

# The first parent's setup link, with its QR code (only while the hub isn't in a family yet).
if [ "$CHECK" != 1 ]; then
  docker compose exec -T hub /app/bin/den_hub setup-link 2>/dev/null | sed 's/^/   /' || true
  echo
fi
