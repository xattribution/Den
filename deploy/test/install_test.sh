#!/usr/bin/env bash
# Tests for deploy/install.sh and deploy/hub/den-connector.sh that need no Docker daemon, no VM
# and no network: the installer's decisions (which distribution, which Docker, which port
# binding, which messages) against fake /etc/os-release files and mocked commands, its --dry-run
# from start to end per distribution, the update and its way back against a mocked docker, and
# the tunnel connector against a fake cloudflared. From the repository root:
#
#   bash deploy/test/install_test.sh
#
# What only a real machine can show is in docs/install-technical.md, "Checked on a real machine".
# The single quotes around sh -c scripts and the A && B || C checks are meant.
# shellcheck disable=SC2016,SC2015
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
INSTALL=$ROOT/deploy/install.sh
CONNECTOR=$ROOT/deploy/hub/den-connector.sh
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0
fail=0

ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
not_ok() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/     | /'; }
expect_contains() { # name haystack needle
  case "$2" in *"$3"*) ok "$1" ;; *) not_ok "$1" "expected to contain: $3
--- got:
$2" ;; esac
}
expect_not_contains() {
  case "$2" in *"$3"*) not_ok "$1" "expected NOT to contain: $3
--- got:
$2" ;; *) ok "$1" ;; esac
}
expect_eq() { if [ "$2" = "$3" ]; then ok "$1"; else not_ok "$1" "expected: $3
got:      $2"; fi; }

# --- a sandbox: only these real tools, plus mocks ---------------------------------------------

SYS=$T/sysbin
mkdir -p "$SYS"
for tool in sh dash bash sed awk grep cat head tail tr cut mkdir rm mv chmod chown date dirname sleep \
  wc du ls ln cp env sha256sum basename kill expr true false readlink mktemp touch sort uniq xargs \
  printf tee stat timeout; do
  real=$(command -v "$tool") && ln -sf "$real" "$SYS/$tool"
done

# mocks MOCKDIR: the commands every scenario fakes, steered by MOCK_* variables.
make_mocks() {
  m=$1
  mkdir -p "$m"
  cat > "$m/uname" <<'EOF'
#!/bin/sh
[ "$1" = -m ] && { echo "${MOCK_ARCH:-x86_64}"; exit 0; }
echo Linux
EOF
  cat > "$m/getconf" <<'EOF'
#!/bin/sh
echo "${MOCK_LONG_BIT:-64}"
EOF
  cat > "$m/df" <<'EOF'
#!/bin/sh
echo "Filesystem 1024-blocks Used Available Capacity Mounted on"
echo "/dev/sda1 100000000 1000 ${MOCK_DF_KB:-50000000} 2% /"
EOF
  cat > "$m/ip" <<'EOF'
#!/bin/sh
case "$*" in
  "-4 route get 1.1.1.1") [ -n "${MOCK_IP_SRC:-}" ] && echo "1.1.1.1 via 10.0.0.1 dev eth0 src $MOCK_IP_SRC uid 0" ;;
  "-4 -o addr show scope global")
    for a in ${MOCK_IP_ADDRS:-}; do echo "2: eth0    inet $a/24 brd 0.0.0.0 scope global eth0"; done ;;
esac
exit 0
EOF
  cat > "$m/hostname" <<'EOF'
#!/bin/sh
echo "${MOCK_IP_SRC:-}"
EOF
  cat > "$m/id" <<'EOF'
#!/bin/sh
echo "${MOCK_UID:-0}"
EOF
  cat > "$m/systemctl" <<'EOF'
#!/bin/sh
echo "systemctl $*" >> "${MOCK_DIR:-/dev/null}/calls"
exit 0
EOF
  chmod +x "$m"/*
}

# A docker that is only a command line (for --dry-run): present, podman's, or without compose.
make_cli_docker() { # dir kind
  case "$2" in
    podman)
      cat > "$1/docker" <<'EOF'
#!/bin/sh
case "$1" in --version) echo "podman version 5.2.0"; exit 0 ;; esac
exit 1
EOF
      ;;
    nocompose)
      cat > "$1/docker" <<'EOF'
#!/bin/sh
case "$1" in
  --version) echo "Docker version 26.1.5+dfsg1, build a72d7cd" ;;
  info) exit 0 ;;
  compose) exit 1 ;;
  version) echo "26.1.5+dfsg1" ;;
  *) exit 1 ;;
esac
EOF
      ;;
    *)
      cat > "$1/docker" <<'EOF'
#!/bin/sh
case "$1" in
  --version) echo "Docker version 28.5.1, build e180ab8" ;;
  info) exit 0 ;;
  compose) [ "$2" = version ] && echo "Docker Compose version v5.6.0"; exit 0 ;;
  version) echo "28.5.1" ;;
  image) exit 1 ;;
  *) exit 0 ;;
esac
EOF
      ;;
  esac
  chmod +x "$1/docker"
}

os_release() { # file ID VERSION_ID PRETTY [extra lines]
  f=$1
  shift
  {
    echo "ID=$1"
    echo "VERSION_ID=\"$2\""
    echo "PRETTY_NAME=\"$3\""
    shift 3
    for line in "$@"; do echo "$line"; done
  } > "$f"
}

# scenario NAME: a fresh directory with os-release, meminfo, mocks; sets S.
scenario() {
  S=$T/$1
  rm -rf "$S"
  mkdir -p "$S/opt" "$S/systemd" "$S/bin"
  make_mocks "$S/mock"
  printf 'MemTotal:        %s kB\n' "${MOCK_MEM_KB:-3900000}" > "$S/meminfo"
  : > "$S/dmi"
}

# in_scenario CMD...: runs CMD in the sandbox, with the installer's paths pointed into S.
in_scenario() {
  env -i PATH="$S/mock:$SYS" HOME="$S" TMPDIR="$S" \
    DEN_DIR="$S/opt/den" DEN_OS_RELEASE="$S/os-release" DEN_MEMINFO="$S/meminfo" DEN_DMI_VENDOR="$S/dmi" \
    DEN_SYSTEMD_DIR="$S/systemd" DEN_BIN_DIR="$S/bin" MOCK_DIR="$S" \
    MOCK_ARCH="${MOCK_ARCH:-x86_64}" MOCK_LONG_BIT="${MOCK_LONG_BIT:-64}" MOCK_DF_KB="${MOCK_DF_KB:-50000000}" \
    MOCK_IP_SRC="${MOCK_IP_SRC-192.168.1.50}" MOCK_IP_ADDRS="${MOCK_IP_ADDRS-192.168.1.50}" \
    DEN_HEALTH_WAIT="${DEN_HEALTH_WAIT:-240}" MOCK_UID="${MOCK_UID:-0}" \
    DEN_INSTALL_SOURCED="${DEN_INSTALL_SOURCED:-0}" \
    "$@"
}

# detect: sources the installer and prints what it decided about this computer.
detect() {
  in_scenario sh -c '. "$1"; detect_platform; echo "PKG=$PKG REPO=$DOCKER_REPO SUITE=$DOCKER_SUITE ARCH=$ARCH"' \
    sh "$INSTALL" 2>&1
}
export DEN_INSTALL_SOURCED=1

# --- which distribution, which Docker ---------------------------------------------------------

check_os() { # name expected-substring ID VERSION PRETTY [extra...]
  name=$1 want=$2
  shift 2
  scenario os
  os_release "$S/os-release" "$@"
  expect_contains "platform: $name" "$(DEN_INSTALL_SOURCED=1 detect)" "$want"
}

check_os "Ubuntu 24.04" "PKG=apt REPO=ubuntu SUITE=noble ARCH=amd64" ubuntu 24.04 "Ubuntu 24.04.3 LTS" UBUNTU_CODENAME=noble VERSION_CODENAME=noble
check_os "Ubuntu 22.04" "PKG=apt REPO=ubuntu SUITE=jammy" ubuntu 22.04 "Ubuntu 22.04.5 LTS" UBUNTU_CODENAME=jammy
check_os "Debian 12" "PKG=apt REPO=debian SUITE=bookworm ARCH=amd64" debian 12 "Debian GNU/Linux 12 (bookworm)" VERSION_CODENAME=bookworm
check_os "Debian 13" "PKG=apt REPO=debian SUITE=trixie" debian 13 "Debian GNU/Linux 13 (trixie)" VERSION_CODENAME=trixie
MOCK_ARCH=aarch64 check_os "Raspberry Pi OS 64-bit (aarch64)" "PKG=apt REPO=debian SUITE=bookworm ARCH=arm64" debian 12 "Debian GNU/Linux 12 (bookworm)" VERSION_CODENAME=bookworm
MOCK_ARCH=armv7l check_os "Raspberry Pi OS 32-bit (raspbian)" "Den needs the 64-bit one" raspbian 12 "Raspbian GNU/Linux 12 (bookworm)" VERSION_CODENAME=bookworm
MOCK_ARCH=armv7l check_os "Debian on 32-bit ARM" "32-bit ARM" debian 12 "Debian GNU/Linux 12 (bookworm)" VERSION_CODENAME=bookworm
MOCK_ARCH=aarch64 MOCK_LONG_BIT=32 check_os "32-bit system on a 64-bit kernel" "32-bit system on a 64-bit processor" debian 12 "Debian GNU/Linux 12 (bookworm)" VERSION_CODENAME=bookworm
MOCK_ARCH=i686 check_os "32-bit x86" "Den needs a 64-bit one" ubuntu 18.04 "Ubuntu 18.04" UBUNTU_CODENAME=bionic
MOCK_ARCH=riscv64 check_os "RISC-V" "doesn't run on this kind of processor (riscv64)" debian 13 "Debian 13" VERSION_CODENAME=trixie
check_os "Fedora 42" "PKG=dnf REPO=fedora SUITE= ARCH=amd64" fedora 42 "Fedora Linux 42 (Workstation Edition)"
MOCK_ARCH=aarch64 check_os "Fedora on ARM" "PKG=dnf REPO=fedora SUITE= ARCH=arm64" fedora 42 "Fedora Linux 42"
check_os "RHEL 9" "PKG=dnf REPO=rhel" rhel 9.6 "Red Hat Enterprise Linux 9.6 (Plow)" 'ID_LIKE="fedora"'
check_os "Rocky 9" "PKG=dnf REPO=centos" rocky 9.6 "Rocky Linux 9.6 (Blue Onyx)" 'ID_LIKE="rhel centos fedora"'
check_os "AlmaLinux 10" "PKG=dnf REPO=centos" almalinux 10.0 "AlmaLinux 10.0 (Purple Lion)" 'ID_LIKE="rhel centos fedora"'
check_os "CentOS 7 is too old" "too old for Den" centos 7 "CentOS Linux 7 (Core)" 'ID_LIKE="rhel fedora"'
check_os "Arch" "PKG=pacman REPO= SUITE= ARCH=amd64" arch "" "Arch Linux"
MOCK_ARCH=aarch64 check_os "Arch Linux ARM" "PKG=pacman REPO= SUITE= ARCH=arm64" archarm "" "Arch Linux ARM" ID_LIKE=arch
check_os "openSUSE Leap 15.6" "PKG=zypper" opensuse-leap 15.6 "openSUSE Leap 15.6" 'ID_LIKE="suse opensuse"'
check_os "openSUSE Tumbleweed" "PKG=zypper" opensuse-tumbleweed 20261028 "openSUSE Tumbleweed" 'ID_LIKE="opensuse suse"'
check_os "openSUSE MicroOS refused" "updates itself as a whole" opensuse-microos 20261028 "openSUSE MicroOS"
check_os "Linux Mint 22 (Ubuntu's packages)" "PKG=apt REPO=ubuntu SUITE=noble" linuxmint 22 "Linux Mint 22" ID_LIKE="ubuntu debian" UBUNTU_CODENAME=noble VERSION_CODENAME=wilma
check_os "Pop!_OS" "PKG=apt REPO=ubuntu SUITE=noble" pop 24.04 "Pop!_OS 24.04 LTS" "ID_LIKE=\"ubuntu debian\"" UBUNTU_CODENAME=noble
check_os "LMDE (Debian's packages)" "PKG=apt REPO=debian SUITE=bookworm" lmde 6 "LMDE 6 (faye)" ID_LIKE=debian DEBIAN_CODENAME=bookworm VERSION_CODENAME=faye
check_os "Alpine refused" "doesn't know how to set itself up on Alpine" alpine 3.20.3 "Alpine Linux v3.20"
check_os "Debian with no codename refused" "couldn't tell which release" debian "" "Debian GNU/Linux trixie/sid"

scenario noos
expect_contains "platform: no os-release" "$(in_scenario sh -c '. "$1"; DEN_OS_RELEASE=/nonexistent; detect_platform' sh "$INSTALL" 2>&1)" "there's no /etc/os-release"

# --- memory and disk ----------------------------------------------------------------------------

resources() { in_scenario sh -c '. "$1"; check_resources && echo "OK $MEM_TEXT $DISK_TEXT"' sh "$INSTALL" 2>&1; }
MOCK_MEM_KB=3900000 scenario res
expect_contains "resources: 4 GB, 50 GB free" "$(resources)" "OK 3.7 GB 48 GB"
MOCK_MEM_KB=900000 scenario res
expect_contains "resources: a 1 GB Pi is enough" "$(resources)" "OK 0.9 GB"
MOCK_MEM_KB=500000 scenario res
expect_contains "resources: 512 MB refused" "$(resources)" "has 488 MB of memory, and Den needs at least 1 GB"
scenario res
expect_contains "resources: a full disk refused" "$(MOCK_DF_KB=900000 resources)" "has 878 MB of free disk space"

# --- the network: home or internet -------------------------------------------------------------

network() { in_scenario sh -c '. "$1"; detect_network; echo "MODE=$NETWORK_MODE BIND=$BIND LAN=$LAN_IP"' sh "$INSTALL" 2>&1; }
scenario net
expect_eq "network: a computer at home" "$(network)" "MODE=lan BIND=0.0.0.0 LAN=192.168.1.50"
expect_eq "network: at home, with Tailscale and Docker's bridge too" \
  "$(MOCK_IP_ADDRS="192.168.1.50 100.101.102.103 172.17.0.1" network)" "MODE=lan BIND=0.0.0.0 LAN=192.168.1.50"
expect_eq "network: a VPS with its public address" \
  "$(MOCK_IP_SRC=203.0.113.7 MOCK_IP_ADDRS="203.0.113.7 172.17.0.1" network)" "MODE=local BIND=127.0.0.1 LAN="
expect_eq "network: a VPS with a public address beside a private one" \
  "$(MOCK_IP_SRC=10.0.0.5 MOCK_IP_ADDRS="10.0.0.5 198.51.100.20" network)" "MODE=local BIND=127.0.0.1 LAN="
echo "Amazon EC2" > "$S/dmi"
expect_eq "network: a cloud server behind its provider's NAT" "$(MOCK_IP_SRC=172.31.5.9 MOCK_IP_ADDRS=172.31.5.9 network)" "MODE=local BIND=127.0.0.1 LAN="
: > "$S/dmi"
mkdir -p "$S/opt/den/state" && echo lan > "$S/opt/den/state/network-mode"
expect_eq "network: --lan, once given, is remembered" \
  "$(MOCK_IP_SRC=203.0.113.7 MOCK_IP_ADDRS=203.0.113.7 network)" "MODE=lan BIND=0.0.0.0 LAN=203.0.113.7"
rm -f "$S/opt/den/state/network-mode"
expect_eq "network: no network at all" "$(MOCK_IP_SRC='' MOCK_IP_ADDRS='' network)" "MODE=lan BIND=0.0.0.0 LAN="

private() { in_scenario sh -c '. "$1"; if is_private_v4 "$2"; then echo private; else echo public; fi' sh "$INSTALL" "$1"; }
for a in 10.1.2.3 192.168.0.9 172.16.0.1 172.31.255.1 100.64.0.1 100.127.9.9 169.254.1.1; do
  expect_eq "address $a is private" "$(private "$a")" private
done
for a in 172.32.0.1 100.128.0.1 8.8.8.8 203.0.113.7 11.0.0.1; do
  expect_eq "address $a is public" "$(private "$a")" public
done

# --- the tunnel token ---------------------------------------------------------------------------

clean() { in_scenario sh -c '. "$1"; clean_token "$2"' sh "$INSTALL" "$1"; }
tok=eyJhIjoiYWNjb3VudCIsInQiOiJ0dW5uZWwiLCJzIjoic2VjcmV0In0=
expect_eq "token: as copied" "$(clean "$tok")" "$tok"
expect_eq "token: inside Cloudflare's install command" "$(clean "sudo cloudflared service install $tok")" "$tok"
expect_eq "token: with spaces and a newline around it" "$(clean "  $tok
")" "$tok"
expect_eq "token: not a token" "$(clean "hello there")" ""

tunnel_host() { in_scenario sh -c '. "$1"; wait_tunnel 0; echo "$TUNNEL_STATE $TUNNEL_HOST"' sh "$INSTALL"; }
scenario tunnelhost
mkdir -p "$S/opt/den/data/hub"
echo '{"state":"connected","hostname":"den.kotvas.app","service":"http://hub:47733","connections":4,"message":"","since":"x","updated":"x"}' > "$S/opt/den/data/hub/tunnel-status.json"
expect_eq "links: the tunnel's hostname" "$(tunnel_host)" "connected den.kotvas.app"
echo "https://den.smith.family/" > "$S/opt/den/data/hub/address"
expect_eq "links: the address the hub settled on wins" "$(tunnel_host)" "connected den.smith.family"

addr() { in_scenario sh -c '. "$1"; wait_address 0; echo "[$TUNNEL_HOST]"' sh "$INSTALL"; }
scenario tunneladdress
mkdir -p "$S/opt/den/data/hub"
echo '{"state":"connected","hostname":"","service":"","connections":4,"message":"","since":"x","updated":"x"}' > "$S/opt/den/data/hub/tunnel-status.json"
expect_eq "address: none yet in Cloudflare" "$(addr)" "[]"
echo '{"state":"connected","hostname":"den.kotvas.app","service":"http://localhost:47733","connections":4,"message":"","since":"x","updated":"x"}' > "$S/opt/den/data/hub/tunnel-status.json"
out=$(addr)
expect_contains "address: sent somewhere else, says what to fix" "$out" "The Service URL must be exactly http://hub:47733"
expect_contains "address: and doesn't count it" "$out" "[]"
echo '{"state":"connected","hostname":"den.kotvas.app","service":"http://hub:47733","connections":4,"message":"","since":"x","updated":"x"}' > "$S/opt/den/data/hub/tunnel-status.json"
expect_eq "address: given in Cloudflare" "$(addr)" "[den.kotvas.app]"

# --- the compose file ---------------------------------------------------------------------------

compose_for() { # mode
  in_scenario sh -c '. "$1"; NETWORK_MODE=$2; detect_network; compose_text' sh "$INSTALL" "$1"
}
scenario compose
lan_compose=$(compose_for lan)
local_compose=$(compose_for local)
expect_contains "compose: at home, the home network reaches the port" "$lan_compose" '"0.0.0.0:47733:47733"'
expect_contains "compose: on a server, only the server itself" "$local_compose" '"127.0.0.1:47733:47733"'
expect_contains "compose: the data, shared with the connector" "$lan_compose" "$S/opt/den/data:/data:z"
expect_contains "compose: the connector runs from the same image" "$lan_compose" 'entrypoint: ["/app/bin/den-connector"]'
expect_contains "compose: the public posture" "$lan_compose" 'DEN_PUBLIC: "1"'
expect_contains "compose: the connector's network is trusted" "$lan_compose" 'DEN_TRUSTED_PROXIES: "172.30.74.0/24"'
expect_contains "compose: never pulled by name" "$lan_compose" 'pull_policy: never'
expect_contains "compose: the hub knows a connector is there" "$lan_compose" 'DEN_CONNECTOR: "cloudflared"'
expect_contains "compose: and where its metrics answer" "$lan_compose" 'DEN_CONNECTOR_METRICS: "http://tunnel:20241"'
expect_not_contains "compose: nothing read from an .env" "$lan_compose" '${'
if docker compose version > /dev/null 2>&1; then
  printf '%s\n' "$lan_compose" > "$T/compose-lan.yaml"
  printf '%s\n' "$local_compose" > "$T/compose-local.yaml"
  if out=$(docker compose -f "$T/compose-lan.yaml" config -q 2>&1) && out2=$(docker compose -f "$T/compose-local.yaml" config -q 2>&1); then
    ok "compose: docker compose config accepts both files"
  else
    not_ok "compose: docker compose config accepts both files" "$out ${out2:-}"
  fi
else
  echo "skip compose: docker compose config (no docker compose here)"
fi

# --- --dry-run, from start to end, per distribution --------------------------------------------

dry_run() { # [docker kind]
  [ -n "${1:-}" ] && make_cli_docker "$S/mock" "$1"
  in_scenario sh "$INSTALL" --dry-run 2>&1
}
unset DEN_INSTALL_SOURCED

scenario dry-ubuntu
os_release "$S/os-release" ubuntu 24.04 "Ubuntu 24.04.3 LTS" UBUNTU_CODENAME=noble
out=$(dry_run)
expect_contains "dry run (Ubuntu, no Docker): says it's a dry run" "$out" "dry run: nothing on this computer changes"
expect_contains "dry run (Ubuntu): describes the computer" "$out" "This computer: Ubuntu 24.04.3 LTS, 64-bit Intel/AMD, 3.7 GB memory, 48 GB free"
expect_contains "dry run (Ubuntu): home network" "$out" "Network: 192.168.1.50 (home network)"
expect_contains "dry run (Ubuntu): Docker's key" "$out" "would run: curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc"
expect_contains "dry run (Ubuntu): Docker's repository" "$out" "would write: /etc/apt/sources.list.d/docker.sources"
expect_contains "dry run (Ubuntu): Docker's packages" "$out" "apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
expect_contains "dry run (Ubuntu): Docker on at boot" "$out" "would run: systemctl enable --now docker.service"
expect_contains "dry run (Ubuntu): the compose file" "$out" "would write: $S/opt/den/compose.yaml"
expect_contains "dry run (Ubuntu): the data, the hub's alone" "$out" "would run: chown -R 10001:10001 $S/opt/den/data"
expect_contains "dry run (Ubuntu): the image" "$out" "would run: docker pull ghcr.io/xattribution/den:stable"
expect_contains "dry run (Ubuntu): tagged as the one that runs" "$out" "would run: docker tag ghcr.io/xattribution/den:stable den:current"
expect_contains "dry run (Ubuntu): starts it" "$out" "would run: docker compose -f $S/opt/den/compose.yaml up -d --remove-orphans"
expect_contains "dry run (Ubuntu): the den command" "$out" "would copy the installer from the image to $S/opt/den/den"
expect_contains "dry run (Ubuntu): the boot unit" "$out" "would write: $S/systemd/den.service"
expect_contains "dry run (Ubuntu): nightly updates" "$out" "would write: $S/systemd/den-update.timer"
expect_contains "dry run (Ubuntu): update now, from the app" "$out" "would write: $S/systemd/den-update.path"
expect_contains "dry run (Ubuntu): turns them on" "$out" "would run: systemctl enable --now den-update.timer den-update.path"
expect_contains "dry run (Ubuntu): ends with the setup link" "$out" "Here Den would print the first parent's setup link"
[ -e "$S/opt/den" ] && not_ok "dry run (Ubuntu): changed nothing" "$(find "$S/opt")" || ok "dry run (Ubuntu): changed nothing"
[ -s "$S/calls" ] && not_ok "dry run (Ubuntu): ran no systemctl" "$(cat "$S/calls")" || ok "dry run (Ubuntu): ran no systemctl"

scenario dry-debian-docker
os_release "$S/os-release" debian 12 "Debian GNU/Linux 12 (bookworm)" VERSION_CODENAME=bookworm
out=$(dry_run present)
expect_contains "dry run (Debian, Docker there): uses it" "$out" "ready: Docker 28.5.1"
expect_not_contains "dry run (Debian, Docker there): installs no Docker" "$out" "docker-ce-cli"

scenario dry-debian-nocompose
os_release "$S/os-release" debian 12 "Debian GNU/Linux 12 (bookworm)" VERSION_CODENAME=bookworm
out=$(dry_run nocompose)
expect_contains "dry run (Debian's docker.io without Compose): adds Compose" "$out" "adding Docker Compose"
expect_contains "dry run (Debian's docker.io without Compose): from Docker's repository" "$out" "apt-get install -y docker-compose-plugin"

scenario dry-pi
os_release "$S/os-release" debian 12 "Debian GNU/Linux 12 (bookworm)" VERSION_CODENAME=bookworm
out=$(MOCK_ARCH=aarch64 dry_run)
expect_contains "dry run (Raspberry Pi OS 64-bit): ARM" "$out" "64-bit ARM"
expect_contains "dry run (Raspberry Pi OS 64-bit): Debian's Docker" "$out" "https://download.docker.com/linux/debian/gpg"

scenario dry-fedora
os_release "$S/os-release" fedora 42 "Fedora Linux 42 (Workstation Edition)"
out=$(dry_run)
expect_contains "dry run (Fedora): Docker's repository" "$out" "curl -fsSL https://download.docker.com/linux/fedora/docker-ce.repo -o /etc/yum.repos.d/docker-ce.repo"
expect_contains "dry run (Fedora): Docker's packages" "$out" "dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

scenario dry-rocky
os_release "$S/os-release" rocky 9.6 "Rocky Linux 9.6 (Blue Onyx)" 'ID_LIKE="rhel centos fedora"'
out=$(dry_run)
expect_contains "dry run (Rocky): CentOS's repository" "$out" "https://download.docker.com/linux/centos/docker-ce.repo"

scenario dry-rhel-podman
os_release "$S/os-release" rhel 9.6 "Red Hat Enterprise Linux 9.6 (Plow)"
out=$(dry_run podman)
expect_contains "dry run (RHEL with podman-docker): says what to do" "$out" "has Podman, a look-alike of Docker"
expect_contains "dry run (RHEL with podman-docker): the command that replaces it" "$out" "| sudo sh -s -- --replace-podman"
out=$(make_cli_docker "$S/mock" podman; in_scenario sh "$INSTALL" --dry-run --replace-podman 2>&1)
expect_contains "dry run (RHEL, --replace-podman): replaces it" "$out" "dnf -y install --allowerasing docker-ce"

scenario dry-arch
os_release "$S/os-release" arch "" "Arch Linux"
out=$(dry_run)
expect_contains "dry run (Arch): pacman, the whole system" "$out" "pacman -Syu --noconfirm --needed docker docker-compose"

scenario dry-suse
os_release "$S/os-release" opensuse-tumbleweed 20261028 "openSUSE Tumbleweed" 'ID_LIKE="opensuse suse"'
out=$(dry_run)
expect_contains "dry run (openSUSE): zypper" "$out" "zypper --non-interactive install docker docker-compose"

scenario dry-vps
os_release "$S/os-release" ubuntu 24.04 "Ubuntu 24.04.3 LTS" UBUNTU_CODENAME=noble
out=$(MOCK_IP_SRC=203.0.113.7 MOCK_IP_ADDRS=203.0.113.7 dry_run present)
expect_contains "dry run (VPS): says it answers only itself and the tunnel" "$out" "internet server: Den will answer this computer and the tunnel only"
out=$(make_cli_docker "$S/mock" present; MOCK_IP_SRC=203.0.113.7 MOCK_IP_ADDRS=203.0.113.7 in_scenario sh "$INSTALL" --dry-run --token "cloudflared service install $tok" 2>&1)
expect_contains "dry run (VPS, --token): keeps the token where the hub does" "$out" "would write the tunnel token to $S/opt/den/data/hub/tunnel-token"
out=$(make_cli_docker "$S/mock" present; in_scenario sh "$INSTALL" --dry-run --token nonsense 2>&1)
expect_contains "dry run (--token nonsense): refused in words" "$out" "doesn't look like a tunnel token"

scenario not-root
os_release "$S/os-release" ubuntu 24.04 "Ubuntu 24.04.3 LTS" UBUNTU_CODENAME=noble
out=$(MOCK_UID=1000 in_scenario sh "$INSTALL" 2>&1)
expect_contains "not root: says to use sudo" "$out" "| sudo sh"
out=$(MOCK_UID=1000 in_scenario sh "$INSTALL" frobnicate 2>&1)
expect_contains "an unknown command: says so" "$out" "doesn't know \"frobnicate\""
out=$(in_scenario sh "$INSTALL" help 2>&1)
expect_contains "help: lists the commands" "$out" "den uninstall"
out=$(in_scenario sh "$INSTALL" status 2>&1)
expect_contains "status before installing: says how to install" "$out" "Den isn't installed on this computer yet"

# --- updates, and the way back, against a mocked docker ---------------------------------------

# A docker that keeps images, tags and one compose project in files under $MOCK_DIR/d:
# tags/<ref> holds an image id, labels/<id> its version; remote/<ref> is what a pull gets;
# unhealthy lists ids that never get healthy; running holds the id the hub runs.
make_state_docker() {
  cat > "$S/mock/docker" <<'EOF'
#!/bin/sh
d=$MOCK_DIR/d
mkdir -p "$d/tags" "$d/labels" "$d/remote"
key() { printf '%s' "$1" | tr '/:' '__'; }
echo "docker $*" >> "$MOCK_DIR/calls"
case "$1" in
  info) exit 0 ;;
  --version) echo "Docker version 28.5.1"; exit 0 ;;
  image)
    case "$2" in
      inspect)
        ref=$5; id=$(cat "$d/tags/$(key "$ref")" 2>/dev/null) || exit 1
        case "$4" in
          *Labels*) cat "$d/labels/$id" 2>/dev/null ;;
          *) echo "$id" ;;
        esac ;;
      rm)
        for f in "$d"/tags/*; do
          [ -f "$f" ] || continue
          if [ "$(cat "$f")" = "$3" ] || [ "$f" = "$d/tags/$(key "$3")" ]; then rm -f "$f"; fi
        done ;;
    esac ;;
  pull)
    [ -f "$MOCK_DIR/offline" ] && { echo "dial tcp: no such host" >&2; exit 1; }
    [ -f "$MOCK_DIR/denied" ] && { echo "Error response from daemon: error from registry: denied" >&2; exit 1; }
    cp "$d/remote/$(key "$2")" "$d/tags/$(key "$2")" ;;
  tag) cp "$d/tags/$(key "$2")" "$d/tags/$(key "$3")" ;;
  inspect)
    id=$(cat "$d/running" 2>/dev/null) || { echo exited; exit 0; }
    if grep -qx "$id" "$d/unhealthy" 2>/dev/null; then echo unhealthy; else echo healthy; fi ;;
  run) echo '#!/bin/sh'; echo "# the den command from image $(cat "$d/tags/den_current"), DEN_GET_URL=" ;;
  compose)
    shift 3
    case "$1" in
      up) cp "$d/tags/den_current" "$d/running" ;;
      stop | down) rm -f "$d/running" ;;
      ps) [ -f "$d/running" ] && echo hubcontainer ;;
    esac ;;
esac
exit 0
EOF
  chmod +x "$S/mock/docker"
  mkdir -p "$S/d/tags" "$S/d/labels" "$S/d/remote"
}
img() { # id version: an image the mock knows
  echo "$2" > "$S/d/labels/$1"
}
tag_img() { echo "$2" > "$S/d/tags/$(printf '%s' "$1" | tr '/:' '__')"; }
remote_img() { echo "$2" > "$S/d/remote/$(printf '%s' "$1" | tr '/:' '__')"; }
current() { cat "$S/d/tags/den_current"; }
previous() { cat "$S/d/tags/den_previous" 2>/dev/null; }
update_json() { cat "$S/opt/den/data/hub/update.json" 2>/dev/null; }
update() { # [timer]
  in_scenario sh "$INSTALL" update ${1:+--from-timer} 2>&1
}
installed_scenario() {
  scenario "$1"
  os_release "$S/os-release" debian 12 "Debian GNU/Linux 12 (bookworm)" VERSION_CODENAME=bookworm
  make_state_docker
  mkdir -p "$S/opt/den/data/hub" "$S/opt/den/state"
  echo "# compose" > "$S/opt/den/compose.yaml"
  img sha256:old v1.0.0
  img sha256:new v1.1.0
  tag_img den:current sha256:old
  tag_img ghcr.io/xattribution/den:stable sha256:old
  echo sha256:old > "$S/d/running"
  echo "family data v1" > "$S/opt/den/data/hub/family"
}

installed_scenario up-to-date
remote_img ghcr.io/xattribution/den:stable sha256:old
out=$(update timer)
expect_contains "update: nothing new" "$out" "Den is up to date (v1.0.0)"
expect_contains "update: says so to the hub" "$(update_json)" '"state":"up-to-date"'
expect_contains "update: the hub reads the version" "$(update_json)" '"current":"v1.0.0"'

installed_scenario healthy
remote_img ghcr.io/xattribution/den:stable sha256:new
out=$(update timer)
expect_contains "update: a new version that starts" "$out" "Updated to v1.1.0"
expect_eq "update: it runs the new one" "$(current)" sha256:new
expect_eq "update: the old one is kept to go back to" "$(previous)" sha256:old
expect_contains "update: the hub can say 'Updated to v1.1.0'" "$(update_json)" '"state":"updated","message":"Updated to v1.1.0","current":"v1.1.0"'
expect_contains "update: and what it was before" "$(update_json)" '"previous":"v1.0.0"'
expect_contains "update: the den command comes from the new image" "$(cat "$S/opt/den/den" 2>/dev/null)" "from image sha256:new"
[ -d "$S/opt/den/state/data-before-update" ] && not_ok "update: the copy of the data is gone after" || ok "update: the copy of the data is gone after"

installed_scenario unhealthy
remote_img ghcr.io/xattribution/den:stable sha256:new
echo sha256:new > "$S/d/unhealthy"
# The new version changes the data as it starts; going back must undo that.
cat > "$S/mock/sleep" <<'EOF'
#!/bin/sh
[ "$(cat "$MOCK_DIR/d/running" 2>/dev/null)" = sha256:new ] && echo "family data v2 (migrated)" > "$MOCK_DIR/opt/den/data/hub/family"
exec /bin/sleep 1
EOF
chmod +x "$S/mock/sleep"
out=$(DEN_HEALTH_WAIT=3 update timer)
expect_contains "rollback: says what happened" "$out" "v1.1.0 didn't start properly, so Den is going back to v1.0.0"
expect_eq "rollback: it runs the old one again" "$(current)" sha256:old
expect_eq "rollback: the old one runs" "$(cat "$S/d/running")" sha256:old
expect_eq "rollback: the data is as the old version left it" "$(cat "$S/opt/den/data/hub/family")" "family data v1"
expect_eq "rollback: the bad version is remembered" "$(cat "$S/opt/den/state/bad-image")" sha256:new
expect_contains "rollback: the hub can say so" "$(update_json)" '"state":"rolled-back"'
rm -f "$S/mock/sleep"
out=$(update timer)
expect_contains "rollback: the next night leaves the bad version alone" "$out" "didn't start before, so Den stays on v1.0.0"
expect_eq "rollback: still on the old one" "$(current)" sha256:old

installed_scenario denied
touch "$S/denied"
out=$(update timer)
expect_contains "update: a download that isn't published says so" "$out" "the download site said no"
expect_not_contains "update: and doesn't blame the internet" "$out" "reach the internet"
expect_eq "update: still on the one it has" "$(current)" sha256:old
pull_why() { DEN_INSTALL_SOURCED=1 in_scenario sh -c '. "$1"; pull_image quiet; echo "${PULL_WHY:-ok}"' sh "$INSTALL"; }
expect_eq "download: denied means not published" "$(pull_why)" missing
rm -f "$S/denied"; touch "$S/offline"
expect_eq "download: no network means offline" "$(pull_why)" offline

installed_scenario manual
remote_img ghcr.io/xattribution/den:stable sha256:new
echo manual > "$S/opt/den/data/hub/update-policy"
out=$(update timer)
expect_contains "manual updates: the night only says one is ready" "$out" "v1.1.0 is ready to install"
expect_contains "manual updates: the hub can offer 'Update now'" "$(update_json)" '"state":"available","message":"v1.1.0 is ready to install","current":"v1.0.0","available":"v1.1.0"'
expect_eq "manual updates: still on the old one" "$(current)" sha256:old
echo now > "$S/opt/den/data/hub/update-request"
out=$(update timer)
expect_contains "Update now (the hub's request file): updates" "$out" "Updated to v1.1.0"
[ -e "$S/opt/den/data/hub/update-request" ] && not_ok "Update now: the request is taken away" || ok "Update now: the request is taken away"

installed_scenario offline
remote_img ghcr.io/xattribution/den:stable sha256:new
touch "$S/offline"
out=$(update timer)
expect_contains "update offline: says so" "$out" "Couldn't reach the internet to look for an update"
expect_eq "update offline: nothing changed" "$(current)" sha256:old

installed_scenario file-modes
remote_img ghcr.io/xattribution/den:stable sha256:old
update timer > /dev/null
expect_eq "update.json: only the hub's user reads it" "$(stat -c '%a %u' "$S/opt/den/data/hub/update.json")" "600 10001"

# --- the tunnel connector, against a fake cloudflared ------------------------------------------

C=$T/connector
mkdir -p "$C/data/hub" "$C/bin"
cat > "$C/bin/cloudflared" <<'EOF'
#!/bin/sh
# A cloudflared that says what it was given, and fails for the token "eyJbad".
echo "$TUNNEL_TOKEN" > "$FAKE_DIR/token-seen"
echo "$$" > "$FAKE_DIR/pid"
case "$TUNNEL_TOKEN" in
  eyJbad*) echo "2026-11-01T03:00:00Z ERR Provided Tunnel token is not valid."; exit 1 ;;
esac
echo "2026-11-01T03:00:00Z INF Starting tunnel tunnelID=abc"
trap 'exit 0' TERM
while :; do sleep 1; done
EOF
cat > "$C/bin/curl" <<'EOF'
#!/bin/sh
# cloudflared's metrics: ready once it runs; its configuration from Cloudflare.
for last; do :; done
[ -s "$FAKE_DIR/pid" ] && kill -0 "$(cat "$FAKE_DIR/pid")" 2>/dev/null || exit 7
case "$last" in
  */ready) echo '{"status":200,"readyConnections":4,"connectorId":"x"}' ;;
  */config) cat "$FAKE_DIR/config" ;;
esac
EOF
chmod +x "$C/bin/"*
echo '{"version":2,"config":{"ingress":[{"hostname":"den.kotvas.app","originRequest":{},"service":"http://hub:47733"},{"service":"http_status:404"}]}}' > "$C/config"

connector_run() { # seconds: runs the connector that long
  env PATH="$C/bin:$PATH" FAKE_DIR="$C" DEN_DATA="$C/data" TMPDIR="$C" DEN_CONNECTOR_TICK=0.3 \
    DEN_CLOUDFLARED="$C/bin/cloudflared" timeout -s TERM "$1" sh "$CONNECTOR" run > "$C/out" 2>&1
}
status_json() { cat "$C/data/hub/tunnel-status.json" 2>/dev/null; }

connector_run 1
expect_contains "connector: no token, it waits" "$(status_json)" '"state":"waiting"'
expect_contains "connector: and says so in words" "$(status_json)" '"message":"No tunnel token yet"'

printf 'sudo cloudflared service install %s\n' "$tok" > "$C/data/hub/tunnel-token"
connector_run 3
expect_contains "connector: connected, with the address" "$(status_json)" '"state":"connected","hostname":"den.kotvas.app","service":"http://hub:47733","connections":4'
expect_eq "connector: cloudflared got the token alone, from the pasted command" "$(cat "$C/token-seen")" "$tok"
expect_contains "connector: cloudflared's log goes to the container's output" "$(cat "$C/out")" "Starting tunnel"
kill -0 "$(cat "$C/pid")" 2>/dev/null && not_ok "connector: stopping it stops cloudflared" || ok "connector: stopping it stops cloudflared"

echo '{"version":3,"config":{"ingress":[{"hostname":"den.kotvas.app","service":"http://localhost:47733"},{"service":"http_status:404"}]}}' > "$C/config"
connector_run 2
expect_contains "connector: a tunnel sent to the wrong place says how to fix it" "$(status_json)" 'change its service to http://hub:47733'

echo "eyJbadtoken" > "$C/data/hub/tunnel-token"
connector_run 3
expect_contains "connector: a token Cloudflare refuses" "$(status_json)" '"state":"error"'
expect_contains "connector: says what to do" "$(status_json)" "Copy it again from the tunnel's page in Cloudflare"
expect_contains "connector: tries again, backing off" "$(cat "$C/out")" "trying again in 5s"

# The token changes while it runs, then goes away.
echo "$tok" > "$C/data/hub/tunnel-token"
(
  sleep 1.5
  echo "eyJzZWNvbmQ" > "$C/data/hub/tunnel-token.new" && mv "$C/data/hub/tunnel-token.new" "$C/data/hub/tunnel-token"
  sleep 1.5
  rm -f "$C/data/hub/tunnel-token"
) &
connector_run 4.5
wait
expect_contains "connector: a new token restarts cloudflared" "$(cat "$C/out")" "the tunnel token changed; restarting cloudflared"
expect_eq "connector: with the new token" "$(cat "$C/token-seen")" "eyJzZWNvbmQ"
expect_contains "connector: no token any more, it stops and waits" "$(status_json)" '"state":"waiting"'
expect_eq "connector: the status file is the hub's user's alone" "$(stat -c '%a' "$C/data/hub/tunnel-status.json")" "600"

# --- shellcheck ---------------------------------------------------------------------------------

if command -v shellcheck > /dev/null; then
  if out=$(shellcheck --shell=sh "$INSTALL" "$CONNECTOR" 2>&1) &&
    out2=$(shellcheck "$ROOT/tools/release.sh" "$0" 2>&1); then
    ok "shellcheck: every script"
  else
    not_ok "shellcheck: every script" "$out ${out2:-}"
  fi
  if command -v dash > /dev/null && dash -n "$INSTALL" && dash -n "$CONNECTOR"; then ok "dash: parses both"; else not_ok "dash: parses both"; fi
else
  echo "skip shellcheck (not installed)"
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" = 0 ]
