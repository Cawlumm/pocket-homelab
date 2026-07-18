# Backups & Disaster Recovery

This document describes the backup and disaster-recovery (DR) design for this
Raspberry Pi 5 homelab. It is written to be *taught*, not just followed: every
choice is explained so you can judge whether it fits your own setup and adapt it.

The short version: **two tiers, one cloud provider, fully infrastructure-as-code,
and — critically — actually restore-tested.** A backup you have never restored
is a hope, not a backup.

---

## 1. The 3-2-1 principle

The industry rule of thumb for surviving data loss is **3-2-1**:

- **3** copies of your data,
- on **2** different types of media,
- with **1** copy off-site.

A homelab is fragile in ways a hosted service is not: it lives on one desk, on
one SD card / SSD, on one power circuit, in one building. A dropped disk, a bad
`rm -rf`, a ransomware-infected client, a flood, or a house fire can take out
everything at once. Off-site is the part people skip and the part that saves you.

Here is how this homelab satisfies 3-2-1:

| 3-2-1 requirement | How this homelab meets it |
|---|---|
| Copy #1 (live) | The running services on the Pi's SSD. |
| Copy #2 (different media) | Snapshots / a local secondary disk (not covered here). |
| Copy #3 (off-site) | **AWS S3** — the two tiers described below. |
| 2 media types | Local flash/SSD + cloud object storage. |
| 1 off-site | Both S3 tiers live in an AWS region far from the house. |

Everything below is about copy #3 — the off-site cloud tier — because that is
the part that requires real design: what to back up, how often, to which storage
class, how to keep it consistent, how much it costs, and how to get it *back*.

---

## 2. Two tiers at a glance

Not all data is equal. This design splits everything into two tiers based on a
single question: **"If I lost this, could I get it back another way?"**

- **Tier 1 — irreplaceable.** Configs, databases, password vault, ebooks,
  personal files. If this is gone, it is *gone*. It is small (~50 GB) and must
  be restorable *now*.
- **Tier 2 — replaceable but annoying.** The big media library — movies, TV,
  music — that could in principle be re-acquired. It is large (terabytes) and a
  slow restore is acceptable because you would rather wait than re-rip everything.

| | **Tier 1** | **Tier 2** |
|---|---|---|
| Tool | `restic` | `aws s3 sync` |
| Destination | S3 **Glacier Instant Retrieval** (GIR) | S3 **Glacier Deep Archive** |
| Bucket | `<PREFIX>-gir-xxxx` | `<PREFIX>-archive-xxxx` |
| Schedule | Nightly, 03:30, systemd timer | Weekly |
| Contents | Configs, databases, irreplaceable data | Full re-downloadable media library |
| Approx. size | ~50 GB | Terabytes |
| Restore latency | Milliseconds (instant) | Hours (up to ~12h standard) |
| Retention | `keep-daily 7 / weekly 4 / monthly 6`, pruned | Versioning + 30-day delete grace |
| Encryption | restic (client-side) + SSE-S3 (AES256) | SSE-S3 (AES256) |
| Why | Small, must-have-now set | Large, nice-to-have set |

The rest of the document is a deep dive into each tier, then the OpenTofu that
provisions the buckets, then the restore drill, cost, and how to adapt it.

---

## 3. Tier 1 deep dive — `restic` to Glacier Instant Retrieval

### 3.1 Why restic

`restic` is a deduplicating, encrypted, snapshotting backup program. It gives us:

- **Client-side encryption.** Data is encrypted *before* it leaves the Pi, so
  the cloud provider only ever sees ciphertext. AWS SSE is a second layer, not
  the only one.
- **Deduplication.** Nightly backups of slowly-changing configs and databases
  cost almost nothing after the first upload — only changed blocks are stored.
- **Snapshots + retention.** Point-in-time recovery, with a retention policy
  that prunes old snapshots automatically.
- **Integrity checking.** `restic check` verifies the repository is not corrupt.

### 3.2 What Tier 1 backs up

Only the irreplaceable set — deliberately *not* the re-downloadable media:

- **Postgres** — a logical dump via `pg_dumpall` (see consistency below).
- **Vaultwarden** — the SQLite DB via a consistent `.backup` (WAL-safe).
- **\*arr configs** — Sonarr / Radarr / Prowlarr etc. configuration and DBs.
- **Audiobookshelf** — config and metadata.
- **Nextcloud** — data + config (with maintenance mode flipped around the dump).
- **Ebooks** and **audiobooks** — personal, not trivially re-downloadable.

The media library itself is excluded here; it belongs in Tier 2.

### 3.3 Why Glacier Instant Retrieval

S3 offers a spectrum of storage classes trading **price** against **retrieval
latency**:

- **STANDARD** — most expensive to store, instant, no retrieval fee.
- **Glacier Instant Retrieval (GIR)** — much cheaper to store, still
  *millisecond* retrieval, small per-GB retrieval fee. Designed for data you
  rarely touch but must have *immediately* when you do.
- **Glacier Deep Archive** — cheapest of all, but retrieval takes *hours* and
  must be explicitly requested.

Tier 1 is small and must be restorable during an actual emergency — you do not
want to wait 12 hours to recover your password vault. GIR is the sweet spot:
near-STANDARD access at a fraction of the storage cost. Because the set is only
~50 GB, the slightly higher per-GB price of GIR versus Deep Archive is a
rounding error in absolute dollars.

### 3.4 Storage-class split: data vs metadata

A subtle but important detail: **the data packs are written directly as
`GLACIER_IR`, while restic's own metadata (index, snapshots, config, locks)
stays in `STANDARD`.**

Why? restic reads its metadata constantly — on every backup, prune, check, and
restore. If that metadata lived in a Glacier class, ordinary operations would
incur per-object retrieval costs and latency on every run. Keeping the small
metadata in STANDARD and pushing only the bulk data packs to GIR gives you cheap
storage where it matters and cheap access where it matters. This is configured
**client-side by restic itself**: the nightly job passes
`--option s3.storage-class=GLACIER_IR`, so restic writes its bulk data packs
straight to GIR while uploading its index/snapshot metadata as STANDARD — no S3
lifecycle transition rule needed.

### 3.5 The nightly script and consistency

The nightly job runs at **03:30** via a systemd timer. The tricky part of
backing up live services is **consistency**: a naive file copy of a database
that is being written to can capture a torn, unrestorable state. The script
handles each store correctly:

- **Postgres** — dumped with `pg_dumpall`, which produces a transactionally
  consistent logical snapshot. Around this, **Nextcloud maintenance mode is
  briefly toggled on** so the Nextcloud app is not mid-write against the DB while
  the dump runs, then toggled back off. The window is seconds.
- **Vaultwarden** — SQLite is copied with the `.backup` command (via
  `sqlite3 … ".backup"`), which is **WAL-safe**: it produces a coherent copy even
  while the database is open and using write-ahead logging. A plain `cp` of a
  live SQLite file can be corrupt; `.backup` cannot.
- **Staging directory** — dumps are written to a staging dir created with mode
  **`700`** (owner-only) because it briefly holds secrets (the password-vault DB,
  DB dumps). The directory is **wiped after** the restic run completes, success
  or fail, so plaintext secrets never linger on disk.

Sketch of the flow (illustrative, not the literal script):

```bash
set -euo pipefail
STAGING="$(mktemp -d)"; chmod 700 "$STAGING"
trap 'rm -rf "$STAGING"' EXIT          # secrets never linger

# Postgres — consistent logical dump, Nextcloud quiesced around it
nextcloud_maintenance on
pg_dumpall > "$STAGING/postgres.sql"
nextcloud_maintenance off

# Vaultwarden — WAL-safe SQLite copy
sqlite3 /data/vaultwarden/db.sqlite3 ".backup '$STAGING/vaultwarden.sqlite3'"

# Ship everything to GIR-backed restic repo
restic backup "$STAGING" /configs /nextcloud/data /books/ebooks /books/audiobooks

# Retention
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
```

### 3.6 Retention

```
restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
```

This keeps: the last **7 daily** snapshots, **4 weekly**, and **6 monthly** —
then `--prune` reclaims the space from snapshots that no longer match. In plain
terms: about a week of fine-grained history, a month of weekly checkpoints, and
half a year of monthly checkpoints. That is enough to recover from "I broke it
last night" *and* "this file was silently corrupted three months ago" without
paying to store every nightly snapshot forever.

---

## 4. Tier 2 deep dive — `aws s3 sync` to Glacier Deep Archive

### 4.1 Why not restic here too?

The media library is large (terabytes) and mostly immutable — files are added,
rarely changed. restic's dedup and snapshotting buy little here, and its pack
format makes selective single-file restore from a deep-archive class awkward. A
plain **`aws s3 sync`** maps each media file to one S3 object, which is simple,
transparent, and cheap to reason about.

### 4.2 Deep Archive: cheapest storage, slowest restore

Deep Archive is the least expensive storage AWS sells. The trade-off is
retrieval: pulling data back takes **hours**, and you pay a retrieval fee. That
is completely acceptable for Tier 2 — if the house burns down, waiting overnight
to re-download the movie library while you deal with insurance is fine. You are
paying rock-bottom storage prices for years of "probably never needed" media.

### 4.3 The 30-day delete grace

`aws s3 sync --delete` will remove objects from the bucket that no longer exist
locally — which is exactly what you want to mirror the library, but also exactly
how a local mistake could propagate to your only off-site copy.

This design defuses that with **bucket versioning plus a lifecycle rule**:

- **Versioning is on**, so `--delete` does not actually erase an object — it
  writes a **delete marker** and retains the previous version.
- A **lifecycle rule expires noncurrent versions after 30 days.**

The net effect is a **30-day "delete grace"**: anything removed by a bad sync is
recoverable for 30 days by removing the delete marker, after which AWS reclaims
the space so you are not paying to store deleted data forever. It is an undo
buffer for your off-site mirror.

---

## 5. Infrastructure as code — OpenTofu

The S3 buckets, their security posture, the IAM user, the cost alarm, and a
monitoring dashboard are **all provisioned by [OpenTofu](https://opentofu.org/)**
(the open-source Terraform fork) under `iac/`. Nothing is clicked together by
hand in the AWS console. This is what makes the design a *portfolio piece*: it is
reproducible, reviewable, and self-documenting.

What the OpenTofu enforces:

- **Two S3 buckets** — `<PREFIX>-gir-xxxx` and `<PREFIX>-archive-xxxx`.
- **Block all public access** on both — no accidental public object, ever.
- **Server-side encryption** (SSE-S3, `AES256`) at rest.
- **Versioning** on both buckets (enables the 30-day delete grace on Tier 2 and
  protects Tier 1's metadata).
- **Lifecycle rules**: abort incomplete multipart uploads after **7 days** (so
  failed large uploads do not silently accrue charges), expire noncurrent
  versions after **30 days**, and transition Tier 2 objects to Deep Archive.
- **A least-privilege IAM user** scoped to *exactly* these two buckets and no
  other AWS resource — the credentials the Pi holds can touch nothing else.
- **An AWS Budgets cost alarm** so a runaway bill (or a misconfiguration) pages
  you instead of surprising you at month end.
- **A CloudWatch dashboard** for at-a-glance bucket size and request metrics.

### 5.1 Annotated bucket snippet (generic — write your own values)

The following is illustrative HCL showing *what* the buckets enforce. Do not
paste real account IDs, bucket suffixes, or keys into version control.

```hcl
# --- The irreplaceable-data bucket (Tier 1, restic -> GIR) ---
resource "aws_s3_bucket" "gir" {
  bucket = "${var.prefix}-gir-${random_id.suffix.hex}"
}

# No public access — belt and suspenders, all four switches on.
resource "aws_s3_bucket_public_access_block" "gir" {
  bucket                  = aws_s3_bucket.gir.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Encrypt everything at rest with SSE-S3 (AES256).
resource "aws_s3_bucket_server_side_encryption_configuration" "gir" {
  bucket = aws_s3_bucket.gir.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Versioning protects restic's metadata from accidental clobber.
resource "aws_s3_bucket_versioning" "gir" {
  bucket = aws_s3_bucket.gir.id
  versioning_configuration { status = "Enabled" }
}

# Housekeeping only. (The GIR storage class is set client-side by restic via
# --option s3.storage-class=GLACIER_IR, so there is NO transition rule here.)
resource "aws_s3_bucket_lifecycle_configuration" "gir" {
  bucket = aws_s3_bucket.gir.id

  rule {
    id     = "abort-incomplete-mpu"
    status = "Enabled"
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }

  rule {
    id     = "expire-noncurrent"
    status = "Enabled"
    noncurrent_version_expiration { noncurrent_days = 30 }
  }
}
```

The IAM user gets a policy allowing only `s3:*Object`/`s3:ListBucket` (and the
multipart actions) on **these two bucket ARNs and their contents** — nothing
wildcarded across the account.

### 5.2 The state file holds a secret — gitignore it

OpenTofu writes the generated IAM user's access key into its **state file**
(`terraform.tfstate`). That state is therefore a **secret** and is
**gitignored**. Never commit it. For a solo homelab, local state kept off-Git is
fine; for anything shared, use an encrypted remote backend (e.g. an S3 backend
with a KMS key and state locking). The repo's `iac/.gitignore` excludes
`*.tfstate*` and any `*.tfvars` that carry values.

---

## 6. Verification & restore drill

> **A backup you haven't restored is a hope, not a backup.**

The single most common failure in amateur DR is discovering, at the worst
possible moment, that the backups were silently broken for months. The only cure
is to *actually restore* — periodically, deliberately, and end-to-end.

### 6.1 Integrity check

`restic check` verifies repository structure and that all referenced data is
present and consistent:

```bash
# Load the repo credentials (see §8) then:
restic check                 # structure + metadata integrity
restic check --read-data     # heavier: re-reads and re-hashes pack data
```

`--read-data` downloads and re-hashes every pack, so it incurs GIR retrieval
cost — run it occasionally (e.g. quarterly), not nightly.

### 6.2 Full restore drill (copy-pasteable)

This proves the backup is not just *present* but *correct* — restore it to a
throwaway directory and byte-compare against the source:

```bash
# 1. Pick a snapshot to test (usually the latest).
restic snapshots

# 2. Restore it into a temporary directory.
RESTORE_DIR="$(mktemp -d)"
restic restore latest --target "$RESTORE_DIR"

# 3. Byte-for-byte compare against the live source.
#    diff -r is silent and exits 0 when the trees are identical.
diff -r /configs "$RESTORE_DIR/configs" && echo "IDENTICAL"

# 4. (Optional) spot-check a database dump actually loads.
#    e.g. restore into a scratch Postgres and run the dump.

# 5. Clean up — the restore held real data.
rm -rf "$RESTORE_DIR"
```

A clean `diff -r` (no output, exit code 0) means the restored tree is
**bit-identical** to the source. That is the standard this design holds itself
to and has been tested against.

### 6.3 Tier 2 restore note

Deep Archive objects must be **restored (thawed) before download** — you issue a
restore request and wait hours for AWS to stage the objects into a readable tier,
then `aws s3 cp`/`sync` them down. Do a small thaw drill (one directory) so you
know the procedure and the timing before you ever need the whole library.

---

## 7. Monitoring — catching silent failures

Backups fail silently. A timer that stopped firing, an expired credential, a full
disk — none of these announce themselves. Two mechanisms turn silence into an
alert, both via **[ntfy](https://ntfy.sh/)** push notifications.

- **`OnFailure=` ntfy on the backup units.** Each systemd backup service has an
  `OnFailure=` hook that fires an ntfy notification to the **`homelab-backups`**
  topic the moment a unit exits non-zero. You hear about *loud* failures
  immediately.

- **A `backup-watchdog` timer for *silent* failures.** A separate systemd timer
  checks the age of the newest restic snapshot and **alerts to `homelab-health`
  if it is older than 26 hours.** Since backups run every 24h, a >26h-old newest
  snapshot means a run was skipped or failed without even starting — the case an
  `OnFailure` hook cannot catch because the unit never ran. The 26h threshold
  gives a couple of hours of slack for a late or slow run before paging you.

Watchdog logic sketch:

```bash
# Newest snapshot timestamp, in epoch seconds.
newest=$(restic snapshots --json --latest 1 | jq -r '.[0].time' \
         | xargs -I{} date -d {} +%s)
age_h=$(( ( $(date +%s) - newest ) / 3600 ))

if (( age_h > 26 )); then
  curl -s -d "Newest restic snapshot is ${age_h}h old (>26h) — backups may be stalled" \
       https://ntfy.example.com/homelab-health
fi
```

Between them: `OnFailure` catches "it ran and broke," the watchdog catches "it
never ran." Together they close the silent-failure gap.

---

## 8. Cost

The whole point of the two-tier split is that **the expensive, instant tier is
tiny and the huge tier is dirt cheap.**

- **Tier 1 (GIR, ~50 GB).** Glacier Instant Retrieval storage for ~50 GB is a
  small fraction of a dollar per month. restic dedup keeps growth minimal.
- **Tier 2 (Deep Archive, terabytes).** Deep Archive is the cheapest storage AWS
  offers; even several TB lands in the low single-digit dollars per month.
- **Total: a few dollars a month.** Realistically this design runs on the order
  of **a couple of dollars to a handful of dollars per month** for a homelab-
  sized dataset — cheaper than a single streaming subscription, for a complete
  off-site DR copy of everything you cannot afford to lose.

Cost control is *designed in*, not hoped for:

- The **AWS Budgets alarm** (provisioned by OpenTofu) pages you if spend crosses
  a threshold — your safety net against a misconfiguration or a retrieval you
  did not expect.
- **Retrieval, not storage, is where surprise bills hide.** Storage is
  predictable; pulling data *back* costs money, and Deep Archive thaws are
  billed per GB. That is fine for a real disaster (you restore once) but is why
  you should not casually `--read-data` the whole GIR repo or thaw the whole
  media library "just to check."
- **`abort-incomplete-multipart-upload` after 7 days** prevents failed big
  uploads from quietly accumulating billable orphaned parts.

---

## 9. How to adapt this for yourself

You can stand up the same design for your own homelab. The building blocks are
generic; only the names and credentials are yours.

1. **Create your own AWS account** (or a dedicated sub-account). Do *not* run
   backups as the root user — create an admin IAM user for `tofu apply`, and let
   OpenTofu create the scoped backup user.

2. **Pick a bucket prefix.** Set `var.prefix` (e.g. your homelab's name). The
   buckets become `<PREFIX>-gir-xxxx` and `<PREFIX>-archive-xxxx`, where `xxxx`
   is a random suffix OpenTofu adds so the globally-unique bucket names never
   collide.

3. **Run OpenTofu.**
   ```bash
   cd iac
   cp terraform.tfvars.example terraform.tfvars   # set prefix, region, budget
   tofu init
   tofu plan       # review exactly what will be created
   tofu apply
   ```
   `tofu apply` prints the created backup IAM user's access key (from state).
   Keep the state file off Git — it is a secret (see §5.2).

4. **Drop credentials on the Pi.** Put the restic repo settings and AWS keys in
   a root-only env file that the systemd units load:
   ```
   /etc/homelab-backup/restic.env      # chmod 600, owned by root
   ```
   ```bash
   # /etc/homelab-backup/restic.env  (example — use your own values)
   export AWS_ACCESS_KEY_ID=...
   export AWS_SECRET_ACCESS_KEY=...
   export RESTIC_REPOSITORY=s3:s3.amazonaws.com/<PREFIX>-gir-xxxx
   export RESTIC_PASSWORD=...          # the restic repo encryption password
   ```
   **Back up `RESTIC_PASSWORD` somewhere outside the Pi** (a real password
   manager, printed in a safe). If you lose it, the encrypted repo is
   unrecoverable — that is the encryption working as intended.

5. **Point ntfy at your topics.** Change `homelab-backups` / `homelab-health` to
   your own ntfy server/topics in the units and watchdog.

6. **Enable the timers and — most importantly — run the restore drill (§6)
   before you trust it.** Set a recurring reminder to re-run the drill. The
   design is only as good as the last time you proved it restores.

---

### Summary

Two tiers matched to how much the data hurts to lose; the small must-have-now set
on instant-retrieval Glacier, the big nice-to-have set on the cheapest deep
archive; consistency handled per-datastore; the whole cloud footprint defined in
OpenTofu with least-privilege IAM, encryption, versioning, cost alarms, and a
30-day undo buffer; monitored for both loud and silent failure; and — the part
that makes it real — **restore-tested to a bit-identical `diff -r`.** A few
dollars a month for a complete, reproducible, tested off-site disaster-recovery
copy of everything irreplaceable.
