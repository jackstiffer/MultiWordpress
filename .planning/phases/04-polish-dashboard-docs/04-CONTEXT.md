# Phase 4: Polish — Dashboard + Docs — Context

**Gathered:** 2026-04-30
**Status:** Ready for planning
**Mode:** Auto

<domain>
## Phase Boundary

Two parallel deliverables:
1. **Thin PHP dashboard** — single-page web UI that reads `/opt/wp/state/sites.json` + `metrics.json` + live `docker stats`, displays cluster pool + per-site rows. Buttons call CLI verbs via narrow sudoers whitelist (NOT mounting docker socket).
2. **Documentation suite** — Caddy/Cloudflare runbook (DOC-02), scaling-cliff doc (DOC-03), polish to root README (DOC-01).

Out of scope: any new CLI verbs, any auth UI inside the dashboard (host Caddy basic_auth handles auth), any DB schema changes, multi-tenant features.

</domain>

<canonical_refs>
- `.planning/REQUIREMENTS.md` — DASH-01, DASH-02, DASH-03, DOC-01, DOC-02, DOC-03
- `.planning/ROADMAP.md` — Phase 4 success criteria
- `.planning/research/PITFALLS.md` — §4.4 (no docker socket), §8.2 (polling overhead), §10 (scaling cliff signs)
- `.planning/research/SUMMARY.md` — locked stack
- `bin/wp-list`, `bin/wp-stats` — JSON output the dashboard consumes
- `/opt/wp/state/metrics.json` (Phase 3 schema) — peak data source
- `compose/compose.yaml` — for understanding the network
- `docs/operational.md` (Phase 3) — how dashboard ties into existing ops docs

</canonical_refs>

<decisions>
## Implementation Decisions

### Dashboard Architecture
- **Container**: `wp-dashboard` runs as a separate Docker container on `wp-network`. Uses official `php:8.3-cli` (or `nginx:alpine` + `php:8.3-fpm-alpine`). Single-process, single-page. No build step.
- **Why a container, not host PHP**: keeps host clean; consistent with the per-site WP container pattern; Caddy can reach it on a loopback port.
- **Why NOT in `wp.slice`**: dashboard is shared infra, not a per-site container; runs alongside `wp-mariadb` and `wp-redis`.
- **Memory cap**: 64 MB (it's a polling viewer, not a workload).
- **Port**: `127.0.0.1:18900` loopback. Caddy reverse-proxies with basic_auth.
- **Image strategy**: simplest is `php:8.3-cli` running `php -S 0.0.0.0:80` (built-in dev server). For a single-operator internal tool, this is fine. Alternative: full nginx+fpm — overkill.

### Single-page UI
- One `index.php` file. ~250–400 lines. Server-rendered HTML on initial load; AJAX polling refreshes the data section every 5s.
- Sections:
  1. **Cluster header**: `wp.slice` pool used / 4 GB, 24h peak %, AudioStoryV2 health badge, disk %.
  2. **Sites table**: slug, domain, status (color-coded badge), current mem MB, 24h-peak mem MB, 24h-peak CPU%, DB-conn now, action buttons (Pause/Resume/Logs).
  3. **Action panel**: "Add new site" form (domain + admin email) → POST → calls `wp-create` via sudoers wrapper → returns formatted creds + Caddy block + DNS row in a modal.
  4. **Logs modal**: clicking "logs" on a site row → fetch last 200 lines from `wp-logs <slug> --tail 200` → render in pre-formatted block.
- Color coding: pool peak ≥ 90% yellow border, ≥ 100% red border. Status badges: running=green, paused=gray, stopped=red.

### Polling
- Polling interval: 5 seconds (DASH-01 requirement).
- Server-side: cache `docker stats` output for 4 seconds (1 second below polling interval) so multiple browser tabs share one snapshot. Use a tiny file-based cache at `/tmp/wp-dashboard-stats.json` (mode 644, atomic rename).
- Endpoints:
  - `GET /` — initial HTML page.
  - `GET /api/sites.json` — current sites + cluster + AudioStoryV2 health (5s polling target).
  - `GET /api/logs?slug=<slug>` — last 200 lines from `wp-logs`.
  - `POST /api/site` — `{"domain": "...", "admin_email": "..."}` → calls wp-create → returns JSON with creds + snippets.
  - `POST /api/site/<slug>/pause`, `POST /api/site/<slug>/resume`, `DELETE /api/site/<slug>` — call respective verbs.
- All write endpoints require POST + CSRF token. Token stored in PHP session (file-based session, scoped to dashboard container).

### Sudoers whitelist (DASH-02 — KEY security decision)
- File: `/etc/sudoers.d/wp-dashboard`.
- Content (exactly, no shell metachars accepted from the dashboard):
  ```
  # Allow wp-dashboard container to invoke a fixed set of CLI verbs.
  Defaults:wpdash !requiretty
  wpdash ALL=(root) NOPASSWD: /opt/wp/bin/wp-create, /opt/wp/bin/wp-delete, /opt/wp/bin/wp-pause, /opt/wp/bin/wp-resume, /opt/wp/bin/wp-list, /opt/wp/bin/wp-stats, /opt/wp/bin/wp-logs
  ```
- The dashboard container runs as user `wpdash` (UID/GID created by host install script).
- The dashboard's PHP code calls these via `shell_exec("sudo /opt/wp/bin/wp-create " . escapeshellarg($domain) . ...)` — every argument passed through `escapeshellarg`. Domain validated against regex `^[a-z0-9.-]+$` BEFORE escapeshellarg as belt-and-suspenders.
- **DO NOT mount `/var/run/docker.sock` into the dashboard container** — RCE in PHP would equal root-on-host. Sudoers whitelist is the ONLY bridge.
- For read endpoints (`wp-list`, `wp-stats`, `wp-logs`), sudo is also required (since secrets and `/opt/wp/state/*` need root or the wpdash user via group membership). Simpler: just sudo through everything. Cost: one process spawn per request — fine at 5s polling.

### Caddy basic_auth (DASH-03)
- Operator adds a Caddy block to their existing Caddyfile:
  ```
  dashboard.dirtyvocal.com {
      basic_auth {
          admin {{bcrypt-hashed-password}}
      }
      reverse_proxy 127.0.0.1:18900
  }
  ```
- Hash generated via `caddy hash-password`. Documented.
- Optional: Cloudflare Access in front for second factor. Document as recommended for non-internal-only setups.

### Repo Layout (additions)
```
dashboard/
├── Dockerfile                 # FROM php:8.3-cli, COPY src/, CMD php -S 0.0.0.0:80
├── compose.yaml               # wp-dashboard service (network, env, port, mem_limit=64m)
├── src/
│   ├── index.php              # main page (HTML + JS)
│   ├── api/
│   │   ├── sites.php          # GET /api/sites.json
│   │   ├── logs.php           # GET /api/logs
│   │   ├── site_create.php    # POST /api/site
│   │   ├── site_pause.php     # POST /api/site/<slug>/pause
│   │   ├── site_resume.php    # POST /api/site/<slug>/resume
│   │   └── site_delete.php    # DELETE /api/site/<slug>
│   ├── lib/
│   │   ├── cli.php            # Wrapper around shell_exec with escapeshellarg + sudo
│   │   ├── auth.php           # CSRF token gen/check
│   │   └── render.php         # tiny HTML helper
│   ├── static/
│   │   ├── style.css          # ~100 lines minimal CSS (no framework)
│   │   └── app.js             # ~150 lines vanilla JS for polling + modal
│   └── router.php             # PHP built-in server router for path-based dispatch
├── .env.example               # CADDY_BASIC_AUTH_HASH placeholder
└── README.md                  # how to install + configure
host/
├── install-dashboard.sh       # creates wpdash user, installs sudoers.d file, builds + starts dashboard container
└── wp-dashboard.sudoers       # the sudoers fragment shipped (copied to /etc/sudoers.d/ by install script)
docs/
├── caddy-cloudflare.md        # DOC-02 — full runbook for both
├── scaling-cliff.md           # DOC-03 — when this VM design breaks
└── (existing: cli.md, first-site-e2e.md, operational.md)
```

### CSRF & Session
- PHP built-in sessions (`session_start()`). Token in `$_SESSION['csrf']`, regenerated per page load. AJAX requests include header `X-CSRF: <token>`.
- Session cookie `Secure`, `HttpOnly`, `SameSite=Strict`. Caddy in front sets HTTPS so `Secure` works.

### docs/caddy-cloudflare.md (DOC-02)
- Section 1: How host Caddy fits — terminates TLS for AudioStoryV2 + every WP site + dashboard.
- Section 2: Cloudflare DNS setup (proxy mode, why proxy not bypass).
- Section 3: SSL/TLS modes (Full Strict — required since Caddy auto-provisions Let's Encrypt; do NOT use Flexible).
- Section 4: Per-new-site checklist (DNS row + Caddy block + reload).
- Section 5: Cache Rules (link to templates/cloudflare-cache-rule.md, no duplication).
- Section 6: WAF rules to consider (block /xmlrpc.php at edge, rate limit /wp-login.php).
- Section 7: Troubleshooting (522 = MTU; 502 = port mismatch; SSL "too many redirects" = SSL mode = Flexible mistake).

### docs/scaling-cliff.md (DOC-03)
- Plain language: when this design stops being a good fit.
- 4 warning signs (per REQUIREMENTS.md DOC-03):
  1. `wp.slice` 24h-peak ≥ 90% even after pausing/migrating heaviest site.
  2. MariaDB connection saturation (any site at 40-conn cap sustained).
  3. AudioStoryV2 OOM-killed or restarting.
  4. Disk > 70%.
- For each: detection command, what it means, what to do.
- Migration paths:
  - Bump VM size first (n2-standard-2 → n2-standard-4).
  - Move heaviest site to its own VM.
  - Move MariaDB to managed Cloud SQL.
  - Adopt Kubernetes (overkill warning).
- Decision matrix: which path for which signal.

### DOC-01 (root README polish)
- Update Status to "All 4 phases complete".
- Add brief screenshot/sketch of the dashboard (ASCII or wording, since no real image gen).
- Add link to docs/caddy-cloudflare.md and docs/scaling-cliff.md.
- Add "Operating in production" section pointing to docs/operational.md + first-site-e2e.md.

</decisions>

<code_context>
- Phase 2 CLI verbs are the dashboard's whole backend. The dashboard is a viewer + a button-pusher.
- Phase 3 metrics.json schema is the dashboard's data source for peaks.
- bin/wp-list and bin/wp-stats both have `--json` modes — perfect for the dashboard's GET endpoints.
- bin/wp-create's `--json` mode returns structured creds + snippets — perfect for the "add site" modal.
- Existing Caddy convention (host Caddy, basic_auth via `caddy hash-password`, reverse_proxy to loopback) is well-established in AudioStoryV2.

</code_context>

<specifics>
- PHP version: 8.3 to match the WP image's PHP version (operational consistency).
- No PHP framework. Vanilla PHP files. Each endpoint is its own .php file under src/api/. router.php dispatches.
- No JS framework. Vanilla JS. fetch() for polling.
- No build step. Files run as-is.
- CSS: ~100 lines of plain CSS, no Tailwind/Bootstrap. Aesthetic: dark theme, monospace for stats, minimal chrome.

</specifics>

<deferred>
- Multi-user dashboard (with roles) — explicit anti-feature; basic_auth + single shared creds is the boundary.
- WebSocket / SSE for real-time updates — 5s polling is sufficient.
- Cluster-wide log search — out of scope; SSH is fine.
- Email/Slack alerts — out of scope.
- Embedded terminal — security risk.
- Plugin browser — wp-admin already does this.

</deferred>

<discretion>
- Exact CSS / visual design (must be readable; aesthetic choices open).
- Whether to use PHP built-in server or nginx+fpm (built-in is simpler; documented trade-off acceptable).
- File-cache TTL for stats (4s recommended).
- Login error wording (must not leak existence of valid users).
- ASCII-only or include emoji (none, per project style).

NOT discretionary:
- No docker socket mount.
- Sudoers whitelist exact path list.
- 5-second polling interval (DASH-01).
- Loopback-only port for dashboard (HARD-01 inheritance).
- CSRF on every write endpoint.

</discretion>

---
*Phase 4 context — last phase. After this, milestone v1.0 is shippable.*
