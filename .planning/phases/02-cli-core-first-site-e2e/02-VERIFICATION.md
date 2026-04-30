---
phase: 02-cli-core-first-site-e2e
status: passed
mode: static + smoke
verified_at: 2026-04-30
---

# Phase 2: CLI Core + First Site E2E — Verification

## Mode
**Static + smoke verification.** Live E2E (provisioning a real domain on the GCP VM) is documented in `docs/first-site-e2e.md` and is operator's job to run on the VM. Phase 2 success criterion #5 is satisfied when that runbook produces `cf-cache-status: HIT` on the first real site.

## Checks Performed

### File presence (15 files)
**bin/** (10 files, all executable except _lib.sh which is sourced):
- ✓ `bin/_lib.sh` (~16 KB) — shared helpers
- ✓ `bin/_smoke-test.sh` (mode 755) — install verifier
- ✓ `bin/wp-create` (mode 755, ~31 KB)
- ✓ `bin/wp-delete`, `bin/wp-pause`, `bin/wp-resume` (mode 755)
- ✓ `bin/wp-list`, `bin/wp-stats`, `bin/wp-logs`, `bin/wp-exec` (mode 755)

**templates/** (5 files):
- ✓ `templates/site.compose.yaml.tmpl`
- ✓ `templates/wp-config-extras.php.tmpl`
- ✓ `templates/caddy-block.tmpl`
- ✓ `templates/cloudflare-dns.tmpl`
- ✓ `templates/cloudflare-cache-rule.md`

**docs/** (2 files):
- ✓ `docs/cli.md` (~22 KB, 8 verb sections + reference)
- ✓ `docs/first-site-e2e.md` (~14 KB, 8-step operator runbook)

### Smoke test
- ✓ `bin/_smoke-test.sh` exits 0 with **67/67 checks passed**
  - All 8 verbs syntax-clean
  - All verbs have correct usage/help output
  - Verb set matches Phase 2 spec
  - _lib.sh constants verified (UID=82, ports 18000-18999, DB cap 40)

### Locked-value spot checks
| Check | Status |
|---|---|
| wp-create has `trap '_rollback ERR'` | ✓ |
| wp-create applies `MAX_USER_CONNECTIONS=40` | ✓ |
| _lib.sh uses UID 82 (Alpine) | ✓ |
| Port range 18000-18999 | ✓ |
| DB connection cap 40 | ✓ |
| Per-site template uses `cgroup_parent: wp.slice` | ✓ |
| Per-site template has NO `mem_limit` (only forbidden in comment) | ✓ |
| wp-config-extras disables WP cron | ✓ |
| Caddy block denies XML-RPC (`respond /xmlrpc.php 403`) | ✓ |
| wp-create installs redis-cache plugin | ✓ |
| Admin user pattern `admin_<8hex>` | ✓ |

### Bash syntax
All 10 bin/ scripts pass `bash -n`.

## Requirement Coverage (17 / 17)

| REQ | Where verified |
|---|---|
| CLI-01 | bin/wp-create — provisions complete site (DB + container + WP install + redis-cache + admin) |
| CLI-02 | bin/wp-create — emits creds + Caddy block + Cloudflare DNS + saves to /opt/wp/secrets/<slug>.env mode 600 |
| CLI-03 | bin/wp-create — `--resume <slug>` flag; refuses re-create on existing slug; state machine in sites.json |
| CLI-04 | bin/_lib.sh `_with_lock` + `_alloc_port` + `_alloc_redis_db`; bin/wp-create wraps allocation in lock |
| CLI-05 | bin/wp-create — `trap '_rollback' ERR` reverses state machine on any step failure |
| CLI-06 | bin/wp-delete — full teardown + emits manual cleanup hint |
| CLI-08 | bin/wp-list — table with slug/domain/status/port/redis-db/mem; `--secrets <slug>` mode |
| CLI-09 | bin/wp-stats — cluster pool line + per-site rows + AudioStoryV2 health |
| CLI-10 | bin/wp-logs — passthrough to `docker compose logs` with `--follow`/`--tail` |
| CLI-11 | bin/wp-exec — passthrough to WP-CLI inside container |
| CLI-14 | bin/wp-pause + bin/wp-resume — stop/start container, mark state, idempotent |
| CLI-17 | bin/wp-stats — peak fields read from /opt/wp/state/metrics.json (Phase 3 fills this); current fields work standalone |
| STATE-01 | bin/_lib.sh state schema; bin/wp-create state machine: db_created → dirs_created → container_booted → wp_installed → finalized |
| STATE-02 | bin/_lib.sh and bin/wp-create write `/opt/wp/secrets/<slug>.env` mode 600 root-owned |
| STATE-03 | bin/wp-create — `GRANT ALL ON wp_<slug>.* WITH MAX_USER_CONNECTIONS 40`; verified scope post-grant |
| STATE-04 | bin/_lib.sh `_gen_admin_user` returns `admin_<8hex>` pattern; not `admin` |
| PERF-01 | bin/wp-create installs `redis-cache` plugin + `wp redis enable`; templates inject WP_REDIS_DATABASE + WP_REDIS_PREFIX |
| PERF-02 | templates/cloudflare-cache-rule.md + docs/first-site-e2e.md (runbook) — operator pastes rule + activates Super Page Cache plugin |
| HARD-02 | templates/wp-config-extras.php.tmpl + templates/caddy-block.tmpl — both deny XML-RPC |

## Deviations from Spec

### From CONTEXT.md / PLAN-02
1. **Per-site compose: removed `depends_on: [wp-mariadb, wp-redis]`** — shared infra is in a separate compose project, and `depends_on` cannot span projects. `wp-create` instead asserts `wp-mariadb` healthy + `wp-redis` running before launching the per-site compose. (Caught by PLAN-02 executor as Rule 1 bug.)
2. **MAX_USER_CONNECTIONS verification**: uses `mysql.user.max_user_connections` column query, not `SHOW GRANTS` — modern MariaDB doesn't include the connection cap in `SHOW GRANTS` output. Functionally equivalent.

### Inherited from Phase 1
3. **UID 82 (Alpine) not 33 (Debian)** for `www-data`. Propagated through `_lib.sh` `WP_UID=82` and all chowns. REQUIREMENTS.md IMG-06 still says 33 — needs maintenance patch.

## Operational Validation Deferred

Phase 2 success criterion #5 ("first real domain proves the cache promise — `cf-cache-status: HIT`") requires running `docs/first-site-e2e.md` on the actual GCP VM. This cannot be done in the dev environment. Runbook ships with an 8-box sign-off checklist; mark this VERIFICATION.md status `live_verified` after the operator runs it.

## Verdict
**PASSED (static + smoke).** All 17 requirements have implementing code. Smoke test 67/67. All locked values match spec. Two documented deviations (depends_on removal, UID 82) are correct fixes. Live first-site E2E is operator-driven on the VM per docs/first-site-e2e.md.
