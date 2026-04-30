# Phase 3: Operational Tooling — Context

**Gathered:** 2026-04-30
**Status:** Ready for planning
**Mode:** Auto

<domain>
## Phase Boundary

Two operational essentials that make 5+ sites painless:
1. **wp-cron stagger** — host-level cron that triggers per-site `wp cron event run --due-now` at deterministic offsets (slug-hash mod), preventing the synchronized `:00` storm. Provisioning script registers a crontab line per new site.
2. **Metrics poll** — host cron `wp-metrics-poll` runs every minute, samples `docker stats` + per-site MariaDB conn count + `wp.slice/memory.current`, persists rolling 24h peaks to `/opt/wp/state/metrics.json`. Reads by `wp-list`/`wp-stats`/dashboard.

Out of scope: dashboard UI (Phase 4), README/docs polish (Phase 4 covers full doc suite; Phase 3 ships only minimal docs/operational.md).

</domain>

<canonical_refs>
- `.planning/REQUIREMENTS.md` — PERF-03, PERF-04
- `.planning/ROADMAP.md` — Phase 3 success criteria
- `.planning/research/PITFALLS.md` — §1.5 wp-cron storms; §1.4 log discipline
- `.planning/phases/02-cli-core-first-site-e2e/02-CONTEXT.md` — sites.json schema (consumer of metrics.json + producer of cron entries)
- `bin/_lib.sh` — reuse helpers (`_log`, `_with_lock`, `_db_exec`)
- `bin/wp-create` — needs minor patch in this phase to register the per-site crontab line
- `bin/wp-delete` — needs minor patch to unregister the crontab line

</canonical_refs>

<decisions>
## Implementation Decisions

### `bin/wp-metrics-poll`
- Bash script. Mode 755. Runs as root via `cron`.
- Sequence (target completion < 200 ms):
  1. Read `/opt/wp/state/metrics.json` (init `{"version":1,"cluster":{},"sites":{}}` if missing).
  2. Sample cluster pool: `cat /sys/fs/cgroup/wp.slice/memory.current` (bytes).
  3. Sample per-site:
     - For each container in `docker ps --filter name=wp- --format '{{.Names}}'`:
       - `docker stats <name> --no-stream --format '{{.MemUsage}} {{.CPUPerc}}'` → parse current MEM bytes + CPU %.
     - Skip `wp-mariadb` and `wp-redis` (shared infra not in pool).
  4. Sample DB conns per site: single `_db_exec "SELECT user, COUNT(*) FROM information_schema.processlist WHERE user LIKE 'wp_%' GROUP BY user;"` → parse rows.
  5. Update `metrics.json`:
     - For each metric, store new sample.
     - Keep rolling 24h sample buffer per site (1440 samples = one per minute × 24h). Use `samples[]` array; trim entries older than `now - 86400 seconds`.
     - Compute peak over the 24h window (max).
     - Persist `{cluster: {pool_used_bytes, pool_used_peak_bytes, peak_window_start, peak_window_end}, sites: {<slug>: {mem_bytes, mem_peak_bytes, cpu_pct, cpu_peak_pct, db_conn, db_conn_peak, last_sample_ts}}}`.
  6. Atomic write via temp + mv. Mode 644.
- Use `jq` for JSON manipulation; `awk`/`sed` only for `docker stats` parsing.
- Error handling: don't fail the cron (always exit 0); log to stderr → cron's mail (or rotate via mailto/bash trap to /dev/null).
- Lock with `flock` so concurrent invocations don't corrupt the file.

### Cron registration
- File: `/etc/cron.d/multiwordpress` (host-level).
- Created by `host/install-metrics-cron.sh`:
  ```
  # MultiWordpress metrics poll (Phase 3) — runs every minute
  * * * * * root /opt/wp/bin/wp-metrics-poll >/dev/null 2>&1
  ```
- Idempotent — overwrite on re-run.
- Phase 1's host README is updated (or new phase-3 README added) to document this install step.

### wp-cron stagger
- Entry pattern in `/etc/cron.d/multiwordpress` (same file): per-site staggered:
  ```
  <minute> * * * * root docker exec -u www-data wp-<slug> wp cron event run --due-now >/dev/null 2>&1
  ```
- `<minute>` = SHA256(slug) mod 60 — deterministic, spreads load across the hour.
- `bin/wp-create` post-finalize step registers the line (appends to `/etc/cron.d/multiwordpress`, then `systemctl reload cron` or just trust cron auto-reload of /etc/cron.d).
- `bin/wp-delete` removes the line by slug match.
- A new helper `bin/_cron-mgr.sh` centralizes the add/remove logic (sourced by wp-create and wp-delete).

### Patches to existing scripts (bin/wp-create, bin/wp-delete)
- `wp-create`: after `_advance_state finalized`, call `_cron_register <slug>`.
- `wp-delete`: before drop DB, call `_cron_unregister <slug>`.
- Both helpers in `bin/_cron-mgr.sh`. wp-create/wp-delete source it.

### Metrics file rotation safety
- 24h × 60 minutes = 1440 samples per site. Each sample ~80 bytes JSON ≈ 115 KB per site. 10 sites ≈ 1.2 MB metrics.json. Acceptable.
- If file grows beyond 5 MB (sanity guard), poller logs a warning and truncates to last 1440 samples per site.
- Use jq to filter samples older than 24h on each write — automatic GC.

### `docs/operational.md`
- One-page reference: how to install the cron (`sudo host/install-metrics-cron.sh`), how to verify (`tail -f /var/log/syslog | grep wp-metrics-poll`), how to manually inspect metrics.json (`cat /opt/wp/state/metrics.json | jq '.cluster'`), troubleshooting (cron not running, stale samples).

### Validation
- After install, wait 2 minutes; `cat /opt/wp/state/metrics.json | jq '.cluster.pool_used_bytes'` returns a non-zero number.
- After 24h, peaks accumulate: `cat /opt/wp/state/metrics.json | jq '.sites["<slug>"].mem_peak_bytes'`.
- `wp-stats` and `wp-list` now show real peak columns instead of `-`.
- No synchronized `:00` CPU spike with 5 staggered sites — verified by watching `wp-stats` over 5 minutes.

</decisions>

<code_context>
- bin/_lib.sh has `_db_exec` and `_log` helpers; reuse.
- bin/wp-create reads sites.json — same registry; metrics.json sits next to it.
- Cron is system cron (`cron` package on Debian/Ubuntu, present on the GCP VM since AudioStoryV2 already runs `gcloud` cron-style jobs implicitly).
</code_context>

<specifics>
- Implementation language: bash (consistent with rest of CLI). No Python, no Go.
- jq dependency: assumed present (already used by _lib.sh). Add a check in install-metrics-cron.sh.
- The metrics.json schema is the contract Phase 4 dashboard relies on. Lock it now.

</specifics>

<deferred>
- `wp-stats --top` / log-based request-rate sampling — out of scope.
- Slack/email alerts on pool ≥ 90% — defer.
- Prometheus/Grafana export — explicit anti-feature.

</deferred>

<discretion>
- Exact jq filters for sample trimming.
- Whether `_cron-mgr.sh` is a separate file or inlined into wp-create/wp-delete.
- Cron output suppression style (`>/dev/null 2>&1` vs MAILTO=).
- Sample buffer size (1440 is recommended; could be smaller if memory or disk is a concern — note that's not the case here).

NOT discretionary:
- Cron file location (`/etc/cron.d/multiwordpress`).
- Stagger algorithm (SHA256(slug) mod 60).
- 24h peak retention.
- metrics.json schema (cluster + sites with the exact field names above).

</discretion>

---
*Phase 3 context — small but lock-step with Phase 4 dashboard.*
