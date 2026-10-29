#!/bin/sh
# Encrypted backups of the hub in /data, into /backups: what the compose files' `backup` service
# runs (docs/hosting.md, "Backups"). It runs as root in its own short-lived container, with no
# network, so it can write to a folder on the server and hand restored files back to the hub's
# user. The passphrase comes from DEN_BACKUP_PASSPHRASE.
#
#   den-backup                  backs up to /backups/den-<UTC date and time>.denbackup and keeps
#                               the newest DEN_BACKUP_KEEP (14) of them
#   den-backup restore FILE     replaces the hub in /data with the backup FILE (in /backups);
#                               the hub must be stopped
set -eu
cd /backups
case "${1:-backup}" in
  backup)
    file="den-$(date -u +%Y-%m-%d-%H%M).denbackup"
    /app/bin/den_hub backup --out "$file" --passphrase-env DEN_BACKUP_PASSPHRASE
    ls -1t den-*.denbackup | tail -n "+$((${DEN_BACKUP_KEEP:-14} + 1))" | xargs -r rm -f --
    ;;
  restore)
    # Takes the name as the server sees it too (backups/den-...), so tab completion works.
    file="${2:?Name the backup: docker compose run --rm backup restore backups/den-....denbackup}"
    file="${file#backups/}"
    /app/bin/den_hub restore --in "$file" --passphrase-env DEN_BACKUP_PASSPHRASE --force
    chown -R den:den /data
    ;;
  *)
    echo "den-backup [backup | restore FILE]" >&2
    exit 64
    ;;
esac
