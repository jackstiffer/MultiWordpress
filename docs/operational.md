# Operational Runbook — Phase 3

This page covers the two operational essentials installed in Phase 3:

1. **`wp-metrics-poll`** — host cron sampling cluster + per-site usage every minute.
2. **wp-cron stagger** — one host cron line per site, deterministically offset by `sha256(slug) mod 60`, so 5+ sites don't all fire at `:00`.

Both live in a single host file: `/etc/cron.d/multiwordpress`.

---

## Install

The metrics-poll cron is installed once per host:

```bash
sudo host/install-metrics-cron.sh
```

This script:

- Verifies `jq` is installed.
- Verifies `cron` (or `crond`) is active (warns; does not fail if not).
- Writes `/etc/cron.d/multiwordpress` with mode `644` (cron requires non-executable).
- Preserves any existing per-site stagger lines on re-run (idempotent).

The script is safe to re-run after upgrades.

Per-site stagger lines are registered automatically by `wp-create` and removed automatically by `wp-delete` — no manual cron editing needed.

---

## Verify

### File contents

```bash
cat /etc/cron.d/multiwordpress
```

You should see:

```
# MultiWordpress cron entries — managed by /opt/wp/bin/_cron-mgr.sh + host/install-metrics-cron.sh
# DO NOT EDIT MANUALLY — wp-create/wp-delete update per-site lines.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Metrics poll — every minute
* * * * * root /opt/wp/bin/wp-metrics-poll >/dev/null 2>&1

# Per-site wp-cron stagger lines — managed by bin/_cron-mgr.sh
17 * * * * root docker exec -u www-data wp-blog_example_com wp cron event run --due-now >/dev/null 2>&1
42 * * * * root docker exec -u www-data wp-shop_example_com wp cron event run --due-now >/dev/null 2>&1
```

### Cron actually running it

```bash
tail -f /var/log/syslog | grep CRON
# (Alpine / RHEL: tail -f /var/log/cron)
```

You should see one CRON line per minute mentioning `wp-metrics-poll`.

### Metrics file populating

```bash
cat /opt/wp/state/metrics.json | jq '.cluster'
```

After 1 minute:

```json
{
  "pool_used_bytes": 471392256,
  "pool_used_peak_bytes": 471392256,
  "peak_window_start": "2026-04-30T16:30:00Z",
  "peak_window_end":   "2026-04-30T16:30:00Z"
}
```

`pool_used_bytes` should be **non-zero** (assuming `wp.slice` has containers attached).

### Site-level peaks (after 24h)

```bash
cat /opt/wp/state/metrics.json | jq '.sites["blog_example_com"]'
```

After 24h+ runtime:

```json
{
  "mem_bytes": 142606336,
  "mem_peak_bytes": 384901120,
  "cpu_pct": 1.2,
  "cpu_peak_pct": 47.8,
  "db_conn": 2,
  "db_conn_peak": 14,
  "last_sample_ts": "2026-05-01T16:30:00Z",
  "samples": [ /* up to 1440 entries */ ]
}
```

### Verify the stagger spread

The whole point of the stagger is to NOT have 5 sites all firing at `:00`. To eyeball the spread:

```bash
awk '/^[0-9]+ \* \* \* \*/' /etc/cron.d/multiwordpress | awk '{print $1}' | sort -n
```

With 5+ sites you expect minute values spread across `0–59`, not clustered at one number.

---

## Manually trigger one site's wp-cron

For testing or after a long downtime:

```bash
docker exec -u www-data wp-<slug> wp cron event run --due-now
```

To list pending events without running them:

```bash
docker exec -u www-data wp-<slug> wp cron event list
```

---

## Troubleshooting

### `pool_used_bytes` stays at 0

- `cat /sys/fs/cgroup/wp.slice/memory.current` — does it return a number? If "no such file", `wp.slice` isn't installed or activated. Run `host/install-wp-slice.sh` (Phase 1).
- Are any containers actually in the slice? `systemctl status wp.slice` should show member containers.

### `metrics.json` empty / missing

- Check cron actually ran the poller in the last minute: `grep wp-metrics-poll /var/log/syslog | tail`.
- Run it manually: `sudo /opt/wp/bin/wp-metrics-poll && cat /opt/wp/state/metrics.json`. Errors print to stderr.
- Verify `jq` is present (`command -v jq`). The poller silently no-ops without it.

### `cron` service not running

- Debian/Ubuntu: `sudo systemctl enable --now cron`
- Alpine: `sudo rc-service crond start && sudo rc-update add crond`
- RHEL/CentOS: `sudo systemctl enable --now crond`

### Stale samples (last_sample_ts > 5 minutes old)

- Cron service stopped — see above.
- Poller is taking too long and getting `flock`-skipped: check the warning lines in syslog. The poller exits early if a previous invocation is still holding the lock.
- `docker stats` is hanging — try `docker stats --no-stream wp-<slug>` manually; if it hangs, the docker daemon needs attention.

### Stagger collision (improbable)

With 60 minute slots and a uniformly-distributed hash, the birthday-paradox 50% collision threshold is ~9 sites. Two sites picking the same minute is harmless — they just both run at that minute, and `wp cron event run --due-now` is fast (<1s typical) so even 5 simultaneous fires won't dent the cluster.

If you genuinely want unique minutes for >9 sites, set a custom `--cron-minute` flag (not yet implemented; tracked under v2 work).

### `jq` missing

`apt install jq` (Debian/Ubuntu) or `apk add jq` (Alpine). The poller and `_cron-mgr.sh` both require it.

---

## metrics.json schema (reference for Phase 4 dashboard)

```json
{
  "version": 1,
  "cluster": {
    "pool_used_bytes":      0,
    "pool_used_peak_bytes": 0,
    "peak_window_start":    "<iso-8601>",
    "peak_window_end":      "<iso-8601>"
  },
  "sites": {
    "<slug>": {
      "mem_bytes":      0,
      "mem_peak_bytes": 0,
      "cpu_pct":        0.0,
      "cpu_peak_pct":   0.0,
      "db_conn":        0,
      "db_conn_peak":   0,
      "last_sample_ts": "<iso-8601>",
      "samples": [
        { "ts": "<iso-8601>", "mem": 0, "cpu": 0.0, "db_conn": 0 }
      ]
    }
  }
}
```

- Peaks are computed over a rolling 24h window (1440 samples max per site).
- Atomic write via temp + `mv` — readers never see a half-written file.
- File grows ~115 KB per site at steady-state; 5 MB sanity guard trims if breached.

This schema is **locked** for Phase 4 — the dashboard reads it as-is.
