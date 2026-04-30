---
phase: 02-cli-core-first-site-e2e
plan: 03
type: execute
wave: 2
depends_on: [02-01, 02-02]
files_modified:
  - bin/wp-create
autonomous: true
requirements: [CLI-01, CLI-02, CLI-03, CLI-04, CLI-05, STATE-01, STATE-02, STATE-03, STATE-04, PERF-01, HARD-02]
must_haves:
  truths:
    - "wp-create blog.example.com end-to-end provisions DB, dirs, container, WP install, redis-cache, admin user"
    - "Re-running with same slug errors cleanly when prior state != failed (no silent overwrite)"
    - "--resume <slug> skips completed state-machine steps"
    - "Mid-flow failure rolls back via trap ERR in reverse state order"
    - "Port (18000+) and redis-DB allocation serialized via flock"
    - "SHOW GRANTS confirms DB user scoped only to wp_<slug>.* with MAX_USER_CONNECTIONS=40"
    - "Admin user is admin_<8hex> (random); secrets persisted to /opt/wp/secrets/<slug>.env mode 600"
    - "Final stdout block prints URL, admin creds, Caddy block, Cloudflare DNS rows, Cache Rule pointer (exactly once)"
    - "--dry-run validates without mutating any host state"
  artifacts:
    - path: "bin/wp-create"
      provides: "Site provisioning CLI verb"
      min_lines: 250
      exports: ["wp-create"]
  key_links:
    - from: "bin/wp-create"
      to: "bin/_lib.sh"
      via: "source"
      pattern: "source .*_lib.sh"
    - from: "bin/wp-create"
      to: "templates/site.compose.yaml.tmpl"
      via: "envsubst/sed render"
      pattern: "site\\.compose\\.yaml\\.tmpl"
    - from: "bin/wp-create"
      to: "wp-mariadb"
      via: "_db_exec for CREATE DATABASE / GRANT"
      pattern: "GRANT ALL ON wp_"
    - from: "bin/wp-create"
      to: "wp core install"
      via: "_wp_exec"
      pattern: "wp core install"
---

<objective>
Build wp-create — the single most complex verb in the CLI. Implements the 14-step provisioning sequence with state machine, rollback, and resume.

Purpose: This is the user's first contact with the system. It must be idempotent, recoverable, and produce paste-ready Caddy + Cloudflare outputs.
Output: bin/wp-create — executable bash script.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/phases/02-cli-core-first-site-e2e/02-CONTEXT.md
@.planning/phases/02-cli-core-first-site-e2e/02-01-SUMMARY.md
@.planning/phases/02-cli-core-first-site-e2e/02-02-SUMMARY.md
@bin/_lib.sh
@templates/site.compose.yaml.tmpl
@templates/wp-config-extras.php.tmpl
@templates/caddy-block.tmpl
@templates/cloudflare-dns.tmpl

Canonical spec sections in 02-CONTEXT.md:
- "wp-create <domain> [--admin-email X] [--resume <slug>]" — full 14-step sequence
- "State Machine Transitions" — 5 states + rollback per state
- "Security" — DB GRANT pattern with MAX_USER_CONNECTIONS=40, admin_<8hex>
- Step 14 — final stdout block format (verbatim)

Phase 1 deviation: containers run as UID 82 (Alpine), NOT 33. Use WP_UID from _lib.sh.
</context>

<tasks>

<task type="auto">
  <name>Task 1: Argument parsing, slug derivation, allocation, secrets</name>
  <files>bin/wp-create</files>
  <action>
Create bin/wp-create. Shebang `#!/usr/bin/env bash`. `set -euo pipefail`. `source "$(dirname "$0")/_lib.sh"`.

**Argument parsing:**
- Positional: `<domain>` (required unless `--resume <slug>` given)
- `--admin-email <email>` (default: admin@<domain>)
- `--resume <slug>` (continue from last completed state)
- `--dry-run` (validate; no host mutations)
- `--json` (emit final summary as JSON instead of human block)
- `-h | --help` (usage)

Use a manual `while [[ $# -gt 0 ]]` parser (no getopt — keeps it portable). Reject unknown flags with usage + exit 2.

**Setup:**
- `_init_state` (no-op if already exists)
- `_require_root`
- `_require_cmd docker`, `_require_cmd jq`, `_require_cmd openssl`, `_require_cmd flock`

**Slug derivation:**
- Call `_sanitize_slug "$DOMAIN"` → SLUG
- If `--resume`: SLUG=$RESUME_SLUG; load existing site entry from sites.json; abort if not found
- Else: check sites.json for existing entry. If present:
  - state == `failed` → tell user to run with `--resume $SLUG` (or wp-delete first); exit 1
  - state == anything else → "site already exists; wp-delete first" → exit 1

**Allocation (within lock; skip on resume if already allocated):**
- `_acquire_lock`
- If new site: PORT=$(_alloc_port); REDIS_DB=$(_alloc_redis_db)
- Else (resume): read PORT, REDIS_DB from existing entry
- Persist tentative entry to sites.json with `state: "allocating"` (so concurrent CLI runs see the slot taken)
- `_release_lock`

**Secret generation (skip on resume if .env already exists):**
- DB_PASSWORD=$(_gen_secret 32)
- WP_ADMIN_USER=$(_gen_admin_user)
- WP_ADMIN_PASSWORD=$(_gen_secret 24)
- 8 WP salts (64 chars each via `openssl rand -base64 64 | tr -d '\n=+/' | head -c 64`)
- Compose `${SECRETS_DIR}/${SLUG}.env` with the schema from CONTEXT.md "Secret File Schema"
- `chmod 600` and `chown root:root` the file

**--dry-run handling:** After computing slug + port + redis-db (without persisting), print the planned values and exit 0. No DB writes, no file writes, no docker calls.
  </action>
  <verify>
    <automated>bash -n bin/wp-create && bin/wp-create --help 2>&1 | grep -qi "wp-create" && bin/wp-create -h 2>&1 | grep -qi "resume"</automated>
  </verify>
  <done>wp-create parses args, validates slug, allocates port/redis-DB within flock, writes secrets file mode 600, supports --dry-run that exits before mutations.</done>
</task>

<task type="auto">
  <name>Task 2: State machine, provisioning steps 7–14, rollback trap</name>
  <files>bin/wp-create</files>
  <action>
Append to bin/wp-create.

**State machine — implement as a function `_advance_state <new-state>` that:**
- Reads current sites.json entry for SLUG
- Appends `{state: "<new-state>", ts: "<RFC3339>"}` to state_history
- Sets `.state = "<new-state>"`
- Saves via `_save_state`

**Rollback trap — `_rollback` function called by `trap _rollback ERR`:**
Reads current state for SLUG, runs reverse-order cleanup:
1. If state >= `container_booted`: `_compose_site $SLUG down` (no -v; DB is shared)
2. If state >= `dirs_created`: `rm -rf "${SITES_DIR}/${SLUG}"`
3. If state >= `db_created`:
   - `_db_exec "DROP DATABASE IF EXISTS wp_${SLUG};"`
   - `_db_exec "DROP USER IF EXISTS 'wp_${SLUG}'@'%';"`
4. Mark sites.json entry `state: "failed"` (preserve for --resume diagnosis; do NOT delete).
5. `_log error "rollback complete; site $SLUG marked failed"`

**Step 7 — Create DB + user + GRANT:**
- `_db_exec "CREATE DATABASE IF NOT EXISTS wp_${SLUG} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"`
- `_db_exec "CREATE USER IF NOT EXISTS 'wp_${SLUG}'@'%' IDENTIFIED BY '${DB_PASSWORD}';"`
- `_db_exec "GRANT ALL ON wp_${SLUG}.* TO 'wp_${SLUG}'@'%' WITH MAX_USER_CONNECTIONS 40;"`
- `_db_exec "FLUSH PRIVILEGES;"`
- **Verify grant scope:** `GRANTS=$(_db_exec "SHOW GRANTS FOR 'wp_${SLUG}'@'%';")`. Assert output contains `wp_${SLUG}.*` and `MAX_USER_CONNECTIONS 40` AND does NOT contain `*.*`. If fails, _die (rollback fires).
- `_advance_state db_created`

**Step 8 — Create dirs:**
- `mkdir -p "${SITES_DIR}/${SLUG}/wp-content"`
- `chown -R ${WP_UID}:${WP_UID} "${SITES_DIR}/${SLUG}"` (UID 82)
- `_advance_state dirs_created`

**Step 9 — Render compose:**
- Read templates/site.compose.yaml.tmpl
- Substitute `{{slug}}`, `{{port}}`, `{{redis_db}}`, `{{domain}}` with sed (or envsubst with conversion)
- Write to `${SITES_DIR}/${SLUG}/compose.yaml`

**Step 10 — Boot container:**
- `_compose_site $SLUG "up -d"`
- Wait for container healthy: poll `docker inspect wp-${SLUG} --format '{{.State.Status}}'` for "running" + tcp readiness on `127.0.0.1:${PORT}` (use `nc -z` or `curl --connect-timeout`); timeout 60s
- Capture container ID into sites.json entry
- `_advance_state container_booted`

**Step 11 — wp core install:**
- `_wp_exec $SLUG core install --url="https://${DOMAIN}" --title="${DOMAIN}" --admin_user="${WP_ADMIN_USER}" --admin_password="${WP_ADMIN_PASSWORD}" --admin_email="${ADMIN_EMAIL}" --skip-email`
- `_advance_state wp_installed`

**Step 12 — redis-cache plugin:**
- `_wp_exec $SLUG plugin install redis-cache --activate`
- `_wp_exec $SLUG redis enable`

**Step 13 — Inject wp-config extras:**
- Read templates/wp-config-extras.php.tmpl
- Inside container: `docker cp` the snippet to `/tmp/wp-config-extras.php`
- `_wp_exec $SLUG config set --raw --type=variable --anchor='/* That' --placement=before` is awkward; instead use `wp config set` for each constant individually OR use `docker exec wp-${SLUG} sh -c 'cat /tmp/wp-config-extras.php >> /var/www/html/wp-config.php.extras && ...'`. Cleanest: append a `require_once` line via `wp config set --raw` and `docker cp` the extras file to `/var/www/html/wp-config-extras.php`. Use whichever idiom is simplest; the canonical requirement is that all the extras (XML-RPC off, DISABLE_WP_CRON, redis defines) are loaded.
- Verify: `_wp_exec $SLUG eval 'echo (defined("DISABLE_WP_CRON") && DISABLE_WP_CRON) ? "ok" : "fail";'` returns "ok"

**Step 14 — Finalize + print summary:**
- `_advance_state finalized`
- Render summary block (use templates/caddy-block.tmpl + templates/cloudflare-dns.tmpl, substituting placeholders)
- VM_PUBLIC_IP: try `curl -s ifconfig.me` (timeout 3s); if fails, print `<your-VM-IP>` placeholder with note
- subdomain_or_at: derive from domain — if 2 labels (apex like example.com), use `@`; else use first label
- Print exactly the block from CONTEXT.md step 14 (admin URL, user, password, email, secrets path, Cloudflare DNS rows, Caddy block, Cache Rule pointer, `wp-list --secrets` redisplay hint)
- If `--json`: emit JSON `{slug, domain, port, redis_db, admin_user, admin_password, admin_email, secrets_path, caddy_block, dns_rows}` instead

**ERR trap registration:** Register `trap _rollback ERR` immediately after slug is determined and tentative entry is in sites.json. Unregister with `trap - ERR` after `_advance_state finalized` so a successful run doesn't trigger rollback on shell exit quirks.

Keep file under 400 lines. If approaching limit, factor more into _lib.sh helpers.
  </action>
  <verify>
    <automated>bash -n bin/wp-create && grep -q "trap _rollback ERR" bin/wp-create && grep -q "MAX_USER_CONNECTIONS 40" bin/wp-create && grep -q "wp core install" bin/wp-create && grep -q "redis-cache" bin/wp-create && grep -q "_advance_state finalized" bin/wp-create && grep -q "SHOW GRANTS" bin/wp-create</automated>
  </verify>
  <done>wp-create implements all 14 steps; rollback trap reverses all 5 state transitions; SHOW GRANTS asserted; final stdout block matches CONTEXT.md verbatim; --json mode emits structured equivalent; --resume picks up at correct state; container chmod 755 set on script.</done>
</task>

</tasks>

<verification>
- `bash -n bin/wp-create` exits 0
- Script declares `set -euo pipefail` and sources _lib.sh
- `trap _rollback ERR` is registered
- All five state names appear in source: db_created, dirs_created, container_booted, wp_installed, finalized
- `MAX_USER_CONNECTIONS 40` literal present
- `wp core install`, `wp plugin install redis-cache`, `wp redis enable` calls present
- `chmod 600` on secrets file, `chown 82:82` on site dir
- Final summary block contains the 3 Cloudflare cookie patterns (or references the cache rule template)
- File mode is 755 (`chmod +x bin/wp-create`)
</verification>

<success_criteria>
wp-create end-to-end: argument parse → allocator-locked port/redis-DB → secrets → DB+grant+verify → dirs → compose render → container up → wp install → redis-cache → wp-config extras → finalize → print summary. Rollback fires on any ERR. --resume skips completed states. --dry-run never mutates host. --json emits structured output. Idempotent re-run errors cleanly without overwriting.
</success_criteria>

<output>
Create `.planning/phases/02-cli-core-first-site-e2e/02-03-SUMMARY.md` documenting:
- Final state machine names (must match CONTEXT.md)
- Rollback ordering decisions
- Any wp-config injection idiom chosen (since CONTEXT left it open)
- Known limitations (e.g., VM_PUBLIC_IP detection failure mode)
</output>
