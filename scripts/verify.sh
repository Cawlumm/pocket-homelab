#!/usr/bin/env bash
# Preflight check — is this host ready and are the stacks configured?
# Safe/read-only: makes no changes. Exit non-zero if anything fails.
# An AI agent can run this to self-check before and after setup.
set -uo pipefail

# Selected stacks: .enabled-stacks (written by bootstrap) or all.
if [ -f .enabled-stacks ]; then mapfile -t STACKS < .enabled-stacks
else STACKS=(postgres nextcloud vaultwarden media books arr obsidian-livesync); fi
fail=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
echo "== selected stacks: ${STACKS[*]}"

echo "== prerequisites"
command -v docker >/dev/null 2>&1 && ok "docker present" || bad "docker not found"
docker compose version >/dev/null 2>&1 && ok "docker compose v2" || bad "docker compose v2 missing"
docker info >/dev/null 2>&1 && ok "docker daemon reachable" || bad "docker daemon not reachable (permissions? add your user to the docker group)"

echo "== docker network"
docker network inspect backend >/dev/null 2>&1 && ok "network 'backend' exists" || bad "network 'backend' missing — run ./bootstrap.sh"

echo "== stack configuration"
for s in "${STACKS[@]}"; do
  if [ ! -f "$s/.env" ] && [ -f "$s/.env.example" ]; then
    bad "$s/.env missing — run ./bootstrap.sh"
  elif [ -f "$s/.env" ] && grep -q 'CHANGE_ME' "$s/.env"; then
    warn "$s/.env still has CHANGE_ME (fill it before starting)"
  elif [ -f "$s/.env" ]; then
    ok "$s/.env configured"
  fi
done

echo "== compose validation"
files=(./docker-compose.yml)
for s in "${STACKS[@]}"; do [ -f "$s/docker-compose.yml" ] && files+=("$s/docker-compose.yml"); done
for f in "${files[@]}"; do
  if docker compose -f "$f" config -q >/dev/null 2>&1; then ok "valid: $f"; else bad "invalid: $f"; fi
done

echo
if [ "$fail" -eq 0 ]; then
  echo -e "\033[32mPREFLIGHT OK\033[0m — ready to 'make up' (fill any CHANGE_ME warnings first)."
else
  echo -e "\033[31mPREFLIGHT FAILED\033[0m — fix the ✗ items above."
fi
exit "$fail"
