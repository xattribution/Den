#!/bin/sh
# Encrypted backups of every family's hub on this server: what the private setup's backup service
# runs (compose.yaml), in the hub's image, as root, with no network. It sees the Den host's data in
# /data: the first family's, and each family on the host under /data/logs/, which it finds by
# address (DEN_HOSTED_FAMILIES, "smith=den-smith.example.com ...", from compose.families.yaml);
# and a family that keeps a hub container of its own in /families/<name> (compose.families.yaml
# mounts them). It writes into /backups, which is ./backups on the server: the first family's
# backups in backups/, each other family's in backups/<name>/, one family per file, wherever it
# runs. Each keeps its newest DEN_BACKUP_KEEP (14), sealed with DEN_BACKUP_PASSPHRASE.
# docs/hosting.md, "Several families".
#
#   docker compose run --rm backup                   every family (what the nightly cron runs)
#   docker compose run --rm backup smith             one family; hub is the first family
#   docker compose run --rm backup restore backups/den-2026-10-28-0317.denbackup
#   docker compose run --rm backup restore backups/smith/den-2026-10-28-0317.denbackup
#                                    into the family whose folder the backup is in, with its hub
#                                    stopped first: docker compose stop hub, which is every family
#                                    on the host (or hub-smith, for a container of its own)
#   docker compose run --rm backup restore newest
#                                    every family from its newest backup, with every hub stopped:
#                                    for moving to a new server
set -eu

usage() {
  echo "Usage: docker compose run --rm backup [FAMILY... | restore backups/[FAMILY/]den-....denbackup | restore newest]" >&2
  exit 64
}

# The families on the Den host: name=address, a word each.
hosted_address() { # NAME: its address, when it is a family on the host
  for pair in ${DEN_HOSTED_FAMILIES:-}; do
    [ "${pair%%=*}" = "$1" ] && { echo "${pair#*=}"; return 0; }
  done
  return 1
}

# The families here: hub (the first), the ones on the host, then each in a container of its own.
families() {
  echo hub
  for pair in ${DEN_HOSTED_FAMILIES:-}; do
    echo "${pair%%=*}"
  done
  for d in /families/*/; do
    [ -d "$d" ] && basename "$d"
  done
  return 0
}
# den_hub's --data and, for a family on the host, --family.
data_args() {
  if [ "$1" = hub ]; then
    echo "--data /data"
  elif address=$(hosted_address "$1"); then
    echo "--data /data --family $address"
  else
    echo "--data /families/$1"
  fi
}
owned_dir() { if [ "$1" = hub ] || hosted_address "$1" >/dev/null; then echo /data; else echo "/families/$1"; fi; }
dir_of() { if [ "$1" = hub ]; then echo backups; else echo "backups/$1"; fi; }
service_of() { if [ "$1" = hub ] || hosted_address "$1" >/dev/null; then echo hub; else echo "hub-$1"; fi; }
known() { [ "$1" = hub ] || hosted_address "$1" >/dev/null || { [ -n "$1" ] && [ -d "/families/$1" ]; }; }

# Paths are relative to /, so what this prints (backups/smith/den-...) is what the server has
# in den/deploy/private.
cd /

back_up() { # FAMILY
  dir=$(dir_of "$1")
  mkdir -p "$dir"
  # shellcheck disable=SC2046 # data_args is words on purpose
  /app/bin/den_hub backup $(data_args "$1") --out "$dir/den-$(date -u +%Y-%m-%d-%H%M).denbackup" \
    --passphrase-env DEN_BACKUP_PASSPHRASE || return 1
  # The names sort by date and time (UTC): keep the newest.
  ls -1 "$dir"/den-*.denbackup | sort -r | tail -n "+$((${DEN_BACKUP_KEEP:-14} + 1))" | xargs -r rm -f --
}

restore_file() { # FAMILY FILE
  echo "$(service_of "$1"): restoring $2"
  # shellcheck disable=SC2046
  if ! /app/bin/den_hub restore $(data_args "$1") --in "$2" --passphrase-env DEN_BACKUP_PASSPHRASE --force; then
    echo "Nothing changed. If $(service_of "$1") is running, stop it first: docker compose stop $(service_of "$1")" >&2
    return 1
  fi
  chown -R den:den "$(owned_dir "$1")"
}

newest() { # FAMILY: its newest backup, or nothing
  ls -1 "$(dir_of "$1")"/den-*.denbackup 2>/dev/null | sort | tail -n 1
}

[ "${1:-}" = backup ] && shift

case "${1:-}" in
  "")
    # Every family, each on its own: one that fails doesn't stop the others.
    failed=""
    for f in $(families); do
      back_up "$f" || failed="$failed $f"
    done
    if [ -n "$failed" ]; then
      echo "No backup for:$failed" >&2
      exit 1
    fi
    ;;
  restore)
    [ $# -eq 2 ] || usage
    if [ "$2" = newest ]; then
      failed=""
      for f in $(families); do
        file=$(newest "$f")
        if [ -z "$file" ]; then
          echo "$(service_of "$f"): no backup in $(dir_of "$f")/, so it stays as it is"
          continue
        fi
        restore_file "$f" "$file" || failed="$failed $f"
      done
      [ -z "$failed" ] || { echo "Not restored:$failed" >&2; exit 1; }
      exit 0
    fi
    # As the server sees it (backups/smith/den-...), so tab completion works; the folder says
    # whose it is.
    file=${2#/}
    file=backups/${file#backups/}
    case ${file#backups/} in
      */*/*) usage ;;
      */*) family=${file#backups/}; family=${family%%/*} ;;
      *) family=hub ;;
    esac
    known "$family" || { echo "There's no family called $family on this server (sudo ./install.sh families)." >&2; exit 64; }
    [ -f "$file" ] || { echo "There's no backup at $file." >&2; exit 66; }
    restore_file "$family" "$file"
    ;;
  -*) usage ;;
  *)
    for f in "$@"; do
      known "$f" || { echo "There's no family called $f on this server (sudo ./install.sh families)." >&2; exit 64; }
    done
    for f in "$@"; do back_up "$f"; done
    ;;
esac
