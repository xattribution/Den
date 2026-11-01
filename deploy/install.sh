#!/bin/sh
# Den's installer: makes any Linux computer (an old PC, a mini PC, a Raspberry Pi 4 or 5 with the
# 64-bit system, a VPS) the family's Den server, with one command and nothing to edit:
#
#   curl -fsSL https://get.kotvas.app | sudo sh
#   curl -fsSL https://get.kotvas.app | sudo sh -s -- --token eyJ...   (with the tunnel's token)
#
# Once installed it is also the server's `den` command (sudo den help). Run the installer again
# any time: it repairs what's broken and updates Den. docs/install-technical.md says how it works.
#
#   den [install]        install, repair or update (the default)
#   den status           is Den running, set up, reachable, up to date
#   den setup-link       a fresh one-time link for the first parent (until the family is made)
#   den tunnel [TOKEN]   give Den the Cloudflare Tunnel's token (den tunnel off: forget it)
#   den update           update now if there's a new version, going back if it doesn't start
#   den logs             what Den has been saying (Ctrl-C stops)
#   den reset            start over: deletes the family's data on this computer (asks first)
#   den uninstall        remove Den (asks whether to keep the family's data)
#
# Options: --dry-run (say what it would do, change nothing), --token TOKEN, --yes (don't ask;
# uninstall then keeps the data), --replace-podman, --image REF, --lan, --local-only.
#
# POSIX sh, so `curl ... | sudo sh` works with dash, bash or busybox. Everything is inside
# functions and the last line calls main, so a download cut short runs nothing.

DEN_GET_URL=https://get.kotvas.app
DEN_IMAGE_DEFAULT=ghcr.io/xattribution/den
DEN_CHANNEL_DEFAULT=stable
DEN_PORT=47733
DEN_UID=10001
DEN_SUBNET=172.30.74.0/24
DEN_PROJECT=denhub
MIN_MEM_KB=850000          # a 1 GB computer (the firmware keeps some)
MIN_DISK_KB=2000000        # Docker and two versions of Den
COMPOSE_FALLBACK=v5.6.0    # the Compose plugin, when a Docker without it is already installed
HEALTH_WAIT=${DEN_HEALTH_WAIT:-240}            # seconds an update has to come up healthy before it's undone

# Where things are. Tests point these somewhere else; nobody else needs to.
DEN_DIR=${DEN_DIR:-/opt/den}
DEN_OS_RELEASE=${DEN_OS_RELEASE:-/etc/os-release}
DEN_MEMINFO=${DEN_MEMINFO:-/proc/meminfo}
DEN_DMI_VENDOR=${DEN_DMI_VENDOR:-/sys/class/dmi/id/sys_vendor}
DEN_SYSTEMD_DIR=${DEN_SYSTEMD_DIR:-/etc/systemd/system}
DEN_BIN_DIR=${DEN_BIN_DIR:-/usr/local/bin}

DATA_DIR=$DEN_DIR/data
HUB_DIR=$DATA_DIR/hub
STATE_DIR=$DEN_DIR/state
COMPOSE_FILE=$DEN_DIR/compose.yaml

DRY_RUN=0
ASSUME_YES=0
REPLACE_PODMAN=0
TOKEN_ARG=
NETWORK_MODE=      # lan | local; decided by detect_network unless --lan or --local-only
MODE_FLAG=
IMAGE_FLAG=
IMAGE=${DEN_IMAGE:-$DEN_IMAGE_DEFAULT}
CHANNEL=$DEN_CHANNEL_DEFAULT

# --- talking to people ----------------------------------------------------------------------

say() { printf '%s\n' "$*"; }
step() { printf '\n%s\n' "$*"; }
note() { printf '      %s\n' "$*"; }

# die MESSAGE...: stops, with each argument as a line. The message says what to do next.
die() {
  printf '\n' >&2
  printf 'Den stopped. ' >&2
  for die_line in "$@"; do printf '%s\n' "$die_line" >&2; done
  printf '\nIf you are stuck, send a photo of this screen to the person who gave you the link.\n' >&2
  exit 1
}

can_ask() { [ "$ASSUME_YES" = 0 ] && { : < /dev/tty; } 2>/dev/null; }

# ask PROMPT: reads a line from the terminal (stdin is the script itself under curl | sh).
ask() {
  printf '%s' "$1" > /dev/tty
  IFS= read -r ANSWER < /dev/tty || ANSWER=
}

# run CMD...: runs it, or with --dry-run says it would. `run compose ...` is Den's compose file.
run() {
  if [ "$1" = compose ]; then shift; set -- docker compose -f "$COMPOSE_FILE" "$@"; fi
  if [ "$DRY_RUN" = 1 ]; then
    say "      would run: $*"
    return 0
  fi
  "$@"
}

# quietly CMD...: runs it with its output kept in a log, shown only if it fails.
quietly() {
  if [ "$1" = compose ]; then shift; set -- docker compose -f "$COMPOSE_FILE" "$@"; fi
  if [ "$DRY_RUN" = 1 ]; then
    say "      would run: $*"
    return 0
  fi
  quietly_log=${TMPDIR:-/tmp}/den-install.$$.log
  "$@" > "$quietly_log" 2>&1
  quietly_status=$?
  if [ "$quietly_status" = 0 ]; then
    rm -f "$quietly_log"
    return 0
  fi
  say "      This step failed. Its last words were:"
  tail -n 15 "$quietly_log" | sed 's/^/        | /'
  rm -f "$quietly_log"
  return "$quietly_status"
}

# try CMD...: runs it with no output and doesn't mind if it fails (or says it would).
try() {
  if [ "$1" = compose ]; then shift; set -- docker compose -f "$COMPOSE_FILE" "$@"; fi
  if [ "$DRY_RUN" = 1 ]; then say "      would run: $*"; return 0; fi
  "$@" > /dev/null 2>&1
}

# put FILE MODE: writes stdin to FILE (atomically) unless FILE already holds exactly that.
put() {
  put_new=$(cat; printf x)
  if [ -f "$1" ] && [ "$(cat "$1"; printf x)" = "$put_new" ]; then return 0; fi
  if [ "$DRY_RUN" = 1 ]; then say "      would write: $1"; return 0; fi
  mkdir -p "$(dirname "$1")"
  printf '%s' "${put_new%x}" > "$1.den-new" && chmod "$2" "$1.den-new" && mv -f "$1.den-new" "$1"
}

# --- this computer --------------------------------------------------------------------------

os_field() { # os_field KEY: a value from os-release, without quotes
  sed -n "s/^$1=//p" "$DEN_OS_RELEASE" 2>/dev/null | head -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

# detect_platform: sets OS_ID, OS_NAME, PKG (apt|dnf|pacman|zypper), DOCKER_REPO and
# DOCKER_SUITE (for apt and dnf), ARCH (amd64|arm64); stops on anything Den doesn't run on.
detect_platform() {
  [ -r "$DEN_OS_RELEASE" ] || die "This doesn't look like a Linux computer Den knows (there's no /etc/os-release)." \
    "Den runs on Ubuntu, Debian, Raspberry Pi OS (64-bit), Fedora, Rocky, AlmaLinux, RHEL, Arch and openSUSE."
  OS_ID=$(os_field ID)
  OS_LIKE=$(os_field ID_LIKE)
  OS_NAME=$(os_field PRETTY_NAME)
  OS_VERSION=$(os_field VERSION_ID)
  OS_NAME=${OS_NAME:-$OS_ID}
  PKG='' DOCKER_REPO='' DOCKER_SUITE=''

  case "$OS_ID" in
    ubuntu) PKG=apt DOCKER_REPO=ubuntu DOCKER_SUITE=$(os_field UBUNTU_CODENAME) ;;
    debian) PKG=apt DOCKER_REPO=debian DOCKER_SUITE=$(os_field VERSION_CODENAME) ;;
    raspbian)
      die "This Raspberry Pi is running the 32-bit Raspberry Pi OS, and Den needs the 64-bit one." \
        "Put \"Raspberry Pi OS (64-bit)\" on its card with Raspberry Pi Imager (raspberrypi.com/software)," \
        "then run the same command again." ;;
    fedora) PKG=dnf DOCKER_REPO=fedora ;;
    rhel) PKG=dnf DOCKER_REPO=rhel ;;
    rocky | almalinux | centos | ol) PKG=dnf DOCKER_REPO=centos ;;
    arch | archarm | manjaro | manjaro-arm | endeavouros) PKG=pacman ;;
    opensuse-leap | opensuse-tumbleweed | opensuse-slowroll | sles | sled) PKG=zypper ;;
    opensuse-microos | opensuse-leap-micro | sl-micro)
      die "$OS_NAME updates itself as a whole and can't take Docker the usual way." \
        "Put openSUSE Leap or Tumbleweed, Ubuntu or Debian on this computer instead, then run this again." ;;
    *)
      # Relatives of Ubuntu and Debian (Linux Mint, Pop!_OS, Zorin, elementary, LMDE) use their
      # parent's Docker packages; of Fedora and RHEL, likewise.
      case " $OS_LIKE " in
        *" ubuntu "*)
          PKG=apt DOCKER_REPO=ubuntu DOCKER_SUITE=$(os_field UBUNTU_CODENAME) ;;
        *" debian "*)
          PKG=apt DOCKER_REPO=debian DOCKER_SUITE=$(os_field DEBIAN_CODENAME) ;;
        *" rhel "* | *" centos "*) PKG=dnf DOCKER_REPO=centos ;;
        *" fedora "*) PKG=dnf DOCKER_REPO=fedora ;;
        *" arch "*) PKG=pacman ;;
        *" suse "* | *" opensuse "*) PKG=zypper ;;
        *)
          die "Den doesn't know how to set itself up on $OS_NAME." \
            "It runs on Ubuntu, Debian, Raspberry Pi OS (64-bit), Fedora, Rocky, AlmaLinux, RHEL, Arch and openSUSE." ;;
      esac
      ;;
  esac
  if [ "$PKG" = apt ] && [ -z "$DOCKER_SUITE" ]; then
    die "Den couldn't tell which release of $OS_NAME this is, so it can't pick the right Docker." \
      "Ubuntu 22.04 or newer, or Debian 12 or newer, works."
  fi
  if [ "$PKG" = dnf ] && [ "$DOCKER_REPO" != fedora ]; then
    case "$OS_VERSION" in
      7 | 7.*) die "$OS_NAME is too old for Den. Version 8 or newer works." ;;
    esac
  fi

  machine=$(uname -m)
  case "$machine" in
    x86_64 | amd64) ARCH=amd64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    armv6l | armv7l | armhf | arm*)
      die "This computer's system is 32-bit ARM, and Den needs 64-bit." \
        "On a Raspberry Pi 4 or 5: put \"Raspberry Pi OS (64-bit)\" on its card with Raspberry Pi Imager," \
        "then run the same command again. (A Raspberry Pi 3 or older can't run Den.)" ;;
    i386 | i486 | i586 | i686)
      die "This computer's system is 32-bit, and Den needs a 64-bit one." \
        "Most computers from the last 15 years can run 64-bit Ubuntu or Debian: put one on it, then run this again." ;;
    *)
      die "Den doesn't run on this kind of processor ($machine)." \
        "It needs a 64-bit Intel or AMD computer, or a 64-bit ARM one like a Raspberry Pi 4 or 5." ;;
  esac
  # A 64-bit kernel can run a 32-bit system (Raspberry Pi OS 32-bit on a Pi 4 does).
  if [ "$(getconf LONG_BIT 2>/dev/null || echo 64)" = 32 ]; then
    die "This computer runs a 32-bit system on a 64-bit processor, and Den needs a 64-bit system." \
      "On a Raspberry Pi: put \"Raspberry Pi OS (64-bit)\" on its card with Raspberry Pi Imager, then run this again."
  fi
}

# check_resources: enough memory and disk, in words people know.
check_resources() {
  mem_kb=$(awk '/^MemTotal:/ {print $2}' "$DEN_MEMINFO" 2>/dev/null)
  mem_kb=${mem_kb:-0}
  if [ "$mem_kb" -lt "$MIN_MEM_KB" ]; then
    die "This computer has $((mem_kb / 1024)) MB of memory, and Den needs at least 1 GB." \
      "Use a computer with more memory (a Raspberry Pi 4 or 5 with 2 GB or more is plenty)."
  fi
  MEM_TEXT=$(awk -v k="$mem_kb" 'BEGIN { printf "%.1f GB", k / 1048576 }')
  # Docker keeps its images in /var/lib/docker; Den keeps the family's data in /opt/den.
  disk_where=/var/lib/docker
  [ -d "$disk_where" ] || disk_where=/var/lib
  [ -d "$disk_where" ] || disk_where=/
  free_kb=$(df -Pk "$disk_where" 2>/dev/null | awk 'NR == 2 {print $4}')
  free_kb=${free_kb:-0}
  opt_where=$DEN_DIR
  [ -d "$opt_where" ] || opt_where=$(dirname "$DEN_DIR")
  [ -d "$opt_where" ] || opt_where=/
  opt_free_kb=$(df -Pk "$opt_where" 2>/dev/null | awk 'NR == 2 {print $4}')
  opt_free_kb=${opt_free_kb:-0}
  [ "$opt_free_kb" -lt "$free_kb" ] && free_kb=$opt_free_kb
  if [ "$free_kb" -lt "$MIN_DISK_KB" ]; then
    die "This computer has $((free_kb / 1024)) MB of free disk space, and Den needs at least 2 GB." \
      "Delete some files (or use a bigger card or disk), then run this again."
  fi
  DISK_TEXT=$(awk -v k="$free_kb" 'BEGIN { printf "%.0f GB", k / 1048576 }')
}

is_private_v4() { # is_private_v4 ADDRESS: private, shared (CGNAT, Tailscale) or link-local?
  case "$1" in
    10.* | 192.168.* | 169.254.* | 127.*) return 0 ;;
    172.1[6-9].* | 172.2[0-9].* | 172.3[01].*) return 0 ;;
    100.6[4-9].* | 100.[7-9][0-9].* | 100.1[01][0-9].* | 100.12[0-7].*) return 0 ;;
  esac
  return 1
}

# detect_network: sets LAN_IP (this computer's address on its network, if it has a private one)
# and NETWORK_MODE: `lan` (a computer at home: Den answers the home network on its port, for the
# first setup page) or `local` (a server on the internet: Den answers this computer only, and the
# family comes in through the tunnel).
detect_network() {
  LAN_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1)
  if [ -z "$LAN_IP" ]; then
    LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  fi
  public=
  for dn_addr in $(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1); do
    is_private_v4 "$dn_addr" || public=$dn_addr
  done
  # Cloud servers that keep a private address behind the provider's own public one.
  vendor=$(cat "$DEN_DMI_VENDOR" 2>/dev/null)
  case "$vendor" in
    *"Amazon EC2"* | Google* | DigitalOcean* | Hetzner* | Linode* | Akamai* | Vultr* | OVH* | Scaleway* | OracleCloud* | Alibaba*)
      [ -n "$public" ] || public="($vendor)" ;;
  esac
  if [ -n "$LAN_IP" ] && ! is_private_v4 "$LAN_IP"; then
    public=$LAN_IP
  fi
  # --lan or --local-only, once given, stays the choice for this computer.
  [ -n "$NETWORK_MODE" ] || NETWORK_MODE=$(cat "$STATE_DIR/network-mode" 2>/dev/null)
  case "$NETWORK_MODE" in
    lan | local) ;;
    *) if [ -n "$public" ]; then NETWORK_MODE=local; else NETWORK_MODE=lan; fi ;;
  esac
  [ "$NETWORK_MODE" = local ] && LAN_IP=
  case "$NETWORK_MODE" in
    lan) BIND=0.0.0.0 ;;
    *) BIND=127.0.0.1 ;;
  esac
}

# port_owner: whatever already listens on Den's port (empty if nothing, or if it's Den).
port_owner() {
  command -v ss > /dev/null 2>&1 || return 0
  po_line=$(ss -Hltnp "sport = :$DEN_PORT" 2>/dev/null | head -n 1)
  [ -n "$po_line" ] || return 0
  case "$po_line" in
    *docker-proxy*)
      # Ours, if our hub is the container that has it.
      if docker ps --filter "label=com.docker.compose.project=$DEN_PROJECT" --format '{{.Ports}}' 2>/dev/null | grep -q ":$DEN_PORT->"; then
        return 0
      fi
      echo "another Docker container"
      ;;
    *) printf '%s\n' "$po_line" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -n 1 ;;
  esac
}

# --- Docker ---------------------------------------------------------------------------------

docker_is_podman() {
  command -v docker > /dev/null 2>&1 && docker --version 2>/dev/null | grep -qi podman
}

docker_ok() { docker info > /dev/null 2>&1; }
compose_ok() { docker compose version > /dev/null 2>&1; }

podman_help() {
  die "This computer has Podman, a look-alike of Docker, and Den needs Docker itself." \
    "If nobody uses Podman on this computer (most people don't), let Den replace it:" \
    "" \
    "    curl -fsSL $DEN_GET_URL | sudo sh -s -- --replace-podman" \
    "" \
    "If someone does use Podman here, ask them first."
}

# apt_docker_repo: Docker's own apt repository for this release.
apt_docker_repo() {
  quietly apt-get update || die "Couldn't reach this computer's software sources." \
    "Check that it's connected to the internet, then run the same command again."
  quietly env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl ||
    die "Couldn't install the basic tools Den needs (curl, certificates)." "Run the same command again in a few minutes."
  run install -m 0755 -d /etc/apt/keyrings
  quietly curl -fsSL "https://download.docker.com/linux/$DOCKER_REPO/gpg" -o /etc/apt/keyrings/docker.asc ||
    die "Couldn't reach download.docker.com." "Check that this computer is connected to the internet, then run the same command again."
  run chmod a+r /etc/apt/keyrings/docker.asc
  put /etc/apt/sources.list.d/docker.sources 644 <<EOF
Types: deb
URIs: https://download.docker.com/linux/$DOCKER_REPO
Suites: $DOCKER_SUITE
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  quietly apt-get update || die "Docker doesn't have packages for $OS_NAME ($DOCKER_SUITE) yet." \
    "Ubuntu LTS or Debian stable works best for Den."
}

dnf_docker_repo() {
  quietly curl -fsSL "https://download.docker.com/linux/$DOCKER_REPO/docker-ce.repo" -o /etc/yum.repos.d/docker-ce.repo ||
    die "Couldn't reach download.docker.com." "Check that this computer is connected to the internet, then run the same command again."
}

DOCKER_PKGS="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

install_docker() {
  case "$PKG" in
    apt)
      apt_docker_repo
      # shellcheck disable=SC2086
      quietly env DEBIAN_FRONTEND=noninteractive apt-get install -y $DOCKER_PKGS ||
        die "Docker didn't install." "Run the same command again; if it fails the same way, restart the computer and try once more."
      ;;
    dnf)
      dnf_docker_repo
      if [ "$REPLACE_PODMAN" = 1 ]; then
        quietly dnf -y remove podman-docker || true
        # shellcheck disable=SC2086
        quietly dnf -y install --allowerasing $DOCKER_PKGS || die "Docker didn't install." "Run the same command again."
      else
        # shellcheck disable=SC2086
        if ! quietly dnf -y install $DOCKER_PKGS; then
          if command -v podman > /dev/null 2>&1; then podman_help; fi
          die "Docker didn't install." "Run the same command again; if it fails the same way, restart the computer and try once more."
        fi
      fi
      ;;
    pacman)
      # Arch updates as a whole (a partial update is how Arch breaks), so this updates the system too.
      quietly pacman -Syu --noconfirm --needed docker docker-compose ||
        die "Docker didn't install." "Run the same command again in a few minutes."
      ;;
    zypper)
      quietly zypper --non-interactive --gpg-auto-import-keys refresh || true
      quietly zypper --non-interactive install docker docker-compose ||
        die "Docker didn't install." "Run the same command again in a few minutes."
      ;;
  esac
}

# install_compose_plugin: Docker is here without Compose (an older or a distribution's Docker).
install_compose_plugin() {
  case "$PKG" in
    apt) apt_docker_repo; quietly env DEBIAN_FRONTEND=noninteractive apt-get install -y docker-compose-plugin && return 0 ;;
    dnf) dnf_docker_repo; quietly dnf -y install docker-compose-plugin && return 0 ;;
    pacman) quietly pacman -S --noconfirm --needed docker-compose && return 0 ;;
    zypper) quietly zypper --non-interactive install docker-compose && return 0 ;;
  esac
  # Otherwise Docker's own build of it, checked against its published checksum.
  case "$ARCH" in amd64) cp_arch=x86_64 ;; *) cp_arch=aarch64 ;; esac
  cp_url=https://github.com/docker/compose/releases/download/$COMPOSE_FALLBACK/docker-compose-linux-$cp_arch
  cp_dir=/usr/local/lib/docker/cli-plugins
  run mkdir -p "$cp_dir"
  if ! quietly curl -fsSL "$cp_url" -o "$cp_dir/docker-compose.new" ||
    ! quietly curl -fsSL "$cp_url.sha256" -o "$cp_dir/docker-compose.sha256"; then
    die "Couldn't download Docker Compose." "Check that this computer is connected to the internet, then run the same command again."
  fi
  if [ "$DRY_RUN" = 0 ]; then
    want=$(awk '{print $1}' "$cp_dir/docker-compose.sha256")
    got=$(sha256sum "$cp_dir/docker-compose.new" | awk '{print $1}')
    rm -f "$cp_dir/docker-compose.sha256"
    if [ -z "$want" ] || [ "$want" != "$got" ]; then
      rm -f "$cp_dir/docker-compose.new"
      die "Docker Compose didn't download properly." "Run the same command again."
    fi
    chmod 755 "$cp_dir/docker-compose.new" && mv -f "$cp_dir/docker-compose.new" "$cp_dir/docker-compose"
  fi
}

ensure_docker() {
  if docker_is_podman && [ "$REPLACE_PODMAN" = 0 ]; then podman_help; fi
  if command -v docker > /dev/null 2>&1 && ! docker_is_podman; then
    DOCKER_STATE=present
  else
    DOCKER_STATE=missing
    say "      installing Docker (a few minutes)"
    install_docker
  fi
  try systemctl enable --now docker.service || try systemctl start docker.service
  if [ "$DRY_RUN" = 0 ]; then
    ed_i=0
    while ! docker_ok && [ "$ed_i" -lt 30 ]; do sleep 1; ed_i=$((ed_i + 1)); done
    docker_ok || die "Docker is installed but isn't running." \
      "Restart this computer, then run the same command again."
  fi
  if [ "$DRY_RUN" = 1 ] && [ "$DOCKER_STATE" = missing ]; then return 0; fi
  if ! compose_ok; then
    say "      adding Docker Compose"
    install_compose_plugin
    [ "$DRY_RUN" = 1 ] || compose_ok || die "Docker Compose didn't install." "Run the same command again."
  fi
  DOCKER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "?")
}

# --- Den's files ----------------------------------------------------------------------------

compose_text() {
  cat <<EOF
# Den, as deploy/install.sh set it up. Don't edit: the installer writes it again each time it
# runs (sudo den). docs/install-technical.md says what each part is for.
name: $DEN_PROJECT

x-logging: &logging
  driver: local
  options:
    max-size: "10m"
    max-file: "3"

services:
  hub:
    image: den:current
    pull_policy: never
    restart: unless-stopped
    environment:
      DEN_NAME: "Den hub"
      DEN_PORT: "$DEN_PORT"
      # Reachable from the internet through the tunnel: the public posture, always.
      DEN_PUBLIC: "1"
      DEN_MDNS: "0"
      # The tunnel's connector, on this network, passes on who's really asking.
      DEN_TRUSTED_PROXIES: "$DEN_SUBNET"
      # The tunnel's connector is there (the first-boot page asks for its token), and where its
      # cloudflared answers /ready and /config.
      DEN_CONNECTOR: "cloudflared"
      DEN_CONNECTOR_METRICS: "http://tunnel:20241"
      DEN_LOG: "info"
    ports:
      # $NETWORK_MODE: $( [ "$BIND" = 0.0.0.0 ] && echo "this computer and its home network (IPv4), never the internet" || echo "this computer only; the family comes in through the tunnel" )
      - "$BIND:$DEN_PORT:$DEN_PORT"
    volumes:
      - $DATA_DIR:/data:z
    networks: [den]
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    logging: *logging

  # The Cloudflare Tunnel: waits for the token in data/hub/tunnel-token, and runs cloudflared
  # with it (deploy/hub/den-connector.sh). No port is open for it: it calls out to Cloudflare.
  tunnel:
    image: den:current
    pull_policy: never
    restart: unless-stopped
    entrypoint: ["/app/bin/den-connector"]
    volumes:
      - $DATA_DIR:/data:z
    networks: [den]
    healthcheck:
      disable: true
    cap_drop: [ALL]
    security_opt: ["no-new-privileges:true"]
    logging: *logging

networks:
  den:
    ipam:
      config:
        - subnet: $DEN_SUBNET
EOF
}

unit_service() {
  cat <<EOF
[Unit]
Description=Den: update to the newest version, and go back if it doesn't start
Wants=network-online.target docker.service
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=$DEN_DIR/den update --from-timer
EOF
}

# den.service: Den comes up at every start of the computer, even after an update that a power cut
# interrupted (Docker alone would leave containers stopped that were stopped on purpose).
unit_boot() {
  cat <<EOF
[Unit]
Description=Den: start the family's hub
Wants=docker.service network-online.target
After=docker.service network-online.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'docker compose -f $COMPOSE_FILE up -d --remove-orphans'

[Install]
WantedBy=multi-user.target
EOF
}

unit_timer() {
  cat <<'EOF'
[Unit]
Description=Den: look for an update every night

[Timer]
OnCalendar=*-*-* 03:30
RandomizedDelaySec=45min
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

unit_path() {
  cat <<EOF
[Unit]
Description=Den: update now when the Den app asks

[Path]
PathExists=$HUB_DIR/update-request
Unit=den-update.service

[Install]
WantedBy=multi-user.target
EOF
}

write_files() {
  run mkdir -p "$DEN_DIR" "$STATE_DIR"
  run chmod 755 "$DEN_DIR"
  run chmod 700 "$STATE_DIR"
  if [ -n "$MODE_FLAG" ]; then printf '%s\n' "$MODE_FLAG" | put "$STATE_DIR/network-mode" 600; fi
  if [ -n "$IMAGE_FLAG" ]; then printf '%s\n' "$IMAGE:$CHANNEL" | put "$STATE_DIR/image" 600; fi
  if [ ! -d "$DATA_DIR" ]; then run mkdir -p "$DATA_DIR"; fi
  run mkdir -p "$HUB_DIR"
  # The hub runs as user 10001 in its container; the data is that user's alone.
  run chown -R "$DEN_UID:$DEN_UID" "$DATA_DIR"
  run chmod 700 "$DATA_DIR" "$HUB_DIR"
  compose_text | put "$COMPOSE_FILE" 644
}

install_units() {
  unit_boot | put "$DEN_SYSTEMD_DIR/den.service" 644
  unit_service | put "$DEN_SYSTEMD_DIR/den-update.service" 644
  unit_timer | put "$DEN_SYSTEMD_DIR/den-update.timer" 644
  unit_path | put "$DEN_SYSTEMD_DIR/den-update.path" 644
  try systemctl daemon-reload
  try systemctl enable den.service
  try systemctl enable --now den-update.timer den-update.path ||
    say "      (Couldn't turn on nightly updates; Den runs anyway. sudo den update updates it by hand.)"
}

# install_command: the installer from the image that runs, as $DEN_DIR/den and `den`.
install_command() {
  if [ "$DRY_RUN" = 1 ]; then
    say "      would copy the installer from the image to $DEN_DIR/den, and link $DEN_BIN_DIR/den to it"
    return 0
  fi
  if docker run --rm --pull never --entrypoint cat den:current /app/install.sh > "$DEN_DIR/den.new" 2>/dev/null &&
    [ -s "$DEN_DIR/den.new" ]; then
    chmod 755 "$DEN_DIR/den.new" && mv -f "$DEN_DIR/den.new" "$DEN_DIR/den"
  else
    rm -f "$DEN_DIR/den.new"
    # An image from before the installer was in it: this script, if it's a file.
    if [ -f "$0" ] && grep -q 'DEN_GET_URL=' "$0" 2>/dev/null; then
      cp "$0" "$DEN_DIR/den" && chmod 755 "$DEN_DIR/den"
    fi
  fi
  if [ -x "$DEN_DIR/den" ]; then
    mkdir -p "$DEN_BIN_DIR" && ln -sfn "$DEN_DIR/den" "$DEN_BIN_DIR/den"
  fi
}

compose() { docker compose -f "$COMPOSE_FILE" "$@"; }

# --- the image and its versions -------------------------------------------------------------

image_id() { docker image inspect -f '{{.Id}}' "$1" 2>/dev/null; }

image_version() {
  iv=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$1" 2>/dev/null)
  iv=$(printf '%s' "$iv" | tr -cd 'A-Za-z0-9._+-')
  printf '%s' "${iv:-dev}"
}

pull_image() {
  if [ "$DRY_RUN" = 1 ]; then say "      would run: docker pull $IMAGE:$CHANNEL"; return 0; fi
  quietly docker pull "$IMAGE:$CHANNEL"
}

hub_container() { compose ps -q hub 2>/dev/null | head -n 1; }

hub_health() {
  hh_id=$(hub_container)
  [ -n "$hh_id" ] || { echo missing; return 0; }
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$hh_id" 2>/dev/null || echo missing
}

# wait_healthy SECONDS: until the hub's own health check says healthy.
wait_healthy() {
  [ "$DRY_RUN" = 1 ] && return 0
  wh_end=$(( $(date +%s) + $1 ))
  while [ "$(date +%s)" -lt "$wh_end" ]; do
    [ "$(hub_health)" = healthy ] && return 0
    sleep 2
  done
  return 1
}

# --- what Den reads: update.json, update-request, update-policy -----------------------------

json_get() { # json_get FILE KEY: a string value from one of Den's one-line JSON files
  sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null | head -n 1
}

# update_policy: what the family chose in the app (<data>/hub/update-policy): auto or manual.
update_policy() {
  up_text=
  [ -f "$HUB_DIR/update-policy" ] && up_text=$(tr -d ' \t\r\n' < "$HUB_DIR/update-policy")
  if [ "$up_text" = manual ]; then echo manual; else echo auto; fi
}

# write_update STATE MESSAGE: <data>/hub/update.json, for the hub to show (docs/install-technical.md).
write_update() {
  [ "$DRY_RUN" = 1 ] && return 0
  mkdir -p "$HUB_DIR"
  wu_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  wu_current=$(image_version den:current)
  wu_previous=
  image_id den:previous > /dev/null && wu_previous=$(image_version den:previous)
  wu_available=${AVAILABLE:-$wu_current}
  wu_updated=$(json_get "$HUB_DIR/update.json" updated)
  [ "$1" = updated ] && wu_updated=$wu_now
  wu_policy=auto
  [ "$(update_policy)" = manual ] && wu_policy=manual
  printf '{"state":"%s","message":"%s","current":"%s","available":"%s","previous":"%s","channel":"%s","policy":"%s","checked":"%s","updated":"%s"}\n' \
    "$1" "$(printf '%s' "$2" | sed 's/["\\]//g')" "$wu_current" "$wu_available" "$wu_previous" "$CHANNEL" "$wu_policy" "$wu_now" "$wu_updated" \
    > "$HUB_DIR/update.json.new"
  chown "$DEN_UID:$DEN_UID" "$HUB_DIR/update.json.new" 2>/dev/null
  chmod 600 "$HUB_DIR/update.json.new"
  mv -f "$HUB_DIR/update.json.new" "$HUB_DIR/update.json"
}

# --- one at a time --------------------------------------------------------------------------

LOCK_DIR=
take_lock() {
  [ "$DRY_RUN" = 1 ] && return 0
  mkdir -p "$DEN_DIR"
  tl_i=0
  while ! mkdir "$DEN_DIR/.lock" 2> /dev/null; do
    tl_pid=$(cat "$DEN_DIR/.lock/pid" 2>/dev/null)
    if [ -n "$tl_pid" ] && ! kill -0 "$tl_pid" 2>/dev/null; then rm -rf "$DEN_DIR/.lock"; continue; fi
    tl_i=$((tl_i + 1))
    [ "$tl_i" -gt 600 ] && die "Den is busy with something else (an update?) and didn't finish in 10 minutes." \
      "Restart this computer, then run the same command again."
    [ "$tl_i" = 1 ] && say "      (waiting for an update that's running now)"
    sleep 1
  done
  echo $$ > "$DEN_DIR/.lock/pid"
  LOCK_DIR=$DEN_DIR/.lock
  trap 'rm -rf "$LOCK_DIR"' EXIT
  trap 'rm -rf "$LOCK_DIR"; exit 130' INT TERM
}

# --- updating, with the way back ------------------------------------------------------------

# snapshot_data: a copy of the family's data while the hub is stopped, so an update that fails
# goes back to exactly what the old version had (a newer one may have changed it).
snapshot_data() {
  rm -rf "$STATE_DIR/data-before-update"
  sd_need=$(du -sk "$DATA_DIR" 2>/dev/null | awk '{print $1}')
  sd_free=$(df -Pk "$DEN_DIR" 2>/dev/null | awk 'NR == 2 {print $4}')
  if [ "${sd_need:-0}" -gt $(( ${sd_free:-0} / 2 )) ]; then
    say "      (not enough disk to keep a copy of the data during the update; going on without one)"
    return 0
  fi
  cp -a "$DATA_DIR" "$STATE_DIR/data-before-update"
}

restore_snapshot() {
  [ -d "$STATE_DIR/data-before-update" ] || return 0
  rm -rf "$DATA_DIR.failed"
  mv "$DATA_DIR" "$DATA_DIR.failed" && cp -a "$STATE_DIR/data-before-update" "$DATA_DIR" && rm -rf "$DATA_DIR.failed"
}

# apply_update: den:current becomes the pulled image; if the hub isn't healthy within
# HEALTH_WAIT seconds, everything goes back and the new image is remembered as bad.
apply_update() {
  au_old_previous=$(image_id den:previous)
  run docker tag den:current den:previous
  if [ -n "$au_old_previous" ] && [ "$au_old_previous" != "$(image_id den:current)" ]; then
    try docker image rm "$au_old_previous"
  fi
  write_update updating "Updating to $AVAILABLE"
  run compose stop
  [ "$DRY_RUN" = 1 ] || snapshot_data
  run docker tag "$IMAGE:$CHANNEL" den:current
  run compose up -d --remove-orphans
  if wait_healthy "$HEALTH_WAIT"; then
    rm -f "$STATE_DIR/bad-image"
    rm -rf "$STATE_DIR/data-before-update"
    write_update updated "Updated to $AVAILABLE"
    install_command
    return 0
  fi
  say "      $AVAILABLE didn't start properly, so Den is going back to $CURRENT."
  run compose stop
  [ "$DRY_RUN" = 1 ] || restore_snapshot
  run docker tag den:previous den:current
  run compose up -d --remove-orphans
  [ "$DRY_RUN" = 1 ] || image_id "$IMAGE:$CHANNEL" > "$STATE_DIR/bad-image"
  wait_healthy 120 || true
  write_update rolled-back "$AVAILABLE didn't start, so Den went back to $CURRENT. It tries again when there's a newer version."
  return 1
}

# do_update FORCE: FORCE=1 when a person asked (den update, the installer, "Update now").
do_update() {
  du_force=$1
  if [ -f "$HUB_DIR/update-request" ]; then du_force=1; rm -f "$HUB_DIR/update-request"; fi
  CURRENT=$(image_version den:current)
  AVAILABLE=$CURRENT
  write_update checking "Looking for an update"
  du_before=$(image_id "$IMAGE:$CHANNEL")
  if ! pull_image; then
    write_update failed "Couldn't reach the internet to look for an update. Den tries again tomorrow night."
    return 1
  fi
  [ "$DRY_RUN" = 1 ] && { apply_update; return 0; }
  du_new=$(image_id "$IMAGE:$CHANNEL")
  AVAILABLE=$(image_version "$IMAGE:$CHANNEL")
  # A download that the new one replaced, and that isn't the current or the previous version.
  if [ -n "$du_before" ] && [ "$du_before" != "$du_new" ] && [ "$du_before" != "$(image_id den:current)" ] &&
    [ "$du_before" != "$(image_id den:previous)" ]; then
    try docker image rm "$du_before"
  fi
  if [ "$du_new" = "$(image_id den:current)" ]; then
    write_update up-to-date "Den is up to date ($CURRENT)"
    return 0
  fi
  if [ "$du_new" = "$(cat "$STATE_DIR/bad-image" 2>/dev/null)" ] && [ "$du_force" = 0 ]; then
    write_update rolled-back "$AVAILABLE didn't start before, so Den stays on $CURRENT until there's a newer version."
    return 0
  fi
  if [ "$du_force" = 0 ] && [ "$(update_policy)" = manual ]; then
    write_update available "$AVAILABLE is ready to install"
    return 0
  fi
  apply_update
}

# --- the tunnel token -----------------------------------------------------------------------

# clean_token TEXT: the eyJ... token from whatever was pasted (Cloudflare shows it in a command).
clean_token() {
  ct=$(printf '%s\n' "$1" | grep -o 'eyJ[A-Za-z0-9+/=_-]*' | head -n 1)
  printf '%s' "$ct"
}

save_token() { # save_token TOKEN: where the hub keeps it, the hub's alone
  if [ "$DRY_RUN" = 1 ]; then say "      would write the tunnel token to $HUB_DIR/tunnel-token"; return 0; fi
  mkdir -p "$HUB_DIR"
  (umask 077 && printf '%s\n' "$1" > "$HUB_DIR/tunnel-token.new")
  chown "$DEN_UID:$DEN_UID" "$HUB_DIR/tunnel-token.new"
  mv -f "$HUB_DIR/tunnel-token.new" "$HUB_DIR/tunnel-token"
}

has_token() { [ -s "$HUB_DIR/tunnel-token" ]; }

# wait_tunnel SECONDS: until the connector says connected (sets TUNNEL_HOST, TUNNEL_STATE).
wait_tunnel() {
  TUNNEL_HOST='' TUNNEL_STATE=''
  [ "$DRY_RUN" = 1 ] && return 0
  wt_end=$(( $(date +%s) + $1 ))
  while :; do
    TUNNEL_STATE=$(json_get "$HUB_DIR/tunnel-status.json" state)
    TUNNEL_HOST=$(json_get "$HUB_DIR/tunnel-status.json" hostname)
    if [ "$TUNNEL_STATE" = connected ] || [ "$TUNNEL_STATE" = error ] || [ "$(date +%s)" -ge "$wt_end" ]; then
      return 0
    fi
    sleep 2
  done
}

# --- the setup link -------------------------------------------------------------------------

hub_paired() {
  curl -fsS --max-time 3 "http://127.0.0.1:$DEN_PORT/api/v1/hub/status" 2>/dev/null | grep -q '"paired":true'
}

# bare_link URL: the hub's one-time link at that address, then its QR code.
bare_link() { compose exec -T hub /app/bin/den_hub setup-link --bare --url "$1" 2>/dev/null; }

print_setup() {
  if [ "$DRY_RUN" = 1 ]; then
    say ""
    say "(dry run) Here Den would print the first parent's setup link and its QR code."
    return 0
  fi
  wait_tunnel 0
  if hub_paired; then
    say ""
    say "Den is set up: the family is on it."
    [ -n "$TUNNEL_HOST" ] && say "The family opens it at https://$TUNNEL_HOST"
    return 0
  fi
  ps_local_url=http://localhost:$DEN_PORT
  ps_qr=
  ps_link=
  ps_lan_link=
  if [ -n "$TUNNEL_HOST" ] && [ "$TUNNEL_STATE" = connected ]; then
    ps_qr=$(bare_link "https://$TUNNEL_HOST")
    ps_link=$(printf '%s\n' "$ps_qr" | head -n 1)
  fi
  if [ "$NETWORK_MODE" = lan ] && [ -n "$LAN_IP" ]; then
    ps_lan=$(bare_link "http://$LAN_IP:$DEN_PORT")
    ps_lan_link=$(printf '%s\n' "$ps_lan" | head -n 1)
    [ -n "$ps_qr" ] || { ps_qr=$ps_lan; ps_link=$ps_lan_link; }
  fi
  ps_any=$(bare_link "$ps_local_url" | head -n 1)
  if [ -z "$ps_any" ]; then
    say ""
    say "Den is running, but it didn't give a setup link yet. Wait a minute, then: sudo den setup-link"
    return 0
  fi
  say ""
  say "Next: make your family. Open this link on your phone or computer"
  if [ "$ps_link" = "$ps_lan_link" ] && [ -n "$ps_lan_link" ]; then
    say "(on the same Wi-Fi as this computer), or scan the code with your phone's camera:"
  elif [ -n "$ps_link" ]; then
    say "(from anywhere), or scan the code with your phone's camera:"
  fi
  if [ -n "$ps_link" ]; then
    say ""
    say "    $ps_link"
    say ""
    printf '%s\n' "$ps_qr" | tail -n +2
    say ""
    [ -n "$ps_lan_link" ] && [ "$ps_lan_link" != "$ps_link" ] && say "On the home Wi-Fi it's also:  $ps_lan_link"
    say "On this computer itself:     $ps_any"
  else
    # A server on the internet with no tunnel yet: nothing but this computer can open Den.
    say "(it opens only once the tunnel is set up):"
    say ""
    say "    sudo den tunnel        (then paste the tunnel token you were given)"
    say ""
    say "On this computer itself it's already: $ps_any"
  fi
  say ""
  say "The link works once. A new one, any time until the family is made:  sudo den setup-link"
}

# --- commands -------------------------------------------------------------------------------

need_root() {
  [ "$DRY_RUN" = 1 ] && return 0
  [ "$(id -u)" = 0 ] || die "Den needs to be installed as the computer's administrator. Run it like this:" \
    "" "    curl -fsSL $DEN_GET_URL | sudo sh" "" "(It asks for your password: the one you log in to this computer with.)"
}

need_installed() {
  [ -f "$COMPOSE_FILE" ] || die "Den isn't installed on this computer yet. To install it:" "" "    curl -fsSL $DEN_GET_URL | sudo sh"
  docker_ok || die "Docker isn't running." "Restart this computer; if this happens again, run the installer again:" \
    "" "    curl -fsSL $DEN_GET_URL | sudo sh"
}

cmd_install() {
  need_root
  say "Den installer"
  [ "$DRY_RUN" = 1 ] && say "(dry run: nothing on this computer changes)"
  detect_platform
  check_resources
  detect_network
  ci_kind="home network"
  [ "$NETWORK_MODE" = local ] && ci_kind="internet server: Den will answer this computer and the tunnel only"
  say ""
  say "This computer: $OS_NAME, $( [ "$ARCH" = amd64 ] && echo "64-bit Intel/AMD" || echo "64-bit ARM" ), $MEM_TEXT memory, $DISK_TEXT free"
  say "Network: ${LAN_IP:-no home network address} ($ci_kind)"

  if [ -n "$TOKEN_ARG" ]; then
    TOKEN=$(clean_token "$TOKEN_ARG")
    [ -n "$TOKEN" ] || die "That doesn't look like a tunnel token (they start with eyJ)." \
      "Copy it again from the tunnel's page in Cloudflare, and run the command again with it."
  fi

  step "[1/5] Docker"
  ensure_docker
  [ "$DRY_RUN" = 1 ] && DOCKER_VERSION=${DOCKER_VERSION:-"(as installed)"}
  note "ready: Docker $DOCKER_VERSION"

  take_lock
  if [ "$DRY_RUN" = 0 ]; then
    ci_owner=$(port_owner)
    [ -z "$ci_owner" ] || die "Something else on this computer already uses port $DEN_PORT ($ci_owner), the one Den needs." \
      "If it's an older Den, stop it first (in its folder: docker compose down), then run this again."
  fi

  step "[2/5] Den's files"
  write_files
  note "in $DEN_DIR (the family's data: $DATA_DIR)"

  step "[3/5] Den itself"
  if image_id den:current > /dev/null; then
    note "looking for a newer version"
    UPDATE_FIRST=1
  else
    note "downloading (about 200 MB)"
    pull_image || die "Couldn't download Den." "Check that this computer is connected to the internet, then run the same command again."
    run docker tag "$IMAGE:$CHANNEL" den:current
    UPDATE_FIRST=0
  fi

  step "[4/5] Starting Den"
  if [ "$UPDATE_FIRST" = 1 ]; then
    # Repair first (the compose file may have changed), then the update, with its way back.
    run compose up -d --remove-orphans
    wait_healthy 120 || note "(it was not running properly; the update below may fix it)"
    do_update 1 || true
  else
    run compose up -d --remove-orphans
  fi
  wait_healthy 180 || die "Den didn't start properly." \
    "Restart this computer, then run the same command again. If it happens again: sudo den logs"
  install_command
  [ "$UPDATE_FIRST" = 1 ] || write_update up-to-date "Installed $(image_version den:current)"
  if [ "$DRY_RUN" = 1 ]; then note "running: Den (the newest)"; else note "running: Den $(image_version den:current)"; fi

  step "[5/5] Nightly updates"
  install_units
  note "on: around 3:30 every night; if an update doesn't start, Den goes back by itself"

  if [ -n "$TOKEN_ARG" ]; then
    save_token "$TOKEN"
  elif [ "$NETWORK_MODE" = local ] && ! has_token && can_ask; then
    say ""
    say "This computer is on the internet, so the family reaches Den through a Cloudflare Tunnel."
    ask "Paste the tunnel token you were given, then press Enter (or just Enter to do it later): "
    TOKEN=$(clean_token "$ANSWER")
    if [ -n "$TOKEN" ]; then save_token "$TOKEN"; elif [ -n "$ANSWER" ]; then
      say "That doesn't look like a tunnel token (they start with eyJ). Later: sudo den tunnel"
    fi
  fi
  if has_token; then
    say ""
    say "Connecting the tunnel..."
    wait_tunnel 45
    case "$TUNNEL_STATE" in
      connected) say "Reachable from anywhere${TUNNEL_HOST:+ at https://$TUNNEL_HOST}." ;;
      error) say "The tunnel didn't connect: $(json_get "$HUB_DIR/tunnel-status.json" message)" ;;
      *) say "The tunnel is still connecting; sudo den status shows when it's up." ;;
    esac
  fi

  say ""
  say "Den is running."
  print_setup
  say ""
  say "Is it all right? sudo den status        Something wrong? Run the same install command again."
}

cmd_status() {
  need_root
  need_installed
  detect_network
  cs_health=$(hub_health)
  cs_version=$(image_version den:current)
  case "$cs_health" in
    healthy) say "Den: running ($cs_version)" ;;
    starting) say "Den: starting ($cs_version)" ;;
    missing) say "Den: not running. Start it again with: sudo den" ;;
    *) say "Den: not well ($cs_health). Run the installer again to repair it: sudo den" ;;
  esac
  if [ "$cs_health" = healthy ] || [ "$cs_health" = starting ]; then
    # Only what the hub says that matters here: a restore it's catching up from, a removal.
    cs_hub=$(compose exec -T hub /app/bin/den_hub status 2>/dev/null | grep -E 'Catching up|removed' | sed 's/^/  /')
    if hub_paired; then say "Family: set up"; else say "Family: not made yet (the link: sudo den setup-link)"; fi
    [ -n "$cs_hub" ] && printf '%s\n' "$cs_hub"
  fi
  wait_tunnel 0
  if ! has_token; then
    say "From anywhere: not yet (no tunnel token: sudo den tunnel)"
  else
    case "$TUNNEL_STATE" in
      connected) say "From anywhere: yes, https://${TUNNEL_HOST:-"(no address yet)"}" ;;
      *) say "From anywhere: not now ($(json_get "$HUB_DIR/tunnel-status.json" message))" ;;
    esac
    cs_msg=$(json_get "$HUB_DIR/tunnel-status.json" message)
    [ "$TUNNEL_STATE" = connected ] && [ -n "$cs_msg" ] && say "  $cs_msg"
  fi
  if [ "$NETWORK_MODE" = lan ] && [ -n "$LAN_IP" ]; then
    say "On the home network: http://$LAN_IP:$DEN_PORT"
  else
    say "On the home network: no (this computer answers only itself and the tunnel)"
  fi
  cs_umsg=$(json_get "$HUB_DIR/update.json" message)
  cs_checked=$(json_get "$HUB_DIR/update.json" checked)
  cs_timer=on
  systemctl is-enabled --quiet den-update.timer 2>/dev/null || cs_timer="off (run the installer again to turn them on)"
  say "Updates: nightly, $cs_timer${cs_umsg:+; last: $cs_umsg}${cs_checked:+ ($cs_checked)}"
  cs_size=$(du -sh "$DATA_DIR" 2>/dev/null | awk '{print $1}')
  cs_free=$(df -Ph "$DEN_DIR" 2>/dev/null | awk 'NR == 2 {print $4}')
  say "Data: $DATA_DIR (${cs_size:-?}); ${cs_free:-?} free on the disk"
}

cmd_setup_link() {
  need_root
  need_installed
  detect_network
  if hub_paired; then
    wait_tunnel 0
    say "Den is already set up: the family is on it. Invite people from the Den app."
    [ -n "$TUNNEL_HOST" ] && say "The family opens it at https://$TUNNEL_HOST"
    return 0
  fi
  # A fresh link means a fresh code: the hub makes one each time it starts.
  say "Making a fresh link..."
  try compose restart hub
  wait_healthy 120 || die "Den didn't start again properly." "Run the installer again to repair it: sudo den"
  print_setup
}

cmd_tunnel() {
  need_root
  need_installed
  ct_text=$1
  if [ "$ct_text" = off ]; then
    run rm -f "$HUB_DIR/tunnel-token"
    say "Den forgot the tunnel token; it's reachable from anywhere no more (the connector stops within seconds)."
    return 0
  fi
  if [ -z "$ct_text" ]; then
    can_ask || die "Give the token with the command: sudo den tunnel eyJ..."
    ask "Paste the tunnel token, then press Enter: "
    ct_text=$ANSWER
  fi
  TOKEN=$(clean_token "$ct_text")
  [ -n "$TOKEN" ] || die "That doesn't look like a tunnel token (they start with eyJ)." \
    "Copy it again from the tunnel's page in Cloudflare, then: sudo den tunnel"
  save_token "$TOKEN"
  say "Connecting the tunnel..."
  wait_tunnel 45
  case "$TUNNEL_STATE" in
    connected) say "Connected${TUNNEL_HOST:+: Den is at https://$TUNNEL_HOST}." ;;
    error) say "It didn't connect: $(json_get "$HUB_DIR/tunnel-status.json" message)" ;;
    *) say "Still connecting; sudo den status shows when it's up." ;;
  esac
  detect_network
  print_setup
}

cmd_update() {
  need_root
  need_installed
  take_lock
  cu_force=1
  [ "$1" = --from-timer ] && cu_force=0
  if do_update "$cu_force"; then
    say "$(json_get "$HUB_DIR/update.json" message)"
  else
    say "$(json_get "$HUB_DIR/update.json" message)"
    return 1
  fi
}

cmd_logs() {
  need_root
  need_installed
  compose logs -f --tail 100
}

cmd_reset() {
  need_root
  need_installed
  say "This deletes everything Den keeps on this computer: the family's data, its settings and the"
  say "tunnel token. The family's phones keep their copy. Then Den starts over, empty."
  can_ask || die "To be sure it's you, reset asks you to type RESET, and there's no keyboard here." \
    "Run it from a terminal: sudo den reset"
  ask "Type RESET (in capitals) to go on, or anything else to stop: "
  [ "$ANSWER" = RESET ] || { say "Nothing changed."; return 0; }
  take_lock
  run compose down --remove-orphans
  run rm -rf "$DATA_DIR" "$STATE_DIR/data-before-update"
  write_files
  run compose up -d
  wait_healthy 180 || die "Den didn't start again properly." "Run the installer again to repair it: sudo den"
  write_update up-to-date "Started over with $(image_version den:current)"
  detect_network
  say "Den started over."
  print_setup
}

cmd_uninstall() {
  need_root
  [ -f "$COMPOSE_FILE" ] || [ -d "$DEN_DIR" ] || { say "Den isn't installed on this computer."; return 0; }
  keep=y
  if can_ask; then
    ask "Remove Den from this computer? [y/N] "
    case "$ANSWER" in y* | Y*) ;; *) say "Nothing changed."; return 0 ;; esac
    ask "Keep the family's data ($DATA_DIR), to install Den again later? [Y/n] "
    case "$ANSWER" in n* | N*) keep=n ;; esac
  elif [ "$ASSUME_YES" = 0 ]; then
    die "Uninstall asks two questions, and there's no keyboard here." "Run it from a terminal: sudo den uninstall"
  fi
  take_lock
  try systemctl disable --now den.service den-update.timer den-update.path
  run rm -f "$DEN_SYSTEMD_DIR/den.service" "$DEN_SYSTEMD_DIR/den-update.service" "$DEN_SYSTEMD_DIR/den-update.timer" "$DEN_SYSTEMD_DIR/den-update.path"
  try systemctl daemon-reload
  if [ -f "$COMPOSE_FILE" ] && docker_ok; then run compose down --remove-orphans; fi
  for cu_image in den:current den:previous "$IMAGE:$CHANNEL"; do
    try docker image rm "$cu_image"
  done
  run rm -f "$DEN_BIN_DIR/den"
  if [ "$keep" = y ]; then
    run rm -rf "$STATE_DIR" "$COMPOSE_FILE" "$DEN_DIR/den" "$DEN_DIR/den.new"
    say "Den is removed. The family's data is still in $DATA_DIR; installing Den again picks it up."
  else
    run rm -rf "$DEN_DIR"
    say "Den and the family's data on this computer are removed (the phones keep their copy)."
  fi
  say "Docker stays installed; other programs may use it."
}

usage() {
  cat <<'EOF'
Den, the family's server. With sudo:

  den                  install, repair or update (the same as the install command)
  den status           is Den running, set up, reachable from anywhere, up to date
  den setup-link       a fresh one-time link for the first parent, until the family is made
  den tunnel [TOKEN]   give Den the Cloudflare Tunnel's token (den tunnel off: forget it)
  den update           update now, going back by itself if the new version doesn't start
  den logs             what Den has been saying (Ctrl-C stops)
  den reset            start over: deletes the family's data on this computer (asks first)
  den uninstall        remove Den (asks whether to keep the family's data)

  --dry-run            say what it would do, and change nothing
EOF
}

main() {
  command=
  arg=
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --yes | -y) ASSUME_YES=1 ;;
      --replace-podman) REPLACE_PODMAN=1 ;;
      --token) shift; TOKEN_ARG=${1:-} ;;
      --token=*) TOKEN_ARG=${1#--token=} ;;
      --image) shift; IMAGE_FLAG=${1:-} ;;
      --lan) NETWORK_MODE=lan MODE_FLAG=lan ;;
      --local-only) NETWORK_MODE=local MODE_FLAG=local ;;
      --from-timer) arg=--from-timer ;;
      -h | --help | help) command=help ;;
      install | status | setup-link | tunnel | update | logs | reset | uninstall)
        if [ -z "$command" ]; then command=$1; else arg=$1; fi ;;
      *)
        if [ "$command" = tunnel ] && [ -z "$arg" ]; then arg=$1; else
          die "Den doesn't know \"$1\"." "Try: sudo den help"
        fi ;;
    esac
    shift
  done
  # --image, once given to the installer, stays this computer's choice: nightly updates follow
  # that tag (back to the default: --image ghcr.io/xattribution/den:stable).
  if [ -z "$IMAGE_FLAG" ] && [ -s "$STATE_DIR/image" ]; then
    IMAGE=$(head -n 1 "$STATE_DIR/image")
  elif [ -n "$IMAGE_FLAG" ]; then
    IMAGE=$IMAGE_FLAG
  fi
  # An image reference with a tag (ghcr.io/xattribution/den:v1.2.3) names the channel too.
  case "${IMAGE##*/}" in
    *:*) CHANNEL=${IMAGE##*:}; IMAGE=${IMAGE%:*} ;;
  esac
  case "${command:-install}" in
    install) cmd_install ;;
    status) cmd_status ;;
    setup-link) cmd_setup_link ;;
    tunnel) cmd_tunnel "$arg" ;;
    update) cmd_update "$arg" ;;
    logs) cmd_logs ;;
    reset) cmd_reset ;;
    uninstall) cmd_uninstall ;;
    help) usage ;;
  esac
}

# Sourced by the tests (deploy/test/install_test.sh) for its functions alone.
[ "${DEN_INSTALL_SOURCED:-0}" = 1 ] || main "$@"
