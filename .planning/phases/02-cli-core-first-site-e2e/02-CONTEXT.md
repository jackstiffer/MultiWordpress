# Phase 2: CLI Core + First Site E2E — Context

**Gathered:** 2026-04-30
**Status:** Ready for planning
**Mode:** Auto (`--auto`) — recommended defaults; all decisions trace to REQUIREMENTS.md / SUMMARY.md / ARCHITECTURE.md

<domain>
## Phase Boundary

Build the entire CLI surface that operates on the Phase 1 foundation, and prove the cache-strategy promise on a real domain. Specifically:

- Provisioning: `wp-create <domain>` end-to-end (DB + user + container + WP install + redis-cache plugin + admin user + emit Caddy/Cloudflare snippets).
- Lifecycle: `wp-delete`, `wp-pause`, `wp-resume`.
- Inspection: `wp-list` (with current/peak mem from metrics file), `wp-stats` (cluster + per-site, sorted by peak mem), `wp-logs`, `wp-exec` (WP-CLI passthrough).
- State: `/opt/wp/state/sites.json` registry with per-site state machine; `/opt/wp/secrets/<slug>.env` mode 600.
- Per-site DB: scoped GRANT with `MAX_USER_CONNECTIONS=40`.
- Per-site config: `wp-config.php` with `WP_HOME`/`WP_SITEURL` from env, `DISABLE_WP_CRON=true`, XML-RPC disabled, `WP_REDIS_DATABASE` + `WP_REDIS_PREFIX`, `WP_DEBUG_LOG=/proc/self/fd/2` (or off in production).
- E2E: provision one real domain, paste Caddy + Cloudflare snippets, verify `cf-cache-status: HIT` for logged-out homepage.

Out of scope for Phase 2: tier system (dropped — shared pool model), backup/restore (dropped), wp-cron stagger cron (Phase 3), metrics-poll cron (Phase 3), dashboard (Phase 4), documentation suite (Phase 4 covers full README; Phase 2 ships CLI README only).

</domain>

<canonical_refs>
## Canonical References

- `.planning/PROJECT.md`
- `.planning/REQUIREMENTS.md` — Phase 2 covers CLI-01..06, CLI-08..11, CLI-14, CLI-17, STATE-01..04, PERF-01, PERF-02, HARD-02
- `.planning/ROADMAP.md` — Phase 2 success criteria
- `.planning/research/SUMMARY.md` — locked stack
- `.planning/research/STACK.md` — image tags, plugin versions
- `.planning/research/ARCHITECTURE.md` — component layout, state machine, port allocator design
- `.planning/research/PITFALLS.md` — §3.1 (DB grants), §6.1–6.5 (provisioning robustness), §7.1–7.2 (cache validation), §9.1–9.2 (security baseline), §4.3 (UID for bind mount)
- `.planning/phases/01-foundation/01-CONTEXT.md` — Phase 1 file layout (compose/, image/, host/)
- `.planning/phases/01-foundation/01-PLAN-02-SUMMARY.md` — **important**: image runs as UID 82 (Alpine), not 33 (Debian). All chowns target 82.
- `.planning/phases/01-foundation/01-VERIFICATION.md` — Phase 1 deviations
- `compose/compose.yaml` (Phase 1 output) — shared infra running, `wp-network` external
- `image/Dockerfile` (Phase 1 output) — image tag `multiwp:wordpress-6-php8.3` (or whatever was tagged in Phase 1's build)

</canonical_refs>

<decisions>
## Implementation Decisions

### Repo Layout (additions)
- `bin/` — all CLI scripts. Each script is a stand-alone bash file with shebang.
  - `bin/wp-create`, `bin/wp-delete`, `bin/wp-pause`, `bin/wp-resume`, `bin/wp-list`, `bin/wp-stats`, `bin/wp-logs`, `bin/wp-exec`
  - `bin/_lib.sh` — shared helpers sourced by all scripts (state I/O, logging, error helpers, port allocator, secret gen).
- `templates/` — files generated/copied per site by `wp-create`:
  - `templates/site.compose.yaml.tmpl` — per-site compose snippet (with `{{slug}}`, `{{port}}`, `{{redis_db}}`, `{{domain}}` placeholders).
  - `templates/wp-config-extras.php.tmpl` — additions for `wp-config.php`.
  - `templates/caddy-block.tmpl` — Caddy snippet to print.
  - `templates/cloudflare-dns.tmpl` — DNS rows to print.
- `docs/` — `docs/cli.md` (CLI reference, one section per verb).

### State Layout (on host)
```
/opt/wp/
├── state/
│   ├── sites.json           # registry (mode 644)
│   ├── allocator.lock       # flock target for port/redis-DB allocation
│   └── metrics.json         # written by Phase 3 metrics-poll; read by wp-stats / wp-list (best-effort)
├── secrets/
│   └── <slug>.env           # per-site secrets, mode 600 root-owned
├── sites/
│   └── <slug>/
│       ├── wp-content/      # bind-mounted into container (chown 82:82)
│       └── compose.yaml     # generated per-site compose
└── logs/                    # not used (logs flow through docker driver)
```

### sites.json Schema
```json
{
  "version": 1,
  "next_port": 18000,
  "next_redis_db": 1,
  "sites": {
    "<slug>": {
      "domain": "<original-domain>",
      "slug": "<sanitized-slug>",
      "port": 18001,
      "redis_db": 2,
      "state": "finalized | paused | failed",
      "state_history": [
        {"state": "db_created", "ts": "2026-04-30T15:00:00Z"},
        {"state": "dirs_created", "ts": "..."},
        {"state": "container_booted", "ts": "..."},
        {"state": "wp_installed", "ts": "..."},
        {"state": "finalized", "ts": "..."}
      ],
      "container_id": "<sha>",
      "created_at": "...",
      "admin_user": "admin_<8hex>"
    }
  }
}
```

### Secret File Schema (per-site .env, mode 600)
```
SLUG=<slug>
DOMAIN=<original-domain>
PORT=<port>
REDIS_DB=<n>
DB_NAME=wp_<slug>
DB_USER=wp_<slug>
DB_PASSWORD=<random32>
WP_ADMIN_USER=admin_<8hex>
WP_ADMIN_PASSWORD=<random24>
WP_ADMIN_EMAIL=admin@<domain>
WP_AUTH_KEY=<wp-secret>
WP_SECURE_AUTH_KEY=<wp-secret>
WP_LOGGED_IN_KEY=<wp-secret>
WP_NONCE_KEY=<wp-secret>
WP_AUTH_SALT=<wp-secret>
WP_SECURE_AUTH_SALT=<wp-secret>
WP_LOGGED_IN_SALT=<wp-secret>
WP_NONCE_SALT=<wp-secret>
```

### Per-Site Compose Template (site.compose.yaml.tmpl)
```yaml
services:
  wp-{{slug}}:
    image: multiwp:wordpress-6-php8.3
    container_name: wp-{{slug}}
    cgroup_parent: wp.slice           # SHARED POOL — no mem_limit
    networks:
      - wp-network
    ports:
      - "127.0.0.1:{{port}}:9000"     # FastCGI on loopback
    env_file:
      - /opt/wp/secrets/{{slug}}.env
    environment:
      WORDPRESS_DB_HOST: wp-mariadb:3306
      WORDPRESS_DB_NAME: ${DB_NAME}
      WORDPRESS_DB_USER: ${DB_USER}
      WORDPRESS_DB_PASSWORD: ${DB_PASSWORD}
      WORDPRESS_REDIS_HOST: wp-redis
      WORDPRESS_REDIS_DATABASE: ${REDIS_DB}
      WORDPRESS_REDIS_PREFIX: wp_{{slug}}_
      WORDPRESS_HOME: https://{{domain}}
      WORDPRESS_SITEURL: https://{{domain}}
    volumes:
      - /opt/wp/sites/{{slug}}/wp-content:/var/www/html/wp-content
    restart: unless-stopped
    depends_on:
      - wp-mariadb       # shared infra
      - wp-redis
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
        compress: "true"

networks:
  wp-network:
    external: true
    name: wp-network
```

### Slug Derivation
- Sanitize: lowercase, replace `.` `-` with `_`, strip non-`[a-z0-9_]`.
  Example: `blog.example.com` → `blog_example_com`.
- Length cap 32 chars (DB user name limit on MariaDB is 80 but 32 is safer).
- Reserved slugs: `mariadb`, `redis`, `network` — refuse with clear error.

### Port Allocator
- Range: 18000–18999 (1000 site slots; well outside AudioStoryV2's 3000/6379 and any common service).
- Algorithm: scan existing `sites.json.sites` for max `port`; allocate `max+1` if gap-less; else find first gap.
- Serialize via `flock /opt/wp/state/allocator.lock` (also serializes redis-DB allocation).

### Redis-DB Allocator
- Range: 1–63 (Redis 0 reserved; bump `databases 64` in redis.conf if site count ≥ 12 — Phase 3 concern, document for now).
- Same allocator pattern as ports.

### State Machine Transitions
1. `db_created` — DB + user + GRANT done. Rollback: drop user + DB.
2. `dirs_created` — `/opt/wp/sites/<slug>/wp-content/` exists, chowned 82:82. Rollback: `rm -rf /opt/wp/sites/<slug>`.
3. `container_booted` — `docker compose -f /opt/wp/sites/<slug>/compose.yaml up -d` succeeded. Rollback: `docker compose down -v` (no -v actually since DB is shared).
4. `wp_installed` — `wp core install` ran successfully inside container. Rollback: nothing extra (DB drop in step 1 covers it).
5. `finalized` — redis-cache plugin activated, baseline plugins/options set, sites.json marked finalized.

### `wp-create <domain> [--admin-email X] [--resume <slug>]`
Sequence:
1. `flock` allocator lock.
2. Sanitize domain → slug. Refuse if slug already in sites.json AND state is not `failed` (no `--force`; user can `wp-delete` first).
3. If `--resume <slug>`: load existing entry, skip completed steps.
4. Allocate port + redis_db (within lock).
5. Generate secrets (random32 for DB pass, random24 for admin, 64-char salts × 8) → write `.env` mode 600.
6. Release lock (mutations to sites.json happen incrementally with separate locks per site or just trust single-operator).
7. Create DB + user + GRANT (with `MAX_USER_CONNECTIONS=40`). Verify GRANT scope. Mark state.
8. Create dirs, chown 82:82. Mark state.
9. Render `templates/site.compose.yaml.tmpl` → `/opt/wp/sites/<slug>/compose.yaml`.
10. `docker compose up -d` for that compose file. Wait for healthy. Mark state.
11. Inside container via `docker exec`: `wp core install --url=https://<domain> --title=<domain> --admin_user=<admin> --admin_password=<pw> --admin_email=<email> --skip-email`.
12. Inside container: `wp plugin install redis-cache --activate`. Then `wp redis enable`.
13. Inject `wp-config.php` extras (XML-RPC off, `DISABLE_WP_CRON`, `WP_DEBUG_LOG=/proc/self/fd/2` if WP_DEBUG enabled, `WP_HOME`/`WP_SITEURL` from env).
14. Mark state `finalized`. Print summary block:
    ```
    ✓ Site created: https://<domain>
    
    Admin URL:      https://<domain>/wp-admin/
    Admin user:     <admin_user>
    Admin password: <admin_pw>
    Admin email:    <email>
    
    Saved to: /opt/wp/secrets/<slug>.env (mode 600 — not stored in shell history)
    
    ── Cloudflare DNS rows ──
    Type   Name                      Content        Proxy
    A      <subdomain or @>          <VM-public-IP> Proxied
    
    ── Caddy block ──
    <domain> {
        php_fastcgi 127.0.0.1:<port>
        root * /opt/wp/sites/<slug>/wp-content
        encode gzip
        log {
            output discard
        }
    }
    
    ── Cloudflare Cache Rule ──
    Set "Cache Everything" with cookie bypass for: wordpress_logged_in_*, wp-postpass_*, comment_author_*
    
    Run `wp-list --secrets <slug>` to redisplay these creds anytime.
    ```
- Trap ERR fires rollback in reverse state order.

### `wp-delete <slug>`
1. Confirm with `--yes` flag or interactive Y/N (in --auto contexts, require --yes).
2. `docker compose -f /opt/wp/sites/<slug>/compose.yaml down`.
3. Drop DB + drop user.
4. `rm -rf /opt/wp/sites/<slug>`.
5. `rm /opt/wp/secrets/<slug>.env`.
6. Update sites.json.
7. Print Caddy block to remove + Cloudflare DNS row to remove.

### `wp-pause <slug>` / `wp-resume <slug>`
- pause: `docker compose -f .../compose.yaml stop`. Mark state `paused`. Container removed but DB/files/secrets intact.
- resume: `docker compose -f .../compose.yaml up -d`. Mark state `finalized` again (or `running`).
- `wp-list` distinguishes `running`, `paused`, `failed`.

### `wp-list`
- Reads sites.json. For each site, augments with:
  - container status (`docker ps --filter name=wp-<slug> --format '{{.Status}}'`)
  - current mem (from `docker stats --no-stream` JSON if container running)
  - 24h-peak mem (from `/opt/wp/state/metrics.json` if exists; "—" otherwise — Phase 3 fills this in)
- Output: aligned columns (slug, domain, status, port, redis_db, mem now, mem peak 24h).
- `--secrets <slug>` flag: print contents of `secrets/<slug>.env` (no echo to history; print directly to stdout).

### `wp-stats`
- Cluster line: `wp.slice` pool used (read `/sys/fs/cgroup/wp.slice/memory.current`) / 4 GB total / 24h peak (from metrics.json).
- AudioStoryV2 health: check container running, restart count.
- Per-site rows: current mem MB, 24h-peak mem MB, 24h-peak CPU%, 24h-peak DB-conn (DB-conn is best-effort — `mysql --silent -e "SELECT user, COUNT(*) FROM information_schema.processlist GROUP BY user;"`). Sorted by peak mem descending.
- Pool ≥ 90% peak: yellow. ≥ 100%: red. Use ANSI colors with auto-detect (NO_COLOR env var, isatty check).

### `wp-logs <slug> [--follow|-f]`
- `docker compose -f /opt/wp/sites/<slug>/compose.yaml logs [--follow]`.

### `wp-exec <slug> <wp-cli-args...>`
- `docker exec -u www-data wp-<slug> wp <args>` — passes through.

### Security
- Admin username random `admin_<8hex>` (NOT `admin`). XML-RPC disabled in wp-config.php. PHP execution under `wp-content/uploads/` denied (Caddy snippet handles since FPM-only).
- DB GRANT scope: `GRANT ALL ON wp_<slug>.* TO 'wp_<slug>'@'%' IDENTIFIED BY '<pw>' WITH MAX_USER_CONNECTIONS 40;`. After grant, `SHOW GRANTS FOR 'wp_<slug>'@'%';` must show only that one DB. Provisioning aborts if not.
- Secrets file mode 600 root-owned. `wp-create` does not echo password to stdout twice — once in summary, once persisted.

### CLI Conventions
- Shebang: `#!/usr/bin/env bash`.
- `set -euo pipefail` at top.
- `trap rollback ERR` in wp-create.
- All paths absolute. Default `WP_ROOT=/opt/wp` (overridable via env for testing).
- Each script `bin/wp-X` is < 400 lines; common code in `bin/_lib.sh`.
- Logging via `_log info|warn|error <msg>` helper that writes to stderr with timestamp.
- Output that's user-data (creds, JSON, snippets) goes to stdout; logs go to stderr.

### First-Site E2E Validation (success criterion 5)
- After CLI ships, manually provision one real domain on the GCP VM.
- Paste Caddy block + Cloudflare DNS rows + Cloudflare Cache Rule.
- Activate Super Page Cache for Cloudflare plugin: `wp-exec <slug> plugin install super-page-cache-for-cloudflare --activate`.
- Validate: `curl -sI https://<domain>/ | grep cf-cache-status` shows `HIT` for logged-out; `curl -sI -H 'Cookie: wordpress_logged_in_x=y' https://<domain>/wp-admin/` bypasses cache.
- Document the validation procedure in `docs/cli.md` and Phase 2 SUMMARY.

</decisions>

<code_context>
## Existing Code Insights

Phase 1 produced (and Phase 2 reuses):
- `compose/compose.yaml` — shared infra. Phase 2's per-site compose files reference `wp-network` as `external: true`.
- `image/` — per-site image template. Phase 2's `wp-create` uses `multiwp:wordpress-6-php8.3` (build tag from Phase 1).
- `host/wp.slice` — shared cgroup. Phase 2's per-site compose uses `cgroup_parent: wp.slice`.
- UID 82 (Alpine), not 33 — propagate to all chowns.

Pattern reuse:
- Log driver block (`json-file`, 10m × 3) baked into per-site compose template.
- Healthcheck pattern from compose.yaml — per-site WP container can have a simple `wp eval 'echo "OK";'` healthcheck via WP-CLI but that's optional.
- AudioStoryV2 deploy.sh pattern (gcloud SSH + scp + docker compose) — informs Phase 4 README "how to deploy this CLI to the VM" docs but not directly used in Phase 2.

</code_context>

<specifics>
## Specific Ideas

- **Testing strategy**: bash unit tests are overkill for greenfield CLI; ship with smoke-test script `bin/_smoke-test.sh` that creates → lists → pauses → resumes → deletes a fake site against a local Docker engine. Run manually post-install.
- **Output format consistency**: every `wp-X` command supports `--json` flag for structured output (used by Phase 4 dashboard). `wp-list --json`, `wp-stats --json`. Default human output; --json mode is identical data via `jq`-friendly structure.
- **No `--force` flag anywhere**: footgun avoidance. Operator must `wp-pause` or `wp-delete` before retrying.
- **Idempotent verbs**: `wp-pause` on already-paused site succeeds with no-op. `wp-resume` on running site same. `wp-delete` on non-existent slug fails with clear error (NOT silent success).
- **`wp-create` `--dry-run`**: optional flag that walks through validation (slug derivation, port allocation, etc.) without writing anything. Useful for sanity check.

</specifics>

<deferred>
## Deferred Ideas

- `wp-update --all` (OPS2-01) — defer to v2.
- `wp-health` (OPS2-02) — defer.
- `wp-disk` (OPS2-03) — defer.
- `wp-stats --top` (OPS2-04) — defer.
- Maintenance-mode shortcut (OPS2-05) — defer.
- Concurrent `wp-create` race handling beyond flock (e.g., true atomic state.json updates) — current single-operator scope makes flock sufficient.

</deferred>

<discretion>
## Claude's Discretion

- Exact bash idiom for state machine transitions (associative arrays vs case statements vs functions).
- jq usage for sites.json mutation (recommend; cleaner than sed/awk).
- Exact wording of error messages (must be actionable, but phrasing is open).
- ANSI color codes for warnings/errors.
- Which template engine for compose generation (envsubst is fine; no need for jinja).
- Whether `_lib.sh` is dot-sourced or `source`d (style preference).

NOT discretionary:
- Slug sanitization rules.
- Port range (18000–18999).
- Redis DB range (1–63).
- DB user grant pattern with `MAX_USER_CONNECTIONS=40`.
- Random admin username pattern (`admin_<8hex>`).
- State machine names (db_created → dirs_created → container_booted → wp_installed → finalized).
- File modes (secrets 600, sites.json 644, scripts 755).
- UID for chown (82, NOT 33).
- All snippet content (Caddy block, Cloudflare rows, cache rule cookies).

</discretion>

---
*Phase 2 context — auto-generated. CLI surface fully specified; downstream agents implement.*
