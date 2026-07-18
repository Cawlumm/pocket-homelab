#!/usr/bin/env bash
# Pocket Homelab bootstrap — prep a Raspberry Pi 5 (Ubuntu) to run these stacks.
# Idempotent: safe to re-run.
#
# Pick which stacks to run (default: all):
#   ./bootstrap.sh                              # everything
#   ./bootstrap.sh nextcloud vaultwarden        # just these (+ deps)
#   STACKS="media books arr" ./bootstrap.sh     # via env var
# The choice is saved to .enabled-stacks so make/verify use the same set.
set -euo pipefail

ALL_STACKS=(postgres nextcloud vaultwarden media books arr obsidian-livesync)
VOL="${DOCKER_VOLUMES:-$HOME/docker/volumes}"

info() { printf '\033[1;36m==>\033[0m %s\n' "$1"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$1"; }
has()  { printf '%s\n' "${SEL[@]}" | grep -qx "$1"; }

# 1. prerequisites
command -v docker >/dev/null 2>&1 || { warn "Docker not found. Install it: https://docs.docker.com/engine/install/"; exit 1; }
docker compose version >/dev/null 2>&1 || { warn "Docker Compose v2 required (docker compose ...)."; exit 1; }

# 2. resolve stack selection:  CLI args > $STACKS env > all
if [ "$#" -gt 0 ]; then SEL=("$@")
elif [ -n "${STACKS:-}" ]; then read -ra SEL <<< "$STACKS"
else SEL=("${ALL_STACKS[@]}"); fi

# validate names
for s in "${SEL[@]}"; do
  printf '%s\n' "${ALL_STACKS[@]}" | grep -qx "$s" || { warn "unknown stack '$s'. Valid: ${ALL_STACKS[*]}"; exit 1; }
done
# dependency: nextcloud needs the shared postgres
if has nextcloud && ! has postgres; then SEL+=(postgres); info "added 'postgres' (required by nextcloud)"; fi
# dedupe, keep order
SEL=($(printf '%s\n' "${SEL[@]}" | awk '!seen[$0]++'))
printf '%s\n' "${SEL[@]}" > .enabled-stacks
info "enabled stacks: ${SEL[*]}"

# 3. shared network
if ! docker network inspect backend >/dev/null 2>&1; then info "creating docker network 'backend'"; docker network create backend; fi

# 4. volume dirs — only for the selected stacks
mk() { mkdir -p "$@"; }
info "creating volume tree under $VOL"
has postgres          && mk "$VOL"/postgres
has nextcloud         && mk "$VOL"/nextcloud
has vaultwarden       && mk "$VOL"/vaultwarden
has media             && mk "$VOL"/media/plex "$VOL"/media/library "$VOL"/media/audiobookshelf/config "$VOL"/media/audiobookshelf/metadata
has books             && mk "$VOL"/books/calibre/config "$VOL"/books/calibre/library "$VOL"/books/calibre-web "$VOL"/books/downloads
has arr               && mk "$VOL"/arr/qbittorrent/config "$VOL"/arr/sonarr "$VOL"/arr/radarr "$VOL"/arr/lidarr "$VOL"/arr/prowlarr "$VOL"/media/library
has obsidian-livesync && mk "$VOL"/obsidian-livesync/data

# 5. seed .env for the selected stacks (never overwrite an existing .env)
for s in "${SEL[@]}"; do
  if [ -f "$s/.env.example" ] && [ ! -f "$s/.env" ]; then cp "$s/.env.example" "$s/.env"; info "created $s/.env"; fi
done

# 6. auto-generate INTERNAL secrets (AUTO_SECRETS=0 to skip). External secrets stay CHANGE_ME.
if [ "${AUTO_SECRETS:-1}" = "1" ] && command -v openssl >/dev/null 2>&1; then
  gen() { openssl rand -hex 24; }
  DB_PASS="$(gen)"   # shared by postgres + nextcloud
  [ -f postgres/.env ]  && sed -i "s|CHANGE_ME_strong_random|$DB_PASS|g" postgres/.env
  if [ -f nextcloud/.env ]; then
    sed -i "s|CHANGE_ME_match_postgres_stack|$DB_PASS|g" nextcloud/.env
    sed -i "s|CHANGE_ME_strong_random|$(gen)|g" nextcloud/.env
  fi
  [ -f vaultwarden/.env ]       && sed -i "s|CHANGE_ME_openssl_rand_base64_48|$(openssl rand -base64 48 | tr -d '\n/=')|g" vaultwarden/.env
  [ -f obsidian-livesync/.env ] && sed -i "s|CHANGE_ME_long_random|$(gen)|g" obsidian-livesync/.env
  info "generated internal secrets for the selected stacks"
fi

# 7. report remaining human-supplied secrets
REMAINING="$(grep -rl 'CHANGE_ME' --include='.env' . 2>/dev/null || true)"
echo
info "bootstrap complete — stacks: ${SEL[*]}"
echo
if [ -n "$REMAINING" ]; then
  warn "These still need YOUR values (external secrets):"
  grep -rn 'CHANGE_ME' --include='.env' . 2>/dev/null | sed 's/^/    /'
  echo
fi
cat <<EOF
Next steps:
  1. Fill any remaining CHANGE_ME above (e.g. ProtonVPN key in arr/.env, your domain).
  2. Start your stacks:   make up          (uses .enabled-stacks)
  3. Check it:            ./scripts/verify.sh
  4. Public access + private mesh: docs/getting-started.md

Change your selection later: re-run  ./bootstrap.sh <stacks...>  (or edit .enabled-stacks).
Nothing is reachable from the internet until you configure Cloudflare Tunnel.
EOF
