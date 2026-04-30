---
phase: 02-cli-core-first-site-e2e
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - bin/_lib.sh
autonomous: true
requirements: [STATE-01, STATE-02, STATE-04, CLI-04]
must_haves:
  truths:
    - "All wp-X scripts can source bin/_lib.sh and call shared helpers without redefinition"
    - "Logging writes to stderr with timestamps; user data writes to stdout"
    - "Port and redis-DB allocators are serialized via flock on /opt/wp/state/allocator.lock"
    - "Slug sanitization rejects reserved names (mariadb, redis, network) and enforces 32-char cap"
    - "Secret generators use openssl rand and produce the lengths CONTEXT.md mandates (32 / 24 / 64x8)"
    - "sites.json reads/writes are atomic (temp file + rename) and use jq"
    - "ANSI color helpers respect NO_COLOR and isatty"
  artifacts:
    - path: "bin/_lib.sh"
      provides: "Shared bash library sourced by every wp-X CLI script"
      contains: "_log _load_state _save_state _acquire_lock _release_lock _alloc_port _alloc_redis_db _gen_secret _gen_admin_user _sanitize_slug _db_exec _wp_exec"
  key_links:
    - from: "bin/_lib.sh"
      to: "/opt/wp/state/sites.json"
      via: "_load_state / _save_state with jq + atomic rename"
      pattern: "jq.*sites.json"
    - from: "bin/_lib.sh"
      to: "/opt/wp/state/allocator.lock"
      via: "_acquire_lock / flock"
      pattern: "flock.*allocator.lock"
---

<objective>
Build the shared bash library that every Phase 2 CLI verb sources. This is foundational — wp-create / wp-delete / wp-pause / wp-resume / wp-list / wp-stats / wp-logs / wp-exec all depend on it.

Purpose: Centralize state I/O, logging, allocators, secret generation, and docker/WP-CLI wrappers so individual scripts stay under 400 lines and behave consistently.
Output: bin/_lib.sh — a sourceable bash library with no top-level side effects.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/phases/02-cli-core-first-site-e2e/02-CONTEXT.md
@.planning/research/ARCHITECTURE.md

Canonical spec sections in 02-CONTEXT.md:
- "State Layout (on host)" — paths
- "sites.json Schema" — JSON shape
- "Slug Derivation" — sanitization rules
- "Port Allocator" / "Redis-DB Allocator" — ranges + algorithm
- "CLI Conventions" — shebang, set -euo pipefail, logging discipline
- "Security" — admin_<8hex> pattern, secret modes
</context>

<tasks>

<task type="auto">
  <name>Task 1: Constants, logging, slug sanitization, secret generators</name>
  <files>bin/_lib.sh</files>
  <action>
Create bin/_lib.sh as a sourceable bash library. NOT executable as a script. No top-level side effects (no `set -euo pipefail` at lib level — caller scripts set that).

Required exports (functions and constants):

1. Path constants (defaulting to /opt/wp, overridable via env):
   - `WP_ROOT="${WP_ROOT:-/opt/wp}"`
   - `STATE_DIR="${WP_ROOT}/state"`
   - `STATE_FILE="${STATE_DIR}/sites.json"`
   - `LOCK_FILE="${STATE_DIR}/allocator.lock"`
   - `METRICS_FILE="${STATE_DIR}/metrics.json"`
   - `SECRETS_DIR="${WP_ROOT}/secrets"`
   - `SITES_DIR="${WP_ROOT}/sites"`
   - `WP_UID=82` (Alpine, per Phase 1 deviation in 01-VERIFICATION.md — NOT 33)

2. Logging — `_log <level> <msg>`:
   - Levels: info, warn, error
   - Writes to STDERR with `[YYYY-MM-DDTHH:MM:SSZ] [LEVEL] msg`
   - Color: green for info, yellow for warn, red for error WHEN tty + NO_COLOR unset
   - Implement `_color_supported` helper: returns 0 if `[[ -t 2 && -z "${NO_COLOR:-}" ]]`

3. JSON output mode:
   - Global flag `_JSON_MODE=0` (caller scripts flip to 1 when --json passed)
   - Helper `_emit_json <jq-expr>` for structured output

4. Slug sanitization — `_sanitize_slug <domain>`:
   - Lowercase, replace `.` and `-` with `_`, strip non-`[a-z0-9_]`
   - Length cap 32 chars (truncate from end with warning)
   - Reserved: `mariadb`, `redis`, `network` — return non-zero with _log error
   - Echo sanitized slug to stdout on success

5. Secret generators:
   - `_gen_secret <length>` — `openssl rand -hex N` adjusted to char length (e.g., length=32 → 16 bytes hex)
   - For WP salts (64 char): `openssl rand -base64 64 | tr -d '\n=+/' | head -c 64`
   - `_gen_admin_user` — echoes `admin_<8hex>` using `openssl rand -hex 4`

6. Top-of-file docs comment:
   - Library version (1.0)
   - Source instructions: `source "$(dirname "$0")/_lib.sh"`
   - Note: NOT meant to be executed directly

Use bash 4+ idioms (associative arrays OK; macOS bash 3.2 NOT a constraint — target Linux Alpine/Debian VM).
  </action>
  <verify>
    <automated>bash -n bin/_lib.sh && bash -c 'source bin/_lib.sh; _sanitize_slug blog.example.com | grep -q ^blog_example_com$ && _gen_admin_user | grep -qE "^admin_[0-9a-f]{8}$" && _log info "ok" 2>&1 | grep -q ok'</automated>
  </verify>
  <done>bin/_lib.sh syntax-checks clean; _sanitize_slug, _gen_admin_user, _log all behave per spec; reserved-slug rejection works; constants are overridable via env.</done>
</task>

<task type="auto">
  <name>Task 2: State I/O, locking, allocators, docker/WP-CLI wrappers</name>
  <files>bin/_lib.sh</files>
  <action>
Append to bin/_lib.sh.

7. State I/O:
   - `_init_state` — if STATE_FILE missing, write initial `{"version":1,"next_port":18000,"next_redis_db":1,"sites":{}}` with mode 644
   - `_load_state` — `cat "$STATE_FILE"` (callers pipe to jq)
   - `_save_state <json-string>` — write to `${STATE_FILE}.tmp` then `mv` (atomic), mode 644
   - `_get_site <slug>` — `jq -r --arg s "$slug" '.sites[$s] // empty' "$STATE_FILE"`
   - `_set_site <slug> <site-json>` — read state, jq-merge, save
   - `_delete_site <slug>` — read state, `jq 'del(.sites[$s])'`, save

8. Locking — wrap flock:
   - `_acquire_lock` — open FD 200 on LOCK_FILE, flock -x 200; trap to release on EXIT
   - `_release_lock` — flock -u 200; close FD 200
   - `_with_lock <fn> <args...>` — convenience wrapper

9. Allocators (must be called within lock):
   - `_alloc_port`:
     - Read all `.sites[].port` values from sites.json
     - Range: 18000–18999
     - Algorithm: scan for max used port; if max < 18999 and (max+1) unused, return max+1; else find first gap starting at 18000
     - Echo allocated port to stdout
     - Error if range exhausted
   - `_alloc_redis_db`:
     - Same pattern, range 1–63 (0 reserved)
     - Warn (do not fail) if returning >= 12 (per CONTEXT.md note about bumping `databases 64` in redis.conf)

10. Docker / WP-CLI wrappers:
    - `_db_exec <sql>` — `docker exec -i wp-mariadb mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "$1"`
      - MARIADB_ROOT_PASSWORD sourced from compose/.env or environment (callers must export)
    - `_wp_exec <slug> <args...>` — `docker exec -u www-data "wp-${slug}" wp "$@"`
    - `_compose_site <slug> <action>` — `docker compose -f "${SITES_DIR}/${slug}/compose.yaml" $action` where action ∈ {up -d, down, stop, start, logs, ps}

11. Error / cleanup helpers:
    - `_die <msg>` — `_log error "$msg"; exit 1`
    - `_require_root` — `[[ $EUID -eq 0 ]] || _die "must run as root"`
    - `_require_cmd <cmd>` — fail if cmd not in PATH

All functions: handle missing args defensively, return non-zero on failure, never `set -e` inside lib (let caller decide).
  </action>
  <verify>
    <automated>bash -n bin/_lib.sh && bash -c 'WP_ROOT=/tmp/_lib_test source bin/_lib.sh; mkdir -p /tmp/_lib_test/state; _init_state && [[ -f /tmp/_lib_test/state/sites.json ]] && jq -e ".next_port == 18000" /tmp/_lib_test/state/sites.json && rm -rf /tmp/_lib_test'</automated>
  </verify>
  <done>bin/_lib.sh complete; _init_state creates valid skeleton; allocators function within lock; _db_exec / _wp_exec / _compose_site wrappers callable; total file < 400 lines.</done>
</task>

</tasks>

<verification>
- `bash -n bin/_lib.sh` exits 0
- Sourcing the lib in a clean bash shell does not produce stderr or exit codes
- `_sanitize_slug blog.example.com` → `blog_example_com`
- `_sanitize_slug mariadb` → non-zero exit + error log
- `_gen_admin_user` matches `^admin_[0-9a-f]{8}$`
- `_init_state` produces valid JSON parseable by jq
- File length < 400 lines
</verification>

<success_criteria>
bin/_lib.sh exists, syntax-checks, exposes the 11 helper groups above, has no top-level side effects, and unblocks all wave-2 plans (wp-create / wp-delete / wp-pause / wp-resume / wp-list / wp-stats / wp-logs / wp-exec).
</success_criteria>

<output>
Create `.planning/phases/02-cli-core-first-site-e2e/02-01-SUMMARY.md` documenting:
- Final function signatures (so wave-2 plans can call them by name)
- Any deviations from CONTEXT.md
- Lessons for executor of wp-create
</output>
