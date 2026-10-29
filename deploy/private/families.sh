# shellcheck shell=bash
# Den, private setup: several families on one server (docs/hosting.md, "Several families").
# install.sh sources this and calls three things:
#   families_command add-family|remove-family|families ...   for sudo ./install.sh add-family ...
#   families_render       in step 7, before docker compose: the generated files below
#   families_whats_left   in step 8: the other families' names to point at this server
# It uses install.sh's helpers (step, info, stop, run, put, env_get, env_set) and CHECK.
#
# The first family is the one install.sh set up: DEN_DOMAIN, DEN_HOMES and DEN_PORT in .env, the
# service hub, the volume den-hub, its backups in backups/. Each other family is one line in .env,
# which add-family writes and remove-family takes out:
#   DEN_FAMILY_SMITH=den-smith.example.com 47735 home.smith.example.net
#                    its address           its hub's port, then its homes' DDNS names
# From those lines install.sh keeps two generated files in step (don't edit them; they're written
# again on every run), and sets COMPOSE_FILE in .env so that plain `docker compose ...` reads both
# compose files:
#   compose.families.yaml   hub-smith: the hub service again, on its own port and 127.0.0.1, with
#                           its own volume den-smith; dnsmasq's answer for its address; the backup
#                           service's view of its data; and Caddy's copy of
#   Caddyfile.families      a site for each family's address, to its own hub only
# den-allowlist reads the same lines and lets each family's homes reach 443.
#
# The functions named host_* make one address reach this server (its Caddy site, dnsmasq answer,
# split-DNS line, public DNS record) and don't care what serves it; the family_* ones are about
# its hub container. Every family keeps its own volume and its own DEN_PUBLIC_URL.

FAMILY_FIRST_PORT=47735

families_usage() {
  cat >&2 <<'EOF'
Usage:
  sudo ./install.sh add-family NAME ADDRESS ["HOMES"]
      like: sudo ./install.sh add-family smith den-smith.example.com "home.smith.example.net"
      NAME is short, lower-case letters and digits; HOMES are the family's homes' DDNS names,
      separated by spaces (none: Tailscale only). Run it again with the same name and address to
      change the homes.
  sudo ./install.sh remove-family NAME [--delete-data]
      takes the family off this server; its data stays unless --delete-data
  sudo ./install.sh families
      the families on this server: address, hub, port, data and backups
EOF
  exit 64
}

families_command() { # add-family | remove-family | families, then its arguments
  local cmd=$1
  shift
  [ "$(id -u)" = 0 ] || stop "run it as root: sudo ./install.sh $cmd ..."
  case $cmd in
    add-family) families_add "$@" ;;
    remove-family) families_remove "$@" ;;
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
family_port() { env_get "$(family_key "$1")" | awk '{print $2}'; }
family_homes() { env_get "$(family_key "$1")" | awk '{$1 = $2 = ""; sub(/^ +/, ""); print}'; }

families_project() { # Compose's project name: den, from compose.yaml
  local p=${COMPOSE_PROJECT_NAME:-}
  [ -n "$p" ] || p=$(env_get COMPOSE_PROJECT_NAME)
  printf '%s' "${p:-den}"
}
families_volume() { printf '%s_den-%s' "$(families_project)" "$1"; }

families_check_name() {
  [[ $1 =~ ^[a-z][a-z0-9]{0,19}$ ]] || stop "a family's name is lower-case letters and digits, starting with a letter, at most 20, like smith (it names hub-smith, its volume and its backups' folder)"
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
    printf '\n# Other families on this server, a line each: the address, the hub'"'"'s port, the homes'"'"' DDNS\n# names. sudo ./install.sh add-family and remove-family write them (docs/hosting.md).\n%s=%s\n' "$key" "$value" >> .env
  fi
}

# --- The generated files ---------------------------------------------------------------------

# Two kinds of piece, kept apart. Per address (needed however the family is served): its Caddy
# site, its dnsmasq answer, and (further down) its split-DNS line and public DNS record. Per hub
# container (what a single Den process serving several families would replace): its compose
# service, its backup mount, starting it, and its setup code.

host_caddy_site() { # ADDRESS PORT: Caddy's site for an address, to the hub on that port
  printf '\n%s {\n\timport den %s\n}\n' "$1" "$2"
}
host_dnsmasq_args() { # ADDRESS: dnsmasq's answer for it, the server's Tailscale address (compose)
  printf '      - --interface-name=%s,tailscale0/4\n      - --local=/%s/\n' "$1" "$1"
}

family_hub_service() { # NAME ADDRESS PORT: the family's hub, as a compose service
  cat <<EOF
  # $1: https://$2
  hub-$1:
    extends: {file: compose.yaml, service: hub}
    # The image the first family's hub builds (or DEN_IMAGE names), built once for every family.
    build: !reset null
    environment:
      DEN_PORT: "$3"
      # Each family's own address: its links, sign-in pages and OAuth name it, and no other.
      DEN_PUBLIC_URL: https://$2
    volumes:
      # Its own volume, never shared with another family.
      - den-$1:/data

EOF
}
family_backup_mount() { printf '      - den-%s:/families/%s\n' "$1" "$1"; }
family_volume_decl() { printf '  den-%s:\n' "$1"; }
family_start() { # NAME: start (or keep) its hub, and the shared services with the new files
  run docker compose up -d --no-deps --wait --wait-timeout 300 "hub-$1" dnsmasq caddy
}
family_stop() { # NAME: stop and remove its hub; its volume stays
  run docker compose rm --stop --force "hub-$1"
}
family_setup() { # NAME: the hub's setup link if it has one, else its setup code
  local out
  if out=$(docker compose exec -T "hub-$1" /app/bin/den_hub setup-link 2>/dev/null) && [[ "$out" == *https://* ]]; then
    printf '%s' "$out"
  elif out=$(docker compose exec -T "hub-$1" /app/bin/den_hub setup-code 2>/dev/null); then
    printf '%s' "$out"
  else
    printf '(hub-%s gives it once it runs: docker compose exec hub-%s /app/bin/den_hub setup-code)' "$1" "$1"
  fi
}

families_caddyfile() {
  local f
  cat <<'EOF'
# Generated by install.sh (families.sh) from the DEN_FAMILY_ lines in .env; don't edit it.
# A site for each of the other families' addresses, to that family's own hub only. The den
# snippet (the certificate, compression, the proxy) is in Caddyfile, which imports this file.
EOF
  for f in $(families_names); do
    host_caddy_site "$(family_domain "$f")" "$(family_port "$f")"
  done
}

families_compose() {
  local f
  cat <<'EOF'
# Generated by install.sh (families.sh) from the DEN_FAMILY_ lines in .env; don't edit it: it's
# written again on every run. sudo ./install.sh add-family and remove-family change the families
# (docs/hosting.md, "Several families"). COMPOSE_FILE in .env adds this file to compose.yaml.

services:
EOF
  for f in $(families_names); do
    family_hub_service "$f" "$(family_domain "$f")" "$(family_port "$f")"
  done
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
  printf '\n  # docker compose run --rm backup: every family; backup.sh finds them in /families.\n  backup:\n    volumes:\n'
  for f in $(families_names); do
    family_backup_mount "$f"
  done
  printf '\nvolumes:\n'
  for f in $(families_names); do
    family_volume_decl "$f"
  done
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

families_free_port() { # the next port for a hub: 47735, 47737, ...
  local p=$FAMILY_FIRST_PORT used f
  used=" 47733 $(env_get DEN_PORT) "
  for f in $(families_names); do used+="$(family_port "$f") "; done
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
  [ $# -ge 2 ] && [ $# -le 3 ] || families_usage
  local name=$1 domain homes h f old port verdict image first
  families_ready
  families_check_name "$name"
  domain=$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')
  domain=${domain#https://}; domain=${domain%%/*}; domain=${domain%.}
  families_valid_address "$domain" || stop "$2 isn't an address like den-$name.example.com"
  if [ $# -eq 3 ]; then
    homes=$(printf '%s' "$3" | tr ',' ' ' | tr '[:upper:]' '[:lower:]' | awk '{$1 = $1; print}')
  else
    homes=$(family_homes "$name")   # run again without homes: they stay as they are
  fi
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
  port=$(family_port "$name")
  [ -n "$port" ] || port=$(families_free_port)

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
  image=$(env_get DEN_IMAGE)
  if [ -z "$image" ] && ! docker image inspect den-hub >/dev/null 2>&1; then
    stop "the hub's image isn't built yet: sudo ./install.sh builds it. Nothing changed."
  fi

  families_env_line "$(family_key "$name")" "$domain $port${homes:+ $homes}"
  families_render
  family_start "$name" ||
    stop "hub-$name didn't come up: docker compose logs hub-$name says why. Fix that and run this again, or remove-family $name."
  families_firewall
  families_show "$name"
}

families_remove() {
  local name="" delete=0 a domain volume answer
  for a in "$@"; do
    case $a in
      --delete-data) delete=1 ;;
      -*) families_usage ;;
      *) [ -z "$name" ] || families_usage; name=$a ;;
    esac
  done
  [ -n "$name" ] || families_usage
  families_ready
  families_check_name "$name"
  domain=$(family_domain "$name")
  volume=$(families_volume "$name")
  if [ -z "$domain" ] && ! docker volume inspect "$volume" >/dev/null 2>&1; then
    stop "there's no family called $name on this server (sudo ./install.sh families lists them)"
  fi
  if [ "$delete" = 1 ] && [ -t 0 ]; then
    read -rp "   This deletes $name's hub for good: its keys and everything it holds. Type $name to go on: " answer
    [ "$answer" = "$name" ] || stop "nothing changed"
  fi

  if [ -n "$domain" ]; then
    step "Taking $name (https://$domain) off this server"
    family_stop "$name"
    if [ "$CHECK" = 0 ]; then sed -i "/^$(family_key "$name")=/d" .env; fi
    families_render
    run docker compose up -d --no-deps --wait --wait-timeout 300 dnsmasq caddy
    families_firewall
  else
    step "$name isn't on this server any more; its data is"
  fi

  echo
  if [ "$delete" = 1 ]; then
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
  local name=$1 domain port homes allowed nohomes
  domain=$(family_domain "$name")
  port=$(family_port "$name")
  homes=$(family_homes "$name")
  nohomes="none, so Tailscale only. Add them later: sudo ./install.sh add-family $name $domain \"<DDNS names>\""
  if [ -n "$homes" ]; then
    allowed=$(/usr/local/sbin/den-allowlist --dry-run 2>&1 | sed -n "s/^\(.*($name):.*\)$/        \1/p" || true)
  fi
  cat <<EOF

   $name is on this server: hub-$name serves https://$domain from 127.0.0.1:$port, with
   its own data in the volume $(families_volume "$name"); its backups go to backups/$name/.

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
   4. For their first parent's phone, at home or with Tailscale on: https://$domain in Safari,
      Share, Add to Home Screen, then Start a family, with
$(family_setup "$name" | sed 's/^/        /')
      (docker compose exec hub-$name /app/bin/den_hub setup-code shows it again.) Then send them
      "For the family (private)" from docs/hosting.md, with their address in it.

EOF
}

families_list() {
  local f fmt='   %-8s %-30s %-11s %-6s %-22s %-15s %s\n' states
  [ -f .env ] || stop "no .env here yet: sudo ./install.sh sets up the first family"
  states=$(docker compose ps -a --format '{{.Service}}	{{.Status}}' 2>/dev/null || true)
  state() { printf '%s' "$states" | awk -F '\t' -v s="$1" '$1 == s {print $2}'; }
  echo
  printf "$fmt" family address hub port data backups now
  printf "$fmt" "(first)" "$(env_get DEN_DOMAIN)" hub "$(env_get DEN_PORT | grep . || echo 47733)" \
    "$(families_volume hub)" backups/ "$(state hub)"
  for f in $(families_names); do
    printf "$fmt" "$f" "$(family_domain "$f")" "hub-$f" "$(family_port "$f")" "$(families_volume "$f")" \
      "backups/$f/" "$(state "hub-$f")"
  done
  echo
  printf '   homes:   (first) %s\n' "$(env_get DEN_HOMES | grep . || echo 'none (Tailscale only)')"
  for f in $(families_names); do
    printf '            %s %s\n' "$f" "$(family_homes "$f" | grep . || echo 'none (Tailscale only)')"
  done
  echo
}

families_whats_left() { # step 8: the other families' names, which need the same as the first
  local f names
  names=$(families_names)
  [ -n "$names" ] || return 0
  printf '\n   The other families on this server need the same public DNS record (a CNAME to %s\n   does) and split-DNS nameserver for their own addresses (sudo ./install.sh families):\n' "$(env_get DEN_DOMAIN)"
  for f in $names; do
    printf '        %-10s %-32s setup code: docker compose exec hub-%s /app/bin/den_hub setup-code\n' \
      "$f" "$(family_domain "$f")" "$f"
  done
}
