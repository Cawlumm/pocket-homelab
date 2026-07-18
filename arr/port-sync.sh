#!/bin/sh
# Watches gluetun forwarded port file and updates qBittorrent listen port via API.
PORT_FILE="/tmp/gluetun/forwarded_port"
QBT_URL="http://localhost:8080"
CURRENT_PORT=""

echo "[port-sync] starting"

while true; do
    if [ ! -f "$PORT_FILE" ]; then
        sleep 10
        continue
    fi

    NEW_PORT=$(cat "$PORT_FILE" 2>/dev/null | tr -d "[:space:]")

    if [ -z "$NEW_PORT" ] || [ "$NEW_PORT" = "$CURRENT_PORT" ]; then
        sleep 30
        continue
    fi

    echo "[port-sync] port changed: $CURRENT_PORT -> $NEW_PORT"

    RESPONSE=$(wget -qO- --post-data "json={\"listen_port\":$NEW_PORT}" \
        "$QBT_URL/api/v2/app/setPreferences" 2>&1)

    if [ $? -eq 0 ]; then
        echo "[port-sync] updated qBittorrent listen port to $NEW_PORT"
        CURRENT_PORT=$NEW_PORT
    else
        echo "[port-sync] failed to update qBittorrent: $RESPONSE"
    fi

    sleep 30
done
