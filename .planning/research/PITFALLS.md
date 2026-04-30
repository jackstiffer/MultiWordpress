# Pitfalls — Multi-WordPress on Shared GCP VM

Concrete gotchas specific to this architecture (per-site WP container, shared MariaDB + Redis, host Caddy, coexisting with AudioStoryV2). Each pitfall lists warning signs, prevention, severity, and target phase.

Severity scale:
- **NOW** — bites on day one if not handled
- **SCALE** — bites between site #5 and #20
- **FUTURE** — bites past site #20 / under load

---

## 1. Resource Starvation

### 1.1 PHP-FPM child explosion (one bad plugin → OOM cascade)
- **Warning**: VM `dmesg` shows OOM kills; AudioStoryV2 container restarts; `docker stats` shows one `wp-*` at >500 MB.
- **Prevention**:
  - Per-container hard limit: `mem_limit: 384m`, `mem_reservation: 128m` in compose. WP cluster ceiling = 4 GB shared between MariaDB (1 GB), Redis (256 MB), and ~6–8 sites at 384 MB each.
  - php-fpm pool: `pm = ondemand`, `pm.max_children = 5`, `pm.process_idle_timeout = 10s`, `pm.max_requests = 500` (recycles workers, defeats memory leaks).
  - `request_terminate_timeout = 30s` to kill runaway PHP processes.
- **Severity**: NOW
- **Phase**: Foundation (compose template), CLI Core (per-site override file)

### 1.2 Shared MariaDB lock-up from one site's slow query
- **Warning**: All sites slow simultaneously; `SHOW PROCESSLIST` shows queries from one DB blocking; `innodb_lock_waits` climbing.
- **Prevention**:
  - `max_execution_time = 30000` (ms) in `my.cnf` — kills runaway queries.
  - Enable slow query log: `slow_query_log = 1`, `long_query_time = 2`, log-rotated to 10 MB.
  - `wp-stats --slow` surfaces top offenders; `wp-exec <site> wp transient delete --all` is the usual fix.
  - InnoDB buffer pool sized 512 MB now, scale to 1 GB at 10+ sites. Don't over-allocate — Next.js needs RAM too.
- **Severity**: SCALE
- **Phase**: Foundation (my.cnf template), Operational Tooling (slow-log surfacing)

### 1.3 Redis cache thrash from wrong eviction
- **Warning**: Cache hit rate < 80% in `redis-cli info stats`; sites slow despite cache plugin "active".
- **Prevention**:
  - `maxmemory 256mb`, `maxmemory-policy allkeys-lru` (NOT `volatile-lru` — WP doesn't always set TTLs).
  - Per-site Redis DB index (0–15 default; bump `databases 64` once site count ≥ 12).
  - Object cache plugin: `redis-cache` (Till Krüss) — set `WP_REDIS_DATABASE = N` per site in `wp-config.php`.
- **Severity**: NOW
- **Phase**: Foundation (redis.conf), CLI Core (wp-create injects DB index)

### 1.4 Log files filling disk despite docker caps
- **Warning**: `df -h` shows root volume creeping past 80%; rotated docker log caps in place but disk still grows.
- **Prevention**:
  - Docker driver caps (10 MB × 3) cover stdout/stderr — already locked in.
  - **Inside-container WordPress logs** are the gap: `wp-content/debug.log`, php-fpm error log, nginx access log if used. Mount logrotate config or use size-based truncation:
    - Set `WP_DEBUG_LOG = false` in production unless actively debugging.
    - php-fpm: `error_log = /proc/self/fd/2` (sends to docker driver, inheriting the 10 MB cap).
    - If using internal nginx in WP container: `access_log off` for static assets, structured 10 MB rotate for the rest.
  - Provisioning script bakes these into every new site's wp-config.php and php.ini.
- **Severity**: SCALE
- **Phase**: Foundation (image), CLI Core (per-site config bake)

### 1.5 wp-cron storms across N sites
- **Warning**: Spiky CPU every minute at :00 across all sites; burst MariaDB connection count.
- **Prevention**:
  - Per-site `wp-config.php`: `define('DISABLE_WP_CRON', true)`.
  - Single host crontab runs `wp cron event run --due-now` per site, **staggered**: site1 at :00, site2 at :05, etc.
  - Provisioning script registers each new site's crontab line with a deterministic offset based on slug hash.
- **Severity**: SCALE
- **Phase**: CLI Core (wp-create injects DISABLE_WP_CRON + registers staggered host cron)

---

## 2. WordPress-Specific Gotchas

### 2.1 `WP_HOME` / `WP_SITEURL` baked into DB
- **Warning**: Renaming a site domain breaks every link; serialized PHP in DB needs `wp search-replace`.
- **Prevention**: Define `WP_HOME` and `WP_SITEURL` in `wp-config.php` from env, not in DB. Make domain change a no-op (env update + `docker compose up -d`).
- **Severity**: SCALE
- **Phase**: CLI Core (wp-config.php template)

### 2.2 Bloated `wp_options` autoload
- **Warning**: First page load >2s for logged-in admin; `SELECT autoload, COUNT(*) FROM wp_options WHERE autoload='yes' GROUP BY autoload;` shows >5,000 rows.
- **Prevention**:
  - Provisioning bakes a "no-junk" baseline: only essential plugins active.
  - `wp-stats --bloat` (later phase) surfaces autoload size per site.
  - Document recommended cleanup: `wp transient delete --expired`.
- **Severity**: FUTURE
- **Phase**: Operational Tooling (later)

### 2.3 File uploads stored in DB (legacy plugins)
- **Warning**: `mariadb` data volume balloons faster than `wp-content/uploads` dir.
- **Prevention**: Document recommended plugin set; warn against "DB-based media library" plugins.
- **Severity**: FUTURE
- **Phase**: Docs

---

## 3. Multi-Site-on-Shared-DB Pitfalls

### 3.1 DB user grants too broad
- **Warning**: `wp_site1` user can `SHOW DATABASES` and see other sites' DBs; security audit fail.
- **Prevention**:
  - `CREATE USER 'wp_<slug>'@'%' IDENTIFIED BY '<pw>'; GRANT ALL ON wp_<slug>.* TO 'wp_<slug>'@'%';` — exact pattern, no wildcards.
  - Provisioning script asserts grant scope before declaring success: `SHOW GRANTS FOR 'wp_<slug>'@'%';` must show only one DB.
- **Severity**: NOW (security)
- **Phase**: CLI Core (wp-create asserts grants)

### 3.2 Connection pool exhaustion
- **Warning**: `Too many connections` errors during traffic spike; `SHOW STATUS LIKE 'Threads_connected';` near `max_connections`.
- **Prevention**:
  - `max_connections = 200` in my.cnf (default 151 is too low for 10+ sites).
  - WordPress `WP_DB_PERSISTENT_CONNECTIONS = false` — persistent connections are an anti-pattern with shared DB.
  - Page cache (next section) is the real fix — uncached page = 5–10 DB connections.
- **Severity**: SCALE
- **Phase**: Foundation (my.cnf)

### 3.3 Backup that locks all DBs
- **Warning**: Sites slow during nightly backup; `mysqldump --all-databases` holds global READ lock.
- **Prevention**:
  - Per-site `mysqldump --single-transaction --quick wp_<slug>` — InnoDB-friendly, no global lock.
  - `wp-backup` iterates one site at a time, not parallel.
- **Severity**: SCALE
- **Phase**: Operational Tooling (wp-backup)

---

## 4. Docker / Host Pitfalls

### 4.1 Restart storm after VM reboot
- **Warning**: VM reboots → all WP containers + MariaDB + Next.js boot simultaneously → 2–3 min outage; some containers fail healthcheck and crash-loop.
- **Prevention**:
  - All containers `restart: unless-stopped`.
  - MariaDB / Redis have `healthcheck` blocks; WP containers `depends_on: { wp-mariadb: { condition: service_healthy } }`.
  - Stagger startup with `restart_policy.delay` — not strictly needed at this scale but plan for it.
- **Severity**: NOW
- **Phase**: Foundation

### 4.2 `:latest` image tags
- **Warning**: `docker pull` silently picks up a breaking WP/PHP update; one site randomly broken after reboot.
- **Prevention**: Pin every image: `wordpress:6.7-php8.3-fpm-alpine`, `mariadb:11.4`, `redis:7-alpine`. Bump deliberately.
- **Severity**: SCALE
- **Phase**: Foundation

### 4.3 Bind mount UID/GID mismatch
- **Warning**: WP can't write to `wp-content/uploads`; "Failed to open stream: Permission denied" in error log.
- **Prevention**:
  - Image runs as `www-data` (UID 33). Provisioning script `chown -R 33:33 /opt/wp/sites/<slug>/wp-content` after creating the dir.
  - Document the UID expectation in CLI README.
- **Severity**: NOW
- **Phase**: CLI Core

### 4.4 Docker socket mounted = root-on-host
- **Warning**: Dashboard container has `/var/run/docker.sock` mounted; any RCE in dashboard PHP = full host compromise.
- **Prevention**:
  - **Do not mount the docker socket into the dashboard.** Dashboard shells out via a narrow sudo-wrapper script (`/usr/local/bin/wp-dashboard-exec`) that whitelists exact commands.
  - Or use `tecnativa/docker-socket-proxy` with read-only `CONTAINERS=1, INFO=1` — but adds a container; sudo-wrapper is leaner.
- **Severity**: NOW
- **Phase**: Polish (dashboard)

### 4.5 GCP MTU mismatch (1460 vs 1500)
- **Warning**: Random TLS handshake failures, slow large DB queries, Cloudflare "522 Connection Timed Out".
- **Prevention**:
  - GCP VPCs use MTU 1460 by default. Docker bridge defaults to 1500 → packet fragmentation on egress.
  - In compose: `networks.wp-network.driver_opts: { com.docker.network.driver.mtu: "1460" }`.
- **Severity**: NOW (specific to GCP)
- **Phase**: Foundation

---

## 5. Coexistence with AudioStoryV2

### 5.1 Port collision
- **Warning**: `docker compose up` fails with "port is already allocated" because port 3000 / 6379 / 80 / 443 is taken.
- **Prevention**:
  - WP containers bind to `127.0.0.1:<auto-allocated-port>` — port pool starts at 18000, allocated by CLI from `state/sites.json`. Never publish to `0.0.0.0`.
  - Shared `wp-redis` on `127.0.0.1:16379` (not 6379 — that's AudioStoryV2's).
  - `wp-mariadb` on `127.0.0.1:13306`.
- **Severity**: NOW
- **Phase**: Foundation (port plan), CLI Core (allocator)

### 5.2 Memory pressure spilling into Next.js
- **Warning**: AudioStoryV2 OOM-killed; `dmesg | grep -i killed`.
- **Prevention**:
  - Hard `mem_limit` on every WP container + MariaDB + Redis. Sum ≤ 4 GB.
  - One-time check post-deploy: `docker stats --no-stream` should show WP cluster ≤ 50% of 8 GB.
  - Alert: dashboard flags red if cluster total > 4 GB.
- **Severity**: NOW
- **Phase**: Foundation, Operational Tooling

### 5.3 Disk IO contention
- **Warning**: Both stacks slow during peak; `iostat -x 1` shows >80% utilization.
- **Prevention**:
  - WP cluster on separate Docker volume if possible (single VM, single disk — limited mitigation).
  - Page cache (next section) drastically reduces disk IO.
  - GCP boot disk type: SSD (already default for n2 family) — confirm.
- **Severity**: FUTURE
- **Phase**: monitor only

---

## 6. Provisioning Script Pitfalls

### 6.1 Half-provisioned site on failure
- **Warning**: `wp-create` fails midway; container exists but DB doesn't, or vice versa; re-running gives "site already exists" but it's broken.
- **Prevention**:
  - Three rollback points (per ARCHITECTURE.md): (1) DB created → trap drops DB; (2) dirs created → trap removes dirs; (3) container booted → trap removes container.
  - `set -euo pipefail` + `trap rollback ERR` at the top of `wp-create`.
  - Final step: write to `state/sites.json` only after WP `wp core install` succeeds. Until then the site doesn't "exist" from the CLI's view.
- **Severity**: NOW
- **Phase**: CLI Core

### 6.2 Concurrent `wp-create` race
- **Warning**: Two `wp-create` calls allocate the same port; second container fails to start.
- **Prevention**: Lockfile around port allocation: `flock /var/lock/wp-create.lock <port-allocator>`. Idempotency token check: refuse if `state/sites.json` already has slug.
- **Severity**: SCALE
- **Phase**: CLI Core

### 6.3 Idempotent re-run
- **Warning**: User re-runs `wp-create blog.example.com` after a partial failure; gets confused error.
- **Prevention**: `wp-create --resume <slug>` continues from last-completed step. State machine in `state/sites.json` per site: `db_created → dirs_created → container_booted → wp_installed → finalized`.
- **Severity**: SCALE
- **Phase**: CLI Core (later iteration)

### 6.4 Secret leakage to shell history
- **Warning**: `history | grep -i password` shows admin creds.
- **Prevention**:
  - `wp-create` writes admin pass to `state/sites/<slug>/.env` (mode 600), prints to stdout once with bold "save this — not stored in shell history" warning.
  - `wp-list --secrets <slug>` re-reads from file (not regenerable).
  - Never accept passwords as CLI args; always generate.
- **Severity**: NOW
- **Phase**: CLI Core

### 6.5 Silent slug collision
- **Warning**: Existing site overwritten because slug derivation is sloppy.
- **Prevention**: Slug = sanitized domain (`blog.example.com` → `blog_example_com`). `wp-create` errors out hard if slug exists in `state/sites.json`. No `--force` flag.
- **Severity**: NOW
- **Phase**: CLI Core

---

## 7. Performance Pitfalls (the "lightning fast" claim)

### 7.1 Object cache without page cache
- **Warning**: TTFB ~400 ms even for logged-out homepage; cache plugin "active" but pages still hit PHP.
- **Prevention**:
  - Object cache (Redis) handles DB; page cache handles PHP. Both needed.
  - Pick ONE page cache: **Cloudflare Cache Rules** (zero overhead, infra you already have). Set rule: cache `*.html` for logged-out via cookie check (`! (http.cookie contains "wordpress_logged_in")`).
  - Backup option: WP Super Cache plugin in "Expert" mode writing static HTML to disk (Caddy serves directly).
  - Document: do NOT enable both Cloudflare cache AND a WP page-cache plugin → cache poisoning.
- **Severity**: NOW (defines whether the project meets its core promise)
- **Phase**: First Site E2E (validate cache strategy on first real domain)

### 7.2 Logged-out cookies busting cache
- **Warning**: Cloudflare reports cache hit ratio < 50%; visitors with `wp-settings-*` cookies get uncached responses.
- **Prevention**:
  - WP doesn't set `wordpress_logged_in_*` until login. The risk is plugins setting tracking cookies pre-login.
  - Cloudflare Cache Rule: explicitly bypass cache only when `wordpress_logged_in_*` is set, and ignore other cookies.
- **Severity**: SCALE
- **Phase**: First Site E2E (docs)

### 7.3 Mobile/desktop split caches
- **Warning**: Cache hit ratio halved without reason.
- **Prevention**: Modern WP themes are responsive — no need for separate mobile cache. Disable any plugin that uses User-Agent-aware caching.
- **Severity**: FUTURE
- **Phase**: Docs

---

## 8. Operational Pitfalls

### 8.1 Untested backups
- **Warning**: Restore needed → backup is corrupt, missing files, or restore script broken.
- **Prevention**:
  - `wp-restore` is shipped Phase 1 alongside `wp-backup`.
  - CI-style smoke test: `wp-backup site1 → wp-create site1-restored --from-backup → wp-delete site1-restored`. Run weekly via cron.
- **Severity**: NOW
- **Phase**: Operational Tooling

### 8.2 Dashboard polling overhead
- **Warning**: Dashboard tab open = 5% sustained CPU on idle VM.
- **Prevention**:
  - Polling interval ≥ 5 seconds. Cache `docker stats --no-stream` output for 4 seconds server-side so multiple clients reuse one sample.
  - No SSE / websockets — overkill for solo-owner internal tool.
- **Severity**: SCALE
- **Phase**: Polish

### 8.3 Forgotten Caddy edits on `wp-delete`
- **Warning**: Site deleted but Caddy still routes to dead container → 502s for visitors who cached DNS.
- **Prevention**: `wp-delete` prints the exact Caddy block to remove and the Cloudflare DNS rows to delete, with checkboxes the user can tick. Optional `wp-delete --print-only` does this without deleting.
- **Severity**: NOW
- **Phase**: CLI Core

### 8.4 No way to identify the noisy neighbor
- **Warning**: Stack hot, but `docker stats` shows a few mid-range hogs — not obvious which site is the cause of *user-perceived* slowness.
- **Prevention**: `wp-stats --top` ranks by CPU + by request rate (parsing access logs). Phase 2 dashboard surfaces same.
- **Severity**: SCALE
- **Phase**: Operational Tooling, Polish

---

## 9. Security Pitfalls (single-owner, but still)

### 9.1 Default `admin` username
- **Warning**: Brute-force attempts hammering `/wp-login.php`.
- **Prevention**: Provisioning generates a random admin username (`admin_<8hex>`) — not `admin`. Document override flag if user wants a known username.
- **Severity**: NOW
- **Phase**: CLI Core

### 9.2 XML-RPC / REST API exposure
- **Warning**: 5 MB/min of XML-RPC pingback requests.
- **Prevention**: `wp-config.php` baseline: `add_filter('xmlrpc_enabled', '__return_false');`. Cloudflare WAF rule: block `/xmlrpc.php`.
- **Severity**: NOW
- **Phase**: CLI Core (config baseline)

### 9.3 PHP execution in uploads dir
- **Warning**: Compromised plugin uploads `shell.php` to `wp-content/uploads/` and executes it.
- **Prevention**: php-fpm config: deny `.php` execution under `/wp-content/uploads/`. Bake into image:
  ```
  location ~* /wp-content/uploads/.*\.php$ { deny all; }
  ```
- **Severity**: NOW
- **Phase**: Foundation (image)

### 9.4 Cross-site DB read via shared MariaDB
- **Warning**: One site compromise → attacker uses DB user to access others.
- **Prevention**: Strict per-site grants (§3.1). Each site's `wp-config.php` has only its own DB user; can't pivot.
- **Severity**: SCALE
- **Phase**: CLI Core (already covered by 3.1)

---

## 10. Scaling Cliff

### When this single-VM design breaks
- **Site #15–20**: MariaDB buffer pool needs to grow past 1 GB; consider bumping VM to n2-standard-4 (4 vCPU, 16 GB).
- **Total RPS > 50** (logged-out, served by PHP): page cache is mandatory; Cloudflare or WP Super Cache.
- **One site needs >1 GB RAM**: it doesn't belong on this design — split it to a dedicated VM.
- **Backups taking > 30 min**: time to introduce S3 offload (out of scope; warn in docs).
- **Dashboard polling docker stats causes measurable CPU**: site count probably ≥ 30; time to migrate dashboard to read pre-computed metrics file written by a host cron.

### Warning signs you've outgrown it
- AudioStoryV2 starts getting OOM-killed weekly even with limits in place.
- WP cluster sustained CPU > 60% with caches warm.
- MariaDB connection count regularly hits 200.
- Disk usage > 70% of boot disk and growing.

When two of those four are true: stop adding sites; start planning a horizontal split (DB on managed Cloud SQL, sites on a second VM).

---

## Phase Mapping Summary

| Pitfall | Phase |
|---|---|
| 1.1 PHP-FPM explosion, 1.3 Redis eviction, 1.4 logs, 4.1 restart storm, 4.2 image pinning, 4.5 GCP MTU, 5.1 ports, 5.2 mem limits, 7.1 cache strategy, 9.3 PHP in uploads | **Foundation** |
| 1.2 slow query, 2.1 WP_HOME, 3.1 grants, 4.3 UID/GID, 6.1–6.5 provisioning robustness, 8.3 Caddy cleanup, 9.1 admin user, 9.2 XML-RPC | **CLI Core** |
| 7.1 cache validation, 7.2 Cloudflare cookie rule | **First Site E2E** |
| 1.4 internal log rotation, 1.5 cron stagger, 3.3 backup locks, 8.1 backup test, 8.4 noisy-neighbor surfacing | **Operational Tooling** |
| 4.4 docker socket, 8.2 polling overhead | **Polish (Dashboard)** |
| 2.2, 2.3, 7.3, scaling cliff | **Docs / Future** |

---

## Confidence Notes

- HIGH confidence: containerization patterns, MariaDB grants, Redis eviction, WordPress security hardening — all well-trodden ground.
- MEDIUM confidence: GCP MTU specifics (1460 default in default VPC; verify your VPC's MTU before deploying — `gcloud compute networks describe default --format='value(mtu)'`).
- MEDIUM confidence: exact thresholds for the scaling cliff — these are estimates based on n2-standard-2 + WordPress 6.x typical workload; revisit after observing first 10 sites under real traffic.
