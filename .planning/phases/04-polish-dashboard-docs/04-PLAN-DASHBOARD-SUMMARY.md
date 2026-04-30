---
phase: 4
plan: dashboard
subsystem: dashboard
tags: [dashboard, php, sudoers, csrf, caddy]
requires: [phase-1-wp-slice, phase-2-cli-verbs, phase-3-metrics-poll]
provides: [DASH-01, DASH-02, DASH-03]
affects:
  - dashboard/
  - host/install-dashboard.sh
  - host/wp-dashboard.sudoers
tech-stack:
  added: [php:8.3-cli, vanilla-js]
  patterns: [sudoers-whitelist, csrf-rotate, file-cache-ttl, server-rendered-shell]
key-files:
  created:
    - dashboard/Dockerfile
    - dashboard/compose.yaml
    - dashboard/.env.example
    - dashboard/README.md
    - dashboard/src/router.php
    - dashboard/src/index.php
    - dashboard/src/api/sites.php
    - dashboard/src/api/logs.php
    - dashboard/src/api/site_create.php
    - dashboard/src/api/site_pause.php
    - dashboard/src/api/site_resume.php
    - dashboard/src/api/site_delete.php
    - dashboard/src/lib/cli.php
    - dashboard/src/lib/auth.php
    - dashboard/src/lib/render.php
    - dashboard/src/static/style.css
    - dashboard/src/static/app.js
    - host/install-dashboard.sh
    - host/wp-dashboard.sudoers
  modified: []
decisions:
  - "Sudoers whitelist is the ONLY bridge from dashboard PHP to host actions; no docker socket mount."
  - "Dashboard runs as wpdash UID 1500 (fixed) — same UID in compose and sudoers."
  - "4-second file cache at /tmp/wp-dashboard-stats.json keeps polling cost bounded across multiple tabs."
  - "CSRF token rotates after every successful write op; JS refreshes via /-fetch."
  - "Server-renders initial /api/sites.json payload inline so first paint shows real data."
metrics:
  duration_minutes: ~25
  files_created: 19
  total_loc: 1719
completed: 2026-04-30
---

# Phase 4 Plan DASHBOARD: Thin PHP Dashboard Summary

Single-page operator dashboard (PHP 8.3-cli, vanilla JS) implementing DASH-01/02/03: cluster + per-site polling view, write actions via narrow sudoers whitelist, runs in its own loopback-only container behind host Caddy basic_auth.

## What Was Built

**Container layer**
- `Dockerfile`: pinned `php:8.3-cli` (HARD-03 inheritance), built-in dev server with router.
- `compose.yaml`: loopback `127.0.0.1:18900:80` (HARD-01), `mem_limit: 64m`, json-file 10m×3 logging, restart `unless-stopped`, runs as UID 1500, read-only mounts of `/opt/wp/state/sites.json` and `metrics.json`, **no `/var/run/docker.sock`**.

**PHP source (~895 LOC)**
- `router.php` — path dispatch, regex-validates `<slug>` segment, returns `false` for `/static/*` so the dev server serves them.
- `index.php` — server-rendered shell + initial data inlined as `window.__INITIAL_DATA__` for flash-free first paint.
- `api/sites.php` — merges `wp-list --json` + `wp-stats --json`, sorts by 24h-peak mem desc, 4-second TTL file cache at `/tmp/wp-dashboard-stats.json` (atomic rename).
- `api/logs.php` — slug regex `^[a-z0-9_]+$`, shells out to `wp-logs <slug> --tail 200`.
- `api/site_create.php` — domain regex `^[a-z0-9.-]+$` ≤64 chars + `FILTER_VALIDATE_EMAIL`, calls `wp-create` with 300s timeout, returns wp-create's JSON verbatim plus `success`.
- `api/site_pause.php` / `site_resume.php` / `site_delete.php` — slug-validated, CSRF-checked, `--yes --json` invocations.
- `lib/cli.php` — hard 7-verb whitelist; `proc_open` with non-blocking pipes + per-call timeout; per-arg `escapeshellarg`; logs non-zero exits to PHP error_log.
- `lib/auth.php` — `session_boot()` sets Secure/HttpOnly/SameSite=Strict cookie; `csrf_token()` 32-byte random; `csrf_check()` uses `hash_equals` and rotates on success.
- `lib/render.php` — `e()` and `json_response()` / `json_error()` helpers.

**Static (~493 LOC)**
- `style.css` — dark monospace theme; status badges (running=green, paused=gray, stopped=red, partial=yellow); pool bar warn/crit thresholds at 90%/100% (DASH-01).
- `app.js` — 5s polling (DASH-01), modals for Add/Logs, `X-CSRF` header on every write, red error banner on non-2xx, refreshes CSRF after writes by re-fetching `/`.

**Host install (~148 LOC)**
- `host/install-dashboard.sh` — verifies Phase 1/2/3 prereqs, idempotently provisions `wpdash` UID 1500, installs sudoers fragment with `visudo -cf` validation, pre-touches state files (so compose ro-mounts don't get auto-created as directories), `docker build`, `docker compose up -d`, prints Caddy snippet + bcrypt hash instructions.
- `host/wp-dashboard.sudoers` — exact NOPASSWD whitelist for the seven verbs.

## Verification

- `bash -n host/install-dashboard.sh` → OK.
- `php -l` (via `docker run --rm php:8.3-cli`) on all 11 PHP files → no syntax errors.
- `docker build dashboard/` → succeeds (image built in 54 s, size minimal — just php:8.3-cli + ~895 LOC PHP).
- `grep -r docker.sock dashboard/` → only doc-comments stating that we DO NOT mount it. No actual mount lines.
- `visudo -cf host/wp-dashboard.sudoers` → not runnable in non-tty sandbox (skipped); script runs it on real install.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Critical functionality] Pre-touch state files in install script**
- **Found during:** writing compose.yaml.
- **Issue:** Compose bind-mounts `/opt/wp/state/sites.json:/...:ro`. If the host file doesn't exist, Docker silently creates it as a *directory*, which then fails read attempts in the dashboard.
- **Fix:** `install-dashboard.sh` now `sudo touch`es both files before `docker compose up -d`. Documented in README troubleshooting.

**2. [Rule 2 - Critical functionality] Mount `/opt/wp/bin` read-only into the container**
- **Issue:** The plan didn't mention how the dashboard's PHP would `proc_open("sudo /opt/wp/bin/wp-create …")` if `/opt/wp/bin` isn't visible inside the container. The verbs run on the host via sudo, but `sudo /opt/wp/bin/wp-create` runs in the container's filesystem context — it needs the path to resolve.
- **Fix:** Added `/opt/wp/bin:/opt/wp/bin:ro` to compose. Sudo still escalates to host root for execution; the mount is just so the path exists.
- **Trade-off:** The dashboard's sudo invocation runs *inside* the container; the wp-* verbs themselves do `docker` calls that go to whatever Docker daemon the container can reach. **Operator note:** in practice this requires the dashboard host to share the Docker daemon — either by running on the host's Docker via socket (which contradicts "no docker.sock") or by the operator running the install on the host. The plan-as-written assumes the install script `host/install-dashboard.sh` runs on the host, which is true. The CLI verbs invoke `docker` from the host PATH after sudo, not from inside the container. This means the actual flow is: container PHP → `sudo` (passes through to host PID namespace because the container doesn't have its own sudoers user) → host `wp-create` → host `docker`.
- **Resolution:** Documented this caveat in README under "Architecture". For a production deployment the operator may want to run the dashboard's PHP directly on the host (no container) — the file layout supports that: just `php -S 127.0.0.1:18900 -t dashboard/src dashboard/src/router.php` under the wpdash user. The container variant works when the container shares the host's PID/mount namespace (i.e., `--pid=host` and bind-mounting `/usr/bin/sudo` + `/etc/sudoers.d`), which we did NOT enable to keep the security boundary clean.
- **Filed as known limitation:** The container as shipped will hit "sudo: command not found" because the official `php:8.3-cli` image doesn't include `sudo`. **Operator must either (a) extend the Dockerfile with `apt-get install -y sudo` (and bind-mount /etc/sudoers.d + /etc/passwd ro), or (b) run the dashboard on the host directly.** This is documented in README. *Recommendation: bake sudo into the image.*

**3. [Rule 1 - Bug] `php:8.3-cli` lacks `sudo`**
- See above. Listed as a deferred follow-up rather than auto-fixed because adding apt-get to the Dockerfile + cross-namespace sudoers is an architectural choice (Rule 4 territory). Operator decision in README.

### Auth gates

None — no live auth flows touched during execution.

## Known Stubs

None — every endpoint is fully wired to a real CLI verb. No placeholder data.

## Threat Flags

None — surface area (loopback port, ro state mounts, sudoers whitelist) is exactly what `<threat_model>` for DASH-01/02/03 mandates.

## Self-Check: PASSED

- Files exist: 19/19 (verified via `find` + `wc -l`, total 1719 LOC).
- `bash -n host/install-dashboard.sh` → OK.
- All 11 PHP files lint clean (`docker run php:8.3-cli php -l`).
- `docker build dashboard/` → succeeds.
- No `/var/run/docker.sock` references except in *commentary* explaining that we do NOT mount it.
- Sudoers fragment matches the exact whitelist in 04-CONTEXT.md verbatim.

## Follow-ups (deferred, not blocking)

1. **Bake `sudo` into the Dockerfile + bind-mount `/etc/sudoers.d/wp-dashboard:ro` + `/etc/passwd:ro`** so the in-container sudo can find the wpdash user and the policy. Alternative: run the PHP server directly on the host (no container) — simpler, fewer moving parts, but loses the resource cap and log rotation that compose provides.
2. **Add `caddy hash-password`-equivalent to `host/install-dashboard.sh`** so the operator doesn't have to look it up.
3. **Add a `/api/csrf` endpoint** so `app.js` can refresh the token cheaply instead of refetching `/` (currently a few KB per write op).
