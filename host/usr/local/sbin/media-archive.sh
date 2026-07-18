#!/usr/bin/env bash
# Tier 2 weekly cold vault: whole media library -> aws s3 sync -> Glacier Deep Archive
# Versioning + lifecycle on the bucket give a 30-day delete grace (mirror-with-undo).
set -euo pipefail
set -a; . /etc/homelab-backup/restic.env; set +a

SRC="${DOCKER_VOLUMES:-/home/youruser/docker/volumes}/media/library"
NTFY="https://ntfy.sh/${NTFY_BACKUPS_TOPIC:-homelab-backups}"

notify_fail() {
  curl -s -H "Title: media archive FAILED" -H "Priority: high" -H "Tags: rotating_light" \
       -d "media-archive.sh failed: $1" "$NTFY" >/dev/null 2>&1 || true
}
trap "notify_fail \"line \$LINENO: \$BASH_COMMAND\"" ERR

aws s3 sync "$SRC" "s3://$ARCHIVE_BUCKET/library" \
  --storage-class DEEP_ARCHIVE \
  --delete \
  --only-show-errors

curl -s -H "Title: media archive OK" -H "Tags: package" \
     -d "Tier2 media cold sync complete $(date +%F)" "$NTFY" >/dev/null 2>&1 || true
