# Requirements: MultiWordpress

**Defined:** 2026-04-30
**Core Value:** Adding the Nth WordPress site must not slow down the existing Next.js apps or the previously-installed WP sites.

## v1 Requirements

### Infrastructure

- [ ] **INFRA-01**: Shared `wp-mariadb` container (mariadb:lts) with healthcheck, capped logs (10 MB / 3 files), and named volume for data.
- [ ] **INFRA-02**: Shared `wp-redis` container (redis:7-alpine) bound to `127.0.0.1:16379` with 256 MB memory cap and `allkeys-lru` eviction. Separate from AudioStoryV2's redis.
- [ ] **INFRA-03**: User-defined Docker bridge network `wp-network` with MTU 1460 (GCP VPC default) — isolated from `audiostory_app-network`.
- [ ] **INFRA-04**: Shared infra defined in a single `compose/compose.yaml`; brought up via `docker compose up -d`.
- [ ] **INFRA-05**: Hard memory limits on every container (sum ≤ 4 GB across all `wp-*` containers).
- [ ] **INFRA-06**: All containers use `restart: unless-stopped`; WP containers `depends_on: { wp-mariadb: { condition: service_healthy } }`.

### Image

- [ ] **IMG-01**: Per-site Dockerfile based on `wordpress:6-php8.3-fpm-alpine` with WP-CLI baked in.
- [ ] **IMG-02**: php-fpm pool config: `pm=ondemand`, `pm.max_children=6`, `pm.process_idle_timeout=30s`, `pm.max_requests=500`.
- [ ] **IMG-03**: php.ini config: OPcache enabled (96 MB), JIT off, `memory_limit=256M`, `request_terminate_timeout=30s`.
- [ ] **IMG-04**: WP `debug.log` redirected to `/proc/self/fd/2`; php-fpm `error_log = /proc/self/fd/2` — internal logs inherit docker driver's 10 MB rotation.
- [ ] **IMG-05**: Bake config that denies PHP execution under `wp-content/uploads/`.
- [ ] **IMG-06**: Image runs as `www-data` (UID 33); document the UID expectation for bind mounts.

### CLI — Site Lifecycle

- [ ] **CLI-01**: `wp-create <domain>` provisions a complete site: container + DB + DB user + WP install + admin user + redis-cache plugin activated.
- [ ] **CLI-02**: `wp-create` prints to stdout exactly once: site URL, admin username, admin password, Cloudflare DNS rows, and Caddy block to paste — with a "save now, not stored in shell history" warning. Persists creds to `/opt/wp/secrets/<slug>.env` (mode 600).
- [ ] **CLI-03**: `wp-create` is idempotent on re-run with same slug (errors out cleanly; no silent overwrite). Supports `--resume <slug>` for partial-failure recovery via per-site state machine.
- [ ] **CLI-04**: `wp-create` allocates ports from a 18000+ pool, allocates a redis DB index per site, generates secrets — all serialized with a lockfile to prevent races.
- [ ] **CLI-05**: `wp-create` rolls back cleanly on any step failure (DB drop, dirs remove, container remove) via `trap ERR`.
- [ ] **CLI-06**: `wp-delete <site>` stops + removes container, drops DB + DB user, removes secrets file, removes site dirs, and prints Caddy/Cloudflare cleanup instructions.
- [ ] **CLI-07**: `wp-delete --archive` writes `wp-content` tarball + DB dump to `/opt/wp/backups/archive/<slug>-<timestamp>.tar.gz` before deletion.
- [ ] **CLI-08**: `wp-list` shows all sites: slug, domain, status (running/stopped), port, redis DB, container ID. Supports `wp-list --secrets <slug>` to re-display creds without exposing in shell history.

### CLI — Operations

- [ ] **CLI-09**: `wp-stats` shows system-wide CPU/mem/disk usage and per-container stats for all `wp-*` containers (parses `docker stats --no-stream` JSON).
- [ ] **CLI-10**: `wp-logs <site>` tails docker logs for one site; `wp-logs <site> --follow` streams.
- [ ] **CLI-11**: `wp-exec <site> <wp-cli-command>` passes through to WP-CLI inside the target container (e.g., `wp-exec blog plugin install yoast`).
- [ ] **CLI-12**: `wp-backup <site>` writes DB dump (`mysqldump --single-transaction --quick`) + wp-content tarball to `/opt/wp/backups/<slug>/<timestamp>/`. Uses single-DB dump — never global locks.
- [ ] **CLI-13**: `wp-restore <site> <backup-path>` restores DB + wp-content from a backup directory.

### State & Secrets

- [ ] **STATE-01**: Site registry at `/opt/wp/state/sites.json` with per-site state machine: `db_created → dirs_created → container_booted → wp_installed → finalized`.
- [ ] **STATE-02**: Per-site secrets in `/opt/wp/secrets/<slug>.env` — mode 600, owner root.
- [ ] **STATE-03**: DB users have grants ONLY to their own DB (`GRANT ALL ON wp_<slug>.*` — no wildcards). Provisioning script asserts grant scope before declaring success.
- [ ] **STATE-04**: Each site uses a unique random admin username (`admin_<8hex>`) — never `admin`. Override flag available.

### Performance / Caching

- [ ] **PERF-01**: `redis-cache` plugin (Till Krüss) baked into provisioning; activated automatically with `WP_REDIS_DATABASE` (per-site index) AND `WP_REDIS_PREFIX` (slug) set in `wp-config.php`.
- [ ] **PERF-02**: Page-cache strategy documented: Cloudflare Cache Rules + Super Page Cache for Cloudflare plugin. CLI prints the cookie-bypass rule the user must paste into Cloudflare.
- [ ] **PERF-03**: `DISABLE_WP_CRON=true` in every site's `wp-config.php`; provisioning script registers a host crontab line per site with a deterministic offset (slug-hash mod) to stagger wp-cron runs.

### Coexistence / Hardening

- [ ] **HARD-01**: WP containers bind only to `127.0.0.1:<allocated-port>` — never `0.0.0.0`. Same for `wp-mariadb` (`127.0.0.1:13306`) and `wp-redis` (`127.0.0.1:16379`).
- [ ] **HARD-02**: XML-RPC disabled by default in every site's `wp-config.php`.
- [ ] **HARD-03**: Image pinning — every container references a specific tag, never `:latest`.

### Dashboard (thin)

- [ ] **DASH-01**: Single-page PHP dashboard showing per-site status, CPU%, mem%, request count (if available), and "view logs" modal. 5-second polling. Read-only by default.
- [ ] **DASH-02**: Dashboard "add site" and "delete site" buttons shell out to CLI via narrow sudoers whitelist (no docker socket mount).
- [ ] **DASH-03**: Dashboard runs in its own container behind host Caddy basic auth.

### Documentation

- [ ] **DOC-01**: README explains: installation, prerequisites (Caddy + Cloudflare assumptions), full lifecycle of one site, backup/restore workflow.
- [ ] **DOC-02**: Caddy snippet template included; one-page guide for paste-into-Caddy + Cloudflare DNS rows.
- [ ] **DOC-03**: Scaling-cliff doc: warning signs that single-VM design has been outgrown.

## v2 Requirements

Deferred. Tracked, not in current roadmap.

### Operations

- **OPS2-01**: `wp-update --all` — update WP core / plugins / themes across all sites in one command.
- **OPS2-02**: `wp-health` — HTTP HEAD check per site, surfaces 5xx / unreachable.
- **OPS2-03**: `wp-disk` — per-site disk usage breakdown (uploads, DB).
- **OPS2-04**: `wp-stats --top` — rank by request rate (parses access logs).
- **OPS2-05**: Maintenance-mode shortcut.
- **OPS2-06**: Weekly backup-restore smoke-test cron.

### Future

- **FUT-01**: S3 offsite backup target.
- **FUT-02**: `wp-rename <old-domain> <new-domain>`.
- **FUT-03**: Slack/Discord alert hook on failures.
- **FUT-04**: Per-site PHP version pinning.

## Out of Scope

| Feature | Reason |
|---------|--------|
| Auto-DNS provisioning via Cloudflare API | User pastes DNS manually — explicit decision; keeps tool dumb-by-design |
| Auto-Caddy edits | Host Caddy is shared with AudioStoryV2; must not be programmatically edited by this tool |
| Reverse proxy in our stack | Host Caddy already provides; adding `wp-caddy` would duplicate |
| Multi-tenant SaaS (billing, tenant isolation, sandboxing) | Single-owner blog network only |
| cPanel/Plesk-style hosting panel | Explicitly rejected — moved away from EasyEngine for being too heavy |
| Per-site staging / blue-green deploys | Out of scope; manual `wp-backup` + clone is sufficient |
| Site clone / duplicate utility | Defer; not a blog-network use case |
| Web-based shell or file browser | Security risk; use SSH |
| Plugin/theme marketplace UI | WP admin already does this |
| One-click installers for non-WP apps | This tool is WordPress-only |
| Built-in CDN | Cloudflare is in front; no second CDN |
| Email server / mail relay UI | Out of scope; use SMTP plugin pointed at external relay |
| Auto-SSL provisioning logic | Host Caddy already auto-provisions Let's Encrypt |
| Per-site PHP-FPM pool engineering | Per-site container makes per-pool tuning unnecessary |
| Per-site CPU/RAM attribution beyond `docker stats` | Per-container stats are free given the architecture |
| Migration tooling from existing hosts | Manual via WP-CLI |
| Log aggregation (ELK / Loki) | 10 MB caps + `docker logs` is enough at this scale |
| Slow-query log GUI | CLI surfacing is enough; v2 if needed |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| INFRA-01 | Phase 1 | Pending |
| INFRA-02 | Phase 1 | Pending |
| INFRA-03 | Phase 1 | Pending |
| INFRA-04 | Phase 1 | Pending |
| INFRA-05 | Phase 1 | Pending |
| INFRA-06 | Phase 1 | Pending |
| IMG-01 | Phase 1 | Pending |
| IMG-02 | Phase 1 | Pending |
| IMG-03 | Phase 1 | Pending |
| IMG-04 | Phase 1 | Pending |
| IMG-05 | Phase 1 | Pending |
| IMG-06 | Phase 1 | Pending |
| CLI-01 | Phase 2 | Pending |
| CLI-02 | Phase 2 | Pending |
| CLI-03 | Phase 2 | Pending |
| CLI-04 | Phase 2 | Pending |
| CLI-05 | Phase 2 | Pending |
| CLI-06 | Phase 2 | Pending |
| CLI-07 | Phase 2 | Pending |
| CLI-08 | Phase 2 | Pending |
| CLI-09 | Phase 2 | Pending |
| CLI-10 | Phase 2 | Pending |
| CLI-11 | Phase 2 | Pending |
| CLI-12 | Phase 2 | Pending |
| CLI-13 | Phase 2 | Pending |
| STATE-01 | Phase 2 | Pending |
| STATE-02 | Phase 2 | Pending |
| STATE-03 | Phase 2 | Pending |
| STATE-04 | Phase 2 | Pending |
| PERF-01 | Phase 2 | Pending |
| PERF-02 | Phase 2 | Pending |
| PERF-03 | Phase 3 | Pending |
| HARD-01 | Phase 1 | Pending |
| HARD-02 | Phase 2 | Pending |
| HARD-03 | Phase 1 | Pending |
| DASH-01 | Phase 4 | Pending |
| DASH-02 | Phase 4 | Pending |
| DASH-03 | Phase 4 | Pending |
| DOC-01 | Phase 4 | Pending |
| DOC-02 | Phase 4 | Pending |
| DOC-03 | Phase 4 | Pending |

**Coverage:**
- v1 requirements: 36 total
- Mapped to phases: 36 ✓
- Unmapped: 0

### By Phase

| Phase | Count | Requirements |
|-------|-------|--------------|
| Phase 1: Foundation | 14 | INFRA-01..06, IMG-01..06, HARD-01, HARD-03 |
| Phase 2: CLI Core + First Site E2E | 19 | CLI-01..13, STATE-01..04, PERF-01, PERF-02, HARD-02 |
| Phase 3: Operational Tooling | 1 | PERF-03 |
| Phase 4: Polish — Dashboard + Docs | 6 | DASH-01..03, DOC-01..03 |

---
*Requirements defined: 2026-04-30*
*Last updated: 2026-04-30 after roadmap creation (traceability populated)*
