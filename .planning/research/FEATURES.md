# Feature Research

**Domain:** Lightweight multi-WordPress hosting tool (CLI + optional thin PHP dashboard)
**Researched:** 2026-04-30
**Confidence:** HIGH (CLI surface, anti-feature scope), MEDIUM (dashboard UX patterns)

## Reference Tools Surveyed

| Tool | Role | Takeaway |
|------|------|----------|
| **EasyEngine** | WP-specific CLI panel (rejected for bloat) | CLI verb shape: `ee site create/delete/list/update/clone/clean`. Per-site nginx + php-fpm + db is the bloat we're avoiding. |
| **CapRover** | General self-host PaaS | Dashboard pattern: Apps tab, real-time logs, HTTP settings, restart button. Read-mostly with a few action buttons. |
| **Dokku** | Single-server PaaS | `dokku <plugin>:create/link`, `dokku storage:mount`, `dokku letsencrypt`. CLI-first; verbs scoped per concern. |
| **Coolify** | Modern self-host panel | Auto-Let's Encrypt, S3 backups, Discord/Telegram notifications. Heavier than we want but UX-relevant for the dashboard. |
| **wp-cli** | Per-site WP automation | `wp core install`, `wp db reset/export/import`, `wp plugin install`. Use as a building block, not a rebuilder. |
| **Plesk WP Toolkit** | Heavy hosting panel | Clone, staging, sync-back, security scans, mass updates. Mostly anti-features for us. |

## Feature Landscape

### Table Stakes (Must Have or Tool is Useless)

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| `wp-create <domain>` — provision container + DB user + WP install + admin user + secrets, print Caddy snippet & DNS rows | Core promise of the tool. Without this, nothing else matters. | M | Wrap `docker run` + `wp core install` via wp-cli inside the container. Generate WP salts, DB password, admin password. Idempotency: refuse if site exists. |
| `wp-delete <site>` — remove container, drop DB+user, archive or delete `wp-content` | Pair to create. Must clean up fully or the host accumulates cruft. | S | `--archive` (default) tars `wp-content` + DB dump to `~/wp-archives/`. `--purge` skips archive. |
| `wp-list` — show all sites with status (running/stopped, port, domain, uptime) | Need to know what exists. Discoverability. | S | `docker ps --filter name=wp-` plus a small registry file (`~/.wp-sites.json`) for domain mapping. |
| `wp-stats` — system-wide + per-container CPU/mem | Promised in PROJECT.md; debugging tool when "is the host stressed?" is the question. | S | Wrap `docker stats --no-stream --format`. Add host totals via `/proc/loadavg`, `free`, `df`. |
| `wp-logs <site>` — tail per-site logs (nginx/php-fpm error, WP debug.log) | Standard ops verb. EasyEngine, CapRover, Dokku all expose it. | S | `docker logs -f wp-<site>` for container stdout; `docker exec` + `tail -f` for in-container WP debug.log. |
| `wp-backup <site>` — DB dump + `wp-content` tar | Single most important data-protection feature. Single-owner blogs = no team backup process; this IS the backup process. | M | `wp db export` via wp-cli + `tar czf wp-content.tgz`. Output to `~/wp-backups/<site>/<timestamp>/`. |
| `wp-restore <site> <backup>` | Backup is useless without restore. Pair always. | M | Inverse of backup. Confirm-prompt destructive. |
| Generated artifacts: Caddy snippet + DNS rows printed to stdout on create | PROJECT.md explicitly out-of-scopes auto-Caddy/auto-DNS, but the *snippets* must exist or the user can't wire the site. | S | Templated string. Include reverse_proxy block targeting the container's bound port. |
| Log rotation (10 MB / 3 files) on every surface | PROJECT.md hard requirement. Disk creep would defeat the "lightweight" promise. | S | Set `log-opts` on `docker run`; configure WP `WP_DEBUG_LOG` + logrotate inside container or PHP-side rotation. |
| Unique secrets per site (DB password, WP salts, admin password) | Security baseline. Shared MariaDB makes this non-negotiable — otherwise one compromised site = all sites compromised. | S | `openssl rand -hex 32` for DB; WP salts via `wp config shuffle-salts` or fetched from api.wordpress.org/secret-key/1.1/salt/. |

### Differentiators (Optional, Evaluated)

| Feature | Value Proposition | Complexity | Phase | Verdict |
|---------|-------------------|------------|-------|---------|
| `wp-exec <site> <wp-cli args>` — wp-cli passthrough | Massive leverage. The user already knows wp-cli; this avoids `docker exec` boilerplate. ~10 lines of code. | S | **Phase 1** | **BUILD.** Cheapest, highest-leverage feature. Effectively free given containers already have wp-cli. |
| `wp-update --all` — bulk WP core + plugin update across all sites | Genuinely useful for 5–20 personal blogs (the alternative is logging into 20 wp-admins monthly). | S | **Phase 2** | **BUILD.** Trivially implementable as a loop over `wp-exec`. Differentiator vs. doing it by hand. |
| `wp-health` — HTTP 200 check per site | Detects "site quietly broken" without requiring external uptime monitoring. | S | **Phase 2** | **BUILD.** `curl -sI https://<domain>` loop. Tiny. |
| `wp-disk <site>` — per-site uploads/wp-content disk usage | Helps spot the "one blog ate 40GB of uploads" problem common with WP. | S | **Phase 2** | **BUILD.** `du -sh` inside container. Trivial. |
| Slow-query log surfacing | Useful but requires MariaDB config + parsing. The shared-DB design makes this less per-site than expected. | M | **Later** | **DEFER.** Out of scope for "lightweight". Revisit if a site actually has perf problems. |
| HTTP request rate / error rate metrics | Requires log aggregation or sidecar. Conflicts with "lightweight". | L | **Skip** | **SKIP.** Cloudflare already shows this for free. Don't duplicate. |
| `wp-clone <src> <dst>` — duplicate a site | Useful for testing changes. But staging is explicitly out of scope per PROJECT.md. | M | **Later** | **DEFER.** Revisit only if user actually asks for it. Plesk-style territory. |
| Maintenance mode toggle | One-liner via `wp maintenance-mode activate`. | S | **Phase 2** | **BUILD if cheap.** Just an alias for `wp-exec <site> maintenance-mode activate`. |
| `wp-rename <site> <new-domain>` — domain change | WP search-replace + config rewrite is fiddly but well-trodden. Useful when domains change. | M | **Later** | **DEFER.** Real demand unclear; out-of-scope "until needed". |
| Per-site PHP version selection | EasyEngine and Plesk both expose this. Useful for old plugin compatibility. | M | **Later** | **DEFER.** Single-owner = single PHP version is fine. Add only if a specific site needs it. |
| Staging copy | Plesk-defining feature. PROJECT.md explicitly out-of-scopes. | L | **Skip** | **SKIP.** Personal blogs don't need staging. |
| S3-compatible offsite backup destination | Coolify ships this. Real value for backup safety. | M | **Later** | **DEFER.** Phase 1 backups are local; an `--upload s3://...` flag can come later. |
| Notifications on failure (Telegram/Discord/email) | Coolify pattern. Useful for unattended ops. | S | **Later** | **DEFER.** Add only after `wp-health` exists. |

### The Dashboard (Read-Mostly, Optional)

PROJECT.md positions the dashboard as "thin PHP, read-only stats + add/delete buttons that shell out to the CLI." Researched UI patterns from CapRover and Coolify:

| Aspect | Recommendation | Rationale |
|--------|----------------|-----------|
| Layout | **Single-page status table** (one row per site) + a header strip with host-level totals. No tabs, no sidebar. | 5–20 sites fits on one screen. CapRover's tabbed UI is overkill for our scale. |
| Per-row content | name / domain / status (green/red dot) / CPU% / mem / disk / last-deploy / actions (logs, delete) | Mirrors `docker ps` columns the user already knows. |
| Refresh strategy | **Polling every 5s via `fetch` + small JSON endpoint** (no SSE, no websockets) | Read-mostly + small dataset (≤ 20 sites) = polling is simpler, no long-lived PHP connections, no PHP-async hassle. SSE would force PHP to hold a connection — wrong fit. |
| Action buttons | "Create site" form (calls `wp-create` via shell), "Delete" (calls `wp-delete --archive`), "View logs" (modal showing last 200 lines via `docker logs --tail 200`) | Matches CLI verbs 1:1. No new logic. |
| Auth | **Caddy basic auth** (host-level), no in-app login | PROJECT.md key decision: "internal-only tool — no auth complexity needed beyond Caddy basic auth". |
| Stats source | **`docker stats --no-stream --format` shelled from PHP**, parsed to JSON | Matches CLI's `wp-stats`. Single source of truth. |
| Logs view | Pop-up modal, last N lines, optional auto-tail (re-poll every 2s while open) | Don't try to build a real terminal in the browser. |
| Real-time tail | **Skip.** Use `docker logs -f` from a real shell when it matters. | Avoids the websocket/SSE complexity that's anti-thesis to "thin PHP". |

**Anti-pattern flag:** Do NOT build a web shell, file browser, or in-browser log streaming. They all push the dashboard from "thin viewer" toward "panel" — the explicit thing this project rejects.

### Anti-Features (Explicitly NOT Building)

Each item below has a one-line "why not." This list is intentionally long — **the project's identity is what it WON'T build**.

| Anti-Feature | Why Tempting | Why Not | What To Do Instead |
|--------------|--------------|---------|--------------------|
| Auto-DNS provisioning via Cloudflare API | "One command and the site is live" | Adds API token storage, blast radius if leaked, and PROJECT.md explicitly out-of-scopes it. Single-owner with 5–20 sites = manual paste is once-per-site, not a real burden. | Print copy-pastable DNS rows; user pastes into Cloudflare. |
| Auto-Caddy edits | Same convenience pitch | Touching host Caddy violates PROJECT.md constraint ("No host Caddy or AudioStoryV2 modifications by this project's automation"). Risk of breaking AudioStoryV2 routing. | Print a Caddy snippet to stdout; user appends manually. |
| Multi-tenant user/billing system | "Could share with friends" | Single-owner per PROJECT.md. Auth, billing, isolation guarantees, and quotas would 10x the codebase. | If sharing ever happens, hand them a CLI invocation. |
| Email server / mail relay UI | WP transactional emails | Mail is its own ops nightmare (deliverability, SPF/DKIM, abuse). | Use a transactional API (Postmark/Resend) via an SMTP plugin per site. |
| File browser / web-based shell | "Quick edits in dashboard" | Dashboard becomes a security boundary that has to be hardened. SSH already exists. | SSH + `docker exec`. |
| Plugin/theme marketplace | Plesk has this | Maintaining a curated catalog is a full-time job; WP.org already does it. | `wp-exec <site> plugin install <slug>` via wp-cli. |
| One-click installer for non-WP apps | CapRover-style template library | Scope explosion. This is a WP tool, not a PaaS. | Use Dokku/CapRover for non-WP needs. |
| Built-in CDN | "Make it fast" | Cloudflare is already in front. Re-implementing edge caching is wasted effort. | Page-cache plugin + Cloudflare. |
| Per-site CPU/RAM quotas (cgroup tuning beyond defaults) | "Noisy neighbor protection" | PROJECT.md decision: shared infra is fine; system-wide stats sufficient. cgroup limits per container would invite tuning rabbit holes. | Trust Docker defaults; monitor host total. |
| Staging environments / blue-green deploys | Plesk defining feature | Out of scope per PROJECT.md. Personal blogs don't need it. | Take a backup before risky changes. |
| Per-WordPress-container reverse proxy | "Cleaner isolation" | Out of scope per PROJECT.md. Adds a container per site (the EasyEngine bloat). | Host Caddy reverse-proxies straight to each WP container's bound port. |
| Per-site PHP-FPM pool tuning | "Performance" | Each site is its own container; pool tuning is a 5% optimization that costs 5x complexity. | Default PHP-FPM config; revisit only if a site is actually slow. |
| Migration tooling from existing hosts | "Onboarding existing blogs" | PROJECT.md out-of-scopes it. Manual import via wp-cli once is fine. | Use `wp db import` + `tar -xzf wp-content.tgz` manually. |
| Security scanner / malware scanner | Plesk WP Toolkit ships this | Scope creep, false positives, maintenance burden. | Cloudflare WAF + keep WP/plugins updated. |
| Auto-updates on a schedule | "Set and forget" | Auto-updating WP core + plugins without test coverage is the #1 way personal sites break silently. | Manual `wp-update --all` on a cadence the user controls. |
| Two-factor auth on the dashboard | "Security" | Caddy basic auth + Cloudflare Access (if needed) is enough for an internal tool. Adding 2FA to a thin PHP app is its own attack surface. | Caddy basic auth, optionally behind Cloudflare Access. |
| Log aggregation / search UI | "Ops convenience" | Grafana/Loki territory. Heavy for 5–20 blogs. | `docker logs` + `grep`. |

## Feature Dependencies

```
wp-create
    └──requires──> Docker engine + shared MariaDB + shared Redis (infra)
    └──requires──> secrets generator (DB pw, WP salts, admin pw)
    └──requires──> Caddy snippet + DNS row template

wp-delete
    └──requires──> wp-create  (to have created the site registry)
    └──requires──> wp-backup  (for the --archive default)

wp-backup
    └──requires──> wp-exec    (uses wp-cli inside container for db export)
    └──requires──> volume layout known (wp-content path)

wp-restore ──pairs-with──> wp-backup  (must always ship together)

wp-list / wp-stats / wp-logs
    └──require──> consistent container naming (wp-<site>) + site registry

wp-update --all ──requires──> wp-exec
wp-health ──enhances──> wp-list (status column)
wp-disk ──enhances──> wp-stats

Dashboard
    └──requires──> CLI commands stable (it shells out)
    └──requires──> JSON endpoint for stats (wraps wp-stats / wp-list)
    └──requires──> Caddy basic auth in front
```

### Dependency Notes

- **`wp-exec` is foundational for Phase 2:** `wp-update`, `wp-backup`, maintenance-mode, future clone — all are thin wrappers over `wp-exec`. Building `wp-exec` early multiplies later velocity.
- **Site registry (`~/.wp-sites.json` or similar) underlies everything:** without a single source of truth listing sites + domains + ports, every list/stats/log command becomes a guessing game. Decide format in Phase 1.
- **Backup must precede delete:** `wp-delete --archive` (the default) calls into `wp-backup`. If backup isn't ready, delete must temporarily refuse `--archive`.
- **Dashboard depends on CLI stability:** any CLI flag rename ripples into the dashboard's shell-out logic. Lock CLI surface before building dashboard.

## MVP Definition

### Launch With (Phase 1 — "It works end-to-end")

The smallest set that lets the user provision, run, and tear down a WP site with confidence.

- [ ] Shared infra: `wp-mariadb`, `wp-redis` (Docker Compose) — **infrastructure, not a feature but prerequisite**
- [ ] `wp-create <domain>` — full provision + secrets + Caddy/DNS snippet output
- [ ] `wp-delete <site>` (with `--archive` defaulting to `wp-backup` first)
- [ ] `wp-list`
- [ ] `wp-stats`
- [ ] `wp-logs <site>`
- [ ] `wp-backup <site>` + `wp-restore <site> <backup>`
- [ ] `wp-exec <site> <args...>` — wp-cli passthrough (cheap, unlocks Phase 2)
- [ ] Log rotation configured at every surface (Docker driver + WP debug.log)
- [ ] Site registry file
- [ ] Docs: how to wire DNS in Cloudflare + paste Caddy snippet

### Add After Validation (Phase 2 — "Daily-driver polish")

Add once Phase 1 has run with real sites for a few weeks.

- [ ] `wp-update --all` (bulk core + plugin updates) — trigger: tired of doing it by hand
- [ ] `wp-health` (HTTP 200 check loop) — trigger: a site silently 500'd and you didn't notice
- [ ] `wp-disk <site>` — trigger: host disk filling, want to know which site
- [ ] Maintenance-mode shortcut — trigger: doing risky changes
- [ ] Thin PHP dashboard (read-only status table + create/delete buttons + log viewer modal, polling every 5s) — trigger: tired of SSHing in to check status

### Future Consideration (Phase 3+ or Skip)

- [ ] S3-compatible offsite backup upload — when local-only backups feel risky
- [ ] `wp-rename <site> <new-domain>` — when a domain actually changes
- [ ] Failure notifications (Telegram/Discord) — once `wp-health` exists and you want to be paged
- [ ] Per-site PHP version — only if a specific site needs it
- [ ] `wp-clone` — only if user explicitly asks (currently out of scope per PROJECT.md)

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority | Phase |
|---------|------------|---------------------|----------|-------|
| `wp-create` | HIGH | MEDIUM | P1 | 1 |
| `wp-delete` | HIGH | LOW | P1 | 1 |
| `wp-list` | HIGH | LOW | P1 | 1 |
| `wp-stats` | HIGH | LOW | P1 | 1 |
| `wp-logs` | HIGH | LOW | P1 | 1 |
| `wp-backup` / `wp-restore` | HIGH | MEDIUM | P1 | 1 |
| `wp-exec` (wp-cli passthrough) | HIGH | LOW | P1 | 1 |
| Caddy/DNS snippet output | HIGH | LOW | P1 | 1 |
| Log rotation | HIGH | LOW | P1 | 1 |
| `wp-update --all` | MEDIUM | LOW | P2 | 2 |
| `wp-health` | MEDIUM | LOW | P2 | 2 |
| `wp-disk` | MEDIUM | LOW | P2 | 2 |
| Maintenance-mode shortcut | LOW | LOW | P2 | 2 |
| PHP dashboard | MEDIUM | MEDIUM | P2 | 2 |
| S3 offsite backup | MEDIUM | MEDIUM | P3 | Later |
| `wp-rename` | LOW | MEDIUM | P3 | Later |
| Notifications | LOW | LOW | P3 | Later |
| Per-site PHP version | LOW | MEDIUM | P3 | Later |
| `wp-clone` / staging | LOW | HIGH | P3 | Skip unless asked |
| Slow-query log surfacing | LOW | MEDIUM | P3 | Skip |
| HTTP request/error metrics | LOW | HIGH | P3 | Skip (Cloudflare has it) |
| Auto-DNS / auto-Caddy | — | — | — | Skip (anti-feature) |
| Multi-tenant / billing | — | — | — | Skip (anti-feature) |
| Web shell / file browser | — | — | — | Skip (anti-feature) |
| Marketplace / scanner / 2FA | — | — | — | Skip (anti-feature) |

**Priority key:**
- **P1:** Ship-blockers. Without these the tool doesn't deliver its promise.
- **P2:** Daily-driver quality-of-life. Add once P1 has been used for a while.
- **P3:** Genuinely "nice to have." Defer until concrete demand surfaces.

## Competitor Feature Analysis

| Feature | EasyEngine | CapRover | Dokku | Coolify | Plesk WPT | Our Approach |
|---------|------------|----------|-------|---------|-----------|--------------|
| Site create | `ee site create --type=wp` (multi-container per site) | One-click WP template | `dokku apps:create` + `mariadb:link` + storage mount | One-click WP template | GUI wizard | `wp-create <domain>`: one slim container + shared DB user. CLI-only. |
| Site delete | `ee site delete` | Dashboard button | `dokku apps:destroy` | Dashboard button | GUI | `wp-delete <site> [--archive\|--purge]` |
| Site list | `ee site list` | Apps tab | `dokku apps:list` | Apps page | Sites grid | `wp-list` |
| Logs | `ee log` | Real-time logs in dashboard | `dokku logs` | Real-time logs | GUI viewer | `wp-logs <site>` (CLI) + dashboard modal (last N lines, no streaming) |
| Stats | Per-component | Per-app metrics | Plugin-based | Built-in graphs | Built-in graphs | `wp-stats` wraps `docker stats`; dashboard polls every 5s |
| Backup | Plugin-based | Volume backup | `dokku-pg-backup` etc. | S3 auto-backup | Built-in clone+backup | `wp-backup` / `wp-restore` (DB + wp-content tar to local FS) |
| SSL | Built-in Let's Encrypt | Built-in Let's Encrypt | `dokku-letsencrypt` plugin | Built-in Let's Encrypt | Built-in Let's Encrypt | Out of stack — host Caddy handles it |
| DNS | Manual | Manual | Manual | Manual | Manual | Manual; CLI prints rows to paste |
| Clone/staging | `ee site clone` | Manual | Manual | Manual | One-click clone+sync | Out of scope |
| Bulk update | Plugin | — | — | — | One-click bulk WP+plugin update | `wp-update --all` (Phase 2) |
| Auth | None / SSH | Login + 2FA | SSH | Login + 2FA | Login + 2FA | Caddy basic auth in front of dashboard |
| Per-site PHP version | Yes | Yes | Yes | Yes | Yes | Out of scope (Phase 3+ if needed) |

## Sources

- [EasyEngine CLI commands](https://easyengine.io/cli/docs/)
- [EasyEngine `ee site create`](https://easyengine.io/cli/commands/site/create/)
- [EasyEngine `ee site list`](https://easyengine.io/cli/commands/site/list/)
- [EasyEngine `ee site delete`](https://easyengine.io/docs-v3/commands/site/delete/)
- [EasyEngine site-command on GitHub](https://github.com/EasyEngine/site-command)
- [Dokku homepage](https://dokku.com/)
- [Dokku WordPress community plugin](https://github.com/dokku-community/dokku-wordpress)
- [How to deploy WordPress on Dokku (DEV)](https://dev.to/jasminetracey/how-to-set-up-your-wordpress-site-on-dokku-24pj)
- [CapRover one-click apps](https://caprover.com/docs/one-click-apps.html)
- [CapRover deployment methods](https://caprover.com/docs/deployment-methods.html)
- [Coolify WordPress service docs](https://coolify.io/docs/services/wordpress)
- [Coolify dashboard docs](https://coolify.io/docs/services/dashboard)
- [Plesk WP Toolkit clone docs](https://www.plesk.com/kb/docs/wp-toolkit-cloning-a-wordpress-website/)
- [Plesk WP Toolkit overview](https://www.plesk.com/wp-toolkit/)
- [wp-cli `wp core install`](https://developer.wordpress.org/cli/commands/core/install/)
- [wp-cli `wp db reset`](https://developer.wordpress.org/cli/commands/db/reset/)
- [wp-cli home](https://wp-cli.org/)
- [Docker `docker container stats` reference](https://docs.docker.com/reference/cli/docker/container/stats/)
- [Docker runtime metrics](https://docs.docker.com/engine/containers/runmetrics/)

---
*Feature research for: lightweight multi-WordPress hosting tool*
*Researched: 2026-04-30*
