# Roadmap: MultiWordpress

**Created:** 2026-04-30
**Granularity:** coarse (4 phases)
**Core Value:** Adding the Nth WordPress site must not slow down the existing Next.js apps or the previously-installed WP sites.

## Phases

- [ ] **Phase 1: Foundation** — Shared infra (MariaDB + Redis + network) and per-site image template, with day-one pitfalls (MTU, ports, mem limits, log caps, image hardening) closed.
- [ ] **Phase 2: CLI Core + First Site E2E** — Full CLI surface (`wp-create`/`wp-delete`/`wp-list`/`wp-stats`/`wp-logs`/`wp-exec`) provisions one real domain end-to-end and validates the Cloudflare + Super Page Cache promise.
- [ ] **Phase 3: Operational Tooling** — Cron stagger and the daily-driver hardening needed to run 5+ sites without manual babysitting.
- [ ] **Phase 4: Polish — Dashboard + Docs** — Thin PHP dashboard (read-only stats + sudoers-whitelisted add/delete) and the documentation suite (Caddy/Cloudflare runbook, scaling-cliff doc).

## Phase Details

### Phase 1: Foundation
**Goal**: Shared infra and per-site image template are up, hardened, and verifiably budget-safe — every day-one pitfall is closed before any site is provisioned.
**Depends on**: Nothing (first phase)
**Requirements**: INFRA-01, INFRA-02, INFRA-03, INFRA-04, INFRA-05, INFRA-06, IMG-01, IMG-02, IMG-03, IMG-04, IMG-05, IMG-06, HARD-01, HARD-03
**Success Criteria** (what must be TRUE):
  1. Operator runs `docker compose -f compose/compose.yaml up -d` and `wp-mariadb` (`127.0.0.1:13306`) + `wp-redis` (`127.0.0.1:16379`) come up healthy on the `wp-network` bridge with MTU 1460, capped logs (10 MB / 3 files), and named volume for MariaDB data.
  2. `docker network inspect wp-network` confirms MTU 1460, and `ss -ltn` confirms no `wp-*` infra port binds to `0.0.0.0`.
  3. `docker build` against the per-site Dockerfile produces an image based on `wordpress:6-php8.3-fpm-alpine` with WP-CLI baked in, php-fpm pool set to `pm=ondemand` / `max_children=6` / `idle_timeout=30s` / `max_requests=500`, OPcache 96 MB / JIT off / `memory_limit=256M`, and PHP execution denied under `wp-content/uploads/`.
  4. `docker run` of the per-site image runs as UID 33 (`www-data`); `WP_DEBUG_LOG` and php-fpm `error_log` both stream to `/proc/self/fd/2` so internal logs inherit the docker driver's rotation.
  5. AudioStoryV2 stack is unaffected: `docker network ls` shows `wp-network` distinct from `audiostory_app-network`, no port conflicts on 3000/6379, and `docker stats` shows the WP infra cluster well under 1 GB resident at idle.
**Plans**: TBD

### Phase 2: CLI Core + First Site E2E
**Goal**: A complete CLI provisions, lists, and tears down sites; the first real domain is live through the CLI and the Cloudflare + Super Page Cache strategy delivers near-static-file TTFB for logged-out reads.
**Depends on**: Phase 1
**Requirements**: CLI-01, CLI-02, CLI-03, CLI-04, CLI-05, CLI-06, CLI-08, CLI-09, CLI-10, CLI-11, CLI-14, STATE-01, STATE-02, STATE-03, STATE-04, PERF-01, PERF-02, HARD-02
**Success Criteria** (what must be TRUE):
  1. Operator runs `wp-create blog.example.com`, pastes the printed Caddy block + Cloudflare DNS rows, and reaches a working WordPress admin at the printed URL — admin username is `admin_<8hex>`, XML-RPC is disabled, `redis-cache` plugin is active with per-site `WP_REDIS_DATABASE` + `WP_REDIS_PREFIX`, and creds persist to `/opt/wp/secrets/<slug>.env` (mode 600).
  2. `wp-create` is robust: re-running with the same slug errors cleanly (no silent overwrite); `--resume <slug>` continues from the last completed state-machine step; any mid-flow failure rolls back DB + dirs + container via `trap ERR`; port (18000+) and redis-DB allocation are serialized via lockfile; `SHOW GRANTS` confirms the DB user has access only to `wp_<slug>.*`.
  3. `wp-list` shows all sites with slug/domain/status/port/redis DB and distinguishes `running` vs `paused`; `wp-list --secrets <slug>` re-displays creds without leaking to shell history; `wp-stats` prints host CPU/mem/disk plus per-container stats for every `wp-*`; `wp-logs <site> [--follow]` and `wp-exec <site> <wp-cli-args>` work; `wp-pause <site>` stops the container (RAM freed, DB + files + secrets intact, registry state = `paused`) and `wp-resume <site>` starts it back; `wp-delete` removes container + DB + user + secrets and prints exact Caddy/Cloudflare cleanup snippets.
  4. The first real domain proves the cache promise: after the operator pastes the documented Cloudflare Cache Rule (cookie-bypass for `wordpress_logged_in_*` / `wp-postpass_` / `comment_author_`) and activates Super Page Cache for Cloudflare, logged-out homepage requests return `cf-cache-status: HIT` with TTFB under ~100 ms, while logged-in admin requests bypass cache and hit origin.
**Plans**: TBD

### Phase 3: Operational Tooling
**Goal**: Adding the 5th–10th site is painless because cron is staggered and resource usage stays inside the 4 GB / 1 vCPU envelope under real load.
**Depends on**: Phase 2
**Requirements**: PERF-03
**Success Criteria** (what must be TRUE):
  1. Every site provisioned in this phase has `DISABLE_WP_CRON=true` in its `wp-config.php`, and `crontab -l` on the host shows one staggered `wp cron event run --due-now` line per site (deterministic offset from slug-hash modulo) — `wp-stats` does not show a synchronized CPU spike at `:00` when 5+ sites are running.
  2. With 5 real sites running and Cloudflare absorbing logged-out reads, `docker stats` shows the WP cluster sustained under 2 GB resident and under 50% of one vCPU; AudioStoryV2 has not been OOM-killed or restarted.
**Plans**: TBD

### Phase 4: Polish — Dashboard + Docs
**Goal**: A read-mostly PHP dashboard makes the stack inspectable without SSH, and the documentation suite lets a future operator (or future-you) wire a new site, recover from disaster, and recognize the scaling cliff.
**Depends on**: Phase 3
**Requirements**: DASH-01, DASH-02, DASH-03, DOC-01, DOC-02, DOC-03
**Success Criteria** (what must be TRUE):
  1. Operator visits the dashboard URL behind host Caddy basic auth and sees a single-page table of every `wp-*` site with status, CPU%, mem%, request count (when available), and a "view logs" modal — refreshed by 5-second polling, no docker socket mounted into the dashboard container.
  2. Dashboard "add site" and "delete site" buttons shell out to `wp-create` / `wp-delete` via a narrow sudoers whitelist (exact command lines, no shell metachars accepted), and `/var/log/auth.log` records each invocation.
  3. README walks a new operator from zero to a live site (prerequisites, Caddy + Cloudflare assumptions, full lifecycle); a Caddy snippet template + Cloudflare DNS row guide is included; a scaling-cliff doc names the four warning signs that this single-VM design has been outgrown.
**Plans**: TBD
**UI hint**: yes

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation | 0/0 | Not started | - |
| 2. CLI Core + First Site E2E | 0/0 | Not started | - |
| 3. Operational Tooling | 0/0 | Not started | - |
| 4. Polish — Dashboard + Docs | 0/0 | Not started | - |

## Coverage

**v1 requirements:** 34 total
**Mapped:** 34 / 34 ✓
**Unmapped:** 0

| Phase | Requirement Count | Requirements |
|-------|-------------------|--------------|
| 1. Foundation | 14 | INFRA-01..06, IMG-01..06, HARD-01, HARD-03 |
| 2. CLI Core + First Site E2E | 17 | CLI-01..06, CLI-08..11, CLI-14, STATE-01..04, PERF-01, PERF-02, HARD-02 |
| 3. Operational Tooling | 1 | PERF-03 |
| 4. Polish — Dashboard + Docs | 6 | DASH-01..03, DOC-01..03 |

## Notes on Phase Shape

- **Phase 2 merges "CLI Core" and "First Site E2E"** under coarse granularity. The first real site is the CLI's own validator — and the Cloudflare + Super Page Cache cache strategy (PERF-02) only proves out on a real domain. Splitting them would create a phase with zero new requirements and one validation criterion. Merging keeps the "CLI is the source of truth" decision honest: the CLI is not done until it has provisioned a real, fast site.
- **Phase 3 is small by REQ count (1)** but is where the multi-site invariants get *proven* under load (cron stagger, budget validation with 5 sites). Most of its content lives in success criteria, not new requirement IDs — by design, since the v1 list under-specifies operational hardening.
- **Phase 4 is last and explicitly UI/docs** — depends on stable CLI flag surface and on the multi-site setup being real enough that documentation reflects observed reality, not theory.

---
*Roadmap created: 2026-04-30*
