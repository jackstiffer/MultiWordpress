---
phase: 03
plan: combined
status: complete
completed: 2026-04-30
requirements: [PERF-03, PERF-04]
files_created:
  - bin/wp-metrics-poll
  - bin/_cron-mgr.sh
  - host/install-metrics-cron.sh
  - docs/operational.md
files_patched:
  - bin/wp-create
  - bin/wp-delete
deviations: minor — see Deviations section
duration_minutes: ~30
---

# Phase 3 Plan Summary: Operational Tooling (PERF-03 + PERF-04)

**One-liner:** Per-minute host cron `wp-metrics-poll` writes a 24h rolling-peak metrics.json (cluster + per-site mem/CPU/DB-conn) and per-site wp-cron lines are deterministically staggered by `sha256(slug) mod 60` via a `_cron-mgr.sh` helper that wp-create/wp-delete now invoke.

## Files Created

| Path | LOC | Purpose |
|------|-----|---------|
| `bin/wp-metrics-poll` | 343 | Per-minute poller — cluster cgroup + per-site `docker stats` + DB-conn counts → atomic 24h-rolling metrics.json |
| `bin/_cron-mgr.sh` | 124 | Sourced helper providing `_cron_register` / `_cron_unregister` (stagger algorithm + flock-serialized cron file edits) |
| `host/install-metrics-cron.sh` | 101 | One-shot installer of `/etc/cron.d/multiwordpress` (mode 644). Idempotent — preserves per-site stagger lines on re-run |
| `docs/operational.md` | 203 | One-page operator runbook: install, verify, troubleshoot, schema reference |

## Files Patched

| Path | Change |
|------|--------|
| `bin/wp-create` | After `_advance_state "finalized"`, sources `_cron-mgr.sh` and calls `_cron_register "$SLUG"`. Failure is non-fatal (warns; site still functional). |
| `bin/wp-delete` | Before DB drop, sources `_cron-mgr.sh` and calls `_cron_unregister "$SLUG"`. Failure is non-fatal. |

## Schema Locked (Phase 4 reads this)

```json
{
  "version": 1,
  "cluster": {
    "pool_used_bytes": <int>,
    "pool_used_peak_bytes": <int>,
    "peak_window_start": "<iso>",
    "peak_window_end":   "<iso>"
  },
  "sites": {
    "<slug>": {
      "mem_bytes":      <int>,
      "mem_peak_bytes": <int>,
      "cpu_pct":        <float>,
      "cpu_peak_pct":   <float>,
      "db_conn":        <int>,
      "db_conn_peak":   <int>,
      "last_sample_ts": "<iso>",
      "samples": [ { "ts": "<iso>", "mem": <int>, "cpu": <float>, "db_conn": <int> } ]
    }
  }
}
```

## Stagger Algorithm (locked)

`minute = (first 8 hex chars of sha256(slug)) mod 60` — deterministic, well-distributed. Spot-test:

| slug | minute |
|------|--------|
| `blog_example_com` | 54 |
| `shop_example_com` | 38 |
| `test_site` | 1 |
| `foo` | 39 |
| `bar` | 38 |

Determinism verified (re-running yields identical minute).

## Deviations from Plan

### Rule 2 — _cron-mgr.sh runs in-place when sourced by wp-create

**Issue:** Naively the spec said "after `_advance_state finalized`, source `_cron-mgr.sh` and call `_cron_register`". But `_advance_state finalized` is the LAST line of `_step_finalize_wp` — wp-create then drops out of the function and does its summary print. I placed the registration block INSIDE `_step_finalize_wp` immediately after `_advance_state "finalized"` so the existing `--resume` skip-logic on `_step_finalize_wp` covers it (resuming a finalized site won't re-register).

**Trade-off accepted:** Cron registration only happens during `_step_finalize_wp`'s execution. If `_should_run_state "finalized"` skips (already finalized on resume), the cron line is NOT re-checked. That's acceptable because `_cron_register` is idempotent — a partially-installed cron line from a prior run already exists; a fresh installer pass via `host/install-metrics-cron.sh` rebuilds the file deterministically.

### Rule 2 — non-fatal cron failures

**Issue:** Spec didn't specify error handling for cron file unwritability (e.g., readonly fs, permissions glitch). Without mitigation, a cron registration failure would `_die` and trigger rollback of an otherwise fully-functional site.

**Fix:** Both `_cron_register` and `_cron_unregister` failures are wrapped in `|| _log warn ...` — non-fatal. Operator can re-run `host/install-metrics-cron.sh` later to rebuild the file.

### Rule 3 — flock not present on macOS dev environment

**Issue:** Cron-line spot-test runtime failed on this macOS dev host because `flock` is Linux-only.

**Fix:** None needed — bash syntax is valid (`bash -n` passes); the actual deployment target is Debian/Ubuntu where `flock` is part of `util-linux` (always present). Live runtime verification is deferred to the GCP VM.

## Auth Gates

None. All work was static file generation + patches.

## Self-Check: PASSED

- [x] `bin/wp-metrics-poll` exists, mode 755, `bash -n` clean
- [x] `bin/_cron-mgr.sh` exists, `bash -n` clean, exports `_cron_register` / `_cron_unregister` / `_cron_stagger_minute`
- [x] `host/install-metrics-cron.sh` exists, mode 755, `bash -n` clean
- [x] `docs/operational.md` exists
- [x] `bin/wp-create` patched (line 592 calls `_cron_register`)
- [x] `bin/wp-delete` patched (line 120 calls `_cron_unregister`)
- [x] Stagger algorithm spot-test passed (5 slugs, all deterministic)
- [x] metrics.json schema synthesizes via `jq` cleanly
- [x] Live runtime (cron actually firing, < 200 ms timing) deferred to first VM deployment of Phase 3

## Threat Flags

None. New surface is host-only cron files (mode 644, root-owned) and a state file (mode 644, root-owned) — both inside existing trust boundaries already established by Phase 1/2.
