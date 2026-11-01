#!/bin/sh
# Den's Cloudflare Tunnel connector: what the `tunnel` service of deploy/install.sh's compose file
# runs, in its own container from the hub's own image, beside the hub, with the hub's data mounted.
#
# Nobody configures it. It waits for the tunnel token in <data>/hub/tunnel-token (the hub's
# first-boot page, or `den tunnel`, writes it there), runs cloudflared with it, restarts
# cloudflared within a few seconds whenever the token changes, stops it when the file goes away,
# and starts it again (backing off) if it exits. What it sees goes to <data>/hub/tunnel-status.json,
# one line of JSON, rewritten every few seconds (docs/install-technical.md, "The tunnel"):
#
#   {"state":"waiting|starting|connected|error","hostname":"den.example.com","service":
#    "http://hub:47733","connections":4,"message":"...","since":"...Z","updated":"...Z"}
#
# The tunnel's public hostname in Cloudflare must send to http://hub:47733: the hub, by its
# name on the compose network, never this container's localhost (the hub would take the
# internet's requests for its own machine's).
#
#   den-connector          run (the container's entrypoint)
#   den-connector once     one pass, then exit (for tests)
set -u

DATA=${DEN_DATA:-/data}
TOKEN_FILE=$DATA/hub/tunnel-token
STATUS_FILE=$DATA/hub/tunnel-status.json
# cloudflared's metrics server: on the compose network too, so the hub reads /ready and /config
# at http://tunnel:20241 (DEN_CONNECTOR_METRICS in the hub's environment). Nothing publishes it.
LISTEN=${DEN_CONNECTOR_LISTEN:-0.0.0.0:20241}
METRICS=127.0.0.1:${LISTEN##*:}
LOG=${TMPDIR:-/tmp}/cloudflared.log
CLOUDFLARED=${DEN_CLOUDFLARED:-cloudflared}
TICK=${DEN_CONNECTOR_TICK:-3}

pid=            # cloudflared's process, while it runs
running_fp=     # the token it runs with (a hash of it, never the token)
shown=0         # lines of its log already copied to this container's output
state=waiting
since=
message=
backoff=0       # seconds until cloudflared may start again after it exited
next_start=0

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
epoch() { date -u +%s; }

# The token alone, from whatever was pasted: Cloudflare's dashboard shows it inside a command
# (cloudflared service install eyJ...), so take the eyJ... word, else the whole text.
read_token() {
  [ -s "$TOKEN_FILE" ] || return 0
  rt_text=$(tr -d '\r' < "$TOKEN_FILE" 2>/dev/null) || return 0
  rt_word=$(printf '%s\n' "$rt_text" | grep -o 'eyJ[A-Za-z0-9+/=_-]*' | head -n 1)
  if [ -n "$rt_word" ]; then printf '%s' "$rt_word"; else printf '%s' "$rt_text" | tr -d ' \t\n'; fi
}

json_escape() { printf '%s' "$1" | tr -d '\000-\037' | sed 's/\\/\\\\/g; s/"/\\"/g'; }

set_state() { # set_state STATE [MESSAGE]
  if [ "$1" != "$state" ]; then since=$(now); fi
  state=$1
  message=${2:-}
}

write_status() { # write_status HOSTNAME SERVICE CONNECTIONS
  [ -d "$DATA/hub" ] || mkdir -p "$DATA/hub" 2>/dev/null || return 0
  ws_host=null ws_service=null
  [ -n "$1" ] && ws_host="\"$(json_escape "$1")\""
  [ -n "$2" ] && ws_service="\"$(json_escape "$2")\""
  ws_tmp=$STATUS_FILE.tmp.$$
  (
    umask 077
    printf '{"state":"%s","hostname":%s,"service":%s,"connections":%s,"message":"%s","since":"%s","updated":"%s"}\n' \
      "$state" "$ws_host" "$ws_service" "${3:-0}" "$(json_escape "$message")" "${since:-$(now)}" "$(now)" > "$ws_tmp"
  ) && mv -f "$ws_tmp" "$STATUS_FILE"
}

stop_cloudflared() {
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null
    sc_i=0
    while kill -0 "$pid" 2>/dev/null && [ "$sc_i" -lt 10 ]; do sleep 1; sc_i=$((sc_i + 1)); done
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  fi
  pid=
  running_fp=
}

start_cloudflared() { # start_cloudflared TOKEN FINGERPRINT
  : > "$LOG"
  shown=0
  # The token goes in the environment (only this container's user can read it there), not on
  # the command line, where `ps` on the server would show it.
  TUNNEL_TOKEN=$1 "$CLOUDFLARED" tunnel --no-autoupdate --metrics "$LISTEN" --loglevel info run >> "$LOG" 2>&1 &
  pid=$!
  running_fp=$2
  set_state starting "Connecting to Cloudflare"
}

# Copies cloudflared's new log lines to this container's output (docker compose logs tunnel),
# and keeps the log file small.
pass_log() {
  [ -f "$LOG" ] || return 0
  pl_total=$(wc -l < "$LOG" | tr -d ' ')
  if [ "$pl_total" -gt "$shown" ]; then
    tail -n "+$((shown + 1))" "$LOG" | head -n "$((pl_total - shown))"
    shown=$pl_total
  fi
  if [ "$(wc -c < "$LOG" | tr -d ' ')" -gt 1000000 ]; then : > "$LOG"; shown=0; fi
}

# Why cloudflared stopped, in words for the setup page, from the end of its log.
exit_reason() {
  er_tail=$(tail -n 30 "$LOG" 2>/dev/null)
  case $er_tail in
    *"not valid"* | *"invalid token"* | *"Invalid tunnel secret"* | *"illegal base64"* | *"Unauthorized"*)
      echo "Cloudflare didn't accept the tunnel token. Copy it again from the tunnel's page in Cloudflare and paste it in." ;;
    *"deleted"* | *"not found"*)
      echo "Cloudflare says this tunnel no longer exists. Make a new one and paste its token." ;;
    *"dial tcp"* | *"no such host"* | *"i/o timeout"* | *"network is unreachable"*)
      echo "Can't reach Cloudflare from this computer. Check that it's connected to the internet." ;;
    *) echo "The tunnel stopped. Den tries again by itself in a moment." ;;
  esac
}

tick() {
  token=$(read_token)
  if [ -n "$token" ]; then
    fp=$(printf '%s' "$token" | sha256sum | cut -c1-16)
  else
    fp=
  fi

  if [ -z "$fp" ]; then
    if [ -n "$pid" ]; then stop_cloudflared; fi
    backoff=0
    set_state waiting "No tunnel token yet"
    write_status "" "" 0
    return 0
  fi

  if [ -n "$pid" ] && [ "$fp" != "$running_fp" ]; then
    echo "den-connector: the tunnel token changed; restarting cloudflared"
    stop_cloudflared
    backoff=0
    next_start=0
  fi

  if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
    wait "$pid" 2>/dev/null
    pass_log
    pid=
    reason=$(exit_reason)
    backoff=$(( backoff == 0 ? 5 : backoff * 2 ))
    [ "$backoff" -gt 60 ] && backoff=60
    next_start=$(( $(epoch) + backoff ))
    set_state error "$reason"
    echo "den-connector: cloudflared exited; trying again in ${backoff}s"
  fi

  if [ -z "$pid" ]; then
    if [ "$(epoch)" -ge "$next_start" ]; then
      start_cloudflared "$token" "$fp"
    fi
    write_status "" "" 0
    return 0
  fi

  pass_log
  ready=$(curl -fsS --max-time 2 "http://$METRICS/ready" 2>/dev/null) || ready=
  connections=$(printf '%s' "$ready" | grep -o '"readyConnections":[0-9]*' | head -n 1 | cut -d: -f2)
  config=$(curl -fsS --max-time 2 "http://$METRICS/config" 2>/dev/null) || config=
  hostname=$(printf '%s' "$config" | grep -o '"hostname":"[^"]*"' | head -n 1 | cut -d'"' -f4)
  service=$(printf '%s' "$config" | grep -o '"service":"[^"]*"' | head -n 1 | cut -d'"' -f4)
  if [ "${connections:-0}" -gt 0 ]; then
    backoff=0
    if [ -z "$hostname" ]; then
      set_state connected "Connected, but the tunnel has no public hostname yet. In Cloudflare, give it one with the service http://hub:47733."
    elif [ "$service" != "http://hub:47733" ]; then
      set_state connected "Connected, but the tunnel sends $hostname to $service. In Cloudflare, change its service to http://hub:47733."
    else
      set_state connected ""
    fi
  elif [ "$state" != starting ]; then
    set_state starting "Connecting to Cloudflare"
  fi
  write_status "$hostname" "$service" "${connections:-0}"
}

case "${1:-run}" in
  once)
    tick
    stop_cloudflared
    exit 0
    ;;
  run)
    trap 'stop_cloudflared; exit 0' TERM INT
    since=$(now)
    echo "den-connector: watching $TOKEN_FILE for the tunnel token"
    while :; do
      tick
      sleep "$TICK" &
      wait $!
    done
    ;;
  *)
    echo "usage: den-connector [run | once]" >&2
    exit 64
    ;;
esac
