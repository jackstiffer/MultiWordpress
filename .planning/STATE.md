# State: MultiWordpress

**Last updated:** 2026-04-30 (post-roadmap)

## Project Reference

**Core value:** Adding the Nth WordPress site must not slow down the existing Next.js apps or the previously-installed WP sites. Lightweight, lightning-fast, isolated-enough.

**Current focus:** Awaiting Phase 1 plan generation.

## Current Position

- **Milestone:** v1
- **Phase:** — (none in progress)
- **Plan:** —
- **Status:** Roadmap complete; ready for `/gsd-plan-phase 1`
- **Progress:** ░░░░░░░░░░ 0% (0 / 4 phases complete)

### Phase Progress

| Phase | Status |
|-------|--------|
| 1. Foundation | Not started |
| 2. CLI Core + First Site E2E | Not started |
| 3. Operational Tooling | Not started |
| 4. Polish — Dashboard + Docs | Not started |

## Performance Metrics

- Phases planned: 4
- Phases complete: 0
- Plans complete: 0
- Requirements mapped: 36 / 36 ✓
- Average plan cycle time: —

## Accumulated Context

### Decisions Locked at Roadmap Time

1. **Per-site WordPress container, shared MariaDB + Redis** — isolation where it matters, EasyEngine bloat avoided.
2. **No reverse proxy in our stack** — host Caddy reaches WP via `127.0.0.1:18000+` (FastCGI). CLI prints snippets; never edits Caddy.
3. **CLI is the source of truth; dashboard is a thin viewer** — all writes via `/opt/wp/bin/*`; dashboard shells out via narrow sudoers, no docker socket mount.
4. **Cloudflare absorbs read traffic; FPM serves the rest** — Cache Rules + Super Page Cache + cookie bypass. Validated on first real domain in Phase 2.
5. **10 MB / 3-file log cap on every surface** — including `WP_DEBUG_LOG=/proc/self/fd/2` and php-fpm `error_log=/proc/self/fd/2` so internal logs inherit docker rotation.
6. **Phase 2 merges CLI Core + First Site E2E** under coarse granularity — first real site is the CLI's validator, not a hand-built precursor.

### Open Todos

- (none — pending Phase 1 planning)

### Blockers

- (none)

### Open Questions Carried From Research

- Confirm GCP VPC MTU at deploy time: `gcloud compute networks describe default --format='value(mtu)'` (Phase 1).
- Exact Cloudflare cookie list to bypass — settle on first real domain (Phase 2).
- Sudoers whitelist exact entries — Phase 4.

## Session Continuity

**Next action:** Run `/gsd-plan-phase 1` to decompose Phase 1 (Foundation) into plans.

**Files of record:**
- `.planning/PROJECT.md` — vision, scope, constraints
- `.planning/REQUIREMENTS.md` — 36 v1 requirements with phase traceability
- `.planning/ROADMAP.md` — 4-phase structure, success criteria, coverage map
- `.planning/research/` — STACK.md, FEATURES.md, ARCHITECTURE.md, PITFALLS.md, SUMMARY.md

**Coexistence reminder:** AudioStoryV2 lives at `/Users/work/Projects/AudioStoryV2` and on the same VM (`audiostory_app-network`, port 3000, redis 6379). Read-only reference. Never modified by this project.

---
*State initialized: 2026-04-30*
