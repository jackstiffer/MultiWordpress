---
phase: 02-cli-core-first-site-e2e
plan: 05
subsystem: cli-inspection
tags: [cli, bash, inspection, read-only, docker, cgroup, metrics]
requires:
  - bin/_lib.sh (Phase 2 / Plan 01)
  - /opt/wp/state/sites.json (registry; written by wp-create)
  - /sys/fs/cgroup/wp.slice/memory.current + memory.max (Phase 1 / host/wp.slice)
  - docker engine (stats / inspect / compose / exec)
provides:
  - bin/wp-list (site registry table + --secrets + --json)
  - bin/wp-stats (cluster pool + AudioStoryV2 health + per-site rows + --json)
  - bin/wp-logs (per-site docker compose logs passthrough)
  - bin/wp-exec (per-site WP-CLI passthrough)
affects:
  - operator visibility surface for Phase 2 (no state mutations)
tech-stack:
  added: []
  patterns:
    - "READ_ONLY=1 before sourcing _lib.sh skips _require_root for inspection verbs"
    - "single docker stats --no-stream call, parsed in-memory per slug (perf)"
    - "graceful 24h-peak fallback when /opt/wp/state/metrics.json absent (Phase 2 normal state)"
    - "exec docker exec for wp-exec — signals + exit code propagate cleanly"
key-files:
  created:
    - bin/wp-list
    - bin/wp-stats
    - bin/wp-logs
    - bin/wp-exec
  modified: []
decisions:
  - "Status mapping: docker State.Status × registry.state → {running, paused, stopped, partial}"
  - "Sort by 24h-peak mem desc; sites with '-' (no metrics yet) always sort last"
  - "AudioStoryV2 detection: try exact names (audiostory-web, audiostory_web, audiostory_web_1, audiostory) then substring 'audiostory' fallback"
  - "DB-CONN reported as live snapshot (not 24h peak) until Phase 3 metrics-poll ships; output footnote disclaims this"
  - "Secrets file (mode 600) read requires root even for read-only verb — wp-list --secrets gates on EUID"
metrics:
  duration: ~25min
  tasks_completed: 2
  files_created: 4
  files_modified: 0
  total_lines: 787
---

# Phase 2 Plan 05: wp-list / wp-stats / wp-logs / wp-exec Summary

Inspection verbs covering CLI-08, CLI-09, CLI-10, CLI-11, CLI-17. Four read-only
bash scripts under `bin/` exposing the Phase 1+2 substrate (sites.json registry,
docker runtime state, wp.slice cgroup pool, metrics.json best-effort) without
needing the operator to remember container names, ports, or docker idioms.

## What Was Built

### `bin/wp-list` (261 lines)

- **Default mode**: aligned 8-column table — `SLUG | DOMAIN | STATUS | TIER | PORT | REDIS-DB | MEM-NOW | MEM-PEAK-24H`. Sorted by 24h-peak mem desc; sites without peak data go last. Footer shows total / running / paused counts.
- **`--secrets <slug>`**: prints `/opt/wp/secrets/<slug>.env` with a header banner. Gates on `EUID==0` since the file is mode 600.
- **`--json`**: structured `{"sites":[{slug, domain, status, port, redis_db, mem_now_mb, mem_peak_24h_mb}, …]}`.
- Status derivation: `docker inspect --format '{{.State.Status}}'` × registry state →
  - `running` (docker running + state finalized)
  - `paused` (state paused)
  - `stopped` (docker exited / missing)
  - `partial` (state non-finalized non-paused — e.g. `db_created`, `container_booted`)
- TIER column reads `shared` (single shared pool today; column reserved for future tiering).

### `bin/wp-stats` (369 lines)

- **Cluster header**:
  - `wp.slice` pool: reads `/sys/fs/cgroup/wp.slice/memory.current` + `memory.max`. Renders `X.XX GB used / Y.YY GB total (NN%) — 24h peak Z.ZZ GB (MM%)`. Color-coded: ≥ 100% peak → red, ≥ 90% → yellow, else default. Honors `NO_COLOR` + isatty(stderr) via `_color_supported`.
  - AudioStoryV2 health: detection cascade through `audiostory-web`, `audiostory_web`, `audiostory_web_1`, `audiostory`, then `docker ps -a --filter name=audiostory` substring fallback. Shows `<name> — <status> (restarts=<N>)` or `(not detected)`. Non-fatal if absent.
  - `/opt/wp` disk usage from `df -h`.
- **Per-site rows**: `SLUG | DOMAIN | MEM-NOW | MEM-PEAK-24H | CPU-PEAK | DB-CONN-NOW`, sorted by peak mem desc.
- **DB-CONN-NOW**: best-effort live snapshot via `_db_exec "SELECT user, COUNT(*) FROM information_schema.processlist WHERE user LIKE 'wp_%' GROUP BY user;"` — explicitly footnoted as **not** a 24h peak (Phase 3's metrics-poll will fill `db_conn_peak`).
- **`--json`**: structured `{cluster, audiostory, disk, metrics_json_present, sites:[…]}`.
- **Phase 2 normal state** (no `metrics.json`): collapses to `SLUG | DOMAIN | MEM-NOW | DB-CONN-NOW` and prints the disclaimer line: `(24h peaks unavailable — wp-metrics-poll not yet running; ships in Phase 3)`.

### `bin/wp-logs` (86 lines)

- `wp-logs <slug> [--follow|-f] [--tail <N>]`. Default `--tail 100` if neither flag given.
- Validates slug exists in registry + compose file present, then `exec docker compose -f /opt/wp/sites/<slug>/compose.yaml logs <flags>`. Pure passthrough — no buffering, no `--json`.

### `bin/wp-exec` (71 lines)

- `wp-exec <slug> <wp-cli-args...>`. Validates slug + container running. Then `exec docker exec -u www-data wp-<slug> wp "$@"` — `exec` replaces the shell so SIGINT / SIGTERM and the exit code propagate cleanly to wp-cli inside the container.

## Output Format Notes (per plan `<output>`)

- **Column widths**:
  - wp-list: `%-20s %-30s %-9s %-7s %-6s %-9s %-10s %s` — 20-char slug, 30-char domain, 9-char status, etc. Slug widths are bounded by `_sanitize_slug` (cap 32) so 20 is a soft display width — long slugs will overrun without breaking semantics.
  - wp-stats: `%-20s %-30s %-10s %-12s %-10s %s` (with peaks) / `%-20s %-30s %-10s %s` (without).
- **AudioStoryV2 detection heuristic**: ordered candidate list of common compose-derived names → fallback to substring `audiostory`. Discovered name is shown explicitly so operators can confirm the right container was matched.
- **metrics.json absent (Phase 2 normal)**: wp-list shows `-` in MEM-PEAK-24H column; wp-stats drops the peak columns entirely and emits a footnote pointing to Phase 3.
- **docker stats perf**: called **once per invocation** with `--no-stream`, output cached in a shell variable, then parsed per-slug via `awk` lookup. No N×docker-stats calls.

## Verification Performed

```bash
chmod 755 bin/wp-{list,stats,logs,exec}
bash -n bin/wp-list bin/wp-stats bin/wp-logs bin/wp-exec    # all OK
bin/wp-list --help | grep list                              # OK
bin/wp-stats --help | grep stats                            # OK
bin/wp-logs --help | grep logs                              # OK
bin/wp-exec --help | grep exec                              # OK
grep -q "docker stats"             bin/wp-list              # OK
grep -q "compose.*logs"            bin/wp-logs              # OK
grep -q "docker exec"              bin/wp-exec              # OK
grep -q "www-data"                 bin/wp-exec              # OK
grep -q "wp.slice/memory.current"  bin/wp-stats             # OK
grep -q "metrics.json"             bin/wp-stats             # OK
grep -q "audiostory"               bin/wp-stats             # OK
grep -q "peak_mem"                 bin/wp-stats             # OK
```

All plan `<verify>` automated assertions pass for both Task 1 and Task 2.

Runtime verification (executing the scripts against `/opt/wp/state` and a live
docker daemon) is deferred to Plan 07's first-site E2E runbook — these scripts
read state that does not exist in this dev environment.

## Deviations from Plan

### [Rule 3 — Filename] Summary file named per orchestrator instructions, not per plan `<output>`

The plan `<output>` block specifies `02-05-SUMMARY.md`. The orchestrator
instructions for this task explicitly require `02-PLAN-05-SUMMARY.md` (matching
the `02-PLAN-NN-SUMMARY.md` convention used by 01 and 02 in this phase). Wrote
the latter to stay consistent with sibling plans and with the `git add` target
in the orchestrator commit command.

### [Rule 2 — Auto-add] `wp-logs --tail <N>`

Plan task 1 spec only mentioned `--follow|-f`. The orchestrator task spec calls
for `--tail <N>` with default 100 when neither flag is set — added as
specified, since `docker compose logs` produces unbounded output otherwise.

### [Rule 2 — Auto-add] `wp-exec` running-state check

Plan said `docker ps -q --filter "name=^wp-${slug}$"` non-empty check; used the
equivalent `docker inspect --format '{{.State.Status}}'` pattern (consistent
with wp-list's status derivation) and surfaces the actual container status in
the error message (`status=missing|exited|paused|...`) for actionable feedback.

### [Rule 2 — Auto-add] `wp-list --secrets` root gate

The plan implied `_require_root` would gate this; since `READ_ONLY=1` short-
circuits `_require_root`, added an explicit `EUID -ne 0` gate specifically for
`--secrets` mode. Default + `--json` modes remain non-root.

## Known Stubs

None — all functionality is wired. The "24h peak" columns intentionally show
`-` until Phase 3's wp-metrics-poll ships and writes `/opt/wp/state/metrics.json`;
this is documented in CONTEXT.md and surfaced inline via the disclaimer line in
`wp-stats`.

## Threat Flags

None new. Inspection verbs read existing state; no new network endpoints, auth
paths, or trust-boundary changes. The `--secrets` flow exposes a root-only
file's contents to root-only stdout — same trust boundary as the existing
secrets file.

## TDD Gate Compliance

N/A — plan type is `execute`, not `tdd`.

## Self-Check: PASSED

- bin/wp-list — FOUND (261 lines, mode 755, bash -n clean)
- bin/wp-stats — FOUND (369 lines, mode 755, bash -n clean)
- bin/wp-logs — FOUND (86 lines, mode 755, bash -n clean)
- bin/wp-exec — FOUND (71 lines, mode 755, bash -n clean)
- All plan `<verify>` grep + test -x assertions pass.
