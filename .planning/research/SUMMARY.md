# Project Research Summary

**Project:** MultiWordpress
**Domain:** Lightweight multi-tenant WordPress hosting on a single shared GCP VM (per-site container, shared MariaDB + Redis, host Caddy + Cloudflare in front)
**Researched:** 2026-04-30
**Confidence:** HIGH

---

## Locked Stack (instant reference)

```
Per-site WP container : wordpress:6-php8.3-fpm-alpine   (PHP 8.3, FPM-only, no Apache/nginx in image)
Shared DB             : mariadb:lts                     (currently 11.4 LTS — Ubuntu Noble base; NO Alpine)
Shared object cache   : redis:7-alpine                  (separate container from AudioStory's redis)
WP-CLI                : baked into per-site image at /usr/local/bin/wp (PHAR)
Image processing      : GD only  (skip Imagick)
PHP                   : OPcache ON (96M, jit=disable, validate_timestamps=1, revalidate=60s)
php-fpm pool          : pm=ondemand, max_children=6, idle_timeout=30s, max_requests=500
MariaDB               : innodb_buffer_pool_size=384M, max_connections=100..200, utf8mb4
Redis                 : --maxmemory 256mb --maxmemory-policy allkeys-lru --save "" --appendonly no
Page cache            : Cloudflare Cache Rules (free) + Super Page Cache for Cloudflare plugin (free)
Object cache plugin   : redis-cache (Till Krüss, free) — NOT Object Cache Pro
Reverse proxy         : EXISTING host Caddy (out of stack); reaches WP via 127.0.0.1:18000+ (FastCGI)
TLS                   : Host Caddy auto-HTTPS (Let's Encrypt) — nothing for our stack to do
Logging               : json-file driver, max-size=10m, max-file=3 on EVERY service (matches AudioStoryV2)
Network               : single user-defined bridge `wp-network`, isolated from `audiostory_app-network`
MTU                   : 1460 on `wp-network` (GCP VPC default — Docker default 1500 fragments)
Mem limits per WP site: mem_limit=384m..512m, mem_reservation=128m
```

**RAM math (10 sites, peak):** ≤ 2.0 GB → fits inside the 4 GB / 50%-of-host budget with headroom.

---

## Executive Summary

MultiWordpress is a thin, opinionated **CLI-first provisioning layer** over a well-trodden Docker pattern: per-site `wordpress:fpm-alpine` containers sharing one MariaDB and one Redis, fronted by the host's existing Caddy + Cloudflare. The tool's identity is what it explicitly *won't* do — no auto-DNS, no Caddy edits, no per-site reverse proxy, no staging, no panel features. Provisioning, deletion, backup/restore, and stats are CLI verbs; an optional thin PHP dashboard polls a JSON endpoint and shells out to those same verbs (CLI is the source of truth).

The recommended approach is high-confidence and well-trodden: official `wordpress:6-php8.3-fpm-alpine` per site, shared `mariadb:lts` with one DB+user per site, shared `redis:7-alpine` for object caching, and Cloudflare Cache Rules + the free Super Page Cache plugin to make logged-out reads near-static-file fast (which is what makes the RAM math work at 10+ sites). PHP-FPM `pm=ondemand` is the load-bearing decision that keeps idle sites near-zero RAM cost.

The day-one risks are concrete and bounded: PHP-FPM child explosion under load, GCP MTU mismatch, port collision with AudioStoryV2, half-provisioned sites on script failure, log files filling disk despite docker caps (the gap is *inside-container* WP/php-fpm logs, not stdout), and the cache strategy not actually delivering the "lightning fast" promise. Each has a known mitigation called out in the relevant phase.

---

## Five Decisions That Shape Every Phase

1. **Per-site WordPress container, shared MariaDB + Redis.** Isolation where it matters (own files, own DB user, own WP version) without paying the EasyEngine "container per concern per site" tax. Defines the entire compose layout.
2. **No reverse proxy in our stack.** Host Caddy already terminates TLS for AudioStoryV2; WP sites bind to `127.0.0.1:<allocated-port>` (18000+) and Caddy reverse-proxies to that. The CLI **prints** the Caddy snippet — never edits Caddy itself.
3. **CLI is the source of truth; dashboard is a thin viewer.** All write operations live in `/opt/wp/bin/*`. Dashboard shells out via narrow sudoers whitelist — **never** mounts the docker socket.
4. **Cloudflare absorbs read traffic; FPM serves the rest.** Page cache lives at Cloudflare's edge (Cache Rules, free) with a plugin issuing `Cache-Control` + cookie-bypass for logged-in users. Without this, the RAM budget for 10+ sites doesn't close.
5. **10 MB / 3-file log cap on every surface — including inside the container.** Docker driver caps stdout/stderr; the gap is WP `debug.log` and php-fpm error log, which must be redirected to `/proc/self/fd/2` so they inherit the docker driver's rotation.

---

## Key Findings

### Recommended Stack

Official images only, FPM-only WordPress (no Apache/nginx bundled), MariaDB on Ubuntu base (NOT Alpine — upstream MariaDB does not test on musl), Redis 7-alpine, no proxy in our stack. PHP 8.3 over 8.4 for plugin compatibility (perf delta <2%); JIT off because WP is I/O-bound. See [STACK.md](./STACK.md) for `php.ini`, `my.cnf`, and `php-fpm` snippets ready to copy.

**Core technologies:**
- `wordpress:6-php8.3-fpm-alpine` — per-site WP runtime (~30–50 MB idle RSS, official, multi-arch).
- `mariadb:lts` (11.4) — shared DB; one DB + one user per site, scoped grants.
- `redis:7-alpine` — shared object cache; **separate container** from AudioStory's redis.
- `redis-cache` plugin (Till Krüss, free) — NOT Object Cache Pro ($95/mo, unjustified at this scale).
- Cloudflare Cache Rules + Super Page Cache for Cloudflare (free) — page-cache layer.
- WP-CLI baked into the per-site image (10 MB PHAR; multiplies CLI tooling later).
- Host Caddy (existing, untouched).

### Expected Features

See [FEATURES.md](./FEATURES.md) for full landscape.

**Must have (Phase 1):** `wp-create`, `wp-delete` (with `--archive`), `wp-list`, `wp-stats`, `wp-logs`, `wp-backup`/`wp-restore`, `wp-exec` (wp-cli passthrough — cheap, unlocks Phase 2), site registry + per-site `.env` mode 600, log rotation on every surface.

**Should have (Phase 2):** `wp-update --all`, `wp-health`, `wp-disk`, maintenance-mode shortcut, thin PHP dashboard (single-page status table, 5s polling, modal log viewer, sudoers-whitelisted writes).

**Defer (Phase 3+):** S3 offsite backup, `wp-rename`, notifications, per-site PHP version. **Skip permanently:** auto-DNS, auto-Caddy, multi-tenant/billing, web shell, marketplace, scanner, auto-updates, staging/clone, slow-query UI, log aggregation.

### Architecture Approach

Single user-defined bridge (`wp-network`). Each site is one container bound to `127.0.0.1:18000+`; host Caddy reverse-proxies. Shared infra in one `compose/compose.yaml`; each site in its own generated `sites/<slug>/compose.yaml` referencing the external network. Bind-mount **only `wp-content`** per site (WP core stays in the image). Named volume for MariaDB. Dashboard is a separate container behind Caddy basic auth, calling CLI via narrow sudoers whitelist (no docker socket).

**Major components:** (1) Shared infra (`wp-mariadb`, `wp-redis`, `wp-network`); (2) per-site WP container; (3) CLI tools in `/opt/wp/bin/`; (4) State + secrets (`/opt/wp/state/sites.json`, `/opt/wp/secrets/<slug>.env`); (5) optional thin PHP dashboard.

### Critical Pitfalls (Top 5 day-one)

1. **GCP MTU 1460 vs Docker 1500** — random TLS failures, CF 522s. Set `com.docker.network.driver.mtu: "1460"` on `wp-network`.
2. **Port collision with AudioStoryV2** — bind ONLY to `127.0.0.1:18000+` from CLI registry; `wp-mariadb` on `127.0.0.1:13306`, `wp-redis` on `127.0.0.1:16379`. Never `0.0.0.0`.
3. **Memory pressure spilling into Next.js** — hard `mem_limit` per container, sum ≤ 4 GB. PHP `memory_limit=256M`, `pm=ondemand`, `max_children=5–6`.
4. **Inside-container log fill** — Docker driver caps stdout but WP `debug.log` and php-fpm error log are *files inside the container*. Set `WP_DEBUG_LOG=/proc/self/fd/2` and php-fpm `error_log = /proc/self/fd/2`.
5. **Cache strategy not actually fast** — object cache (Redis) alone leaves TTFB ~400ms. Cloudflare Cache Rules + Super Page Cache plugin is what delivers the promise. Validate on first real domain. Do NOT stack APO + Cache Everything (verified anti-pattern).

---

## Reconciling Cross-Document Disagreements

**Contradiction A — Per-site image shape:** ARCHITECTURE.md proposed nginx+php-fpm in one container; STACK.md proposed FPM-only with host Caddy speaking FastCGI. **Resolution: STACK.md wins** — FPM-only keeps the image to ~80 MB, avoids two-processes-per-container, and Caddy speaks FastCGI natively. Sites publish FPM port 9000 on `127.0.0.1:18000+` and Caddy talks FastCGI to loopback.

**Contradiction B — Redis multi-site isolation:** ARCHITECTURE.md said per-site DB index + prefix; STACK.md said prefix only on shared DB 0 (Redis upstream discourages multi-DB). **Resolution: belt and suspenders — set both** `WP_REDIS_DATABASE` AND `WP_REDIS_PREFIX`. DB index gives free `FLUSHDB` per site; prefix protects against plugins that bypass the DB setting. PITFALLS.md §1.3 implicitly takes this position.

---

## Implications for Roadmap

ARCHITECTURE.md proposes 5 phases; FEATURES.md proposes 2+. They reconcile cleanly: FEATURES.md's Phase 1 = ARCHITECTURE.md's Phases 1–3 combined.

### Phase 1 — Foundation (shared infra + image)
**Rationale:** Day-one pitfalls all live here. **Delivers:** `compose/compose.yaml` (healthchecked, capped logs, MTU 1460), per-site Dockerfile + php.ini + php-fpm pool, image template files. **Avoids pitfalls:** 1.1, 1.3, 1.4, 4.1, 4.2, 4.5, 5.1, 5.2, 9.3.

### Phase 2 — CLI Core (provisioning + teardown + registry)
**Rationale:** With infra up, CLI makes the project useful. `wp-exec` early unlocks every later wrapper. **Delivers:** `/opt/wp/bin/{wp-create, wp-delete, wp-list, wp-stats, wp-logs, wp-backup, wp-restore, wp-exec}`, `state/sites.json` + lockfile, port + redis-DB allocator, secrets generator, rollback traps, snippet templates. **Avoids:** 2.1, 3.1, 4.3, 6.1–6.5, 8.3, 9.1, 9.2.

### Phase 3 — First Site End-to-End (validate the cache promise)
**Rationale:** Provision one real domain through the CLI built in Phase 2. Where "lightning fast" is *proved* — Cloudflare Cache Rule + Super Page Cache + cookie bypass. Don't add the 2nd site until the 1st is fast. **Avoids:** 7.1, 7.2.

### Phase 4 — Operational Tooling
**Rationale:** Add verbs that make 5+ sites painless; backup correctness validated here. **Delivers:** `wp-update --all`, `wp-health`, `wp-disk`, maintenance-mode shortcut, `wp-stats --top`, weekly backup-restore smoke test, staggered host cron for `wp-cron`. **Avoids:** 1.4, 1.5, 3.3, 8.1, 8.4.

### Phase 5 — Polish (dashboard)
**Rationale:** Last because it depends on stable CLI. Read-only first; writes via sudoers whitelist (no docker socket). **Avoids:** 4.4, 8.2.

### Phase Ordering Rationale
- Foundation first — every pitfall list starts there; MTU/port/mem/log decisions are load-bearing.
- CLI before first site — first site is the validator, not a hand-built precursor.
- First site E2E before more sites — cache strategy IS the core value claim.
- Backup before third site — data value climbs fast; untested backups are useless.
- Dashboard last — depends on stable CLI flag surface.

### Research Flags

| Phase | Flag | Why |
|---|---|---|
| 1 — Foundation | NEEDS RESEARCH | GCP MTU verification + Caddy↔FPM wiring details |
| 2 — CLI Core | standard patterns | Bash + docker + wp-cli — well-trodden |
| 3 — First Site E2E | NEEDS RESEARCH | Cloudflare Cache Rules + Super Page Cache config; cookie-bypass syntax |
| 4 — Operational Tooling | standard patterns | Each verb is a thin wrapper |
| 5 — Polish (dashboard) | possibly research | Sudoers patterns + safe shell-out from PHP |

---

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH | Versions verified against Docker Hub, MariaDB docs, WP.org, Cloudflare docs (April 2026). |
| Features | HIGH (CLI), MEDIUM (dashboard) | CLI mirrors EasyEngine/Dokku/CapRover. Dashboard UX informed but unvalidated. |
| Architecture | HIGH | Textbook pattern; two contradictions resolved above. |
| Pitfalls | HIGH (general), MEDIUM (GCP-specific) | Containerization/MariaDB/Redis well-known. GCP MTU + scaling thresholds need verification. |

**Overall confidence:** HIGH

### Open Questions / Gaps for Roadmapper

- **Caddy ↔ WP wiring exact form:** `php_fastcgi 127.0.0.1:<port>` (FPM TCP on loopback) is the recommended path; confirm in Phase 1.
- **GCP VPC MTU value:** confirm with `gcloud compute networks describe default --format='value(mtu)'` before locking compose.
- **Cloudflare Cache Rule cookie list:** exact list of WP cookies to bypass — validate with first real site.
- **Backup smoke-test cadence:** PROJECT.md doesn't specify; decide in Phase 4 (suggest weekly cron).
- **wp-cron stagger algorithm:** slug-hash modulo N suggested; settle in Phase 4.
- **Dashboard sudoers whitelist:** exact entries left for Phase 5 design.

---

## Sources

**Primary (HIGH):** Docker Hub official images; MariaDB / Redis / WordPress.org official docs; Cloudflare developer docs; AudioStoryV2 in-repo `compose.yaml`; `.planning/PROJECT.md`.
**Secondary (MEDIUM):** PHPBenchLab 2026 benchmarks; Kinsta blog (PHP 8 / OPcache / JIT); Tideways php-fpm tuning; EasyEngine / Dokku / CapRover / Coolify / Plesk WP Toolkit docs; Cloudflare community APO anti-pattern thread.
**Tertiary (LOW — verify):** Exact GCP VPC MTU; scaling-cliff thresholds (estimates).

---
*Research completed: 2026-04-30*
*Ready for roadmap: yes*
