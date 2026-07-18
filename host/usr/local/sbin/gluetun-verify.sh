#!/usr/bin/env bash
# Verify the VPN downloaders are not leaking. qbittorrent + *arr share gluetun.s
# network namespace, so gluetun.s public IP == their egress IP.
# Alerts (state-based, no spam) if: gluetun unhealthy, no VPN egress, or egress == home IP.
set -uo pipefail
NTFY=https://ntfy.sh/homelab-health
STATE=/var/lib/homelab-backup/gluetun-verify.state

HOME_IP=$(curl -s --max-time 10 https://ipinfo.io/ip 2>/dev/null | tr -d "[:space:]")
VPN_IP=$(docker exec gluetun wget -qO- --timeout=10 https://ipinfo.io/ip 2>/dev/null | tr -d "[:space:]")
GLU_HEALTH=$(docker inspect -f "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}" gluetun 2>/dev/null || echo "missing")

STATUS=""
if [ "$GLU_HEALTH" != "healthy" ]; then
  STATUS="gluetun unhealthy (health=$GLU_HEALTH) - downloaders may be offline"
elif [ -z "$VPN_IP" ]; then
  STATUS="no VPN egress IP - tunnel down (killswitch likely blocking; downloads stalled)"
elif [ -n "$HOME_IP" ] && [ "$VPN_IP" = "$HOME_IP" ]; then
  STATUS="LEAK: downloader egress $VPN_IP equals home IP - traffic NOT going through VPN"
fi

CUR=$(printf "%s" "$STATUS" | md5sum | cut -d" " -f1)
PREV=$(cat "$STATE" 2>/dev/null || echo "")
[ "$CUR" = "$PREV" ] && exit 0
printf "%s" "$CUR" > "$STATE"
if [ -n "$STATUS" ]; then
  curl -s --max-time 10 -H "Title: homelab VPN issue" -H "Priority: urgent" -H "Tags: rotating_light,lock" -d "$STATUS" "$NTFY" >/dev/null 2>&1 || true
elif [ -n "$PREV" ]; then
  curl -s --max-time 10 -H "Title: homelab VPN OK" -H "Tags: white_check_mark,lock" -d "VPN egress restored ($VPN_IP)" "$NTFY" >/dev/null 2>&1 || true
fi
