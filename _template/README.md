# Service template

Skeleton for adding a new self-hosted service to the homelab.

## Use it
```bash
cp -r _template myapp && cd myapp
# edit docker-compose.yml (image, ports, volumes) and .env.example
cp .env.example .env && $EDITOR .env      # fill CHANGE_ME values
docker compose up -d
```

## Checklist
- [ ] Pick a **free host port** (avoid `8080`). Check `docker ps` / `ss -tulpn`.
- [ ] Put live data under `../../volumes/<yourservice>/` (never in git).
- [ ] Keep secrets in `.env` (gitignored) — never in `docker-compose.yml`.
- [ ] Attach to the `backend` network only if it talks to Postgres/another stack.
- [ ] To expose it publicly: add one ingress line to your Cloudflare Tunnel config
      (`<svc>.example.com → http://localhost:<port>`) — never a router port-forward.
- [ ] Add a `healthcheck` so the container-watchdog can alert if it goes unhealthy.
- [ ] Run `../scripts/verify.sh` before starting.
