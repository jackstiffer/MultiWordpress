# Per-Site WordPress Image (multiwp:wordpress-6-php8.3)

Built from `wordpress:6-php8.3-fpm-alpine`. FPM-only — no Apache or nginx in
the image (host Caddy is the proxy). Hardened defaults baked in for every
future site provisioned by Phase 2's `wp-create`.

## Build

    docker build -t multiwp:wordpress-6-php8.3 image/

## Conventions Phase 2 must respect

### UID 82 (www-data) — IMG-06
PHP request handlers run as `www-data`. **On Alpine, `www-data` is UID/GID 82** —
NOT 33 (which is the Debian convention some docs/REQUIREMENTS-IMG-06 imply).
Locked by HARD-03 (`wordpress:6-php8.3-fpm-alpine`); verifiable via
`docker run --rm --entrypoint id multiwp:wordpress-6-php8.3 -u www-data`.

**Important — privilege drop happens at the FPM-pool layer, NOT at the
Dockerfile USER directive.** The Dockerfile deliberately does NOT set
`USER www-data` because the upstream entrypoint (`docker-entrypoint.sh`)
MUST run as root on first boot to:
1. Copy WordPress core from `/usr/src/wordpress/` to `/var/www/html/`
2. `chown www-data:www-data /var/www/html/` recursively
3. Then `exec gosu www-data php-fpm` to drop to www-data

If you set `USER www-data` in the Dockerfile, the entrypoint runs as
www-data, sees it's not root, and skips steps 1–2. Phase 2's
`wp core install` then fails with "This does not seem to be a WordPress
installation" because `/var/www/html` is empty.

The actual privilege boundary lives in `fpm-zz-wp.conf`:
```
[www]
user = www-data
group = www-data
```
This pins every PHP-FPM worker to UID 82, regardless of how the container
PID 1 was launched.

When `wp-create` creates `/opt/wp/sites/<slug>/wp-content/`, it MUST
`chown -R 82:82` the directory or the container will get "Permission denied"
writing uploads (PITFALLS §4.3). The chown target is **82:82**, not 33:33.

If a future migration moves to a Debian-based base image, the chown target
becomes 33:33 — but as long as we stay on Alpine, it is 82:82.

### Log redirection — IMG-04
The image redirects:
- php-fpm `error_log` → `/proc/self/fd/2`
- php-fpm `access.log` → `/proc/self/fd/2`

Phase 2's per-site `wp-config.php` MUST set:

    define('WP_DEBUG_LOG', '/proc/self/fd/2');

so WordPress's own `debug.log` also streams to the docker driver and inherits
the 10 MB rotation. Without this, debug.log accumulates inside the container
filesystem and silently fills the disk (PITFALLS §1.4).

### PHP-in-uploads denial — IMG-05 / PITFALLS §9.3
FPM is configured with `security.limit_extensions = .php`. The full denial
of `.php` execution under `wp-content/uploads/` requires a Caddy snippet at
the proxy layer; Phase 2's `wp-create` prints this snippet for the operator
to paste:

    # In the per-site Caddyfile:
    @uploads_php path_regexp uploads_php ^/wp-content/uploads/.*\.php$
    respond @uploads_php 403

### FPM port
The container listens on TCP `:9000` (FastCGI). Phase 2 publishes per-site
loopback ports `127.0.0.1:18000+:9000` (HARD-01).

### Memory model — INFRA-05
This image carries NO per-container memory cap. Phase 2 MUST run each
container with `--cgroup-parent=wp.slice` and MUST NOT set `mem_limit` /
`--memory`. The wp.slice cgroup (4 GB) is the only memory ceiling.

### Pinning — HARD-03
The base image is pinned at `wordpress:6-php8.3-fpm-alpine`. Bump deliberately;
never let `:latest` drift in.

## Files

- `Dockerfile` — image recipe.
- `php.d-zz-wp.ini` — copied to `/usr/local/etc/php/conf.d/zz-wp.ini`.
- `fpm-zz-wp.conf` — copied to `/usr/local/etc/php-fpm.d/zz-wp.conf`.
