# host/ — host-level config (outside Docker)

Version-controlled copies of system files on homelab. These are **reference copies**
for reproducibility — live files are at the deploy paths below. After editing here,
copy back (sudo) + reload as noted.

| Repo path | Deploy path | Reload |
|-----------|-------------|--------|
| etc/ssh/sshrc | /etc/ssh/sshrc | none |
| etc/samba/smb.conf | /etc/samba/smb.conf | systemctl reload smbd |
| usr/local/sbin/restic-backup.sh | same | none |
| usr/local/sbin/media-archive.sh | same | none |
| usr/local/sbin/backup-watchdog.sh | same | none |
| usr/local/sbin/container-watchdog.sh | same | none |
| etc/systemd/system/*.{service,timer} | same | systemctl daemon-reload |
| etc/systemd/system/ntfy-failure@.service | same | systemctl daemon-reload |

## NOT in git (secrets — host only)
- /etc/homelab-backup/restic.env — AWS creds + restic repo/password path
- /root/.restic-pass — restic repository password

## What runs
- smbd — [Media] SMB share (//homelab/Media or //192.168.1.10/Media -> volumes/media/library, user mediasvc). LAN access needs: ufw allow from 192.168.1.0/24 to any port 139,445.
- sshrc — smart SSH-login ntfy (interactive + external IPs only) -> homelab-logins
- restic-backup (nightly 03:30) -> Glacier IR;  media-archive (weekly Sun 02:00) -> Deep Archive  [topic: homelab-backups]
- backup-watchdog (daily 06:00) — alerts if newest restic snapshot > 26h old  [topic: homelab-health]
- container-watchdog (every 15min) — alerts on unhealthy/down/restarting containers, only on state change  [topic: homelab-health]
- gluetun-verify (every 30min) — alerts if VPN downloaders leak (egress==home IP), no egress, or gluetun unhealthy  [topic: homelab-health]
- ntfy-failure@.service — OnFailure handler on the backup units -> homelab-health

## ntfy topics
- homelab-updates  : watchtower auto-updates
- homelab-backups  : backup run OK/fail
- homelab-health   : watchdog alerts (stale backup, container down, unit failure)
- homelab-logins      : external interactive SSH logins
