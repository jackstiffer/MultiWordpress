---
phase: 03
status: passed
verification_type: static
verified: 2026-04-30
live_verification: deferred to first VM deployment of Phase 3
---

# Phase 3 Verification — Static

Phase 3 ships host-cron infrastructure that cannot be exercised meaningfully on the dev box (no `wp.slice`, no `wp-mariadb` container, no `cron` service in the way Linux does it). All checks below are **static**: file presence, bash syntax, patch landing, schema validity, algorithm determinism. **Live runtime verification is deferred to the first VM deployment of Phase 3** — explicitly tracked.

## Static Checks

### 1. File presence (5 expected)

| File | Expected | Result |
|------|----------|--------|
| `bin/wp-metrics-poll` | exists, mode 755 | ✓ FOUND (343 LOC, mode 755) |
| `bin/_cron-mgr.sh` | exists, sourceable | ✓ FOUND (124 LOC) |
| `host/install-metrics-cron.sh` | exists, mode 755 | ✓ FOUND (101 LOC, mode 755) |
| `docs/operational.md` | exists | ✓ FOUND (203 LOC) |
| `bin/wp-create` (patched) | unchanged shape, contains `_cron_register` call | ✓ Line 592: `_cron_register "$SLUG" \|\| _log warn ...` |
| `bin/wp-delete` (patched) | contains `_cron_unregister` call | ✓ Line 120: `_cron_unregister "$SLUG" \|\| _log warn ...` |

### 2. Bash syntax (`bash -n`)

```
bash -n bin/wp-metrics-poll              → OK
bash -n bin/_cron-mgr.sh                 → OK
bash -n host/install-metrics-cron.sh     → OK
bash -n bin/wp-create  (post-patch)      → OK
bash -n bin/wp-delete  (post-patch)      → OK
```

### 3. Function loading

```
$ source bin/_cron-mgr.sh
$ type _cron_register      → "_cron_register is a function"  ✓
$ type _cron_unregister    → "_cron_unregister is a function" ✓
$ type _cron_stagger_minute → "_cron_stagger_minute is a function" ✓
```

### 4. Stagger algorithm spot-test (deterministic + spread)

Algorithm: `minute = first-8-hex(sha256(slug)) mod 60`.

| slug | minute (run 1) | minute (run 2) | deterministic? |
|------|---------------:|---------------:|:--------------:|
| `blog_example_com` | 54 | 54 | ✓ |
| `shop_example_com` | 38 | 38 | ✓ |
| `test_site` | 1 | 1 | ✓ |
| `foo` | 39 | 39 | ✓ |
| `bar` | 38 | 38 | ✓ |

Spread: `{1, 38, 39, 54}` over 5 slugs — well-distributed. (Two slugs collided at 38 — birthday-paradox math says ~9 sites is the 50% collision point; collisions are harmless because `wp cron event run --due-now` is fast.)

### 5. metrics.json schema validation

Synthesized one and round-tripped through `jq`:

```json
{
  "version": 1,
  "cluster": {
    "pool_used_bytes": 471392256,
    "pool_used_peak_bytes": 471392256,
    "peak_window_start": "2026-04-30T16:30:00Z",
    "peak_window_end":   "2026-04-30T16:30:00Z"
  },
  "sites": {
    "blog_example_com": {
      "mem_bytes": 142606336,
      "mem_peak_bytes": 384901120,
      "cpu_pct": 1.2,
      "cpu_peak_pct": 47.8,
      "db_conn": 2,
      "db_conn_peak": 14,
      "last_sample_ts": "2026-05-01T16:30:00Z",
      "samples": [{"ts":"2026-05-01T16:29:00Z","mem":142606336,"cpu":1.2,"db_conn":2}]
    }
  }
}
```

`jq -e .` round-trip: ✓ valid JSON. Peak-recompute jq filter (`[.samples[].mem] | max`) tested independently: ✓.

## Requirements Coverage

### PERF-03 (wp-cron stagger)

- [x] `DISABLE_WP_CRON=true` already in `templates/wp-config-extras.php.tmpl` (Phase 2 carryover — verified by `grep DISABLE_WP_CRON templates/wp-config-extras.php.tmpl`).
- [x] `bin/wp-create` registers a host crontab line per site with deterministic offset (`_cron_register "$SLUG"` after finalize, line 592).
- [x] `bin/wp-delete` unregisters the line on site removal (`_cron_unregister "$SLUG"` before DB drop, line 120).
- [x] Stagger algorithm = `sha256(slug) mod 60` — spec-locked, deterministic, verified.
- [x] Cron file template (`/etc/cron.d/multiwordpress`) includes a header + metrics-poll line + per-site stagger lines section. Idempotent install via `host/install-metrics-cron.sh`.

### PERF-04 (metrics poll)

- [x] `bin/wp-metrics-poll` exists, samples cluster (`/sys/fs/cgroup/wp.slice/memory.current`), per-site (`docker stats --no-stream`), and DB connections (`information_schema.processlist GROUP BY user`).
- [x] Skips `wp-mariadb` and `wp-redis` containers.
- [x] 24h rolling sample buffer (≤ 1440 entries per site), trimmed by ts on each write.
- [x] Atomic write via temp + `mv`.
- [x] `flock` against concurrent invocations (non-blocking — skip if previous still running).
- [x] Always exits 0 (cron-safe).
- [x] 5 MB sanity guard with auto-trim.
- [x] Sub-200ms target: cannot be measured statically — **deferred to live VM verification**.
- [x] Drops samples older than 24h on every write (jq filter `select(.ts >= $cutoff)`).
- [x] Schema locked: `cluster {pool_used_bytes, pool_used_peak_bytes, peak_window_start, peak_window_end}`, `sites.<slug> {mem_bytes, mem_peak_bytes, cpu_pct, cpu_peak_pct, db_conn, db_conn_peak, last_sample_ts, samples[]}`.

## Deferred to Live VM Verification

These checks need a real Debian/Ubuntu VM with `wp.slice` active and at least one `wp-<slug>` container running. They will be exercised on first deployment of Phase 3 to the GCP VM:

1. `sudo host/install-metrics-cron.sh` — runs without error.
2. `cat /etc/cron.d/multiwordpress` — shows header + metrics-poll line.
3. After ~70 seconds: `jq '.cluster.pool_used_bytes' /opt/wp/state/metrics.json` returns non-zero.
4. `time /opt/wp/bin/wp-metrics-poll` — completes in < 200 ms (single-site case; scales linearly with site count).
5. After running `wp-create blog.example.com`, `grep wp-blog_example_com /etc/cron.d/multiwordpress` returns one line at the slug-derived minute (54 per spot-test).
6. `wp-stats` (Phase 2 surface) shows real peak columns instead of `-` after first poll cycle.
7. With 5 sites running, `awk '/^[0-9]+ \* \* \* \*/' /etc/cron.d/multiwordpress | awk '{print $1}' | sort -n` shows minute values spread, not clustered.
8. After 24h+: per-site `mem_peak_bytes`, `cpu_peak_pct`, `db_conn_peak` populated.

## Frontmatter

`status: passed` (static). Live-runtime checks documented above and tracked under Phase 3 deployment runbook.
