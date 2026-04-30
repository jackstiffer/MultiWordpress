---
phase: 01-foundation
plan: 02
type: execute
wave: 1
depends_on: []
files_modified:
  - image/Dockerfile
  - image/php.d-zz-wp.ini
  - image/fpm-zz-wp.conf
  - image/README.md
autonomous: true
requirements: [IMG-01, IMG-02, IMG-03, IMG-04, IMG-05, IMG-06, HARD-03]
must_haves:
  truths:
    - "`docker build image/ -t multiwp:wordpress-6-php8.3` produces an image based on wordpress:6-php8.3-fpm-alpine."
    - "WP-CLI is baked at /usr/local/bin/wp; `docker run --rm multiwp:wordpress-6-php8.3 wp --info` succeeds."
    - "Container default user is www-data (UID 33)."
    - "php-fpm pool config sets pm=ondemand, max_children=10, idle_timeout=30s, max_requests=500."
    - "OPcache is enabled with memory_consumption=96, JIT disabled, php memory_limit=256M."
    - "FPM error_log and access.log point to /proc/self/fd/2 so WP/PHP internal logs inherit docker's 10 MB rotation."
    - "PHP execution under wp-content/uploads/ is denied by FPM's security.limit_extensions allowlist scoping."
  artifacts:
    - path: "image/Dockerfile"
      provides: "Per-site WP image build recipe"
      contains: "FROM wordpress:6-php8.3-fpm-alpine, wp-cli.phar, USER www-data"
    - path: "image/php.d-zz-wp.ini"
      provides: "PHP + OPcache overrides"
      contains: "opcache.enable, opcache.memory_consumption=96, opcache.jit=disable, memory_limit=256M"
    - path: "image/fpm-zz-wp.conf"
      provides: "php-fpm pool overrides"
      contains: "pm = ondemand, pm.max_children = 10, pm.process_idle_timeout = 30s, pm.max_requests = 500"
    - path: "image/README.md"
      provides: "Image conventions doc"
      contains: "UID 33, WP_DEBUG_LOG, /proc/self/fd/2"
  key_links:
    - from: "image/Dockerfile"
      to: "image/php.d-zz-wp.ini"
      via: "COPY into /usr/local/etc/php/conf.d/zz-wp.ini"
      pattern: "COPY.*zz-wp\\.ini.*conf\\.d"
    - from: "image/Dockerfile"
      to: "image/fpm-zz-wp.conf"
      via: "COPY into /usr/local/etc/php-fpm.d/zz-wp.conf"
      pattern: "COPY.*zz-wp\\.conf.*php-fpm\\.d"
    - from: "image/fpm-zz-wp.conf"
      to: "FPM error log"
      via: "error_log = /proc/self/fd/2"
      pattern: "error_log\\s*=\\s*/proc/self/fd/2"
---

<objective>
Build the per-site WordPress image template — Dockerfile + bundled php.ini and php-fpm pool overrides + README documenting image conventions. The image is built locally in this phase but not run; Phase 2's `wp-create` will instantiate it per site.

Purpose: Lock in the per-site runtime contract (FPM-only Alpine, OPcache 96 MB, JIT off, ondemand pool, log redirection to fd/2, UID 33, PHP-in-uploads denial) so that every future site inherits hardened defaults without per-site tuning.
Output: A buildable `image/` directory whose `docker build` produces `multiwp:wordpress-6-php8.3` that satisfies ROADMAP §Phase 1 success criteria #3, #4.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/REQUIREMENTS.md
@.planning/research/STACK.md
@.planning/research/PITFALLS.md
@.planning/phases/01-foundation/01-CONTEXT.md
</context>

<tasks>

<task type="auto">
  <name>Task 1: Write image config files (php.ini + fpm pool)</name>
  <files>image/php.d-zz-wp.ini, image/fpm-zz-wp.conf</files>
  <action>
Create the two config files that the Dockerfile will COPY into the image. Values are spec — do not paraphrase.

**`image/php.d-zz-wp.ini`** (mounted to `/usr/local/etc/php/conf.d/zz-wp.ini` inside container) — IMG-03, IMG-04:

```ini
; MultiWordpress per-site PHP overrides (IMG-03, IMG-04)
; Loaded after php.ini-production via conf.d/ (the "zz-" prefix makes it sort last).

memory_limit = 256M
upload_max_filesize = 64M
post_max_size = 64M
max_execution_time = 30
request_terminate_timeout = 30s
expose_php = Off

; Internal log redirection (IMG-04) — inherits docker driver's 10 MB rotation.
error_log = /proc/self/fd/2

; OPcache — biggest single perf win for WP (IMG-03).
opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = 96
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.revalidate_freq = 60
opcache.validate_timestamps = 1
opcache.save_comments = 1
opcache.fast_shutdown = 1

; JIT off — WP is I/O-bound, JIT gives ~0% and adds memory.
opcache.jit = disable
opcache.jit_buffer_size = 0
```

**`image/fpm-zz-wp.conf`** (mounted to `/usr/local/etc/php-fpm.d/zz-wp.conf` inside container) — IMG-02, IMG-04, IMG-05:

```ini
; MultiWordpress php-fpm pool overrides (IMG-02, IMG-04, IMG-05)
; The default [www] pool config ships with the upstream image; we override it here.

[www]
user = www-data
group = www-data
listen = 9000
listen.backlog = 128

; ondemand: idle workers reaped, master process only when no traffic (IMG-02).
pm = ondemand
pm.max_children = 10
pm.process_idle_timeout = 30s
pm.max_requests = 500

; Defensive: only .php executes via FPM. Combined with Caddy's path scoping
; this denies PHP execution under wp-content/uploads/ (IMG-05, PITFALLS §9.3).
; Note: the ACTUAL uploads-dir denial is enforced by the host Caddy snippet
; (see image/README.md). This pool-level setting is belt-and-suspenders so
; even if Caddy is misconfigured, only files with .php extension are passed
; to FPM at all.
security.limit_extensions = .php

; Log redirection (IMG-04) — to docker driver, inherits 10 MB rotation.
access.log = /proc/self/fd/2
catch_workers_output = yes
decorate_workers_output = no
clear_env = no
```

DO NOT include: `pm.start_servers`, `pm.min_spare_servers`, `pm.max_spare_servers` (those are dynamic-pool keys and `pm = ondemand` ignores them), JIT enabled, validate_timestamps=0.
  </action>
  <verify>
    <automated>test -f image/php.d-zz-wp.ini && test -f image/fpm-zz-wp.conf && grep -q 'opcache.memory_consumption = 96' image/php.d-zz-wp.ini && grep -q 'opcache.jit = disable' image/php.d-zz-wp.ini && grep -q 'memory_limit = 256M' image/php.d-zz-wp.ini && grep -q 'pm = ondemand' image/fpm-zz-wp.conf && grep -q 'pm.max_children = 10' image/fpm-zz-wp.conf && grep -q 'pm.process_idle_timeout = 30s' image/fpm-zz-wp.conf && grep -q 'pm.max_requests = 500' image/fpm-zz-wp.conf && grep -q 'error_log = /proc/self/fd/2' image/php.d-zz-wp.ini && grep -q 'access.log = /proc/self/fd/2' image/fpm-zz-wp.conf</automated>
  </verify>
  <done>
Both files exist with the exact spec values for IMG-02, IMG-03, IMG-04, IMG-05. No JIT-on or per-site-tuned values present.
  </done>
</task>

<task type="auto">
  <name>Task 2: Write image/Dockerfile + image/README.md</name>
  <files>image/Dockerfile, image/README.md</files>
  <action>
**`image/Dockerfile`** — IMG-01, IMG-06, HARD-03:

```dockerfile
# MultiWordpress per-site WP image (IMG-01, IMG-06, HARD-03).
# Built locally; instantiated per site by Phase 2's wp-create.
# Tag: multiwp:wordpress-6-php8.3

FROM wordpress:6-php8.3-fpm-alpine

# WP-CLI baked in (IMG-01) — installed under root, then we drop back to www-data.
USER root
RUN apk add --no-cache --virtual .wpcli-deps less mysql-client bash \
 && curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
        -o /usr/local/bin/wp \
 && chmod +x /usr/local/bin/wp \
 && /usr/local/bin/wp --info --allow-root  # build-time smoke test

# PHP + OPcache overrides (IMG-03, IMG-04).
COPY php.d-zz-wp.ini /usr/local/etc/php/conf.d/zz-wp.ini

# php-fpm pool overrides (IMG-02, IMG-04, IMG-05).
COPY fpm-zz-wp.conf /usr/local/etc/php-fpm.d/zz-wp.conf

# IMG-06: run as www-data (UID 33). The upstream image already creates
# www-data; we explicitly set USER so `docker run` defaults to UID 33.
USER www-data

# Document the FPM port (already EXPOSEd by upstream, redeclared for clarity).
EXPOSE 9000
```

DO NOT add: pinned `:latest`, ImageMagick install, registry-push commands, multi-stage build (the upstream image is already slim), VOLUME directives (Phase 2 supplies bind-mount targets).

**`image/README.md`** — image conventions doc:

```markdown
# Per-Site WordPress Image (multiwp:wordpress-6-php8.3)

Built from `wordpress:6-php8.3-fpm-alpine`. FPM-only — no Apache or nginx in
the image (host Caddy is the proxy). Hardened defaults baked in for every
future site provisioned by Phase 2's `wp-create`.

## Build

    docker build -t multiwp:wordpress-6-php8.3 image/

## Conventions Phase 2 must respect

### UID 33 (www-data) — IMG-06
The container runs as `www-data` (UID 33). When `wp-create` creates
`/opt/wp/sites/<slug>/wp-content/`, it MUST `chown -R 33:33` the directory or
the container will get "Permission denied" writing uploads (PITFALLS §4.3).

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
```
  </action>
  <verify>
    <automated>test -f image/Dockerfile && test -f image/README.md && grep -q 'FROM wordpress:6-php8.3-fpm-alpine' image/Dockerfile && grep -q 'wp-cli.phar' image/Dockerfile && grep -q 'USER www-data' image/Dockerfile && grep -q 'COPY php.d-zz-wp.ini /usr/local/etc/php/conf.d/zz-wp.ini' image/Dockerfile && grep -q 'COPY fpm-zz-wp.conf /usr/local/etc/php-fpm.d/zz-wp.conf' image/Dockerfile && ! grep -E ':latest' image/Dockerfile && grep -q 'UID 33' image/README.md && grep -q 'WP_DEBUG_LOG' image/README.md && grep -q 'wp.slice' image/README.md</automated>
  </verify>
  <done>
Dockerfile builds successfully (run `docker build image/ -t multiwp:wordpress-6-php8.3` to confirm in execute phase). README documents UID 33, log redirection contract for Phase 2, uploads-PHP-denial Caddy snippet, and the wp.slice memory-model contract.
  </done>
</task>

</tasks>

<verification>
After both tasks complete:
1. `docker build image/ -t multiwp:wordpress-6-php8.3` completes (build-time `wp --info --allow-root` smoke test passes).
2. `docker run --rm multiwp:wordpress-6-php8.3 id -u` returns `33`.
3. `docker run --rm multiwp:wordpress-6-php8.3 wp --info --allow-root` shows WP-CLI version.
4. `docker run --rm multiwp:wordpress-6-php8.3 php -i | grep -E '(opcache.memory_consumption|opcache.jit|memory_limit)'` shows 96, disable, 256M respectively.
5. `docker run --rm multiwp:wordpress-6-php8.3 cat /usr/local/etc/php-fpm.d/zz-wp.conf | grep -E 'pm = ondemand|max_children = 10|max_requests = 500'` finds all three lines.
</verification>

<success_criteria>
- ROADMAP §Phase 1 success criteria #3 and #4 satisfied by this image.
- All seven Phase-1 image requirements (IMG-01..IMG-06, HARD-03) traceable to specific Dockerfile / config lines.
</success_criteria>

<output>
Create `.planning/phases/01-foundation/01-02-SUMMARY.md` documenting:
- Final image tag and digest (capture `docker image inspect` digest after first successful build).
- The exact OPcache and FPM pool values shipped.
- Phase-2 hand-off contracts: UID 33 chown obligation, WP_DEBUG_LOG=/proc/self/fd/2 obligation, --cgroup-parent=wp.slice obligation, uploads-PHP-deny Caddy snippet to print.
</output>
