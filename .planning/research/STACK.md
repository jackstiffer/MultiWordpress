# Stack Research

**Domain:** Lightweight multi-tenant WordPress hosting on a single shared VM (Docker Compose, host Caddy + Cloudflare in front)
**Researched:** 2026-04-30
**Confidence:** HIGH (versions verified against Docker Hub, MariaDB docs, WordPress.org, Cloudflare docs as of April 2026)

---

## TL;DR — Recommended Stack

- **Per-site image:** `wordpress:6-php8.3-fpm-alpine` (official, FPM-only, Alpine).
- **PHP:** 8.3 with **OPcache ON, JIT OFF**. (8.4 is fine but 8.3 is the sweet spot for plugin compatibility + perf.)
- **DB:** Single shared `mariadb:lts` (currently 11.4 LTS, Ubuntu Noble base — official). One DB + one user per site.
- **Object cache:** Single shared `redis:7-alpine` (separate from AudioStory's Redis), **allkeys-lru, 256 MB cap**, plus **`redis-cache` plugin (Till Krüss)** with **per-site `WP_REDIS_PREFIX`** (key-prefix isolation, NOT separate DB indexes).
- **Page cache:** **Cloudflare Cache Rules + a WordPress plugin that issues correct `Cache-Control` and purges on update** (recommended: **Super Page Cache for Cloudflare** by Optimole, free; alt: **WP Super Cache** for FastCGI-style on-disk static HTML). Cloudflare APO is optional (paid on free plan, ~$5/mo per zone).
- **Image processing:** **GD only** in the slim image. Skip Imagick.
- **WP-CLI:** Bake `wp` PHAR into the image as `/usr/local/bin/wp` (10 MB binary, free), or run a sidecar `wordpress:cli` container on demand from the host CLI.
- **php-fpm pool:** **`pm = ondemand`**, `pm.max_children = 6`, `pm.process_idle_timeout = 30s`, `pm.max_requests = 500`. ~50–80 MB idle per site.

**Total RAM budget at 10 sites:** ~1.0–1.6 GB WP containers + 0.5 GB MariaDB + 0.25 GB Redis + 0.5 GB headroom = **≤ 2.5 GB**, well under the 4 GB cap. Math shown at the end.

---

## Recommended Stack

### Core Technologies

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| `wordpress:6-php8.3-fpm-alpine` | WP 6.x + PHP 8.3 on Alpine 3.x | Per-site WP runtime (php-fpm only, no httpd) | Official image, FPM variant has **no Apache** so it stays slim (~80 MB image, ~30–50 MB idle RSS before traffic). Alpine base is musl-libc and roughly half the size of the Debian variant. The `6-php8.3-fpm-alpine` floating tag tracks the latest WP 6.x patch — pin to a digest in production. |
| `mariadb:lts` | 11.4 LTS (Ubuntu Noble) | Shared DB for all sites | LTS is supported until 2029. **Do not use Alpine MariaDB** — MariaDB explicitly does not test on musl libc and the official image has no Alpine variant. UBI9/Noble images are ~150 MB but proven. MariaDB > MySQL 8 here because (a) MariaDB resizes buffer pool in 1 MB increments since 11.4 (no `innodb_buffer_pool_chunk_size` rounding), (b) lower memory floor than MySQL 8 default, (c) plugin/feature parity for WP. |
| `redis:7-alpine` | 7.x | Shared object cache (separate container from AudioStory's redis) | Already proven in your AudioStoryV2 stack. Alpine = ~30 MB image. New container so we can isolate auth + DB from AudioStory and tune `maxmemory` independently. |
| **Host Caddy** (out of stack) | existing | TLS + reverse proxy to each `wp-<site>:9000` (FastCGI) | Already running. Use `php_fastcgi unix//var/run/php-fpm.sock` style — but since each WP container is its own service, expose tcp `9000` on the WP container and have Caddy do `php_fastcgi wp-<site>:9000` on the shared docker network. |
| Cloudflare (free tier, in front) | existing | Edge CDN + page cache | Free plan supports **Cache Rules** (Page Rules deprecated for new accounts as of Jan 2025). Free tier can do "Cache Everything" with cookie-bypass rules for logged-in users. |

### Per-Site WordPress Image — Image Comparison (decision: official)

| Image | Idle RSS (php-fpm only) | Pros | Cons | Verdict |
|-------|-------------------------|------|------|---------|
| `wordpress:6-php8.3-fpm-alpine` (official) | ~30–50 MB before traffic | Official, security-patched promptly, multi-arch (incl. arm64), trusted, simplest | Includes a few extensions you may not need (ships with both gd and imagick by default in some variants — verify per tag) | **CHOSEN** |
| `wodby/wordpress` | ~50–70 MB | Pre-tuned, opcache defaults set | Third-party, slower CVE response, opinionated (wants Wodby ecosystem) | Reject — opacity |
| `bitnami/wordpress` | ~150–200 MB (bundles Apache) | "Production" defaults | Bundles Apache → defeats FPM-only goal; large; Bitnami catalog churn | Reject — too heavy |
| `TrafeX/docker-wordpress` | ~40 MB | Nginx+FPM in one container | Bundles its own nginx (we don't want that — host Caddy is the proxy) | Reject — we don't want nginx-in-the-container |
| Custom slim Alpine + `php:8.3-fpm-alpine` + WP source | ~25–35 MB | Smallest possible | You own the security treadmill (apply WP and PHP CVEs yourself); little benefit over official | Reject — maintenance burden not worth ~10 MB |

**Anti-pattern called out:** Do not pick an image that bundles its own webserver (Apache or nginx) — that duplicates host Caddy and adds 30–80 MB per site for no benefit. The fpm-alpine variant is purpose-built for this layout.

### PHP / OPcache / JIT (per-site `php.ini` snippet)

PHP 8.3 (not 8.4 yet) is the recommended target. Reasons:
- WP core works on 8.4 but **a meaningful fraction of plugins still emit deprecation notices on 8.4** (`E_DEPRECATED` from `null`-typed parameters, etc.). 8.3 is the current "safe fast" tier.
- 8.3 vs 8.4 vs 8.5 perf delta on WordPress is **<1–2%** in benchmarks (WP is I/O-bound — DB and template render dominate). Verified via PHPBenchLab 2026 benchmarks.
- **JIT: OFF.** JIT helps CPU-heavy code (math, parsing). WP request-paths are I/O-bound; JIT adds memory and gives near-zero gains on WP, sometimes a small regression. Standard guidance from Kinsta and PHPBenchLab benchmarks.

```ini
; /usr/local/etc/php/conf.d/zz-wp.ini  (mounted into the container)
memory_limit = 256M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 60
expose_php = Off

; OPcache — biggest single perf win for WP
opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = 96      ; MB; 96 fits typical WP+plugins comfortably
opcache.interned_strings_buffer = 16  ; MB
opcache.max_accelerated_files = 10000 ; WP core ~3k + plugins
opcache.revalidate_freq = 60          ; seconds; production: 60–300
opcache.validate_timestamps = 1       ; keep on; turn off only if you redeploy via container restart
opcache.save_comments = 1             ; required by WP/plugins (PHPDoc-driven code)
opcache.fast_shutdown = 1
opcache.jit = disable                 ; off for WP
opcache.jit_buffer_size = 0
```

Per-site OPcache cost: ~110 MB shared memory ceiling, but realistically uses 40–60 MB of it after warmup. This is the single biggest "memory you should accept paying" because it cuts request CPU by 2–3×.

### Shared MariaDB (`my.cnf` snippet)

One shared MariaDB container, one database + user per site (created by the `wp-create` CLI). Connection pooling is **not needed** at this scale (10 sites × ~6 fpm workers = max ~60 connections; MariaDB default `max_connections=151`).

```ini
# /etc/mysql/conf.d/wp-shared.cnf  (mounted)
[mysqld]
# RAM budget: ~512 MB total for MariaDB
innodb_buffer_pool_size = 384M           # ~75% of MariaDB's RAM allocation; holds hot WP rows for 10 sites
innodb_log_file_size = 64M
innodb_flush_log_at_trx_commit = 2       # fsync once per second; fine for blogs (small data-loss window on crash)
innodb_flush_method = O_DIRECT
innodb_file_per_table = 1                # already default; lets us drop a site's tablespace cleanly
innodb_stats_on_metadata = 0

max_connections = 100                    # 10 sites × 6 fpm workers + headroom
thread_cache_size = 16
table_open_cache = 2000

# Disable query cache (concurrency hazard, removed in MySQL 8 entirely; off-by-default on modern MariaDB)
query_cache_type = 0
query_cache_size = 0

# Slow query log to stdout for the 10 MB / 3-file json-file rotation
slow_query_log = 1
slow_query_log_file = /var/lib/mysql/slow.log
long_query_time = 1.0

character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
```

**Why MariaDB over MySQL 8 / Percona at this scale:**
- MariaDB's resident memory under low buffer-pool config is ~150–200 MB; MySQL 8 baselines closer to 400 MB on the same config because of `Performance Schema` defaults that are harder to fully disable.
- Percona is MySQL with extra observability — overkill for personal blogs and same memory floor as MySQL.
- MariaDB 11.4 LTS removed `innodb_buffer_pool_chunk_size` rounding (resizes in 1 MB steps), so we can right-size cleanly.

### Shared Redis (object cache for all WP sites)

Distinct from AudioStory's Redis. Run as `wp-redis` on a separate port (e.g., `6380`) or only on the internal docker network with no host port at all (preferred — less attack surface).

```bash
# command for wp-redis service
redis-server
  --requirepass ${WP_REDIS_PASSWORD}
  --maxmemory 256mb
  --maxmemory-policy allkeys-lru        # treat as pure cache; evict LRU when full
  --save ""                              # no persistence — it's a cache
  --appendonly no
  --tcp-keepalive 300
  --lazyfree-lazy-eviction yes
  --lazyfree-lazy-expire yes
  --loglevel notice
```

**Multi-site isolation: use key prefixes, NOT separate DB indexes.** Verified Redis upstream guidance — `SELECT n` databases share `maxmemory` and eviction policy, so they give "the illusion of separation" without real isolation. The `redis-cache` plugin supports this via:

```php
// wp-config.php (per site, set by wp-create)
define( 'WP_CACHE', true );
define( 'WP_REDIS_HOST', 'wp-redis' );
define( 'WP_REDIS_PORT', 6379 );
define( 'WP_REDIS_PASSWORD', getenv('WP_REDIS_PASSWORD') );
define( 'WP_REDIS_PREFIX', 'wp_<sitename>:' );  // ← isolation
define( 'WP_REDIS_DATABASE', 0 );               // all sites share DB 0
define( 'WP_CACHE_KEY_SALT', '<sitename>' );    // belt + suspenders
define( 'WP_REDIS_MAXTTL', 86400 );
```

**Plugin choice: `redis-cache` (Till Krüss, free).** Verified active, ~2M+ active installs. Object Cache Pro ($95/mo or $950/yr) is the same author's commercial version — better at scale (1500+ tests, finer-grained invalidation) but **not justified for ~10 personal blogs**. WP Redis (10up) is no longer the most active option — Till Krüss's `redis-cache` is the de facto standard in 2025–2026.

### Page / Full-Page Caching Strategy

This is the key to "lightning fast for logged-out readers." Recommendation: **two layers, free.**

**Layer 1 (edge, free): Cloudflare Cache Rules.**
- Create one Cache Rule: "If hostname matches `*.yourdomain` AND `cf.client.cookies` does NOT contain `wordpress_logged_in_`, `wp-postpass_`, `comment_author_` → Cache Eligible: Eligible for cache, Edge TTL: 4 hours, Browser TTL: respect origin."
- This is what APO does for free; APO ($5/mo per zone) just automates it and adds smart purges. **Skip APO** unless you want smart-purge-on-publish without a plugin.
- **Do NOT stack APO + Cache Everything page rules** — verified anti-pattern from Cloudflare community: causes stale admin/preview/cart pages.

**Layer 2 (origin plugin): full-page cache that auto-purges on edits.**

| Plugin | Verdict | Why |
|--------|---------|-----|
| **Super Page Cache for Cloudflare** (free) | **CHOSEN** | Issues `Cache-Control: public, s-maxage=...` + tags for surgical Cloudflare purges via API on post update. Pairs natively with Cloudflare Cache Rules. |
| WP Super Cache | Acceptable alternative | On-disk static HTML cache; cuts origin CPU dramatically. Use this if you don't trust Cloudflare to be the only cache layer. Slightly more complex to configure with FPM (no `mod_rewrite`). |
| W3 Total Cache | Reject | Bloated, complex, history of bugs. The complexity isn't worth it at this scale. |
| WP Rocket | Reject (paid, unnecessary) | $59/yr per site. Free options match it for a personal-blog workload. |
| LiteSpeed Cache | Reject | Designed for LiteSpeed/OpenLiteSpeed servers. We use Caddy + php-fpm — most of the plugin's killer features (ESI, in-server cache) don't apply. |
| Caddy FastCGI cache at proxy layer | Out of scope | Caddy supports `cache-handler` (Souin) but it's host-level and we said no host changes. Cloudflare gives you the same effect for free. |
| Static-page generation (e.g., Simply Static) | Reject for primary | Great for archival sites; bad fit for blogs that publish regularly and have comments. |

**Result:** Logged-out readers hit Cloudflare's edge → 0 origin requests for cached pages. Logged-in users (you, the author) bypass via cookie → hit origin → still fast via OPcache + Redis object cache.

### Image Processing: GD only

```dockerfile
# In the per-site Dockerfile (extending wordpress:6-php8.3-fpm-alpine)
# GD ships in the official image. Imagick does NOT in some Alpine tags.
# Explicitly do not install imagick.
```

- **GD** is built into the official `wordpress:php8.3-fpm-alpine` image (PHP `gd` extension). Lower memory ceiling, faster for typical blog hero/thumbnail resizing.
- **Imagick** (PHP wrapper around ImageMagick) supports more formats (TIFF, PSD, animated GIFs) and disk-based pixel cache for huge images, but adds ~30 MB image size and pulls in ImageMagick's notorious CVE history. WordPress prefers Imagick when both are present, so installing it would silently change behavior across sites.
- For personal blogs uploading JPG/PNG/WebP, **GD is sufficient and lighter**.

If a specific site ever needs Imagick (e.g., a portfolio uploading TIFFs), build a per-site variant `wp-<site>-imagick` Dockerfile.

### WP-CLI

Two clean options — pick one and standardize:

**Option A (recommended): bake into the image.** Add to your per-site Dockerfile:

```dockerfile
FROM wordpress:6-php8.3-fpm-alpine
RUN curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
        -o /usr/local/bin/wp \
 && chmod +x /usr/local/bin/wp \
 && apk add --no-cache --virtual .wpcli-deps less mysql-client
USER www-data
RUN wp --info  # smoke test at build time
USER root
```

Then `docker exec wp-<site> wp <cmd> --path=/var/www/html` from your host CLI tool.

**Option B: sidecar.** Use the official `wordpress:cli` image as a one-shot:

```bash
docker run --rm \
  --network audiostory_app-network \
  --volumes-from wp-<site> \
  -e WORDPRESS_DB_HOST=wp-mariadb \
  wordpress:cli wp <cmd>
```

Option A is simpler for the `wp-create` / `wp-delete` CLI tools and adds only ~10 MB to the per-site image. Option B keeps the runtime image smaller but requires correct env+volume threading on every call.

### Per-Site `php-fpm` Pool Tuning

This is where "lightweight at 10 sites" lives or dies.

```ini
; /usr/local/etc/php-fpm.d/zz-wp-pool.conf
[www]
user = www-data
group = www-data
listen = 9000
listen.backlog = 128

; ondemand — the right choice for many low-traffic sites
pm = ondemand
pm.max_children = 6                   ; ceiling, not target
pm.process_idle_timeout = 30s         ; reap idle workers fast → low resident RAM
pm.max_requests = 500                 ; recycle workers to bound any leak

; FPM-side logging into stdout (so json-file rotation handles it)
access.log = /proc/self/fd/2
catch_workers_output = yes
decorate_workers_output = no
clear_env = no                        ; allow WP to read env (DB creds etc)
```

**Why `ondemand` not `dynamic` / `static`:**
- 10 sites × `dynamic` with `pm.start_servers=2` = 20 workers always resident at ~50 MB each = ~1 GB resident even with zero traffic. **Bad for our budget.**
- `static` is for high-traffic single-tenant boxes — irrelevant here.
- `ondemand`: a site with zero traffic for 30s reaps **all** workers → master process only (~5 MB RAM). First request after idle pays one fork (~80 ms). Acceptable for personal blogs.
- `pm.max_children = 6` × 50 MB ≈ 300 MB peak per site under heavy traffic. Realistic concurrent peak across 10 sites is far less (logged-out → Cloudflare absorbs).

---

## RAM Budget Math (10 sites)

| Component | Idle | Realistic peak (1–2 sites being read at once) | Notes |
|-----------|------|----------------------------------------------|-------|
| 10 × `wp-<site>` (FPM master only) | ~10 × 8 MB = 80 MB | 1–2 sites × 6 workers × 50 MB = 300–600 MB | `ondemand` reaps idle |
| OPcache shared memory (per active site) | 0 MB if reaped | ~50 MB × active sites = ~50–150 MB | Lives in shm, only allocated when fpm runs |
| `wp-mariadb` | ~200 MB | ~450 MB | buffer pool 384M + connections + threads |
| `wp-redis` | ~50 MB | ~256 MB (cap) | maxmemory enforces ceiling |
| **Subtotal — WP stack** | **~330 MB** | **~1.0–1.6 GB** | |
| Headroom (kernel, docker daemon overhead, log shipping) | 200 MB | 400 MB | |
| **Total against 4 GB cap** | **~530 MB (13%)** | **~1.4–2.0 GB (35–50%)** | well under |

Even at 20 sites (2× growth), peak ≈ 2.0–2.8 GB → still under 4 GB. **Cloudflare absorbing the read traffic is what makes this math work** — without it, peak fpm worker concurrency would balloon.

---

## Installation (per-site Dockerfile + compose snippet)

`Dockerfile.wp` (one image, parameterized per site by env):

```dockerfile
FROM wordpress:6-php8.3-fpm-alpine

# WP-CLI
RUN apk add --no-cache --virtual .wpcli-deps less mysql-client \
 && curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
        -o /usr/local/bin/wp \
 && chmod +x /usr/local/bin/wp

# php.ini overrides
COPY php/zz-wp.ini /usr/local/etc/php/conf.d/zz-wp.ini

# php-fpm pool overrides
COPY php/zz-wp-pool.conf /usr/local/etc/php-fpm.d/zz-wp-pool.conf

# WordPress debug.log rotation handled by logrotate or by capping in wp-config.php:
# define('WP_DEBUG_LOG', '/proc/self/fd/2');  // ship to docker logs → json-file rotation
```

Compose service (generated per site by `wp-create`):

```yaml
wp-myblog:
  build: ./wp-image
  container_name: wp-myblog
  environment:
    WORDPRESS_DB_HOST: wp-mariadb
    WORDPRESS_DB_NAME: wp_myblog
    WORDPRESS_DB_USER: wp_myblog
    WORDPRESS_DB_PASSWORD: ${WP_MYBLOG_DB_PASS}
    WORDPRESS_TABLE_PREFIX: wp_
    WORDPRESS_CONFIG_EXTRA: |
      define('WP_REDIS_HOST', 'wp-redis');
      define('WP_REDIS_PASSWORD', getenv('WP_REDIS_PASSWORD'));
      define('WP_REDIS_PREFIX', 'wp_myblog:');
      define('WP_CACHE_KEY_SALT', 'myblog');
      define('WP_DEBUG_LOG', '/proc/self/fd/2');
  volumes:
    - wp_myblog_content:/var/www/html/wp-content
  networks: [wp-network]
  restart: unless-stopped
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "3"
      compress: "true"
```

---

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| `wordpress:6-php8.3-fpm-alpine` | `wordpress:6-php8.4-fpm-alpine` | When you've audited every plugin for PHP 8.4 compatibility — small perf gain (~1–2%). |
| MariaDB 11 LTS | MySQL 8 | If a future plugin specifically requires MySQL-only features (rare for WP). |
| `redis-cache` (free) | Object Cache Pro ($95/mo) | Sites with WooCommerce + 100k+ products + heavy logged-in traffic. Not your scenario. |
| GD only | Imagick | Per-site override if a specific blog needs TIFF/PSD/animated GIF output. |
| Cloudflare Cache Rules + Super Page Cache | Cloudflare APO ($5/mo/zone) | If you want one-click smart-purge and don't want to manage cache rules manually. Worth it once you have 5+ sites and edits are frequent. |
| `pm = ondemand` | `pm = dynamic` | If a specific site has consistent traffic (>10 req/s sustained). Easy per-site override since each site is its own container. |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| EasyEngine | Multi-container per site (nginx + php-fpm + db + redis each). Resource cost grows linearly with sites. Explicitly the anti-pattern this project rejects. | This stack: shared MariaDB + Redis, FPM-only WP container. |
| `bitnami/wordpress` | Bundles Apache → 150–200 MB image, defeats FPM-only goal. | `wordpress:6-php8.3-fpm-alpine`. |
| Alpine MariaDB images (`yobasystems/alpine-mariadb`) | MariaDB upstream does NOT test on musl libc; subtle bugs reported. Verified in MariaDB docker repo issues. | Official `mariadb:lts` (Ubuntu Noble base). |
| Separate Redis DB indexes per site (`SELECT 0`, `SELECT 1`, …) | Redis databases share `maxmemory` and eviction; gives illusion of isolation. Verified by upstream eviction docs. | Single DB 0 + per-site `WP_REDIS_PREFIX` key namespace. |
| OPcache `validate_timestamps = 0` | Speeds up the request slightly but means `wp plugin update` won't take effect until container restart — surprises everyone. | Keep `validate_timestamps = 1`, `revalidate_freq = 60`. |
| JIT enabled (`opcache.jit = tracing`) | WP is I/O-bound; JIT adds ~32–128 MB shm per worker for ~0–2% gain (and occasional regressions). Verified by Kinsta and PHPBenchLab benchmarks. | `opcache.jit = disable`. |
| `pm = static` per site | At 10 sites × static workers always resident → blows the RAM budget. | `pm = ondemand` with `pm.max_children = 6`. |
| WP Rocket / W3 Total Cache | WP Rocket is paid; W3TC is bloated. Free Cloudflare-edge + Super Page Cache covers the use case. | Super Page Cache for Cloudflare (free). |
| Stacking Cloudflare APO + "Cache Everything" page rule | Verified anti-pattern: causes stale admin/preview/cart. | Pick one (APO OR Cache Rules with cookie bypass), not both. |
| Adding a `wp-caddy` reverse proxy in our stack | Duplicates host Caddy. | Use host Caddy `php_fastcgi wp-<site>:9000`. |
| Imagick by default | Larger image, larger CVE surface, WP auto-prefers it over GD. | GD only; per-site Imagick variant if ever needed. |

## Stack Patterns by Variant

**If a site is high-traffic (sustained >10 req/s logged-out, or significant logged-in activity):**
- Switch that one container to `pm = dynamic`, `pm.start_servers = 4`, `pm.max_children = 12`.
- Bump that site's OPcache `memory_consumption` to 192 MB.
- Consider Object Cache Pro license for that site only.

**If a site is WooCommerce (cart, sessions, lots of logged-in writes):**
- Cloudflare cache must bypass cart/checkout cookies.
- Bump shared MariaDB `innodb_buffer_pool_size` to 512–768 MB.
- Reconsider Object Cache Pro.

**If you need fully-offline-tolerant (no Cloudflare available):**
- Add WP Super Cache as a second on-disk page cache layer at the origin.

## Version Compatibility (verified April 2026)

| Component | Version | Notes |
|-----------|---------|-------|
| `wordpress:6-php8.3-fpm-alpine` | tracks WP 6.9.x as of writing | Confirmed via Docker Hub tags listing. Pin to digest in production. |
| `mariadb:lts` | 11.4 LTS | Supported until 2029. Buffer pool resizes in 1 MB steps since 11.4. |
| `redis:7-alpine` | 7.4.x | Same image family already in use for AudioStory. |
| `redis-cache` plugin | 2.x | "Network Activate" required if you ever convert to WP multisite (you won't — separate containers). |
| Cloudflare Page Rules | DEPRECATED for new accounts (Jan 2025) | Use Cache Rules. Existing rules auto-migrate during 2025–2026. |
| WP-CLI | 2.x | PHAR install pattern is stable; no breaking change pending. |

## Sources

- [Docker Hub — official wordpress image tags](https://hub.docker.com/_/wordpress) — confirmed `6-php8.3-fpm-alpine`, `php8.3-fpm-alpine`, current WP 6.9.x latest tag, multi-arch support
- [docker-library/wordpress (GitHub)](https://github.com/docker-library/wordpress) — Dockerfile source for the official image, verified GD inclusion
- [Docker Hub — official mariadb image](https://hub.docker.com/_/mariadb) — `lts` = 11.4, no Alpine variant offered
- [MariaDB/mariadb-docker (GitHub)](https://github.com/MariaDB/mariadb-docker) — confirmed musl/Alpine not supported upstream
- [MariaDB docs — InnoDB system variables](https://mariadb.com/docs/server/server-usage/storage-engines/innodb/innodb-system-variables) — buffer-pool sizing rules, 1 MB resize since 11.4
- [Redis docs — key eviction](https://redis.io/docs/latest/develop/reference/eviction/) — confirmed `allkeys-lru` semantics, that DB indexes share `maxmemory` and policy
- [WordPress.org — Redis Object Cache plugin](https://wordpress.org/plugins/redis-cache/) — verified `WP_REDIS_PREFIX`, `WP_CACHE_KEY_SALT` for multi-site isolation
- [Object Cache Pro](https://objectcache.pro/) — verified pricing ($95/mo, $950/yr) and that it's the same author as `redis-cache`
- [Cloudflare Cache Rules docs](https://developers.cloudflare.com/cache/how-to/cache-rules/) — verified Page Rules deprecation Jan 2025, Cache Rules replacement
- [Cloudflare community — APO + Cache Everything anti-pattern](https://community.cloudflare.com/t/apo-cache-everything-cookie-rules/384125) — verified stacking issue
- [PHPBenchLab — PHP 8.3 vs 8.4 vs 8.5 WordPress benchmark (2026)](https://phpbenchlab.com/php-8-3-vs-8-4-vs-8-5-wordpress-performance-benchmark-2026/) — verified <1–2% delta, JIT not material for WP
- [Kinsta — PHP 8 features and JIT](https://kinsta.com/blog/php-8/) — verified JIT character (CPU-bound, not I/O-bound workloads)
- [SitePoint — Imagick vs GD](https://www.sitepoint.com/imagick-vs-gd/) — verified WP prefers Imagick when both present
- [WP-CLI docs (PHAR install)](https://wp-cli.org/) — verified install URL stability
- [Tideways — Introduction to PHP-FPM tuning](https://tideways.com/profiler/blog/an-introduction-to-php-fpm-tuning) — verified `ondemand` semantics and trade-offs

---
*Stack research for: lightweight multi-WP hosting on shared VM*
*Researched: 2026-04-30*
