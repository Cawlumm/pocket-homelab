#!/usr/bin/env bash
# Tier 1 nightly backup: configs + DBs + irreplaceable media -> restic -> Glacier IR
set -euo pipefail
set -a; . /etc/homelab-backup/restic.env; set +a

STAGE=/var/backups/homelab-stage
VOL="${DOCKER_VOLUMES:-/home/youruser/docker/volumes}"
NTFY="https://ntfy.sh/${NTFY_BACKUPS_TOPIC:-homelab-backups}"

notify_fail() {
  curl -s -H "Title: restic backup FAILED" -H "Priority: high" -H "Tags: rotating_light" \
       -d "restic-backup.sh failed: $1" "$NTFY" >/dev/null 2>&1 || true
}
trap "notify_fail \"line \$LINENO: \$BASH_COMMAND\"" ERR

# Fresh staging dir for DB-consistent dumps
rm -rf "$STAGE"; mkdir -p "$STAGE"; chmod 700 "$STAGE"

# 1. Postgres: dump ALL dbs (nextcloud) consistently.
#    Briefly quiesce nextcloud so it is not mid-write during the dump.
docker exec -u www-data nextcloud php occ maintenance:mode --on >/dev/null 2>&1 || true
docker exec postgres pg_dumpall -U nextcloud > "$STAGE/postgres-all.sql"
docker exec -u www-data nextcloud php occ maintenance:mode --off >/dev/null 2>&1 || true

# 2. Vaultwarden: consistent sqlite snapshot (handles WAL) + RSA keys.
sqlite3 "$VOL/vaultwarden/db.sqlite3" ".backup '$STAGE/vaultwarden-db.sqlite3'"
cp -a "$VOL/vaultwarden/rsa_key.pem" "$STAGE/" 2>/dev/null || true

# 3. restic backup. Data packs -> GLACIER_IR; restic keeps metadata in STANDARD.
restic backup \
  --tag homelab-nightly \
  --option s3.storage-class=GLACIER_IR \
  --exclude="**/db.sqlite3-wal" \
  --exclude="**/db.sqlite3-shm" \
  --exclude="**/vaultwarden/db.sqlite3" \
  --exclude="**/vaultwarden/icon_cache" \
  --exclude="**/vaultwarden/tmp" \
  --exclude="**/logs.db" \
  --exclude="**/appdata_*/preview" \
  --exclude="**/.cache" \
  "$STAGE" \
  "$VOL/media/library/Audiobooks" \
  "$VOL/books/calibre/library" \
  "$VOL/arr/sonarr" "$VOL/arr/radarr" "$VOL/arr/lidarr" "$VOL/arr/prowlarr" \
  "$VOL/media/audiobookshelf/config" \
  "$VOL/vaultwarden" \
  "$VOL/nextcloud"

# 4. Retention + prune
restic forget --tag homelab-nightly \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune

# 5. Clean staging (contains secrets)
rm -rf "$STAGE"

curl -s -H "Title: restic backup OK" -H "Tags: white_check_mark" \
     -d "Tier1 nightly backup complete $(date +%F)" "$NTFY" >/dev/null 2>&1 || true
