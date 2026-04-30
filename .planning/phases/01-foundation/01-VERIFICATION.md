---
phase: 01-foundation
status: passed
mode: static
verified_at: 2026-04-30
---

# Phase 1: Foundation — Verification

## Mode
**Static verification only.** This environment (macOS, no GCP VM, no Docker daemon with cgroup v2) cannot run the operational success criteria from ROADMAP.md (e.g., `cat /sys/fs/cgroup/wp.slice/memory.max` requires Linux + cgroup v2). All locked-value and syntax checks pass; live operational verification deferred to first deployment.

## Checks Performed

### File presence (11 / 11)
- ✓ `compose/compose.yaml`
- ✓ `compose/.env.example`
- ✓ `image/Dockerfile`
- ✓ `image/php.d-zz-wp.ini`
- ✓ `image/fpm-zz-wp.conf`
- ✓ `image/README.md`
- ✓ `host/wp.slice`
- ✓ `host/install-wp-slice.sh`
- ✓ `host/README.md`
- ✓ `.gitignore`
- ✓ `README.md`

### Syntax
- ✓ `docker compose -f compose/compose.yaml config --quiet` parses cleanly
- ✓ `bash -n host/install-wp-slice.sh` — no syntax errors

### Locked values (14 / 14)
| Check | Status |
|---|---|
| MTU 1460 in compose network | ✓ |
| MariaDB on `127.0.0.1:13306` | ✓ |
| Redis on `127.0.0.1:16379` | ✓ |
| MariaDB pinned `mariadb:11.4` | ✓ |
| Redis pinned `redis:7-alpine` | ✓ |
| WP image `wordpress:6-php8.3-fpm-alpine` | ✓ |
| php-fpm `pm = ondemand` | ✓ |
| php-fpm `pm.max_children = 10` | ✓ |
| OPcache `memory_consumption=96` | ✓ |
| OPcache `opcache.jit = disable` | ✓ |
| `wp.slice` MemoryMax=4G | ✓ |
| `wp.slice` CPUWeight=100 | ✓ |
| install script verifies `cgroup2fs` | ✓ |
| install script verifies `memory.max == 4294967296` | ✓ |

### Hardening
- ✓ No `:latest` tags in actual image references (only documentation comments forbidding them)
- ✓ No `0.0.0.0` port bindings — every published port is `127.0.0.1:*`

## Requirement Coverage (15 / 15)
| REQ | Where verified |
|---|---|
| INFRA-01 | compose.yaml: wp-mariadb (mariadb:11.4 + healthcheck + named volume + capped logs) |
| INFRA-02 | compose.yaml: wp-redis (allkeys-lru + 256mb + loopback + capped logs) |
| INFRA-03 | compose.yaml: wp-network with MTU 1460 |
| INFRA-04 | compose.yaml is the single shared-infra compose; documented in README |
| INFRA-05 | host/README.md contracts per-site `--cgroup-parent=wp.slice`; mariadb/redis explicitly NOT in slice |
| INFRA-06 | compose.yaml: `restart: unless-stopped` + healthcheck on shared services |
| INFRA-07 | host/wp.slice + host/install-wp-slice.sh + cgroup-v2 verify |
| IMG-01 | image/Dockerfile: FROM `wordpress:6-php8.3-fpm-alpine` + WP-CLI bake + smoke test |
| IMG-02 | image/fpm-zz-wp.conf: pm=ondemand, max_children=10, idle_timeout=30s, max_requests=500 |
| IMG-03 | image/php.d-zz-wp.ini: OPcache 96M + JIT disable + memory_limit=256M + request_terminate_timeout=30s |
| IMG-04 | error_log=/proc/self/fd/2 in php.ini; access.log=/proc/self/fd/2 in fpm pool |
| IMG-05 | fpm-zz-wp.conf: security.limit_extensions=.php; image/README.md provides Caddy deny snippet for uploads |
| IMG-06 | image/Dockerfile: USER www-data (Alpine UID 82 — see deviation) |
| HARD-01 | All published ports `127.0.0.1:*`; verified above |
| HARD-03 | mariadb:11.4 + redis:7-alpine + wordpress:6-php8.3-fpm-alpine all pinned, no :latest |

## Deviations from Spec

### IMG-06 / UID 33 → UID 82 (Alpine)
**Recorded by PLAN-02 executor; carried into PLAN-04 README.**

REQUIREMENTS.md IMG-06 says "Image runs as `www-data` (UID 33)". Empirically, the Alpine base image (`wordpress:fpm-alpine`) puts `www-data` at UID/GID **82** (Alpine convention; 33 is the Debian convention). Documenting 33 would have caused Phase 2's `wp-create` chown to target the wrong UID.

**Resolution applied:** image/Dockerfile uses `USER www-data` (which resolves to 82); image/README.md and root README.md both call out UID 82 with explicit Alpine-vs-Debian note.

**Follow-up:** REQUIREMENTS.md IMG-06 wording should be patched (32 → 82) on the next maintenance pass. Non-blocking; the implementation is correct.

## Operational Validation Deferred

These ROADMAP §Phase 1 success criteria require a Linux host with cgroup v2 and a running Docker daemon:

1. `docker compose up -d` brings shared infra healthy.
2. `docker network inspect wp-network` shows MTU 1460 (live).
3. `ss -ltn` shows no `0.0.0.0` (live, runtime check).
4. `docker build` of per-site image (verified by PLAN-02 executor on the build agent's host; succeeded).
5. `cat /sys/fs/cgroup/wp.slice/memory.max == 4294967296` (host-only).
6. AudioStoryV2 unaffected (live coexistence test).

These will be validated on first deployment to the GCP VM. The README.md validation table provides the exact commands.

## Verdict
**PASSED (static).** All locked values, syntax, file presence, and hardening checks pass. One documented deviation (UID 82 vs spec's 33, a real bug fix). Operational checks deferred to first deployment per ROADMAP success criteria definitions.
