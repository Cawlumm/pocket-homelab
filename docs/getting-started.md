# Getting started

From a fresh Raspberry Pi 5 to a running homelab. Everything here uses placeholder
values (`example.com`, `youruser`) — substitute your own.

## 0. What you need
- Raspberry Pi 5 (4 GB works; 8 GB is comfier), booting from an **NVMe SSD** if you can (SD cards die).
- **Ubuntu Server 24.04/25.04** (arm64) or Raspberry Pi OS 64-bit.
- A domain you control on **Cloudflare** (free plan is fine) — for public access with no open ports.
- Optional: a **Tailscale** account (free) for private admin access, and an **AWS** account for offsite backups.

## 1. Install Docker
```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker "$USER"   # log out/in after this
docker compose version            # confirm Compose v2
```

## 2. Clone into ~/docker/stacks
The compose files expect the repo to live at `~/docker/stacks` (volumes resolve to `~/docker/volumes`).
```bash
git clone https://github.com/Cawlumm/pocket-homelab.git ~/docker/stacks
cd ~/docker/stacks
```

## 3. Bootstrap
```bash
./bootstrap.sh                            # all stacks
# or pick a subset (deps auto-added; e.g. nextcloud -> postgres):
./bootstrap.sh nextcloud vaultwarden
```
This creates the `backend` docker network, the `~/docker/volumes/...` tree (only for the stacks you
chose), seeds their `.env`, and **auto-generates the internal secrets** (DB / admin / Vaultwarden token /
CouchDB passwords). It saves your selection to `.enabled-stacks` so `make up` and `verify` use the same
set, then prints any remaining `CHANGE_ME` values that only you can supply.
(Skip auto-gen with `AUTO_SECRETS=0 ./bootstrap.sh`. Change selection later by re-running with new args.)

## 4. Fill in the external secrets
Only the things a machine can't invent are left as `CHANGE_ME`:
- `arr/.env` — your **ProtonVPN WireGuard private key**.
- `vaultwarden/.env` — your `DOMAIN` (`https://vault.example.com`).
- `nextcloud/.env` — your `NEXTCLOUD_TRUSTED_DOMAINS` (public host + LAN IP).

Then run the preflight check:
```bash
./scripts/verify.sh     # confirms host ready + every .env filled + compose valid
```

## 5. Start the stacks (DB first)
```bash
make up          # starts every stack (postgres first) + watchtower, then `docker ps`
```
No `make`? Use the manual loop:
```bash
( cd postgres && docker compose up -d )
for s in nextcloud vaultwarden media books arr obsidian-livesync; do ( cd "$s" && docker compose up -d ); done
( docker compose up -d )   # top-level watchtower
```
Services are now on `localhost:<port>` (see the table in the main README). Nothing is public yet.

## 6. Public access — Cloudflare Tunnel (no open ports)
```bash
# install cloudflared, then authenticate + create a tunnel
cloudflared tunnel login
cloudflared tunnel create homelab
```
Point hostnames at local ports in `/etc/cloudflared/config.yml`:
```yaml
tunnel: <TUNNEL_ID>
credentials-file: /root/.cloudflared/<TUNNEL_ID>.json
ingress:
  - hostname: nextcloud.example.com
    service: http://localhost:8081
  - hostname: vault.example.com
    service: http://localhost:8084
  # ...one per service...
  - service: http_status:404   # keep this fallback LAST
```
Create DNS + run it as a service:
```bash
cloudflared tunnel route dns homelab nextcloud.example.com   # repeat per hostname
sudo cloudflared service install
sudo systemctl restart cloudflared
```
Your router keeps **zero** forwarded ports. See `docs/security.md` for why this matters, and put
sensitive apps (like Vaultwarden) behind **Cloudflare Access**.

## 7. Private access — Tailscale
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```
Now `ssh youruser@<tailscale-ip>` works from anywhere without exposing SSH publicly.

## 8. Offsite backups
Provision the AWS buckets + IAM with OpenTofu, then wire the Pi's backup env. Full runbook:
**`docs/backups-and-dr.md`**.

## 9. Updates
`watchtower` auto-updates containers nightly and pings ntfy. To update manually:
```bash
cd ~/docker/stacks/<stack> && docker compose pull && docker compose up -d
```

## Optional: host config (backups, watchdogs, SMB)
Reference copies of the systemd units + scripts live in `host/`. See `host/README.md` for the
deploy paths (copy to `/usr/local/sbin`, `/etc/systemd/system`, then `systemctl daemon-reload`).
