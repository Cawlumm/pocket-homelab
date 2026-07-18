# Lessons Learned

Real operational war stories from running this Raspberry Pi 5 homelab. Each
entry is a thing that actually broke, the fix that stuck, and the general lesson
worth carrying to the next project.

The reason to write these down: the specific bug is rarely the interesting part.
The *class* of mistake is what you want to recognise faster next time.

Placeholders throughout: domain `example.com`, user `youruser`, ntfy topic
`homelab-health`.

---

## 1. NVMe unsafe-shutdown discipline

**Symptom.** After hard power-cuts (yanking the cable, a breaker trip), the Pi
came back with kernel I/O errors against the NVMe drive and brief service
crashes on boot. Occasionally a service needed a manual restart before it was
happy again.

**Cause.** NVMe drives — especially the cheaper ones people pair with a Pi 5 —
do not love losing power mid-write. In-flight writes and the drive's own
internal metadata can be left inconsistent, surfacing as I/O errors until things
settle (or worse, as accumulating media errors over time).

**Fix / discipline.**

- **Always shut down cleanly:** `sudo shutdown -h now`. Never just pull power.
- **Consider a UPS.** Even a small one buys enough time to ride out a blip or to
  trigger an automated clean shutdown on power loss.
- **Monitor drive health.** Watch the NVMe SMART `media_errors` counter over
  time; a rising count is an early warning to replace the drive before it fails.

```bash
sudo nvme smart-log /dev/nvme0 | grep -i media_errors
```

**General lesson.** Storage is stateful and unforgiving. Treat "clean shutdown"
as non-negotiable operational hygiene, not a nicety, and monitor the *trend* of
error counters rather than waiting for a hard failure.

---

## 2. Nextcloud file-lock leak

**Symptom.** A Nextcloud folder became stuck as "locked" — clients refused to
sync it, showing file-locking errors. It never cleared on its own.

**Cause.** Nextcloud's default **transactional file locking uses the database.**
Under real use, stale lock rows were not always cleaned up, and the
`oc_file_locks` table grew to **tens of thousands of rows**. The accumulated
cruft wedged the folder in a permanently-locked state.

**Fix.** Move file locking out of the database and into an in-memory store:

1. Add a **valkey** container (valkey is a maintained Redis fork). It is used
   purely as an ephemeral cache — **no persistence configured**, because a lock
   cache does not need to survive a restart. (In fact, losing it on restart is a
   clean way to clear stale locks.)
2. Point Nextcloud at it in `config.php`:

```php
'memcache.locking'     => '\OC\Memcache\Redis',
'memcache.distributed' => '\OC\Memcache\Redis',
'redis' => [
    'host' => 'valkey',
    'port' => 6379,
],
```

3. Clear the existing stale rows once (truncate `oc_file_locks`) after cutover.

**General lesson.** **Use Redis/valkey for Nextcloud locking, not the database.**
More broadly: a relational DB is the wrong tool for high-churn ephemeral state
like locks. Ephemeral, fast-expiring data belongs in an in-memory store designed
for it — and its non-persistence is a *feature*, not a compromise.

---

## 3. Watchtower abandonment

**Symptom.** Automatic container updates silently stopped working, then the
updater container itself started crashing after a Docker Engine upgrade.

**Cause.** The original **watchtower image had been abandoned upstream.** When
Docker bumped its Engine API version, the unmaintained image could no longer
talk to the daemon and broke. "Set and forget" quietly became "set and rot."

**Fix.** Swapped the image for a **maintained community fork** of watchtower that
tracks current Docker API versions, and confirmed updates were flowing again.

**General lesson.** **Even auto-updaters need a maintained upstream.** The tool
whose entire job is to keep everything current is itself software that ages. Two
habits follow:

- **Check that your tooling is actively maintained** before you depend on it —
  last-commit date, open-issue responsiveness, whether it follows the platform's
  API changes.
- **Pin and watch your automation.** The thing you trust to run unattended is
  exactly the thing whose failure you will notice last, so give it explicit
  monitoring.

---

## 4. gluetun startup race

**Symptom.** After a reboot or a `docker compose up`, the VPN-dependent
containers (the downloader stack) would sometimes come up dead — no network,
crash-looping, or exiting immediately.

**Cause.** A classic **startup race.** The dependent containers share gluetun's
network namespace, but Docker started them as soon as gluetun's *process* had
started — not when the VPN tunnel was actually **up and healthy**. They raced
ahead of a namespace that had no working route yet and failed.

**Fix.** Gate the dependents on gluetun's **health check**, not merely its
existence:

```yaml
services:
  gluetun:
    # ... must define a healthcheck for `service_healthy` to work
    healthcheck:
      test: ["CMD", "wget", "-q", "-O-", "https://ipinfo.io/ip"]
      interval: 30s
      timeout: 10s
      retries: 3

  qbittorrent:
    network_mode: "service:gluetun"
    depends_on:
      gluetun:
        condition: service_healthy
```

**General lesson.** **Model real readiness, not just start order.** "Started" and
"ready to serve" are different events, and depending on the wrong one produces
races that are intermittent and maddening to debug. `depends_on` with
`condition: service_healthy` (backed by an actual health check) waits for the
condition that matters. This applies far beyond Docker — anywhere you wait on a
dependency, wait on *readiness*, not *existence*.

---

## 5. Postgres collation warning after a glibc bump

**Symptom.** After an OS update, Postgres logs filled with:

```
WARNING: database "..." has a collation version mismatch
DETAIL: The database was created using collation version X, but the operating
        system provides version Y.
```

**Cause.** Postgres uses the operating system's C library (**glibc**) for string
collation — sort order, comparisons, index ordering. An OS upgrade bumped glibc,
and its collation definitions changed version. Postgres noticed the mismatch and
warned, because in theory a changed collation can corrupt the ordering
assumptions baked into text indexes.

**Fix.** Rebuild affected indexes, then tell Postgres the database now matches
the current OS collation:

```sql
REINDEX DATABASE "yourdb";
ALTER DATABASE "yourdb" REFRESH COLLATION VERSION;
```

In practice this warning was **benign but noisy** for this workload — but the
correct response is still to reindex and refresh, not to ignore it, because the
underlying risk (silently wrong text-index ordering) is real even when rare.

**General lesson.** **OS library upgrades can desync your database.** The database
is not a sealed box; it leans on host libraries like glibc/ICU for collation.
When you upgrade the base OS or bump a container's base image, watch for
collation warnings and handle them deliberately. It is a good argument for
pinning base images and reading changelogs before major libc jumps.

---

## Cross-cutting themes

Pulling back from the individual incidents, the same few lessons keep recurring:

- **State is where the danger is.** Storage, databases, and locks caused the
  nastiest failures. Stateless services just restart; stateful ones corrupt.
- **"Started" is not "ready."** The gluetun race and (in spirit) clean shutdown
  are both about respecting real lifecycle states instead of proxies for them.
- **Everything you depend on ages.** Watchtower rotted; glibc moved under
  Postgres. Even "finished" infrastructure needs maintenance and monitoring.
- **Make failures loud.** Health checks, ntfy alerts, and SMART monitoring exist
  so problems announce themselves early instead of being discovered as an
  outage.

The homelab is worth running partly *because* it teaches these the hard way, in a
place where the blast radius is your own media library and not production.
