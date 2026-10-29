# shellcheck shell=bash
# Den, private setup: several families on one server (docs/hosting.md, "Several families").
# install.sh sources this and calls three things:
#   families_command add-family|remove-family|merge-families|families ...   for sudo ./install.sh ...
#   families_render       in step 7, before docker compose: the generated files below
#   families_whats_left   in step 8: the other families' names to point at this server
# It uses install.sh's helpers (step, info, stop, run, put, env_get, env_set) and CHECK.
#
# The first family is the one install.sh set up: DEN_DOMAIN, DEN_HOMES and DEN_PORT in .env, the
# service hub, the volume den-hub, its backups in backups/. Each other family is one line in .env,
# which add-family writes and remove-family takes out:
#   DEN_FAMILY_SMITH=den-smith.example.com host home.smith.example.net
#                    its address           where it runs, then its homes' DDNS names
# Where it runs is `host` (the default): the first family's hub is a Den host, one process
# serving several families, and the family is one more of them, its data in the volume den-hub
# under logs/<id>/ (den_hub add-family). Or a port (47735, ...): the family has a hub container
# of its own, hub-smith, with its own volume den-smith (add-family --container, and every family
# added before the host). merge-families moves those onto the host.
#
# From those lines install.sh keeps two generated files in step (don't edit them; they're written
# again on every run), and sets COMPOSE_FILE in .env so that plain `docker compose ...` reads both
# compose files:
#   compose.families.yaml   the hub-<name> container of each family that has one; for every hub,
#                           when there is any such container, every family's address pointed at
#                           Caddy on 127.0.0.1 (extra_hosts) and listed in DEN_PEER_HUBS, so a
#                           calendar one family shares with another is fetched on this machine
#                           (families on the host need neither: the host reads them in-process);
#                           dnsmasq's answer for each address; the backup service's view of each
#                           family's data; and Caddy's copy of
#   Caddyfile.families      a site for each family's address: the host's port for a family on the
#                           host, its own hub's port for one in its own container
# den-allowlist reads the same lines and lets each family's homes reach 443.
#
# The functions named host_* make one address reach this server (its Caddy site, dnsmasq answer,
# split-DNS line, public DNS record) and don't care what serves it; the family_* ones are about
# where its hub runs. Every family keeps its own data, its own keys and its own DEN_PUBLIC_URL.

FAMILY_FIRST_PORT=47735

families_usage() {
  cat >&2 <<'EOF'
Usage:
  sudo ./install.sh add-family NAME ADDRESS ["HOMES"] [--container]
      like: sudo ./install.sh add-family smith den-smith.example.com "home.smith.example.net"
      NAME is short, lower-case letters and digits; HOMES are the family's homes' DDNS names,
      separated by spaces (none: Tailscale only). Run it again with the same name and address to
      change the homes. The family joins the Den host (the first family's hub), with its own
      keys and data; --container gives it a hub container of its own instead.
  sudo ./install.sh remove-family NAME [--delete-data]
      takes the family off this server; its data stays unless --delete-data
  sudo ./install.sh remove-family NAME ADDRESS --delete-data
      deletes the data the Den host kept for a family taken off it earlier
  sudo ./install.sh merge-families [--dry-run]
      moves every family that has a hub container of its own onto the Den host: a backup of
      every family first, then each hub's data, keys and all, so no phone pairs again
  sudo ./install.sh families
      the families on this server: address, hub, port, data and backups
EOF
  exit 64
}

families_command() { # add-family | remove-family | merge-families | families, then its arguments
  local cmd=$1
  shift
  [ "$(id -u)" = 0 ] || stop "run it as root: sudo ./install.sh $cmd ..."
  case $cmd in
    add-family) families_add "$@" ;;
    remove-family) families_remove "$@" ;;
    merge-families) families_merge "$@" ;;
    families) [ $# -eq 0 ] || families_usage; families_list ;;
  esac
}

# --- The DEN_FAMILY_ lines -------------------------------------------------------------------

families_names() { # the other families, in the order of their lines in .env
  [ -f .env ] || return 0
  sed -n 's/^[[:space:]]*DEN_FAMILY_\([A-Za-z0-9]*\)[[:space:]]*=.*/\1/p' .env | tr '[:upper:]' '[:lower:]' | awk '!seen[$0]++'
}
family_key() { printf 'DEN_FAMILY_%s' "$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"; }
family_domain() { env_get "$(family_key "$1")" | awk '{print $1}'; }
family_port() { env_get "$(family_key "$1")" | awk '{print $2}'; } # a port, or "host"
family_homes() { env_get "$(family_key "$1")" | awk '{$1 = $2 = ""; sub(/^ +/, ""); print}'; }
family_hosted() { [ "$(family_port "$1")" = host ]; } # NAME: is it a family of the Den host?
families_hosted() { local f; for f in $(families_names); do family_hosted "$f" && printf '%s\n' "$f"; done; return 0; }
families_contained() { local f; for f in $(families_names); do family_hosted "$f" || printf '%s\n' "$f"; done; return 0; }
families_host_port() { env_get DEN_PORT | grep . || echo 47733; } # the Den host's port (the first family's hub)

families_project() { # Compose's project name: den, from compose.yaml
  local p=${COMPOSE_PROJECT_NAME:-}
  [ -n "$p" ] || p=$(env_get COMPOSE_PROJECT_NAME)
  printf '%s' "${p:-den}"
}
families_volume() { printf '%s_den-%s' "$(families_project)" "$1"; }

families_check_name() {
  [[ $1 =~ ^[a-z][a-z0-9]{0,19}$ ]] || stop "a family's name is lower-case letters and digits, starting with a letter, at most 20, like smith (it names its backups' folder, and hub-smith if it has a container)"
  [ "$1" != hub ] || stop "hub is the first family's hub; give this family another name"
}
families_valid_address() { [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$ ]]; }

# families_env_line KEY VALUE: the family's line in .env; a new one goes after the others.
families_env_line() {
  local key=$1 value=$2 after
  if [ "$CHECK" = 1 ]; then info "would set $key in .env"; return 0; fi
  if grep -q "^$key=" .env; then
    env_set "$key" "$value"
    return 0
  fi
  after=$(grep -n '^DEN_FAMILY_[A-Za-z0-9]*=' .env | tail -n 1 | cut -d: -f1 || true)
  [ -n "$after" ] || after=$(grep -n '^# DEN_FAMILY_' .env | tail -n 1 | cut -d: -f1 || true)
  if [ -n "$after" ]; then
    sed -i "${after}a\\
$key=$value" .env
  else
    printf '\n# Other families on this server, a line each: the address, where its hub runs (host: on the\n# Den host; a port: its own container), the homes'"'"' DDNS names. sudo ./install.sh add-family\n# and remove-family write them (docs/hosting.md).\n%s=%s\n' "$key" "$value" >> .env
  fi
}

# --- The generated files ---------------------------------------------------------------------

# Two kinds of piece, kept apart. Per address (needed however the family is served): its Caddy
# site, its dnsmasq answer, and (further down) its split-DNS line and public DNS record. Per hub
# container (only for a family with a container of its own): its compose service, its backup
# mount, starting it, and its setup code.

host_caddy_site() { # ADDRESS PORT: Caddy's site for an address, to the hub on that port
  printf '\n%s {\n\timport den %s\n}\n' "$1" "$2"
}
host_dnsmasq_args() { # ADDRESS: dnsmasq's answer for it, the server's Tailscale address (compose)
  printf '      - --interface-name=%s,tailscale0/4\n      - --local=/%s/\n' "$1" "$1"
}

family_upstream() { # NAME: the port Caddy sends its address to
  if family_hosted "$1"; then families_host_port; else family_port "$1"; fi
}

family_hub_service() { # NAME ADDRESS PORT: a family's own hub container, as a compose service
  cat <<EOF
  # $1: https://$2, in a container of its own
  hub-$1:
    extends: {file: compose.yaml, service: hub}
    # The image the first family's hub builds (or DEN_IMAGE names), built once for every family.
    build: !reset null
    environment:
      DEN_PORT: "$3"
      # Each family's own address: its links, sign-in pages and OAuth name it, and no other.
      DEN_PUBLIC_URL: https://$2
$(families_peers_env)
$(families_peers_hosts)
    volumes:
      # Its own volume, never shared with another family.
      - den-$1:/data

EOF
}

# Calendars shared between the families on this server (docs/hosting.md, "Calendars shared
# between families on this server"). Families on the Den host read each other's in the host's
# own process, with nothing to configure. A family in a container of its own is another process:
# each hub then sees every family's address as 127.0.0.1, where Caddy answers it (this server's
# own network), so one hub fetches another family's shared calendar through Caddy with the
# certificate checked, without leaving the machine, and without depending on the server reaching
# its own public address (which a provider that puts the public address in front of the server
# doesn't loop back, and the firewall would drop as a stranger). DEN_PEER_HUBS lets the hub's
# NetGuard reach loopback for these names only, over https.
families_addresses() { # every family's address here: the first's as ${DEN_DOMAIN} (compose fills it in), then the others'
  printf '%s\n' '${DEN_DOMAIN}'
  local f
  for f in $(families_names); do family_domain "$f"; done
}
families_peers_env() { # the DEN_PEER_HUBS line, in a hub's environment
  printf '      DEN_PEER_HUBS: "%s"' "$(families_addresses | paste -sd ' ' -)"
}
families_peers_hosts() { # the extra_hosts a hub needs: every family's address at Caddy, here
  local a
  printf '    extra_hosts:\n'
  for a in $(families_addresses); do printf '      - "%s:127.0.0.1"\n' "$a"; done
}
family_backup_mount() { printf '      - den-%s:/families/%s\n' "$1" "$1"; }
family_volume_decl() { printf '  den-%s:\n' "$1"; }
families_hosted_env() { # what backup.sh needs to find the families on the host: name=address ...
  local f out=""
  for f in $(families_hosted); do out+="${out:+ }$f=$(family_domain "$f")"; done
  printf '%s' "$out"
}

family_start() { # NAME: start (or keep) where its hub runs, and the shared services with the new files
  if family_hosted "$1"; then
    # The host's own compose service is unchanged by a family on it, so it keeps running:
    # nobody else's sync drops. Caddy and dnsmasq start again with the new address.
    run docker compose up -d --no-deps --wait --wait-timeout 300 hub $(families_container_hubs) dnsmasq caddy || return 1
    if [ "$CHECK" = 1 ]; then info "would run: docker compose exec -T hub /app/bin/den_hub add-family --hostname $(family_domain "$1")"; return 0; fi
    if families_on_host | grep -qx "https://$(family_domain "$1")"; then
      info "The host serves $(family_domain "$1") already"
      return 0
    fi
    run docker compose exec -T hub /app/bin/den_hub add-family --hostname "$(family_domain "$1")" >/dev/null
  else
    run docker compose up -d --no-deps --wait --wait-timeout 300 "hub-$1" $(families_other_hubs "$1") dnsmasq caddy
  fi
}
families_on_host() { # the addresses the host has (serving, or opening again), one per line, as den_hub families lists them
  docker compose exec -T hub /app/bin/den_hub families 2>/dev/null | awk '/^https?:\/\// && !/taken off/ {print $1}'
}
families_served() { # ADDRESS: does the host have it (serving it, or opening it again)?
  [ "$CHECK" = 1 ] && return 1
  families_on_host | grep -qx "https://$1"
}
families_container_hubs() { # every family's own hub container
  local f
  for f in $(families_contained); do printf ' hub-%s' "$f"; done
}
families_other_hubs() { # [NAME]: every other hub on this server; up -d restarts those whose list
  # of families (DEN_PEER_HUBS, extra_hosts) changed, and leaves the rest running
  local f
  printf 'hub'
  for f in $(families_contained); do [ "$f" = "${1:-}" ] || printf ' hub-%s' "$f"; done
}
family_stop() { # NAME: stop and remove its hub container; its volume stays
  run docker compose rm --stop --force "hub-$1"
}
family_exec() { # NAME COMMAND...: den_hub COMMAND for the family, where its hub runs
  local name=$1
  shift
  if family_hosted "$name"; then
    docker compose exec -T hub /app/bin/den_hub "$@" --family "$(family_domain "$name")"
  else
    docker compose exec -T "hub-$name" /app/bin/den_hub "$@"
  fi
}
family_exec_shown() { # NAME COMMAND: how the owner runs den_hub COMMAND for the family by hand
  if family_hosted "$1"; then
    printf 'docker compose exec hub /app/bin/den_hub %s --family %s' "$2" "$(family_domain "$1")"
  else
    printf 'docker compose exec hub-%s /app/bin/den_hub %s' "$1" "$2"
  fi
}
family_setup() { # NAME: the hub's setup link and its QR code, else (an older hub) its setup code
  local out
  if out=$(family_exec "$1" setup-link 2>/dev/null) && [[ "$out" == *https://* ]]; then
    printf '%s' "$out"
  elif out=$(family_exec "$1" setup-code 2>/dev/null) && [[ "$out" != *' '* ]]; then
    printf 'Open https://%s in Safari, Share, Add to Home Screen, open Den from there,\nthen Start a family, with the setup code %s' "$(family_domain "$1")" "$out"
  elif [ -n "${out:-}" ]; then
    printf '%s' "$out"
  else
    printf '(its hub gives it once it runs: %s)' "$(family_exec_shown "$1" setup-link)"
  fi
}

families_caddyfile() {
  local f
  cat <<'EOF'
# Generated by install.sh (families.sh) from the DEN_FAMILY_ lines in .env; don't edit it.
# A site for each of the other families' addresses: to the Den host for a family on it (the one
# upstream every family on the host shares), to its own hub for one in a container of its own.
# The den snippet (the certificate, compression, the proxy) is in Caddyfile, which imports it.
EOF
  for f in $(families_names); do
    host_caddy_site "$(family_domain "$f")" "$(family_upstream "$f")"
  done
}

families_compose() {
  local f contained
  contained=$(families_contained)
  cat <<'EOF'
# Generated by install.sh (families.sh) from the DEN_FAMILY_ lines in .env; don't edit it: it's
# written again on every run. sudo ./install.sh add-family and remove-family change the families
# (docs/hosting.md, "Several families"). COMPOSE_FILE in .env adds this file to compose.yaml.

services:
EOF
  if [ -n "$contained" ]; then
    cat <<EOF
  # The Den host (compose.yaml) sees the addresses of the families in containers of their own on
  # this machine too.
  hub:
    environment:
$(families_peers_env)
$(families_peers_hosts)

EOF
    for f in $contained; do
      family_hub_service "$f" "$(family_domain "$f")" "$(family_port "$f")"
    done
  fi
  cat <<EOF
  # Caddy reads its configuration only when it starts (its admin API is off): when the families
  # change, the label changes and \`docker compose up -d\` starts it again.
  caddy:
    volumes:
      - ./Caddyfile.families:/etc/caddy/families/Caddyfile:ro
    labels:
      den.families: "$(families_caddyfile | sha256sum | cut -c1-16)"

  # Every family's address, answered with this server's Tailscale address (the first family's as
  # in compose.yaml, then the others).
  dnsmasq:
    command:
EOF
  host_dnsmasq_args "\${DEN_DOMAIN}"
  for f in $(families_names); do
    host_dnsmasq_args "$(family_domain "$f")"
  done
  printf '\n  # docker compose run --rm backup: every family; backup.sh finds those on the Den host by\n  # DEN_HOSTED_FAMILIES (in /data, by address) and the others in /families.\n  backup:\n'
  printf '    environment:\n      DEN_HOSTED_FAMILIES: "%s"\n' "$(families_hosted_env)"
  if [ -n "$contained" ]; then
    printf '    volumes:\n'
    for f in $contained; do
      family_backup_mount "$f"
    done
    printf '\nvolumes:\n'
    for f in $contained; do
      family_volume_decl "$f"
    done
  fi
}

families_compose_files() { # what COMPOSE_FILE says when there are other families
  local files=compose.yaml:compose.families.yaml
  # Setting COMPOSE_FILE stops Compose from reading compose.override.yaml by itself.
  [ -f compose.override.yaml ] && files=$files:compose.override.yaml
  printf '%s' "$files"
}

# families_render: compose.families.yaml, Caddyfile.families and COMPOSE_FILE in .env, from the
# DEN_FAMILY_ lines; without any, compose.yaml alone, as on a server with one family.
families_render() {
  local names want f
  names=$(families_names)
  if [ -z "$names" ]; then
    if [[ "$(env_get COMPOSE_FILE)" == *compose.families.yaml* ]]; then
      if [ "$CHECK" = 1 ]; then info "would take COMPOSE_FILE out of .env"; else sed -i 's/^COMPOSE_FILE=/# COMPOSE_FILE=/' .env; fi
    fi
    for f in compose.families.yaml Caddyfile.families; do
      [ -e "$f" ] || continue
      if [ "$CHECK" = 1 ]; then info "would remove: $f"; else rm -f "$f"; info "removed: $f"; fi
    done
    return 0
  fi
  info "Other families on this server: $(echo $names)"
  put Caddyfile.families 644 < <(families_caddyfile)
  put compose.families.yaml 644 < <(families_compose)
  want=$(families_compose_files)
  if [ "$(env_get COMPOSE_FILE)" != "$want" ]; then
    if [ "$CHECK" = 0 ] && ! grep -q '^#\{0,1\} *COMPOSE_FILE=' .env; then
      printf '\n# The compose files: install.sh sets this while there are other families.\nCOMPOSE_FILE=%s\n' "$want" >> .env
    else
      env_set COMPOSE_FILE "$want"
    fi
    info "COMPOSE_FILE=$want (in .env): docker compose reads both files"
  fi
}

# --- Adding and removing ---------------------------------------------------------------------

families_ready() { # the first family's install has run on this server
  local first
  first=$(env_get DEN_DOMAIN)
  { [ -f .env ] && [ -n "$first" ] && [ "$first" != den.example.com ]; } ||
    stop "set up the first family first: sudo ./install.sh"
  { command -v docker >/dev/null && docker compose version >/dev/null 2>&1; } ||
    stop "Docker with Compose isn't installed yet: sudo ./install.sh"
  [ -f /etc/den/den_fw.nft ] || stop "the firewall isn't installed yet: sudo ./install.sh"
}

families_host_ready() { # the Den host runs, and is new enough to take families on
  [ "$CHECK" = 1 ] && return 0
  docker compose exec -T hub /app/bin/den_hub families >/dev/null 2>&1 ||
    stop "the first family's hub isn't running a Den host yet. Update it first (git pull, then sudo ./install.sh), then run this again. Nothing changed."
}

families_free_port() { # the next port for a hub container: 47735, 47737, ...
  local p=$FAMILY_FIRST_PORT used f
  used=" 47733 $(env_get DEN_PORT) "
  for f in $(families_contained); do used+="$(family_port "$f") "; done
  while [[ "$used" == *" $p "* ]] || { command -v ss >/dev/null && [ -n "$(ss -Hltn "sport = :$p" 2>/dev/null)" ]; }; do
    p=$((p + 2))
  done
  printf '%s' "$p"
}

# families_zone_check ADDRESS: does the Cloudflare token in .env see the address's zone, so Caddy
# can get its certificate? 0 yes, 1 no, 3 Cloudflare couldn't be asked.
families_zone_check() {
  local token
  token=$(env_get CLOUDFLARE_API_TOKEN)
  [ -n "$token" ] || return 1
  CF_TOKEN=$token python3 - "$1" <<'PY'
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
labels = sys.argv[1].split(".")
for i in range(len(labels) - 1):
    zone = ".".join(labels[i:])
    found = get("/zones?name=" + zone).get("result") or []
    if found:
        if not get("/zones/%s/dns_records?per_page=1" % found[0]["id"]).get("success"):
            print("   The token sees the zone %s but not its records." % zone)
            sys.exit(1)
        print("   The Cloudflare token sees the zone %s: Caddy can get the certificate." % zone)
        sys.exit(0)
sys.exit(1)
PY
}

families_firewall() { # den-allowlist, now, with the families' homes as .env has them
  if [ -f /etc/systemd/system/den-allowlist.service ]; then
    run systemctl start den-allowlist.service || info "den-allowlist reported a problem: journalctl -u den-allowlist -n 20"
  fi
}

families_add() {
  local name="" domain="" homes="" given=0 container=0 h f old where verdict image first a
  local -a words=()
  for a in "$@"; do
    case $a in
      --container) container=1 ;;
      -*) families_usage ;;
      *) words+=("$a") ;;
    esac
  done
  [ ${#words[@]} -ge 2 ] && [ ${#words[@]} -le 3 ] || families_usage
  name=${words[0]}
  families_ready
  families_check_name "$name"
  domain=$(printf '%s' "${words[1]}" | tr '[:upper:]' '[:lower:]')
  domain=${domain#https://}; domain=${domain%%/*}; domain=${domain%.}
  families_valid_address "$domain" || stop "${words[1]} isn't an address like den-$name.example.com"
  if [ ${#words[@]} -eq 3 ]; then
    given=1
    homes=$(printf '%s' "${words[2]}" | tr ',' ' ' | tr '[:upper:]' '[:lower:]' | awk '{$1 = $1; print}')
  fi
  [ "$given" = 1 ] || homes=$(family_homes "$name")   # run again without homes: they stay as they are
  for h in $homes; do
    families_valid_address "${h%.}" || stop "$h isn't a DDNS name like home.$name.example.net"
  done
  [ "$domain" != "$(env_get DEN_DOMAIN)" ] || stop "$domain is the first family's address"
  for f in $(families_names); do
    [ "$f" = "$name" ] || [ "$(family_domain "$f")" != "$domain" ] || stop "$domain is $f's address already"
  done
  old=$(family_domain "$name")
  [ -z "$old" ] || [ "$old" = "$domain" ] ||
    stop "$name is on this server already, at $old. A new address is a new app on every phone; to move them anyway, remove-family $name (its data stays), then add-family $name with the new address."
  # Where it runs: as it was for a family already here; else on the host, or its own container.
  where=$(family_port "$name")
  if [ -z "$where" ]; then
    if [ "$container" = 1 ]; then where=$(families_free_port); else where=host; fi
  elif [ "$container" = 1 ] && [ "$where" = host ]; then
    stop "$name is on the Den host already; a container of its own would be a second hub for the same family"
  fi

  step "Family $name: https://$domain"
  # Caddy gets every family's certificate with the one token in .env, through the zone's DNS.
  verdict=0
  families_zone_check "$domain" || verdict=$?
  case $verdict in
    0) ;;
    3) ;;
    *)
      first=$(env_get DEN_DOMAIN)
      stop "Caddy gets each family's certificate with CLOUDFLARE_API_TOKEN from .env, and that token doesn't see $domain's zone (or can't edit its DNS records). In Cloudflare, My Profile, API Tokens, the token's Edit: add that zone under Zone Resources, if it's in your account. Or give the family a name in the zone the token has, like den-$name.${first#*.}. Nothing changed."
      ;;
  esac
  if [ "$where" = host ]; then
    families_host_ready
  else
    image=$(env_get DEN_IMAGE)
    if [ -z "$image" ] && ! docker image inspect den-hub >/dev/null 2>&1; then
      stop "the hub's image isn't built yet: sudo ./install.sh builds it. Nothing changed."
    fi
  fi

  families_env_line "$(family_key "$name")" "$domain $where${homes:+ $homes}"
  families_render
  if [ "$where" = host ]; then
    family_start "$name" ||
      stop "the Den host didn't take $name on: docker compose logs hub says why. Fix that and run this again, or remove-family $name."
  else
    family_start "$name" ||
      stop "hub-$name didn't come up: docker compose logs hub-$name says why. Fix that and run this again, or remove-family $name."
  fi
  families_firewall
  families_show "$name"
}

families_remove() {
  local name="" addr="" delete=0 a domain volume answer hosted=0
  for a in "$@"; do
    case $a in
      --delete-data) delete=1 ;;
      -*) families_usage ;;
      *)
        if [ -z "$name" ]; then name=$a
        elif [ -z "$addr" ]; then addr=$a
        else families_usage; fi
        ;;
    esac
  done
  [ -n "$name" ] || families_usage
  families_ready
  families_check_name "$name"
  domain=$(family_domain "$name")
  if [ -z "$domain" ] && [ -n "$addr" ]; then
    # A family the Den host had, taken off earlier: only the data the host keeps is left.
    [ "$delete" = 1 ] || stop "$name isn't on this server. To delete the data the host keeps for it: sudo ./install.sh remove-family $name $addr --delete-data"
    if [ -t 0 ]; then
      read -rp "   This deletes the hub the host kept for $addr for good: its keys and everything it holds. Type $name to go on: " answer
      [ "$answer" = "$name" ] || stop "nothing changed"
    fi
    run docker compose exec -T hub /app/bin/den_hub remove-family --family "$addr" --delete-data ||
      stop "the Den host didn't delete it (above says why; den_hub families lists what it keeps, with ids)."
    info "Deleted the data the host kept for $addr."
    return 0
  fi
  [ -z "$addr" ] || [ "$addr" = "$domain" ] || stop "$name is at $domain, not $addr"
  volume=$(families_volume "$name")
  family_hosted "$name" && hosted=1
  if [ -z "$domain" ] && ! docker volume inspect "$volume" >/dev/null 2>&1; then
    stop "there's no family called $name on this server (sudo ./install.sh families lists them)"
  fi
  if [ "$delete" = 1 ] && [ -t 0 ]; then
    read -rp "   This deletes $name's hub for good: its keys and everything it holds. Type $name to go on: " answer
    [ "$answer" = "$name" ] || stop "nothing changed"
  fi

  if [ -n "$domain" ]; then
    step "Taking $name (https://$domain) off this server"
    if [ "$hosted" = 1 ]; then
      run docker compose exec -T hub /app/bin/den_hub remove-family --family "$domain" $([ "$delete" = 1 ] && echo --delete-data) ||
        stop "the Den host didn't let $name go: docker compose logs hub says why. Nothing else changed."
    else
      family_stop "$name"
    fi
    if [ "$CHECK" = 0 ]; then sed -i "/^$(family_key "$name")=/d" .env; fi
    families_render
    run docker compose up -d --no-deps --wait --wait-timeout 300 $(families_other_hubs) dnsmasq caddy
    families_firewall
  else
    step "$name isn't on this server any more; its data is"
  fi

  echo
  if [ "$hosted" = 1 ]; then
    if [ "$delete" = 1 ]; then
      info "Deleted $name's data from the Den host."
    else
      info "$name's data stays on the Den host (in the volume $(families_volume hub), under logs/):"
      info "add-family $name $domain brings the same family back. To delete it: sudo ./install.sh remove-family $name $domain --delete-data"
    fi
  elif [ "$delete" = 1 ]; then
    if docker volume inspect "$volume" >/dev/null 2>&1; then
      run docker volume rm "$volume"
      info "Deleted $name's hub and its data (the volume $volume)."
    else
      info "$name's data was already gone (no volume $volume)."
    fi
  else
    info "$name's data stays, in the volume $volume: add-family $name with its address brings"
    info "the same hub back, with the family as it was. To delete it: sudo ./install.sh remove-family $name --delete-data"
  fi
  if [ -d "backups/$name" ]; then
    info "Its backups stay in backups/$name/ (rm -r backups/$name deletes them)."
  fi
  if [ -n "$domain" ]; then
    cat <<EOF

   By hand, when they've moved on:
   - Public DNS, in Cloudflare: delete the record for $domain.
   - Tailscale admin console: DNS, the nameserver restricted to $domain; Access controls,
     group:family-$name and its grant entry; Users, their accounts.
EOF
  fi
  echo
}

# --- Moving containers onto the host ---------------------------------------------------------

# families_merge [--dry-run]: every family with a hub container of its own (a port in its line)
# moves onto the Den host, one by one: a backup of every family first; then for each, its hub
# stops, `den_hub adopt` copies its data (keys.json included, so it keeps its device id and no
# phone pairs again) into the host, which serves it at once, and its line says host. A family
# whose adopt fails gets its own hub back, started again, and the merge stops there. Then Caddy
# sends every address to the host, and the containers go. Their volumes stay, untouched but for
# a note that makes such a hub wait for a phone before writing, should it ever start again.
families_merge() {
  local dry=0 a f domain volume moving=() moved=()
  for a in "$@"; do
    case $a in
      --dry-run) dry=1 ;;
      *) families_usage ;;
    esac
  done
  families_ready
  for f in $(families_contained); do moving+=("$f"); done
  if [ ${#moving[@]} -eq 0 ]; then
    info "Every family here is on the Den host already: nothing to merge."
    return 0
  fi
  step "Moving ${moving[*]} onto the Den host (hub, https://$(env_get DEN_DOMAIN), port $(families_host_port))"
  for f in "${moving[@]}"; do
    domain=$(family_domain "$f")
    volume=$(families_volume "$f")
    docker volume inspect "$volume" >/dev/null 2>&1 || stop "$f's volume $volume isn't here; nothing changed"
    info "$f: https://$domain, hub-$f on port $(family_port "$f"), data in $volume -> the host, data in $(families_volume hub) under logs/"
  done
  if [ "$dry" = 1 ] || [ "$CHECK" = 1 ]; then
    cat <<EOF

   What it would do (--dry-run: nothing changed):
   1. docker compose run --rm backup             every family, into backups/
   2. for each of ${moving[*]}:
        docker compose stop hub-<name>             (only that, if the host has it already)
        docker compose run --rm --no-deps -v <its volume>:/adopt/<name> hub \\
          adopt /adopt/<name> --hostname <its address>
        (the host serves it at once, as the same hub: no phone pairs again; if adopt fails,
        hub-<name> starts again only if the host doesn't have it)
        DEN_FAMILY_<NAME>=<address> host ...       in .env
        Caddyfile.families and compose.families.yaml again, and Caddy and dnsmasq restarted:
        its address to port $(families_host_port) at once
   3. docker compose up -d --remove-orphans dnsmasq caddy    (the hub-<name> containers go)
   The volumes stay as they are. Phones and computers need nothing: same addresses, same hubs.
   Safe to run again if it stops part way.
EOF
    return 0
  fi
  families_host_ready

  step "A backup of every family first"
  run docker compose run --rm backup ||
    stop "the backup didn't finish (above says why); nothing was moved. Fix it and run this again."

  for f in "${moving[@]}"; do
    domain=$(family_domain "$f")
    volume=$(families_volume "$f")
    step "$f: https://$domain onto the host"
    # The host may serve it already (a merge that stopped after the copy, run again): then its
    # container must never run again, whatever happens next. Two of the same hub would number
    # their changes the same.
    if families_served "$domain"; then
      info "The host serves $f already."
      run docker compose stop "hub-$f"
    else
      run docker compose stop "hub-$f"
      if ! run docker compose run --rm --no-deps -v "$volume:/adopt/$f" hub adopt "/adopt/$f" --hostname "$domain"; then
        # adopt can fail after the host took the family on (a connection cut after its answer):
        # ask the host, never the exit code, before starting the container again.
        if families_served "$domain"; then
          info "The host took $f on all the same."
        else
          info "The host didn't take $f on; starting hub-$f again, as it was."
          run docker compose start "hub-$f" || true
          stop "merging $f didn't finish (above says why). ${moved[*]:+Moved: ${moved[*]}. }$f and the families after it keep their own containers; run this again once it's fixed."
        fi
      fi
    fi
    families_env_line "$(family_key "$f")" "$domain host$( [ -n "$(family_homes "$f")" ] && printf ' %s' "$(family_homes "$f")")"
    moved+=("$f")
    # Its address to the host now, not at the end: each family is down only while it moves.
    families_render
    run docker compose up -d --no-deps --wait --wait-timeout 300 dnsmasq caddy
  done
  families_merge_finish
  step "Every family is on the Den host"
  for f in "${moved[@]}"; do
    info "$f: $(family_exec "$f" status 2>/dev/null | tail -n 1)"
  done
  cat <<EOF

   Nothing changes for phones and computers: the same addresses, the same hubs (each kept its
   keys), so they keep syncing; reminders, calendar links and assistants keep working.
   The old volumes stay as they were ($(for f in "${moved[@]}"; do printf '%s ' "$(families_volume "$f")"; done)):
   never start those hubs again. Once you're happy, docker volume rm them. backups/<name>/ has
   each family's backup from just before the move.

EOF
}

families_merge_finish() { # after families moved: the files again, and the containers gone
  families_render
  run docker compose up -d --remove-orphans --no-deps --wait --wait-timeout 300 $(families_other_hubs) dnsmasq caddy
}

# --- What the owner does, and sees -----------------------------------------------------------

families_ts_ip() {
  local ip none="<the server's Tailscale address: tailscale ip -4>"
  ip=$(tailscale ip -4 2>/dev/null | head -n 1 || true)
  printf '%s' "${ip:-$none}"
}
families_public_v4() {
  local ip none="<the server's public IPv4>"
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1 || true)
  printf '%s' "${ip:-$none}"
}

# families_covered ADDRESS: an address whose split-DNS entry also covers this one (Tailscale's
# "Restrict to domain" takes in the names under it), or nothing.
families_covered() {
  local a f
  for a in "$(env_get DEN_DOMAIN)" $(for f in $(families_names); do family_domain "$f"; done); do
    [ "$a" != "$1" ] && [[ "$1" == *".$a" ]] && { printf '%s' "$a"; return 0; }
  done
  return 0
}

host_dns_records() { # ADDRESS: the public DNS record that brings it to this server
  printf '        CNAME  %s  %s     (moving servers then changes one record)\n' "$1" "$(env_get DEN_DOMAIN)"
  printf '        A      %s  %s\n' "$1" "$(families_public_v4)"
}
host_split_dns() { # ADDRESS: the split-DNS entry that sends it through the tunnel
  local covered
  covered=$(families_covered "$1")
  if [ -n "$covered" ]; then
    printf 'nothing: the nameserver for %s covers %s too' "$covered" "$1"
  else
    printf 'Add nameserver, Custom: %s, Restrict to domain on, domain %s' "$(families_ts_ip)" "$1"
  fi
}

families_show() { # NAME: where it lives, and what's left to do by hand
  local name=$1 domain port homes allowed nohomes where
  domain=$(family_domain "$name")
  port=$(family_port "$name")
  homes=$(family_homes "$name")
  nohomes="none, so Tailscale only. Add them later: sudo ./install.sh add-family $name $domain \"<DDNS names>\""
  if [ -n "$homes" ]; then
    allowed=$(/usr/local/sbin/den-allowlist --dry-run 2>&1 | sed -n "s/^\(.*($name):.*\)$/        \1/p" || true)
  fi
  if family_hosted "$name"; then
    where="the Den host (hub, 127.0.0.1:$(families_host_port)) serves https://$domain, with
   $name's own keys and data in the volume $(families_volume hub) under logs/"
  else
    where="hub-$name serves https://$domain from 127.0.0.1:$port, with
   its own data in the volume $(families_volume "$name")"
  fi
  cat <<EOF

   $name is on this server: $where; its backups go to backups/$name/.

   1. Public DNS, in Cloudflare, DNS only (grey cloud), one of:
$(host_dns_records "$domain")
   2. Tailscale admin console:
      - DNS, Nameservers: $(host_split_dns "$domain")
      - Access controls: the family's group, and the group in the src of the grant to
        tag:den-server (tailscale-acl.hujson):
          "group:family-$name": ["<their sign-in emails>"],
      - Users, Invite users: them (docs/hosting.md, "Tailscale for several families")
   3. Their homes, on Cloudflare as DNS only: ${homes:-$nohomes}
EOF
  [ -z "${allowed:-}" ] || printf '      The firewall lets them in now:\n%s\n' "$allowed"
  cat <<EOF
   4. For their first parent's iPhone, at home or with Tailscale on, once 1 and 2 are done:
$(family_setup "$name" | sed 's/^/        /')
      ($(family_exec_shown "$name" setup-link) shows it again.) Then send them
      "For the family (private)" from docs/hosting.md, with their address in it.

EOF
}

families_list() {
  local f fmt='   %-8s %-30s %-11s %-6s %-22s %-15s %s\n' states hostport
  [ -f .env ] || stop "no .env here yet: sudo ./install.sh sets up the first family"
  states=$(docker compose ps -a --format '{{.Service}}	{{.Status}}' 2>/dev/null || true)
  state() { printf '%s' "$states" | awk -F '\t' -v s="$1" '$1 == s {print $2}'; }
  hostport=$(families_host_port)
  echo
  printf "$fmt" family address hub port data backups now
  printf "$fmt" "(first)" "$(env_get DEN_DOMAIN)" hub "$hostport" "$(families_volume hub)" backups/ "$(state hub)"
  for f in $(families_names); do
    if family_hosted "$f"; then
      printf "$fmt" "$f" "$(family_domain "$f")" "hub (host)" "$hostport" "$(families_volume hub)" "backups/$f/" "$(state hub)"
    else
      printf "$fmt" "$f" "$(family_domain "$f")" "hub-$f" "$(family_port "$f")" "$(families_volume "$f")" \
        "backups/$f/" "$(state "hub-$f")"
    fi
  done
  echo
  printf '   homes:   (first) %s\n' "$(env_get DEN_HOMES | grep . || echo 'none (Tailscale only)')"
  for f in $(families_names); do
    printf '            %s %s\n' "$f" "$(family_homes "$f" | grep . || echo 'none (Tailscale only)')"
  done
  if [ -n "$(families_contained)" ]; then
    printf '\n   In containers of their own: %s. sudo ./install.sh merge-families moves them onto the Den host.\n' "$(families_contained | paste -sd ' ' -)"
  fi
  echo
}

families_whats_left() { # step 8: the other families' names, which need the same as the first
  local f names
  names=$(families_names)
  [ -n "$names" ] || return 0
  printf '\n   The other families on this server need the same public DNS record (a CNAME to %s\n   does) and split-DNS nameserver for their own addresses (sudo ./install.sh families):\n' "$(env_get DEN_DOMAIN)"
  for f in $names; do
    printf '        %-10s %-32s setup link: %s\n' "$f" "$(family_domain "$f")" "$(family_exec_shown "$f" setup-link)"
  done
}
