#!/usr/bin/env bash
# Alert if the newest restic snapshot is older than threshold (silent-failure catch).
set -euo pipefail
set -a; . /etc/homelab-backup/restic.env; set +a
NTFY=https://ntfy.sh/homelab-health
MAX_AGE_H=26
alert() { curl -s --max-time 10 -H "Title: homelab BACKUP STALE" -H "Priority: urgent" -H "Tags: rotating_light" -d "$1" "$NTFY" >/dev/null 2>&1 || true; }
TS=$(restic snapshots --json --latest 1 2>/dev/null | grep -o "\"time\":\"[^\"]*\"" | head -1 | sed -E "s/\"time\":\"//; s/\.[0-9]+//; s/\"//")
if [ -z "$TS" ]; then alert "No restic snapshots found / repo unreachable on $(hostname)"; exit 0; fi
EPOCH=$(date -d "$TS" +%s 2>/dev/null || echo 0)
AGE_H=$(( ( $(date +%s) - EPOCH ) / 3600 ))
if [ "$EPOCH" -eq 0 ] || [ "$AGE_H" -ge "$MAX_AGE_H" ]; then
  alert "Newest restic backup is ${AGE_H}h old (threshold ${MAX_AGE_H}h) on $(hostname). Backups may have stopped."
fi
