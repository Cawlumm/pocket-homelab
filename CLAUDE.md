# CLAUDE.md

This repo can be set up by an AI agent. **Read `AGENTS.md` first** — it is the
step-by-step setup playbook (target path, secrets to request from the human,
procedure, verification).

Quick guardrails (full list in AGENTS.md):

- Clone to **`~/docker/stacks`** (compose volumes resolve via `../../volumes`).
- Run `./bootstrap.sh` (creates network + volumes + `.env` files, auto-generates
  internal secrets), then `./scripts/verify.sh`, then `make up`.
- **Never** commit `.env`, keys, or Terraform state (all gitignored).
- **Never** expose a service publicly before its Cloudflare Tunnel + Access are set.
- Ask before destructive commands (`down -v`, `volume rm`, `prune`, `tofu apply/destroy`).
- After any change, run `./scripts/verify.sh`; if it fails, stop and fix.
