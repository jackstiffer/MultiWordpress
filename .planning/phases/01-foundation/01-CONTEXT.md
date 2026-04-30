# Phase 1: Foundation — Context

**Gathered:** 2026-04-30
**Status:** Ready for planning
**Mode:** Auto (`--auto`) — recommended defaults selected; all decisions trace to REQUIREMENTS.md and SUMMARY.md

<domain>
## Phase Boundary

Stand up the shared infrastructure containers (`wp-mariadb`, `wp-redis`) on a dedicated bridge network (`wp-network`, MTU 1460), build the per-site WordPress image template (FPM-only Alpine, OPcache, hardened), and install the host-level `wp.slice` systemd unit that enforces the 4 GB cluster memory cap. No site is provisioned in this phase — the deliverable is a healthy baseline that any future `wp-create` will plug into.

Out of scope for Phase 1: the CLI (Phase 2), provisioning of the first site (Phase 2), metrics polling (Phase 3), dashboard (Phase 4).

</domain>

<canonical_refs>
## Canonical References (read before planning)

- `.planning/PROJECT.md` — project context, core value, constraints
- `.planning/REQUIREMENTS.md` — locked v1 requirements (Phase 1 covers INFRA-01..07, IMG-01..06, HARD-01, HARD-03)
- `.planning/REQUIREMENTS.md#memory-model-locked` — shared-pool memory model spec (wp.slice, no per-site caps)
- `.planning/ROADMAP.md` — Phase 1 goal + success criteria
- `.planning/research/STACK.md` — locked stack with image tags, php.ini / my.cnf / redis.conf snippets
- `.planning/research/ARCHITECTURE.md` — component boundaries, network topology, build order
- `.planning/research/PITFALLS.md` — day-one pitfalls Phase 1 must close (§1.1, §1.3, §1.4, §4.1, §4.2, §4.5, §5.1, §5.2, §9.3)
- `.planning/research/SUMMARY.md` — locked stack reference block
- `/Users/work/Projects/AudioStoryV2/compose.yaml` — read-only reference for log conventions, port baseline, and isolation expectations
- `/Users/work/Projects/AudioStoryV2/Caddyfile` — read-only reference for the host Caddy that this stack will live alongside

</canonical_refs>

<decisions>
## Implementation Decisions

### File Layout
- Repo root: shared infra in `compose/compose.yaml`; per-site image template in `image/` (Dockerfile + bundled config files); host artifacts (`wp.slice`, install scripts) in `host/`.
- All bind-mount targets root at `/opt/wp/` on the VM. Specifically:
  - `/opt/wp/state/` — sites.json, lockfiles
  - `/opt/wp/secrets/` — per-site .env files (mode 600)
  - `/opt/wp/sites/<slug>/wp-content/` — per-site WP content bind mount (Phase 2 creates these; Phase 1 documents the convention)
  - `/opt/wp/backups/` — placeholder dir (no backup tooling shipping; out of scope)
  - `/opt/wp/data/mariadb/` — named-volume target for shared MariaDB
- Docker named volume `wp_mariadb_data` (mounted to `/var/lib/mysql` inside container).
- Redis is ephemeral cache — `--save ""` and `--appendonly no`; no persistence volume needed.

### Compose / Image Conventions
- Pin every image to a specific tag (HARD-03): `mariadb:11.4`, `redis:7-alpine`, `wordpress:6-php8.3-fpm-alpine`. No `:latest`.
- Logging driver: `json-file` with `max-size: 10m, max-file: 3, compress: true` on every service — match AudioStoryV2's pattern verbatim.
- Healthcheck on `wp-mariadb` (`mariadb-admin ping`) and `wp-redis` (`redis-cli ping`); WP containers in Phase 2 will `depends_on: { wp-mariadb: { condition: service_healthy } }`.
- All containers `restart: unless-stopped`.
- All published ports loopback-only: `wp-mariadb` → `127.0.0.1:13306`, `wp-redis` → `127.0.0.1:16379`. No `0.0.0.0` bindings.

### Network
- `wp-network` is a user-defined bridge created by the compose file with `driver_opts.com.docker.network.driver.mtu=1460` (GCP VPC default — mismatched 1500 causes silent TLS failures). Distinct from `audiostory_app-network`.
- AudioStoryV2 stack stays on its own bridge; no cross-attachment in Phase 1.

### Per-Site Image (built but not run in Phase 1)
- Base: `wordpress:6-php8.3-fpm-alpine`. WP-CLI baked at `/usr/local/bin/wp` via Dockerfile (curl PHAR, chmod +x, smoke test in build).
- php.ini overrides shipped via `/usr/local/etc/php/conf.d/zz-wp.ini`:
  - OPcache: `enable=1`, `memory_consumption=96`, `validate_timestamps=1`, `revalidate_freq=60`, `max_accelerated_files=10000`, `interned_strings_buffer=16`. JIT off (`opcache.jit=disable`).
  - `memory_limit=256M`, `max_execution_time=30`, `request_terminate_timeout=30s`, `post_max_size=64M`, `upload_max_filesize=64M`.
  - `error_log=/proc/self/fd/2` (stdout via docker driver inheriting 10 MB rotation).
- php-fpm pool overrides via `/usr/local/etc/php-fpm.d/zz-wp.conf`:
  - `pm = ondemand`, `pm.max_children = 10`, `pm.process_idle_timeout = 30s`, `pm.max_requests = 500`.
  - `access.log = /proc/self/fd/2`.
- FPM listens on TCP `:9000` (bound `0.0.0.0` inside container; host publishing happens per-site in Phase 2).
- Hardening:
  - PHP execution under `wp-content/uploads/` denied via FPM `security.limit_extensions = .php` AND a documented Caddy snippet (out of stack).
  - Image runs as `www-data` (UID 33). Document UID expectation in image README; Phase 2's `wp-create` will `chown -R 33:33` site dirs.
  - WordPress writes `debug.log` only when `WP_DEBUG_LOG` is explicitly set; Phase 2 will set it to `/proc/self/fd/2` per site to inherit docker rotation. Phase 1 image documents this in a comment.

### Host wp.slice (INFRA-07)
- Path: `/etc/systemd/system/wp.slice`.
- Body:
  ```
  [Unit]
  Description=Cluster cgroup for MultiWordpress per-site containers
  Before=slices.target

  [Slice]
  MemoryMax=4G
  MemoryHigh=3.5G
  CPUWeight=100
  ```
- Install script (`host/install-wp-slice.sh`):
  1. Verify cgroup v2: `stat -fc %T /sys/fs/cgroup/` must return `cgroup2fs`. Abort with clear error if not.
  2. `sudo cp host/wp.slice /etc/systemd/system/wp.slice`
  3. `sudo systemctl daemon-reload`
  4. `sudo systemctl start wp.slice` (a slice is "started" by activation; subsequent containers attach to it).
  5. Verify `cat /sys/fs/cgroup/wp.slice/memory.max` returns `4294967296`.
- Phase 2's `wp-create` will pass `--cgroup-parent=wp.slice` to per-site `docker run`/`docker compose`. Compose validation in Phase 2 must reject any per-site service that sets `mem_limit` or `--memory`.

### Resource Caps for Shared Infra (NOT in wp.slice)
- `wp-mariadb`: `mem_limit: 1g`, `mem_reservation: 512m`. `innodb_buffer_pool_size=384M` to start (bump with site count). `max_connections=200`. utf8mb4 default.
- `wp-redis`: `mem_limit: 320m`. `--maxmemory 256mb --maxmemory-policy allkeys-lru --save "" --appendonly no --tcp-backlog 511 --tcp-keepalive 300 --lazyfree-lazy-eviction yes`. NOT password-protected at this scale (loopback-only binding is the boundary; document this trade-off).

### Validation / Smoke Test (acceptance for Phase 1)
- Single command brings up everything: `docker compose -f compose/compose.yaml up -d`.
- `docker compose ps` shows both `wp-mariadb` and `wp-redis` healthy.
- `docker network inspect wp-network` shows MTU 1460.
- `ss -tlnp | grep -E ':(13306|16379)'` shows loopback-only.
- `cat /sys/fs/cgroup/wp.slice/memory.max` returns `4294967296`.
- `docker build image/` completes with the per-site image tag (e.g., `multiwp:wordpress-6-php8.3`).
- AudioStoryV2 still healthy: `docker compose ps` in `/opt/audiostory/` shows web + redis up; no port conflicts on 3000/6379.

</decisions>

<code_context>
## Existing Code Insights

This is a greenfield project — no existing source files in `/Users/work/Projects/MultiWordpress` beyond `.planning/`. The reference codebase is `/Users/work/Projects/AudioStoryV2` (READ-ONLY).

Reusable patterns to copy from AudioStoryV2 (verbatim where called out):
- `compose.yaml` log driver block (`max-size: 10m, max-file: 3, compress: true`).
- `redis` service options style (CLI-flag-based config, no separate redis.conf file needed).
- `restart: unless-stopped` + `depends_on { condition: service_healthy }` pattern.
- Network naming convention (project-prefixed: AudioStoryV2 uses `audiostory_app-network`; we use `wp-network`).

Patterns to deliberately NOT copy:
- AudioStoryV2's redis uses `--maxmemory-policy volatile-lru` — we use `allkeys-lru` because WP doesn't always set TTLs (per PITFALLS §1.3).
- AudioStoryV2's redis is password-protected; ours is loopback-only and unprotected (single-VM boundary).
- AudioStoryV2's web service publishes to `:3000` directly; our containers will use loopback-only ports allocated from 18000+ in Phase 2.

</code_context>

<specifics>
## Specific Ideas

- **Repo skeleton to land in this phase:**
  ```
  /
  ├── compose/
  │   └── compose.yaml          # shared infra (wp-mariadb, wp-redis, wp-network)
  ├── image/
  │   ├── Dockerfile            # per-site WP image (built, not run)
  │   ├── php.d-zz-wp.ini       # OPcache + WP overrides
  │   ├── fpm-zz-wp.conf        # pm=ondemand, max_children=10
  │   └── README.md             # image conventions (UID 33, log redirection, etc.)
  ├── host/
  │   ├── wp.slice              # systemd unit (MemoryMax=4G)
  │   ├── install-wp-slice.sh   # cgroup v2 check + install
  │   └── README.md             # host setup steps
  ├── compose/.env.example      # template for required env vars (MARIADB_ROOT_PASSWORD, REDIS_PASSWORD if used)
  ├── .gitignore                # ignore .env, .planning/ stays tracked per config
  └── README.md                 # one-page overview pointing at phases
  ```
- **`.env` strategy for Phase 1:** root MariaDB password + (optional) redis password live in `/opt/wp/.env` on the host (mode 600), referenced by compose. Per-site secrets are Phase 2's job.
- **Image build is local-only in Phase 1.** No registry push. Phase 2's `wp-create` will reference the locally-built tag (`multiwp:wordpress-6-php8.3`).
- **No CI in Phase 1** — manual `docker compose up -d` + `docker build image/` validates. CI is out of scope for v1.

</specifics>

<deferred>
## Deferred Ideas

(None — Phase 1 is purely infra; nothing in the discussion suggested out-of-scope additions.)

</deferred>

<discretion>
## Claude's Discretion

The following implementation details are at Claude's discretion during planning, guided by the locked decisions above and the canonical refs:

- Exact Dockerfile syntax (multi-stage vs single, COPY ordering for cache efficiency).
- Compose file structure (single file vs split with `extends`/include).
- Whether to use `redis` CLI flags or a `redis.conf` file (both work; CLI-flag style matches AudioStoryV2).
- Exact text of host `install-wp-slice.sh` — must satisfy the verification steps but the code shape is open.
- README phrasing.
- Whether to bake `.env.example` with placeholder values vs comments.

Claude should NOT exercise discretion on:
- Image tags (locked by REQUIREMENTS / SUMMARY).
- Memory model (shared `wp.slice` cgroup; no per-site `mem_limit` on WP containers).
- MTU value (1460).
- Loopback-only port bindings.
- Log cap values.
- php-fpm pool values (ondemand, max_children=10).
- OPcache values.
- These are spec, not preferences.

</discretion>

---
*Phase 1 context — auto-generated from locked REQUIREMENTS + SUMMARY decisions.*
