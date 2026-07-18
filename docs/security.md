# Security Posture

This document describes the security model of this Raspberry Pi 5 homelab: the
choices made, and — more importantly — *why* each one matters. It is written to
be useful both as a checklist for other homelabbers and as a portfolio
walk-through for engineers reviewing this repo.

The guiding principle throughout is **defence in depth**: no single control is
trusted to be perfect, so several independent layers each have to fail before
anything bad happens.

All examples use placeholder values: domain `example.com`, admin user
`youruser`, ntfy topics like `homelab-health`.

---

## 1. Zero inbound ports

**The rule: the home router forwards no ports. None.**

Public access to services (e.g. `app.example.com`) is provided by a
**Cloudflare Tunnel** running the `cloudflared` daemon on the Pi. `cloudflared`
makes an **outbound** connection to Cloudflare's edge and holds it open;
inbound traffic rides back down that already-established connection.

```
Visitor ──► Cloudflare edge ──(existing outbound tunnel)──► cloudflared ──► app
```

### Why this shrinks the attack surface

- **Nothing to scan.** With classic port-forwarding, the router advertises open
  ports to the entire internet. Bots find them within minutes and hammer them
  with credential-stuffing and exploit attempts. Here, a port scan of the home
  IP returns *nothing* — there is no listening service to attack.
- **No open door to defend.** You cannot be exploited on a port that does not
  exist. The only network path in is a connection the Pi itself dialled out.
- **DDoS and WAF for free.** Traffic transits Cloudflare, so volumetric attacks
  and common web exploits are absorbed at the edge before they ever reach the
  home connection.

### Why it beats exposing a reverse proxy directly

A common intermediate setup is to forward 80/443 to a self-hosted reverse proxy
(Caddy, Traefik, nginx). That is better than forwarding to each app, but the
proxy itself is now internet-facing:

- Your **home IP is public** and tied to your DNS — it can be logged, targeted,
  and correlated.
- A bug in the proxy (or a misconfigured route) is directly reachable.
- You own TLS termination, patching, and rate-limiting for an exposed daemon.

With the tunnel, the reverse-proxy role lives on Cloudflare's edge. The Pi's
origin IP is never published, and the only locally-exposed surface is
`cloudflared`, which listens on *nothing* inbound.

---

## 2. Cloudflare Access in front of sensitive apps

For sensitive services — the password manager is the canonical example —
**Cloudflare Access** sits in front of the tunnel as an authentication gate.

A request to `vault.example.com` must satisfy an Access policy (e.g. "email in
this allow-list, verified via one-time PIN or an identity provider") **before
Cloudflare will forward the request to the app at all**.

### Why this matters

- **Auth happens before the app is reached.** The application's own login page
  is never exposed to an unauthenticated internet. A zero-day in the app's auth
  flow is not reachable by someone who cannot first clear Access.
- **Independent second factor.** Even if app credentials leak, an attacker still
  faces the Access policy — a separate identity check the app knows nothing
  about.
- **Central revocation.** Remove a person from the Access policy and they lose
  entry to every gated app at once, regardless of app-level accounts.

This is the identity-aware-proxy pattern: the gate is in front of the door, not
behind it.

---

## 3. VPN killswitch for the downloader stack

The `arr` stack (indexers + download clients) must **never** transmit from the
home IP. This is enforced structurally, not by hope.

### How it fails closed

The download containers are started with
`network_mode: "service:gluetun"` — they **share gluetun's network
namespace**. They have no network interface of their own; all their traffic
exits through gluetun's ProtonVPN tunnel.

The consequence is the whole point: **if the VPN tunnel drops, the containers
lose all connectivity.** There is no interface for them to fall back to. This is
a *fail-closed* design — the failure mode is "no traffic," never "traffic over
the wrong path."

```
downloaders ──(no own NIC)──► gluetun namespace ──► ProtonVPN ──► internet
                                     │
                            tunnel down ⇒ no egress at all
```

### Active leak detection

Structural fail-closed is backstopped by monitoring. A **`gluetun-verify`
systemd timer** runs every 30 minutes and checks the downloaders' actual egress
IP:

- If egress IP **== home IP** → a leak. Alert.
- If there is **no egress** at all → tunnel down. Alert.
- If gluetun reports **unhealthy** → alert.

Alerts go to an **ntfy** topic (e.g. `homelab-health`) so a leak is noticed in
minutes, not discovered later.

### Why both layers

The namespace share prevents leaks *by construction*; the timer catches the
cases construction can't — a misconfiguration, a gluetun bug reporting healthy
while routing wrong, or a silent no-egress state that would otherwise just look
like "downloads are slow today."

---

## 4. Least-privilege AWS IAM for backups

Off-site backups go to AWS S3. The Pi authenticates as a dedicated IAM user
whose permissions are scoped to **exactly the two backup buckets and nothing
else**.

### The scoping

- **Resource ARNs are pinned** to the specific bucket ARNs (and their
  `/*` object paths). The policy names those buckets explicitly — it does not
  grant `arn:aws:s3:::*`.
- **Actions are minimal** — only the S3 operations the backup tool actually
  needs (put/get/list/delete objects, list the bucket). No IAM, no EC2, no
  billing, no other service.

```jsonc
// illustration — scoped to the backup buckets only
{
  "Effect": "Allow",
  "Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:DeleteObject"],
  "Resource": [
    "arn:aws:s3:::youruser-homelab-backup",
    "arn:aws:s3:::youruser-homelab-backup/*"
  ]
}
```

### Bucket-side hardening

- **Block Public Access** is on for the buckets — no object can be made public,
  even by accident.
- **SSE at rest** — server-side encryption is enabled so objects are encrypted
  on disk.

### Why this matters

If the Pi is compromised and its AWS credentials are stolen, the blast radius is
capped at the backup buckets. The attacker cannot pivot to spin up EC2 for
crypto-mining, read other buckets, or escalate in the AWS account. Least
privilege turns "credential theft" from "account takeover" into "they can mess
with my backups" — which is exactly what versioning and the local copies exist
to survive.

---

## 5. Host firewall (ufw)

The host runs `ufw` with a **default-deny inbound** policy. Only a short list is
opened:

| Port / service | Scope                         | Reason                          |
| -------------- | ----------------------------- | ------------------------------- |
| SSH            | LAN + Tailscale               | Administration                  |
| SMB            | **LAN subnet only** (e.g. `192.168.1.0/24`) | File shares, never off-LAN |
| Selected LAN app ports | LAN                   | Local-only web UIs              |

Everything else that is reachable from outside arrives via the **Cloudflare
Tunnel** or over **Tailscale** — neither of which needs an inbound firewall
hole, because both are outbound-established.

### Why LAN-scoping matters

SMB in particular is a historically abused protocol. Binding it to the LAN
subnet means that even if something upstream were misconfigured, the file-share
port is not reachable from the internet or from other Tailscale nodes — only
from the physical local network. Default-deny means the *absence* of an explicit
rule is itself a control: new services do not become reachable just because they
started listening.

---

## 6. SSH hardening

- **Key-only authentication.** Password login is disabled
  (`PasswordAuthentication no`). Brute-force against passwords is impossible
  because passwords are not accepted.
- **Passwordless sudo** for the admin user (`youruser`). This is a deliberate
  convenience trade-off: entry already requires possession of the SSH private
  key, so the sudo password would add friction without adding a meaningful
  independent factor for a single-admin box. (On a multi-user or higher-value
  host, keep the sudo password.)
- **Smart login notifier.** A PAM/`sshrc`-style hook pings ntfy — but only for
  **interactive logins from non-trusted IPs**. "Trusted" means the LAN subnet
  and the Tailscale range; those are expected and stay silent to avoid alert
  fatigue. A login from anywhere else fires an ntfy alert immediately.

### Why the notifier is scoped

An alert on *every* login trains you to ignore alerts. By staying quiet for
routine LAN/Tailscale access and only shouting for the genuinely unusual — an
interactive session from an unknown IP — the signal stays meaningful. That is
the one you actually want to see within seconds.

---

## 7. Secrets hygiene

**Nothing secret lives in the git repo.** Concretely:

- **`.env` files, keys, and password hashes are gitignored.** Each stack has its
  own `.env` holding that stack's DB credentials, API keys, and (for the
  downloader stack) the ProtonVPN key. These are present on the host, never in
  version control.
- **Backup credentials** (including restic's repository password and the AWS
  keys) live in a **root-only** file: `/etc/homelab-backup/restic.env`, mode
  `600`, owned by root. Not in the repo, not readable by service users.
- **Terraform state is gitignored.** State files record resource attributes
  *including the generated IAM secret access key in plaintext*. Committing state
  would leak the very credential the least-privilege policy was protecting.
- **CI secret-scanning with gitleaks** runs on every push. If a key is ever
  committed by mistake, the pipeline flags it.

### The lesson worth internalising

> `.gitignore` protects the **working tree**, not **history**.

Adding a file to `.gitignore` stops *future* accidental staging. It does
**nothing** for a secret that was already committed in an earlier commit — that
secret is still sitting in the repo history and is exposed the moment the repo
goes public. `git rm --cached` removes it from the current tree but leaves every
historical copy intact.

So the rule is: **scan before you publish.** Run a history scanner (gitleaks
`detect` over full history, `git-filter-repo`/BFG to purge if you find
something) *before* making a repo public — and treat any secret that ever
touched a public repo as compromised and rotate it, because you cannot un-ring
that bell.

---

## 8. Threat model — what this does NOT protect against

Honesty matters more than a clean checklist. These controls raise the cost of
remote attacks substantially, but they are not a force field. Known gaps:

- **Physical access.** Anyone who can touch the Pi can pull the NVMe/SD and read
  it. Data at rest on the host is **not** full-disk-encrypted here. Physical
  security is the deployment environment's job, not this repo's.
- **Container escape.** Containers share the host kernel. A container breakout
  (kernel vuln, misconfigured mount, privileged flag) would land on the host.
  Containers reduce blast radius but are not a strong security boundary the way
  a VM or separate machine is.
- **Supply chain of `:latest` images.** Auto-updating to `:latest` means
  trusting upstream image publishers on every pull. A compromised or
  typosquatted image, or a malicious update, would be pulled and run
  automatically. Pinning digests and watching what you run mitigates this but is
  a real, accepted trade-off for convenience here.
- **A compromised Cloudflare or ProtonVPN account.** Both are trusted third
  parties in the critical path. Their compromise (or a coerced/legal disclosure)
  is outside what any local config can prevent.
- **The human.** Phishing the admin's Cloudflare/AWS/Proton logins bypasses the
  clever network topology entirely. MFA on those accounts is the real control
  there, and it lives off-box.

Knowing the gaps is the point: it tells you where *not* to store your most
sensitive data on this setup, and what the next hardening investment (disk
encryption, VM isolation, digest pinning) should be.

---

## Summary

| Layer            | Control                                   | Failure mode it addresses            |
| ---------------- | ----------------------------------------- | ------------------------------------ |
| Network ingress  | Zero forwarded ports; Cloudflare Tunnel   | Internet-facing attack surface       |
| App auth         | Cloudflare Access in front of sensitive apps | App-level auth zero-days          |
| Downloader egress| gluetun namespace share + verify timer    | VPN leak exposing home IP            |
| Cloud IAM        | Scoped S3-only IAM user; block public + SSE | Credential-theft blast radius      |
| Host firewall    | ufw default-deny; LAN-scoped SMB          | Unexpected reachable services        |
| SSH              | Key-only; scoped login notifier           | Brute force; unnoticed intrusion     |
| Secrets          | Gitignore + gitleaks CI; root-only creds  | Leaking secrets to a public repo     |

Defence in depth: several of these have to fail together before anything is lost.
