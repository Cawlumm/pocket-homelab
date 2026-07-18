# Host tuning (Raspberry Pi 5)

The host-level (non-Docker) tweaks that keep ~20 containers happy on a 4 GB Pi, plus
how the SMB media share is exposed. Reference copies of the relevant files live in
[`host/`](../host/) — see `host/README.md` for deploy paths.

Placeholders: LAN `192.168.1.0/24`, user `youruser`, Tailscale IP `100.x.y.z`.

---

## Memory: swap + swappiness

Running ~20 containers on 4 GB RAM means you *will* touch swap. Two settings matter.

**A swapfile** (here 4 GB) as an OOM safety net:
```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab   # persist across reboots
swapon --show                                                # verify
```

**Low `vm.swappiness`** so the kernel prefers RAM and only swaps under real pressure
(swap on NVMe is fine, but you don't want constant churn):
```bash
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf
sudo sysctl --system                                         # apply now
sysctl vm.swappiness                                         # expect: 10
```

> **Verify it actually stuck.** Setting it in a file is not the same as it being
> live. Check `sysctl vm.swappiness` after a reboot — a default or cloud-init can
> leave the *runtime* value at `60` even though the file says `10`. If they disagree,
> run `sudo sysctl --system` (and confirm no other file re-sets it).

## Logs: don't let them eat the disk

**Docker** — cap per-container JSON logs (`/etc/docker/daemon.json`):
```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
```
```bash
sudo systemctl restart docker   # applies to newly-created containers
```

**journald** — cap the system journal (`/etc/systemd/journald.conf`):
```ini
[Journal]
SystemMaxUse=200M
```
```bash
sudo systemctl restart systemd-journald
```

## Trim unused services (free RAM + reduce surface)

A default Ubuntu/Pi image ships daemons a headless homelab doesn't need. Disabling
them frees memory and removes attack surface:
```bash
# PCP performance tooling, snap, modem, and legacy syslog (journald already logs)
sudo systemctl disable --now pmcd pmie pmlogger pmproxy snapd ModemManager rsyslog
```
Only disable what you actually don't use — adjust to your setup.

## Firewall (ufw)

Default-deny inbound; open only what must be reached directly. Everything else arrives
via the Cloudflare Tunnel or Tailscale — neither needs an inbound hole.
```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 22/tcp                 # SSH
sudo ufw allow 32400/tcp              # Plex (direct/DLNA)
sudo ufw allow from 192.168.1.0/24 to any port 139,445 proto tcp comment 'SMB from LAN'
sudo ufw enable
sudo ufw status numbered
```
See [security.md](security.md) for the full rationale.

---

## SMB media share (Samba) — LAN vs Tailscale

The media library is shared over SMB so you can manage files from a desktop. The share
is defined in [`host/etc/samba/smb.conf`](../host/etc/samba/smb.conf):

```ini
[Media]
   path = /home/youruser/docker/volumes/media/library
   valid_users = mediasvc
   force user  = mediasvc
   writable = yes
   create mask = 0664
   directory mask = 0775
```
```bash
sudo useradd -M -s /usr/sbin/nologin mediasvc     # dedicated share user (no shell)
sudo smbpasswd -a mediasvc                          # set its SMB password
sudo systemctl reload smbd
```

Samba binds all interfaces, so **access is controlled by the firewall**, not smb.conf.

### Option A — LAN only (default, most secure)
```bash
sudo ufw allow from 192.168.1.0/24 to any port 139,445 proto tcp comment 'SMB from LAN'
```
Mount from a same-network machine:
```powershell
net use M: \\<pi-lan-ip>\Media /user:mediasvc      # Windows
```
```bash
sudo mount -t cifs //<pi-lan-ip>/Media /mnt/media -o user=mediasvc   # Linux/macOS
```

### Option B — reachable anywhere over Tailscale (optional)
Add a rule scoped to the **Tailscale interface** so the share rides the encrypted mesh
without ever touching the public internet:
```bash
sudo ufw allow in on tailscale0 to any port 139,445 proto tcp comment 'SMB over Tailscale'
```
Then mount using the Pi's Tailscale IP from any of your devices:
```powershell
net use M: \\100.x.y.z\Media /user:mediasvc
```

**Trade-off.** Option B exposes SMB to *every device in your tailnet*. That's a small,
authenticated, encrypted network you control — fine if you trust those devices. If you
don't need remote file management, stay on Option A. **Never** open 139/445 to the
public internet or forward them on your router — SMB is a historically abused protocol.

> Tip: for occasional remote access you can skip the firewall change entirely and just
> Tailscale into the LAN, or use `tailscale serve`/Nextcloud for files instead of SMB.

---

See also: [security.md](security.md) (firewall + threat model) and
[lessons-learned.md](lessons-learned.md) (NVMe shutdown discipline, why swap matters).
