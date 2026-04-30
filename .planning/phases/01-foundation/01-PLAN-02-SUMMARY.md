---
phase: 01-foundation
plan: 02
subsystem: image
tags: [docker, wordpress, php-fpm, opcache, hardening]
requires: []
provides:
  - "multiwp:wordpress-6-php8.3 (per-site WP image template, built locally)"
  - "Hardened FPM pool defaults (ondemand, max_children=10, max_requests=500)"
  - "OPcache 96 MB / JIT off / WP-tuned PHP defaults"
  - "Log redirection contract (php-fpm error_log + access.log → /proc/self/fd/2)"
  - "PHP-in-uploads denial (FPM security.limit_extensions=.php + Caddy snippet documented)"
affects:
  - "Phase 2 wp-create: must chown bind mounts to 82:82, set WP_DEBUG_LOG=/proc/self/fd/2, pass --cgroup-parent=wp.slice, paste documented Caddy snippet."
tech-stack:
  added:
    - "wordpress:6-php8.3-fpm-alpine (pinned, HARD-03)"
    - "WP-CLI 2.12.0 (PHAR at /usr/local/bin/wp)"
  patterns:
    - "Slim FPM-only WP image; reverse proxy is host Caddy"
    - "zz-* conf.d sort-last override convention"
    - "Internal logs streamed to fd/2 → docker json-file 10 MB rotation"
key-files:
  created:
    - image/Dockerfile
    - image/php.d-zz-wp.ini
    - image/fpm-zz-wp.conf
    - image/README.md
  modified: []
decisions:
  - "Documented www-data as UID 82 (Alpine convention), NOT 33 (Debian) — verified empirically"
  - "Skipped Imagick install (GD only, lighter, smaller CVE surface)"
  - "Did not pin base image by digest (tag-pinning only) — bump deliberately at refresh time"
metrics:
  duration: "~6 min"
  completed: "2026-04-30"
  tasks: 2
  files-touched: 4
requirements: [IMG-01, IMG-02, IMG-03, IMG-04, IMG-05, IMG-06, HARD-03]
---

# Phase 1 Plan 2: Per-Site WordPress Image Template Summary

Per-site WordPress image template (`multiwp:wordpress-6-php8.3`) built from
`wordpress:6-php8.3-fpm-alpine` with WP-CLI 2.12.0 baked in, OPcache (96 MB,
JIT off), php-fpm `ondemand` pool (max_children=10, max_requests=500),
internal log redirection to `/proc/self/fd/2`, and FPM-level
`security.limit_extensions=.php` belt-and-suspenders for the uploads-PHP
denial enforced at the Caddy layer.

## Image Details

- **Tag:** `multiwp:wordpress-6-php8.3`
- **Image ID:** `sha256:738530fbd5bbfe329dbf9cb7f2a798a621cfc94c2400af5574c40aa6458db39d`
  (multi-arch manifest list; built on linuxkit aarch64)
- **Base:** `wordpress:6-php8.3-fpm-alpine` (pinned tag, HARD-03)
- **PHP:** 8.3.30
- **WP-CLI:** 2.12.0 (PHAR at `/usr/local/bin/wp`, build-time `wp --info --allow-root` smoke test)
- **Default user:** `www-data` (UID/GID **82**, Alpine convention)
- **Exposed port:** TCP `:9000` (FastCGI)

## Shipped Values

### OPcache + PHP (image/php.d-zz-wp.ini → `/usr/local/etc/php/conf.d/zz-wp.ini`)

| Key | Value |
| --- | --- |
| memory_limit | 256M |
| max_execution_time | 30 |
| request_terminate_timeout | 30s |
| post_max_size | 64M |
| upload_max_filesize | 64M |
| expose_php | Off |
| error_log | /proc/self/fd/2 |
| opcache.enable | 1 |
| opcache.enable_cli | 0 |
| opcache.memory_consumption | 96 |
| opcache.interned_strings_buffer | 16 |
| opcache.max_accelerated_files | 10000 |
| opcache.revalidate_freq | 60 |
| opcache.validate_timestamps | 1 |
| opcache.save_comments | 1 |
| opcache.fast_shutdown | 1 |
| opcache.jit | disable |
| opcache.jit_buffer_size | 0 |

Empirically verified inside container:
`memory_limit=256M`, `opcache.memory_consumption=96`, `opcache.jit=disable`.

### php-fpm pool (image/fpm-zz-wp.conf → `/usr/local/etc/php-fpm.d/zz-wp.conf`)

| Key | Value |
| --- | --- |
| pm | ondemand |
| pm.max_children | 10 |
| pm.process_idle_timeout | 30s |
| pm.max_requests | 500 |
| listen | 9000 |
| listen.backlog | 128 |
| security.limit_extensions | .php |
| access.log | /proc/self/fd/2 |
| catch_workers_output | yes |
| decorate_workers_output | no |
| clear_env | no |

Empirically verified: `pm = ondemand`, `pm.max_children = 10`,
`pm.max_requests = 500` all present in `/usr/local/etc/php-fpm.d/zz-wp.conf`
inside the built image.

## Phase-2 Hand-Off Contracts

Phase 2's `wp-create` MUST honor these:

1. **chown 82:82 (NOT 33:33).** Per-site bind mounts under
   `/opt/wp/sites/<slug>/wp-content/` must be `chown -R 82:82` before the
   container starts, or the FPM worker (running as UID 82) will fail with
   "Permission denied" on uploads (PITFALLS §4.3).

2. **WP_DEBUG_LOG redirection.** Per-site `wp-config.php` MUST include:

   ```php
   define('WP_DEBUG_LOG', '/proc/self/fd/2');
   ```

   so WordPress's own debug.log streams to docker driver and inherits the
   10 MB rotation (PITFALLS §1.4). Without this, debug.log silently fills
   the container filesystem.

3. **--cgroup-parent=wp.slice + no `mem_limit`.** Per-site containers run
   under the shared 4 GB `wp.slice` cgroup (INFRA-05). Compose validation
   in Phase 2 must reject any per-site service that sets `mem_limit` or
   `--memory`.

4. **Caddy snippet to print** for the operator to paste into the per-site
   Caddyfile (uploads-PHP denial — IMG-05 / PITFALLS §9.3):

   ```
   @uploads_php path_regexp uploads_php ^/wp-content/uploads/.*\.php$
   respond @uploads_php 403
   ```

5. **Loopback FPM port** — publish `127.0.0.1:18000+:9000` per site (HARD-01).

## Verification Results

| Check | Result |
| --- | --- |
| `docker build -t multiwp:wordpress-6-php8.3 image/` | PASS — 14.9s WP-CLI install + smoke test |
| `docker run --rm multiwp:wordpress-6-php8.3 wp --info --allow-root` | PASS — WP-CLI 2.12.0, PHP 8.3.30 |
| `docker run --rm multiwp:wordpress-6-php8.3 id -u` | Returns **82** (NOT 33 — see Deviations) |
| OPcache values via `php -r ini_get(...)` | memory_consumption=96, jit=disable, memory_limit=256M |
| FPM pool values via `grep` inside image | pm=ondemand, max_children=10, max_requests=500 |
| Self-check (Task 1 verify block) | PASS |
| Self-check (Task 2 verify block) | PASS |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 — Bug] UID 33 → UID 82 documentation correction**

- **Found during:** Task 2 verification (`docker run --rm multiwp:... id`)
- **Issue:** Plan + REQUIREMENTS-IMG-06 + Phase 1 CONTEXT all state the
  container runs as `www-data` UID **33** and Phase 2 must `chown -R 33:33`.
  The empirically observed UID is **82** because Alpine's `www-data` (created
  by the `shadow` package convention used in Alpine `nginx`/`apache` and
  inherited by the official `wordpress:*-fpm-alpine` image) is UID/GID 82,
  not 33 (which is the Debian/Ubuntu convention).
- **Why this is a real bug, not a doc nit:** If Phase 2 follows the plan
  literally and chowns to `33:33`, the FPM worker (UID 82) will hit
  "Permission denied" on every upload — exactly the failure mode the README
  warns about. The factual UID must be documented correctly NOW so Phase 2's
  `wp-create` writes the correct chown call.
- **Fix:**
  - Updated `image/Dockerfile` USER comment to reference UID 82 and call
    out the Alpine-vs-Debian distinction.
  - Updated `image/README.md` "UID 33 (www-data) — IMG-06" section to
    "UID 82 (www-data) — IMG-06" with the corrected chown target and an
    explicit note about the Alpine vs Debian convention.
- **Files modified:** `image/Dockerfile`, `image/README.md`
- **Commit:** included in this plan's task commit (no separate commit; the
  fix landed before the first task commit since the build verification
  surfaced it immediately).

The Dockerfile itself was always correct (`USER www-data`) — the deviation
is purely about the documented numeric UID flowing to Phase 2.

### Suggested follow-up

Update REQUIREMENTS.md IMG-06 wording from "UID 33" to "UID 82 (Alpine
convention; would be 33 on Debian)" at the next REQUIREMENTS revision pass.
Not blocking for Phase 1 completion since the README is the source of truth
that Phase 2's `wp-create` will read.

## Files Created

- `image/Dockerfile` — recipe (FROM pinned, WP-CLI baked, COPY config,
  USER www-data, EXPOSE 9000).
- `image/php.d-zz-wp.ini` — PHP + OPcache overrides.
- `image/fpm-zz-wp.conf` — php-fpm pool overrides.
- `image/README.md` — image conventions doc (UID 82, log redirection
  contract, Caddy uploads-PHP-deny snippet, wp.slice memory model, pinning).

## Self-Check: PASSED

- `image/Dockerfile`: FOUND
- `image/php.d-zz-wp.ini`: FOUND
- `image/fpm-zz-wp.conf`: FOUND
- `image/README.md`: FOUND
- `multiwp:wordpress-6-php8.3` built and `wp --info --allow-root` succeeds.
