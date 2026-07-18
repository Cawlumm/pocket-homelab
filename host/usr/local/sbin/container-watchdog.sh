#!/usr/bin/env bash
# Alert (once, on state change) if any container is unhealthy / crash-looping /
# unexpectedly down (always|unless-stopped restart policy but not running).
set -euo pipefail
NTFY=https://ntfy.sh/homelab-health
STATE=/var/lib/homelab-backup/container-watchdog.state
UNHEALTHY=$(docker ps --filter health=unhealthy --format "{{.Names}}" | sort | tr "\n" " ")
RESTARTING=$(docker ps -a --filter status=restarting --format "{{.Names}}" | sort | tr "\n" " ")
DOWN=""
for c in $(docker ps -a --filter status=exited --filter status=dead --format "{{.Names}}"); do
  pol=$(docker inspect -f "{{.HostConfig.RestartPolicy.Name}}" "$c" 2>/dev/null || echo "")
  case "$pol" in always|unless-stopped) DOWN="$DOWN $c" ;; esac
done
BAD=""
[ -n "$UNHEALTHY" ] && BAD="${BAD}unhealthy: ${UNHEALTHY}\n"
[ -n "$RESTARTING" ] && BAD="${BAD}restarting: ${RESTARTING}\n"
[ -n "$DOWN" ] && BAD="${BAD}down:${DOWN}\n"
CUR=$(printf "%s" "$BAD" | md5sum | cut -d" " -f1)
PREV=$(cat "$STATE" 2>/dev/null || echo "")
[ "$CUR" = "$PREV" ] && exit 0
printf "%s" "$CUR" > "$STATE"
if [ -n "$BAD" ]; then
  curl -s --max-time 10 -H "Title: homelab container issue" -H "Priority: high" -H "Tags: warning" -d "$(printf "Problem containers:\n%b" "$BAD")" "$NTFY" >/dev/null 2>&1 || true
elif [ -n "$PREV" ]; then
  curl -s --max-time 10 -H "Title: homelab containers recovered" -H "Tags: white_check_mark" -d "All containers healthy again" "$NTFY" >/dev/null 2>&1 || true
fi
