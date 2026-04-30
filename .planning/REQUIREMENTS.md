# Requirements: MultiWordpress

**Defined:** 2026-04-30
**Core Value:** Adding the Nth WordPress site must not slow down the existing Next.js apps or the previously-installed WP sites.

## v1 Requirements

### Tier Table (locked, referenced by CLI-15/CLI-16/PERF-04/DASH-01)

| Tier | `mem_limit` | `pm.max_children` | DB `MAX_USER_CONNECTIONS` |
|---|---|---|---|
| `small` | 192 MB | 3 | 10 |
| `standard` *(default)* | 384 MB | 6 | 20 |
| `large` | 768 MB | 12 | 40 |
| `xl` | 1.5 GB | 24 | 80 |

Cluster-wide cap: sum of all running sites' `mem_limit` must remain ≤ 4 GB. CLI enforces; pause sites to free budget.

### Infrastructure

- [ ] **INFRA-01**: Shared `wp-mariadb` container (mariadb:lts) with healthcheck, capped logs (10 MB / 3 files), and named volume for data.
- [ ] **INFRA-02**: Shared `wp-redis` container (redis:7-alpine) bound to `127.0.0.1:16379` with 256 MB memory cap and `allkeys-lru` eviction. Separate from AudioStoryV2's redis.
- [ ] **INFRA-03**: User-defined Docker bridge network `wp-network` with MTU 1460 (GCP VPC default) — isolated from `audiostory_app-network`.
- [ ] **INFRA-04**: Shared infra defined in a single `compose/compose.yaml`; brought up via `docker compose up -d`.
- [ ] **INFRA-05**: Hard memory limits on every container (sum ≤ 4 GB across all `wp-*` containers).
- [ ] **INFRA-06**: All containers use `restart: unless-stopped`; WP containers `depends_on: { wp-mariadb: { condition: service_healthy } }`.

### Image

- [ ] **IMG-01**: Per-site Dockerfile based on `wordpress:6-php8.3-fpm-alpine` with WP-CLI baked in.
- [ ] **IMG-02**: php-fpm pool config: `pm=ondemand`, `pm.process_idle_timeout=30s`, `pm.max_requests=500`. `pm.max_children` is templated from the per-site tier (default `standard` = 6) — see Tier Table.
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
- [ ] **CLI-08**: `wp-list` shows all sites: slug, domain, status (running/paused/stopped), tier, port, redis DB, container ID. Supports `wp-list --secrets <slug>` to re-display creds without exposing in shell history.

### CLI — Operations

- [ ] **CLI-09**: `wp-stats` shows system-wide CPU/mem/disk usage and per-container stats for all `wp-*` containers (parses `docker stats --no-stream` JSON).
- [ ] **CLI-10**: `wp-logs <site>` tails docker logs for one site; `wp-logs <site> --follow` streams.
- [ ] **CLI-11**: `wp-exec <site> <wp-cli-command>` passes through to WP-CLI inside the target container (e.g., `wp-exec blog plugin install yoast`).
- [ ] **CLI-14**: `wp-pause <site>` and `wp-resume <site>` toggle a site's running state. `wp-pause` stops the container (frees its RAM, keeps DB + files + secrets intact), marks state `paused` in the registry, and prints the optional Caddy snippet to swap in a "site paused" stub if the operator wants visitors to see a friendly page instead of 502. `wp-resume` starts the container, restores state to `running`. `wp-list` shows paused sites distinctly.
- [ ] **CLI-15**: `wp-create --tier=<small|standard|large|xl>` provisions a site at the chosen tier (default `standard`). Tier maps to `mem_limit` + `pm.max_children` + MariaDB `MAX_USER_CONNECTIONS` per the locked tier table. Cluster-budget guard refuses provisions that would push total `mem_limit` sum past 4 GB; error message names which sites to pause or downsize to free budget.
- [ ] **CLI-16**: `wp-tier <site> <new-tier>` retiers a running site. Recreates the container with new `mem_limit` + `pm.max_children`, re-issues the DB GRANT with new `MAX_USER_CONNECTIONS`, updates registry. ~5s downtime; DB + files + secrets + redis DB index preserved. Same budget guard as `wp-create`.
- [ ] **CLI-17**: `wp-stats` reads `/opt/wp/state/metrics.json` and shows per site: current mem%, 24h-peak mem%, 24h-peak CPU%, 24h-peak DB-connection count, current tier. Sites at ≥ 90% of any allocation flagged with `tier-up suggested`; ≥ 100% flagged with `tier-up needed`.

### State & Secrets

- [ ] **STATE-01**: Site registry at `/opt/wp/state/sites.json` with per-site state machine: `db_created → dirs_created → container_booted → wp_installed → finalized`.
- [ ] **STATE-02**: Per-site secrets in `/opt/wp/secrets/<slug>.env` — mode 600, owner root.
- [ ] **STATE-03**: DB users have grants ONLY to their own DB (`GRANT ALL ON wp_<slug>.*` — no wildcards). `WITH MAX_USER_CONNECTIONS <tier_limit>` clause applied per the Tier Table. Provisioning script asserts grant scope and connection limit before declaring success.
- [ ] **STATE-04**: Each site uses a unique random admin username (`admin_<8hex>`) — never `admin`. Override flag available.

### Performance / Caching

- [ ] **PERF-01**: `redis-cache` plugin (Till Krüss) baked into provisioning; activated automatically with `WP_REDIS_DATABASE` (per-site index) AND `WP_REDIS_PREFIX` (slug) set in `wp-config.php`.
- [ ] **PERF-02**: Page-cache strategy documented: Cloudflare Cache Rules + Super Page Cache for Cloudflare plugin. CLI prints the cookie-bypass rule the user must paste into Cloudflare.
- [ ] **PERF-03**: `DISABLE_WP_CRON=true` in every site's `wp-config.php`; provisioning script registers a host crontab line per site with a deterministic offset (slug-hash mod) to stagger wp-cron runs.
- [ ] **PERF-04**: Host cron `wp-metrics-poll` runs every minute, samples `docker stats --no-stream` JSON + per-site MariaDB connection count, and writes a rolling 24h peak per site (mem%, CPU%, DB conn) to `/opt/wp/state/metrics.json`. Drops samples older than 24h on each write. Sample run completes in < 200 ms.

### Coexistence / Hardening

- [ ] **HARD-01**: WP containers bind only to `127.0.0.1:<allocated-port>` — never `0.0.0.0`. Same for `wp-mariadb` (`127.0.0.1:13306`) and `wp-redis` (`127.0.0.1:16379`).
- [ ] **HARD-02**: XML-RPC disabled by default in every site's `wp-config.php`.
- [ ] **HARD-03**: Image pinning — every container references a specific tag, never `:latest`.

### Dashboard (thin)

- [ ] **DASH-01**: Single-page PHP dashboard showing per-site status, tier, current mem%, 24h-peak mem%, 24h-peak CPU%, 24h-peak DB-connection count, and "view logs" modal. Color-codes any peak ≥ 90% (yellow, "tier-up suggested") and ≥ 100% (red, "tier-up needed"). 5-second polling. Read-only by default.
- [ ] **DASH-02**: Dashboard "add site" and "delete site" buttons shell out to CLI via narrow sudoers whitelist (no docker socket mount).
- [ ] **DASH-03**: Dashboard runs in its own container behind host Caddy basic auth.

### Documentation

- [ ] **DOC-01**: README explains: installation, prerequisites (Caddy + Cloudflare assumptions), full lifecycle of one site (create → live → delete).
- [ ] **DOC-02**: Caddy snippet template included; one-page guide for paste-into-Caddy + Cloudflare DNS rows.
- [ ] **DOC-03**: Scaling-cliff doc: warning signs that single-VM design has been outgrown. Sign #1 = a single site sustained-needs > `xl` tier (i.e., 24h-peak mem stays at 100% on `xl`). Sign #2–4 = MariaDB connection saturation, AudioStoryV2 OOM-kills, disk > 70%.

## v2 Requirements

Deferred. Tracked, not in current roadmap.

### Operations

- **OPS2-01**: `wp-update --all` — update WP core / plugins / themes across all sites in one command.
- **OPS2-02**: `wp-health` — HTTP HEAD check per site, surfaces 5xx / unreachable.
- **OPS2-03**: `wp-disk` — per-site disk usage breakdown (uploads, DB).
- **OPS2-04**: `wp-stats --top` — rank by request rate (parses access logs).
- **OPS2-05**: Maintenance-mode shortcut.

### Future

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
| Backup / restore tooling (`wp-backup`, `wp-restore`, `--archive`, S3 offload) | Out of scope — operator handles backups out-of-band (e.g., `wp-exec <site> wp db export`, host-level snapshots, or Cloudflare/managed backups) |
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
| CLI-08 | Phase 2 | Pending |
| CLI-09 | Phase 2 | Pending |
| CLI-10 | Phase 2 | Pending |
| CLI-11 | Phase 2 | Pending |
| CLI-14 | Phase 2 | Pending |
| CLI-15 | Phase 2 | Pending |
| CLI-16 | Phase 2 | Pending |
| CLI-17 | Phase 2 | Pending |
| STATE-01 | Phase 2 | Pending |
| STATE-02 | Phase 2 | Pending |
| STATE-03 | Phase 2 | Pending |
| STATE-04 | Phase 2 | Pending |
| PERF-01 | Phase 2 | Pending |
| PERF-02 | Phase 2 | Pending |
| PERF-03 | Phase 3 | Pending |
| PERF-04 | Phase 3 | Pending |
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
- v1 requirements: 38 total
- Mapped to phases: 38 ✓
- Unmapped: 0

### By Phase

| Phase | Count | Requirements |
|-------|-------|--------------|
| Phase 1: Foundation | 14 | INFRA-01..06, IMG-01..06, HARD-01, HARD-03 |
| Phase 2: CLI Core + First Site E2E | 20 | CLI-01..06, CLI-08..11, CLI-14..17, STATE-01..04, PERF-01, PERF-02, HARD-02 |
| Phase 3: Operational Tooling | 2 | PERF-03, PERF-04 |
| Phase 4: Polish — Dashboard + Docs | 6 | DASH-01..03, DOC-01..03 |

---
*Requirements defined: 2026-04-30*
*Last updated: 2026-04-30 after roadmap creation (traceability populated)*
