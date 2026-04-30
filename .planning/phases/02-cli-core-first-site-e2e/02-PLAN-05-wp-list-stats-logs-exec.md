---
phase: 02-cli-core-first-site-e2e
plan: 05
type: execute
wave: 2
depends_on: [02-01]
files_modified:
  - bin/wp-list
  - bin/wp-stats
  - bin/wp-logs
  - bin/wp-exec
autonomous: true
requirements: [CLI-08, CLI-09, CLI-10, CLI-11, CLI-17]
must_haves:
  truths:
    - "wp-list shows all sites: slug, domain, status (running/paused/failed), port, redis_db, current mem (MB), 24h-peak mem (MB)"
    - "wp-list --secrets <slug> prints contents of /opt/wp/secrets/<slug>.env to stdout (no shell history leak)"
    - "wp-stats prints cluster line (wp.slice pool used / 4 GB / 24h peak) + AudioStoryV2 health + per-site rows sorted by 24h-peak mem desc"
    - "wp-stats colors: pool >= 90% peak yellow, >= 100% red, with NO_COLOR + isatty respect"
    - "wp-logs <slug> [--follow] streams docker compose logs"
    - "wp-exec <slug> <wp-cli-args...> passes through to WP-CLI inside container"
    - "All four verbs support --json where structured output is meaningful (list, stats)"
  artifacts:
    - path: "bin/wp-list"
      provides: "Site registry inspection CLI"
      min_lines: 80
    - path: "bin/wp-stats"
      provides: "Cluster + per-site stats CLI"
      min_lines: 100
    - path: "bin/wp-logs"
      provides: "Per-site log tail CLI"
      min_lines: 30
    - path: "bin/wp-exec"
      provides: "WP-CLI passthrough"
      min_lines: 30
  key_links:
    - from: "bin/wp-list"
      to: "/opt/wp/state/sites.json + docker stats"
      via: "_load_state + docker stats --no-stream --format json"
      pattern: "docker stats"
    - from: "bin/wp-stats"
      to: "/sys/fs/cgroup/wp.slice/memory.current"
      via: "cat read"
      pattern: "wp.slice/memory.current"
    - from: "bin/wp-stats"
      to: "/opt/wp/state/metrics.json"
      via: "best-effort jq read; '—' fallback if missing"
      pattern: "metrics.json"
    - from: "bin/wp-exec"
      to: "wp-<slug> container"
      via: "docker exec -u www-data passthrough"
      pattern: "docker exec.*www-data"
---

<objective>
Build the four read-mostly inspection verbs: wp-list, wp-stats, wp-logs, wp-exec.

Purpose: Operator visibility into site registry, resource usage, logs, and arbitrary WP-CLI commands — without needing to remember container names, ports, or docker idioms.
Output: 4 executable bash scripts under bin/.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/phases/02-cli-core-first-site-e2e/02-CONTEXT.md
@.planning/phases/02-cli-core-first-site-e2e/02-01-SUMMARY.md
@bin/_lib.sh

Canonical spec sections in 02-CONTEXT.md:
- "wp-list" — columns + --secrets flag
- "wp-stats" — cluster line + AudioStoryV2 health + per-site rows + color thresholds
- "wp-logs <slug> [--follow|-f]"
- "wp-exec <slug> <wp-cli-args...>"
- "Specific Ideas" — --json on every verb where structured output is meaningful
</context>

<tasks>

<task type="auto">
  <name>Task 1: bin/wp-list and bin/wp-logs and bin/wp-exec</name>
  <files>bin/wp-list, bin/wp-logs, bin/wp-exec</files>
  <action>
All scripts: shebang `#!/usr/bin/env bash`, `set -euo pipefail`, source _lib.sh, chmod 755.

**bin/wp-list:**
- Args: `--secrets <slug>` (mutually exclusive with default listing), `--json`, `-h|--help`
- Default mode (no --secrets):
  - `_load_state` → iterate `.sites[]`
  - For each site: derive runtime fields:
    - status: query `docker ps --filter "name=^wp-${slug}$" --format "{{.Status}}"`. Map to: "running" if Status starts "Up", "paused" if state==paused in registry, "failed" if state==failed, "stopped" otherwise
    - current_mem_mb: from `docker stats --no-stream --format '{{json .}}'` filtered by container name; parse `MemUsage` (e.g. "150.2MiB / ..."); if not running → "—"
    - peak_mem_mb_24h: from /opt/wp/state/metrics.json `.sites[$slug].mem_peak_bytes` if exists, converted to MB; else "—"
  - Output: aligned columns. Header: `SLUG  DOMAIN  STATUS  PORT  REDIS_DB  MEM_NOW  MEM_PEAK_24H`
  - Use printf with column widths derived from longest values, or `column -t`
- `--secrets <slug>` mode:
  - Validate slug exists in registry
  - `cat ${SECRETS_DIR}/${slug}.env` (must run as root; _require_root if .env mode 600)
  - Print directly to stdout (caller can pipe; no extra formatting)
- `--json` mode (default listing): emit `[{slug, domain, status, port, redis_db, current_mem_mb, peak_mem_mb_24h, created_at, admin_user}, ...]`

Performance note: a single `docker stats --no-stream --format '{{json .}}'` call returns ALL containers; cache the result and look up per slug rather than calling N times.

**bin/wp-logs:**
- Args: `<slug>`, `--follow|-f`, `-h|--help`
- Validate slug exists; _die if not
- If --follow: `_compose_site $SLUG "logs --follow"` (forwards to docker compose logs --follow)
- Else: `_compose_site $SLUG logs --tail=200`
- Pass through stdout/stderr unchanged (no buffering)

**bin/wp-exec:**
- Args: `<slug>` then ALL remaining args go straight to wp-cli
- Validate slug exists; _die if not
- Validate container running: `docker ps -q --filter "name=^wp-${slug}$"` non-empty; else _die "site not running; wp-resume first"
- `exec docker exec -u www-data "wp-${slug}" wp "$@"` — use `exec` to replace shell so signals + exit code propagate cleanly
- Examples in --help: `wp-exec myblog plugin list`, `wp-exec myblog user list --role=administrator`
  </action>
  <verify>
    <automated>bash -n bin/wp-list &amp;&amp; bash -n bin/wp-logs &amp;&amp; bash -n bin/wp-exec &amp;&amp; bin/wp-list --help 2>&amp;1 | grep -qi list &amp;&amp; bin/wp-logs --help 2>&amp;1 | grep -qi logs &amp;&amp; bin/wp-exec --help 2>&amp;1 | grep -qi exec &amp;&amp; grep -q "docker stats" bin/wp-list &amp;&amp; grep -q "compose.*logs" bin/wp-logs &amp;&amp; grep -q "docker exec" bin/wp-exec &amp;&amp; grep -q "www-data" bin/wp-exec &amp;&amp; test -x bin/wp-list &amp;&amp; test -x bin/wp-logs &amp;&amp; test -x bin/wp-exec</automated>
  </verify>
  <done>Three scripts syntax-clean, executable; wp-list renders aligned columns + supports --secrets + --json; wp-logs forwards to docker compose logs with optional --follow; wp-exec exec-replaces shell to forward signals to wp-cli inside container.</done>
</task>

<task type="auto">
  <name>Task 2: bin/wp-stats</name>
  <files>bin/wp-stats</files>
  <action>
Create bin/wp-stats. Shebang + set -euo pipefail + source _lib.sh + chmod 755.

**Args:**
- `--json`, `-h|--help`

**Cluster line:**
- pool_used_now_bytes: `cat /sys/fs/cgroup/wp.slice/memory.current` (fallback: 0 with warn if unreadable)
- pool_max_bytes: `cat /sys/fs/cgroup/wp.slice/memory.max` (expected 4294967296)
- pool_peak_24h_bytes: `jq -r '.cluster.pool_used_peak_bytes // empty' /opt/wp/state/metrics.json 2>/dev/null` (— if missing)
- pool_pct_now = pool_used_now / pool_max * 100
- pool_pct_peak = pool_peak_24h / pool_max * 100 (— if peak missing)
- Color logic on the peak: >= 100 → red; >= 90 → yellow; else default. Use _color_supported gate.
- Render: `wp.slice pool: 1.2 GB used / 4 GB total (30%) — 24h peak 2.1 GB (52%)`

**AudioStoryV2 health:**
- Try to detect AudioStoryV2 container by common name pattern. Use `docker ps -a --filter "name=audiostory" --format '{{.Names}} {{.Status}} {{.RestartCount}}'`. If `docker inspect` for restart count needed, use `docker inspect --format '{{.RestartCount}}' <name>` per matched name.
- Render: `AudioStoryV2: running (restarts=0)` or `AudioStoryV2: not detected` if no match
- This is best-effort; do not fail wp-stats if AudioStoryV2 absent

**Per-site rows:**
- _load_state → iterate sites
- For each site running (status check via docker ps):
  - current_mem_bytes: from `docker stats --no-stream --format '{{json .}}'` parsed
  - peak_mem_bytes_24h: from metrics.json `.sites[$slug].mem_peak_bytes` (— if missing)
  - peak_cpu_pct_24h: from metrics.json `.sites[$slug].cpu_peak_pct` (— if missing)
  - peak_db_conn_24h: from metrics.json `.sites[$slug].db_conn_peak` (— if missing); fallback to current best-effort `_db_exec "SELECT user, COUNT(*) FROM information_schema.processlist GROUP BY user;"` filtered to `wp_<slug>` if metrics.json absent
- Sort rows by peak_mem_bytes_24h descending (sites with "—" peaks sort last)
- Columns: `SLUG  MEM_NOW  MEM_PEAK_24H  CPU_PEAK_24H  DB_CONN_PEAK_24H`

**--json mode:**
Emit `{cluster: {pool_used_now_bytes, pool_max_bytes, pool_peak_24h_bytes, pool_pct_now, pool_pct_peak}, audiostory: {detected, status, restart_count}, sites: [{slug, current_mem_bytes, peak_mem_bytes_24h, peak_cpu_pct_24h, peak_db_conn_24h}]}`

**ANSI colors:**
- Use _color_supported gate from _lib.sh
- Red (`\033[31m`), yellow (`\033[33m`), reset (`\033[0m`)
- Color the cluster pool peak line based on pool_pct_peak threshold
- Optionally color per-site peak_mem cells if a per-site threshold is meaningful (skip for v1; cluster-level only is sufficient)

If metrics.json doesn't exist (Phase 3 hasn't shipped yet), wp-stats still prints cluster + AudioStoryV2 + per-site rows with peaks shown as "—". This is the expected state during Phase 2.
  </action>
  <verify>
    <automated>bash -n bin/wp-stats &amp;&amp; bin/wp-stats --help 2>&amp;1 | grep -qi stats &amp;&amp; grep -q "wp.slice/memory.current" bin/wp-stats &amp;&amp; grep -q "metrics.json" bin/wp-stats &amp;&amp; grep -q "audiostory" bin/wp-stats &amp;&amp; grep -q "peak_mem" bin/wp-stats &amp;&amp; test -x bin/wp-stats</automated>
  </verify>
  <done>wp-stats prints cluster line + AudioStoryV2 health + per-site rows sorted by peak mem desc; ANSI colors gated on isatty + NO_COLOR; gracefully handles missing metrics.json (Phase 2 normal state); --json emits structured equivalent.</done>
</task>

</tasks>

<verification>
- 4 files exist, chmod 755
- bash -n passes for all
- wp-list aligns columns and supports --secrets + --json
- wp-stats reads /sys/fs/cgroup/wp.slice/memory.current and metrics.json (best-effort)
- wp-logs forwards --follow flag
- wp-exec uses `exec docker exec -u www-data` for signal propagation
- All four error on non-existent slug (where slug is a positional)
</verification>

<success_criteria>
The four inspection verbs cover all read-mostly Phase 2 requirements (CLI-08, CLI-09, CLI-10, CLI-11, CLI-17); each is < 200 lines; uses _lib.sh consistently; handles missing metrics.json gracefully (— placeholder).
</success_criteria>

<output>
Create `.planning/phases/02-cli-core-first-site-e2e/02-05-SUMMARY.md` documenting:
- Column widths chosen for wp-list / wp-stats
- AudioStoryV2 detection heuristic (container name pattern used)
- Behavior when metrics.json absent (Phase 2 normal state)
- Whether docker stats was called once-and-cached or per-site (perf note)
</output>
