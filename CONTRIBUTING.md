# Contributing to pocket-homelab

Thanks for wanting to help! This repo is meant to be useful to as many Pi homelabbers
as possible — issues, docs, and new stacks are all welcome.

## Ground rules

1. **Never commit secrets.** No `.env`, keys, tokens, password hashes, or Terraform
   state. Every stack ships a `.env.example` with `CHANGE_ME` placeholders. CI runs a
   **gitleaks** scan on every PR and will block a leak.
2. **Redact identifiers** in docs and examples: use `example.com`, `youruser`,
   `homelab-*` topics, no real public IPs or cloud account IDs.
3. **Keep it Pi-friendly.** This targets a 4 GB Raspberry Pi 5 — prefer lightweight,
   arm64-compatible images. Note RAM impact for anything heavy.

## Adding a new stack

Use the [`_template/`](_template/) pattern:

```bash
cp -r _template myapp && cd myapp
$EDITOR docker-compose.yml .env.example README.md
```

- One Compose project per directory, `.env.example` alongside.
- Pick a free host port (avoid `8080`). Add a `healthcheck`.
- Live data under `../../volumes/<stack>/` (gitignored).
- If it should be reachable, document the Cloudflare Tunnel ingress line — never a
  router port-forward.
- Add it to the README stack table and the `STACKS` list in `Makefile` / `bootstrap.sh`
  if it's a core stack.

## Before you open a PR

```bash
./scripts/verify.sh          # host + config + compose validation
make validate                # docker compose config on every stack
```

- Keep changes focused; one topic per PR.
- Update the relevant doc under `docs/` if behavior changes.
- CI (gitleaks + compose validation) must pass.

## Reporting issues

Use the issue templates. For bugs, include your Pi model, OS, Docker version, the
stack involved, and logs (`docker logs <container>`) — with secrets removed.

Thanks for making it better.
