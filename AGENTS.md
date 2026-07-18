# AGENTS.md — setup playbook for AI agents

This file lets a human point an AI coding agent (Claude Code, Cursor, Aider, etc.)
at this repo and say *"set up my homelab."* Follow it top to bottom. It is written
to be executed, not just read.

If you are a human: you can also just follow `docs/getting-started.md` yourself.

---

## What you are setting up

Eight Docker Compose stacks on a Raspberry Pi 5 (Ubuntu), reachable with **no open
router ports** (Cloudflare Tunnel) + a private Tailscale mesh, with offsite backups.
Full design: `docs/architecture.md`.

## Target & assumptions

- Run this **on the Pi** (or over SSH to it). Ubuntu 24.04/25.04 arm64.
- The repo must live at **`~/docker/stacks`** — compose files resolve volumes to
  `~/docker/volumes/...` via `../../volumes`. Clone there, not elsewhere.
- Docker Engine + Compose v2 installed and the invoking user in the `docker` group.

## Secrets you MUST get from the human (never invent these)

Ask for these explicitly, and **only for the stacks the human selected** (e.g. skip the ProtonVPN key
if they didn't pick `arr`). Do **not** fabricate, guess, or commit them.

| Needed for | Value to request | Notes |
|---|---|---|
| `arr/.env` | ProtonVPN **WireGuard private key** | From the user's ProtonVPN account. Required for the download stack. |
| `vaultwarden/.env`, `nextcloud/.env` | The user's **domain** (e.g. `example.com`) | Replaces `example.com` placeholders. |
| Cloudflare Tunnel | Cloudflare **login / tunnel** | The human runs `cloudflared tunnel login` interactively (browser). |
| Backups (optional) | **AWS credentials** | Only if setting up `iac/` + offsite backups. Least-priv user; see `docs/backups-and-dr.md`. |

Everything else (database / admin / CouchDB passwords, Vaultwarden admin token) is
**auto-generated** by `bootstrap.sh` — you do not ask the human for those.

## Procedure

```bash
# 1. Clone to the required path
git clone <repo-url> ~/docker/stacks
cd ~/docker/stacks

# 2. Bootstrap. Ask the human which stacks they want, then pass them (deps auto-added).
#    Omit args for everything. Choice is saved to .enabled-stacks for make/verify.
./bootstrap.sh                          # all stacks
# ./bootstrap.sh nextcloud vaultwarden  # or a subset
#    -> creates 'backend' network + volumes + seeds .env + AUTO-GENERATES internal secrets,
#       then prints any remaining CHANGE_ME values that need the human.

# 3. Fill the human-supplied secrets (see table above), e.g.:
#      arr/.env          PROTON_WG_PRIVATE_KEY=...
#      vaultwarden/.env  DOMAIN=https://vault.<their-domain>
#      nextcloud/.env    NEXTCLOUD_TRUSTED_DOMAINS=nextcloud.<their-domain> <lan-ip>

# 4. Preflight — must pass before starting anything.
./scripts/verify.sh

# 5. Bring it up (DB first; handled by the make target).
make up            # or the manual loop in bootstrap.sh output

# 6. Confirm health.
docker ps          # every container Up / healthy
./scripts/verify.sh
```

Public exposure (Cloudflare Tunnel) and private access (Tailscale) are **separate,
mostly-interactive** steps — walk the human through `docs/getting-started.md §6–7`.
Do not expose anything publicly until the tunnel + Cloudflare Access are configured.

## Guardrails (hard rules)

- **Never commit secrets.** `.env` files, keys, and Terraform state are gitignored.
  Do not `git add -f` them. Do not paste secret values into logs, commit messages,
  or chat.
- **Never expose a service to the internet before** its Cloudflare Tunnel ingress +
  (for sensitive apps) Cloudflare Access are set up. No router port-forwarding — ever.
- **Do not run destructive commands** without explicit human confirmation:
  `docker compose down -v`, `docker volume rm`, `docker system prune`,
  `rm -rf ~/docker/volumes/...`, `tofu destroy`. These delete data.
- **Ask before `tofu apply`** — it creates real, billable AWS resources.
- **Idempotent by design:** `bootstrap.sh` never overwrites an existing `.env`, and
  re-running `make up` is safe. Prefer re-running over hand-editing generated files.
- If `./scripts/verify.sh` fails, fix the reported item; do not proceed to `make up`.

## How to verify success

- `./scripts/verify.sh` exits 0 (network exists, every `.env` present with no
  `CHANGE_ME`, every compose file valid).
- `docker ps` shows all containers `Up`, health-checked ones `healthy`.
- Local reachability, e.g. `curl -fsS http://localhost:8081/status.php` (Nextcloud).
- Public URLs resolve only after the tunnel step.

## Repo map (for orientation)

- `docs/` — architecture, getting-started, backups-and-dr, security, lessons-learned
- `<stack>/docker-compose.yml` + `.env.example` — one Compose project each
- `host/` — systemd units + backup/watchdog scripts (reference copies; deploy paths in `host/README.md`)
- `iac/` — OpenTofu for the AWS backup buckets/IAM (optional)
- `bootstrap.sh`, `Makefile`, `scripts/verify.sh` — setup + lifecycle + preflight
