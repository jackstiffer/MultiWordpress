# MultiWordpress

## What This Is

A lightweight, multi-site WordPress hosting setup that runs alongside existing Next.js apps on a single GCP VM. Each WordPress site lives in its own slim container; shared infra (one MariaDB, one Redis) keeps the per-site footprint minimal. Provisioning and deletion are CLI-driven; an optional thin PHP dashboard surfaces docker-level stats for quick debugging.

## Core Value

**Adding the Nth WordPress site must not slow down the existing Next.js apps or the previously-installed WP sites.** Lightweight, lightning-fast, isolated-enough — that's the whole point.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Per-site WordPress container (slim image: WP + php-fpm only) named `wp-<sitename>`
- [ ] Shared `wp-mariadb` container with one DB + dedicated user per site
- [ ] Shared `wp-redis` container for object caching (separate from AudioStory's Redis)
- [ ] CLI tool: `wp-create <domain>` — provisions container, DB, user, WP install, prints admin creds + Cloudflare DNS rows + Caddy block to paste
- [ ] CLI tool: `wp-delete <site>` — removes container, drops DB, archives wp-content (or deletes per flag)
- [ ] CLI tool: `wp-list` — show all sites with status
- [ ] CLI tool: `wp-stats` — system-wide + per-container CPU/mem/disk
- [ ] CLI tools: `wp-pause` / `wp-resume` — stop a site's container to free its RAM (DB + files preserved), restart on resume; status surfaced in `wp-list`
- [ ] All container logs capped at 10 MB / 3 files (matches AudioStoryV2 pattern)
- [ ] WordPress-internal logs (debug.log, php-fpm error log) also rotated to ~10 MB / 3 files
- [ ] Stack stays under ~50% of host (≤ 1 vCPU, ≤ 4 GB RAM with 5+ sites at typical load)
- [ ] FastCGI/page caching strategy that makes logged-out reads near-static-file fast
- [ ] Thin PHP dashboard (read-only stats + add/delete buttons that shell out to the CLI)
- [ ] Docs: how to wire a new site into the existing host Caddy + Cloudflare

### Out of Scope

- Reverse proxy in our stack (no `wp-caddy`) — host Caddy already handles routing; we just print the snippet to paste
- Auto-DNS / API-driven Cloudflare provisioning — user pastes DNS rows manually
- Auto-SSL provisioning logic — host Caddy already auto-provisions via Let's Encrypt
- Multi-tenant SaaS features (per-client billing, isolation guarantees, sandboxing) — single-owner blogs only
- cPanel/Plesk-style full hosting panel — explicitly rejected; reference: moved away from EasyEngine for being too heavy
- Per-WordPress-container reverse proxy or per-site PHP-FPM pool tuning beyond defaults
- Staging environments / blue-green deploys per site
- Per-site CPU/RAM attribution beyond what `docker stats` already gives — system-wide is fine
- Migration tooling from existing hosts — sites will be created fresh or imported manually via WP-CLI
- Backup / restore tooling (`wp-backup`, `wp-restore`, `--archive`, S3 offload) — operator handles backups out-of-band (host-level snapshots, manual `wp-exec <site> wp db export`, or external service)

## Context

- **Existing host**: GCP VM `dirtyvocal-nextjs` (n2-standard-2: 2 vCPU, 8 GB RAM) in `us-central1-c`. Already runs the AudioStoryV2 Next.js app + Redis via Docker Compose. Caddy on the host handles all reverse proxying with auto-HTTPS, Cloudflare in front of Caddy.
- **Reference repo (read-only)**: `/Users/work/Projects/AudioStoryV2` — its `compose.yaml` and `deploy.sh` show the deployment pattern (gcloud SCP + `docker compose up`) and the log-capping convention this project will inherit. **Do not modify that repo.**
- **Anti-pattern (rejected)**: EasyEngine — uses multiple containers per site (nginx + php-fpm + db + redis each, sometimes more). Resource cost compounds linearly with site count. Want shared infra instead.
- **Site count**: 5 personal blogs today, expected to grow. All owned by the same person.
- **Domains**: Each site gets its own custom domain. DNS is managed manually in Cloudflare. Caddy on host is configured manually per new site.
- **Resource budget**: WP stack must fit in 50% of host = 1 vCPU + 4 GB RAM, leaving the rest for AudioStoryV2 and headroom.

## Constraints

- **Tech stack**: Must run on existing Docker engine on the GCP VM. No Kubernetes, no separate VMs, no cloud-managed databases.
- **Performance**: Adding sites is sublinear in resource cost — the 10th site must not dramatically degrade the 1st. Logged-out page loads should hit cache and serve fast.
- **Operational**: No host Caddy or AudioStoryV2 modifications by this project's automation. User edits Caddy manually using snippets the CLI prints.
- **Budget**: Single VM. No managed DB. No paid SaaS dependencies for core function.
- **Security**: Each site's DB user has access only to its own DB. WordPress secrets unique per site. No shared filesystem between sites' wp-content.
- **Logs**: 10 MB cap on every log surface (docker driver + WP/PHP internal logs). Disk must not creep up over time.
- **Compatibility**: Must coexist with existing AudioStoryV2 stack on same Docker network or its own — must not collide with port 3000, 6379, or anything AudioStoryV2 binds.

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Per-site WordPress container, shared MariaDB + Redis | Balances isolation (own files, own DB user, own WP version) with resource efficiency (shared heavy services). Avoids EasyEngine bloat. | — Pending |
| No reverse proxy in our stack | Host Caddy already exists and handles HTTPS + Cloudflare termination for the Next.js side. Adding `wp-caddy` would duplicate it. | — Pending |
| CLI as source of truth, dashboard as thin viewer | Dashboard is optional polish; CLI must work without it. Avoids logic duplication. Internal-only tool — no auth complexity needed beyond Caddy basic auth. | — Pending |
| Naming convention `wp-*` for every container | Lets `docker stats $(docker ps --filter name=wp- -q)` and similar one-liners cleanly scope the WP cluster. | — Pending |
| 10 MB / 3-file log cap on every surface | Matches AudioStoryV2 convention. Prevents slow disk-fill that would eventually take down the VM. | — Pending |
| System-wide stats only (option i, not per-site PHP-FPM pools) | Per-container stats come for free from `docker stats` since each site is its own container. No need to engineer pool-level attribution. | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-04-30 after initialization*
