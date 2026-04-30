# MultiWordpress

Lightweight, multi-site WordPress hosting for a single GCP VM that already runs other workloads (specifically AudioStoryV2). Each site is its own slim WordPress + php-fpm container; shared MariaDB and Redis live in their own containers; a host systemd cgroup (`wp.slice`) caps the entire WP cluster at 4 GB so the Nth site cannot starve the Next.js apps next door. CLI-first (Phase 2), with an optional thin PHP dashboard later (Phase 4). Four-phase roadmap: **Foundation → CLI Core + First Site → Operational Tooling → Polish**.

## Status

- **Phase 1 (Foundation): COMPLETE** — shared infra compose, per-site image template, and host `wp.slice` are all shipped and verifiable.
- **Phase 2 (CLI Core + First Site E2E): COMPLETE (static + smoke)** — all eight CLI verbs shipped and smoke-tested. First-real-domain E2E runbook lives in [`docs/first-site-e2e.md`](docs/first-site-e2e.md) (operator-driven on the VM).
- **Phase 3 (Operational Tooling): COMPLETE (static)** — `wp-metrics-poll` cron + per-site wp-cron stagger. Live verification on first VM deployment.
- **Phase 4 (Polish — Dashboard + Docs): COMPLETE** — thin PHP dashboard (sudoers-whitelisted CLI bridge, no docker socket) + Caddy/Cloudflare runbook + scaling-cliff doc.

**Milestone v1.0 complete.** First-site E2E (`cf-cache-status: HIT` validation) is the only operator-driven step remaining; everything else is static-verified and shippable.

## Operating in Production

- **First-time deployment from zero (recommended)**: [docs/deploy.md](docs/deploy.md) — fresh GCP VM to first site live. The whole install is automated by `sudo bash host/setup.sh` — detects what's installed, asks before each step, only does what's missing. ~30 minutes.
- **Provision your first site (if VM already set up)**: [docs/first-site-e2e.md](docs/first-site-e2e.md) — 8-step validation runbook.
- **Day-to-day operations**: [docs/cli.md](docs/cli.md) — full CLI reference.
- **Cron + metrics**: [docs/operational.md](docs/operational.md) — install + verify the metrics-poll cron.
- **Caddy + Cloudflare**: [docs/caddy-cloudflare.md](docs/caddy-cloudflare.md) — SSL modes, WAF rules, troubleshooting.
- **Dashboard**: [dashboard/README.md](dashboard/README.md) — install + Caddy basic_auth setup.
- **Scaling cliff**: [docs/scaling-cliff.md](docs/scaling-cliff.md) — when this single-VM design has been outgrown.

## Architecture

```
                  ┌────────────────────────────────────────────────┐
                  │                  GCP VM (host)                 │
                  │                                                │
                  │   ┌──────────────────────────────────────┐     │
                  │   │     wp.slice  (MemoryMax = 4 GiB)    │     │
                  │   │                                      │     │
                  │   │   wp-<site-1>   wp-<site-2>   ...    │     │
                  │   │   (FPM :9000)   (FPM :9000)          │     │
                  │   │   loopback      loopback             │     │
                  │   │   :18000        :18001               │     │
                  │   └──────────────────────────────────────┘     │
                  │                                                │
                  │   wp-mariadb (127.0.0.1:13306)  ──┐  outside   │
                  │   wp-redis   (127.0.0.1:16379)  ──┤  the slice │
                  │                                  │  (own caps) │
                  │                                                │
                  │            host Caddy  (reverse proxy + TLS)   │
                  │                  ▲                             │
                  │                  │ 443                         │
                  └──────────────────┼─────────────────────────────┘
                                     │
                              Cloudflare (DNS + cache)
                                     │
                                  Internet
```

Per-site WP containers attach to the user-defined bridge `wp-network` (MTU 1460, GCP VPC default). Shared MariaDB + Redis sit on the same bridge but are **not** members of `wp.slice` — they own their own `mem_limit` directives. AudioStoryV2 lives on a separate bridge (`audiostory_app-network`) and a separate cgroup; this stack does not touch it.

## Prerequisites

- Linux host with **Docker engine** + **systemd** + **cgroup v2**. Verify cgroup v2 with `stat -fc %T /sys/fs/cgroup/` → must return `cgroup2fs`. (Ubuntu 22.04+, Debian 12+, and most distros since 2022.)
- An **existing host Caddy** doing TLS termination behind **Cloudflare** (this repo prints per-site Caddy snippets; it does not manage Caddy).
- Sufficient hardware — reference target is a **GCP n2-standard-2** (2 vCPU, 8 GB RAM); the WP cluster is sized to half the host (1 vCPU, 4 GB RAM).
- `sudo` privilege for installing the systemd slice.

## Phase 1 Setup Runbook

Run these in order on the VM. Conventional install path is `/opt/wp/`.

1. **Clone the repo to the host:**
   ```bash
   sudo git clone <repo-url> /opt/wp
   cd /opt/wp
   ```

2. **Install the host `wp.slice` cgroup:**
   ```bash
   chmod +x host/install-wp-slice.sh
   sudo host/install-wp-slice.sh
   ```
   Verifies cgroup v2, copies `wp.slice` → `/etc/systemd/system/`, runs `daemon-reload`, starts the slice, and asserts `memory.max == 4294967296`. See [`host/README.md`](host/README.md).

3. **Configure shared-infra secrets:**
   ```bash
   cp compose/.env.example compose/.env
   chmod 600 compose/.env
   $EDITOR compose/.env   # set MARIADB_ROOT_PASSWORD (suggest: openssl rand -hex 24)
   ```

4. **Bring up shared MariaDB + Redis:**
   ```bash
   docker compose -f compose/compose.yaml up -d
   ```

5. **Build the per-site WordPress image template (local-only, no registry):**
   ```bash
   docker build -t multiwp:wordpress-6-php8.3 image/
   ```
   Bakes WP-CLI 2.12.0, OPcache 96 MB, FPM `pm=ondemand max_children=10`, log redirection to `/proc/self/fd/2`, and `security.limit_extensions=.php`. See [`image/README.md`](image/README.md).

After step 5, run the validation table below. No site is provisioned in Phase 1 — that's Phase 2.

## Phase 1 Validation

Each row maps to one ROADMAP §Phase 1 success criterion. Run on the VM after the setup runbook.

| # | Criterion | Command | Expected |
|---|-----------|---------|----------|
| 1 | Shared infra healthy | `docker compose -f compose/compose.yaml ps` | `wp-mariadb` and `wp-redis` both `running` with `(healthy)` in STATUS |
| 2 | `wp-network` MTU is 1460 | `docker network inspect wp-network --format '{{(index .Options "com.docker.network.driver.mtu")}}'` | `1460` |
| 3 | Loopback-only ports | `ss -ltn \| grep -E ':(13306\|16379)\b'` | rows show `127.0.0.1:13306` and `127.0.0.1:16379`; no `0.0.0.0` bindings |
| 4 | Per-site image builds + WP-CLI works | `docker build -t multiwp:wordpress-6-php8.3 image/ && docker run --rm multiwp:wordpress-6-php8.3 wp --info --allow-root` | build succeeds; `wp --info` prints WP-CLI 2.12.0 + PHP 8.3.x |
| 5 | `wp.slice` capped at 4 GiB | `cat /sys/fs/cgroup/wp.slice/memory.max` | `4294967296` |
| 6 | AudioStoryV2 unaffected | `docker network ls \| grep -E 'wp-network\|audiostory_app-network'` and `docker stats --no-stream` | both networks present and distinct; no port conflicts on 3000/6379; AudioStoryV2 containers are NOT in `wp.slice`; WP infra well under 1 GB resident at idle |

If all six rows pass, Phase 1 is done.

## Layout

```
.
├── compose/
│   ├── compose.yaml          # shared infra: wp-mariadb + wp-redis + wp-network (MTU 1460)
│   └── .env.example          # template — copy to compose/.env and fill MARIADB_ROOT_PASSWORD
├── image/
│   ├── Dockerfile            # per-site WP image recipe (FPM-only, hardened)
│   ├── php.d-zz-wp.ini       # OPcache + PHP overrides (dropped into /usr/local/etc/php/conf.d/)
│   ├── fpm-zz-wp.conf        # php-fpm pool overrides (ondemand, max_children=10)
│   └── README.md             # image conventions: UID 82, log redirection, uploads-PHP deny
├── host/
│   ├── wp.slice              # systemd Slice unit (MemoryMax=4G, CPUWeight=100)
│   ├── install-wp-slice.sh   # cgroup-v2 verify + slice install
│   └── README.md             # host setup runbook + Phase-2 hand-off contract
├── .gitignore
├── README.md                 # this file
└── .planning/                # GSD-managed planning artifacts (tracked in git)
```

## CLI Quick Reference

After Phase 1 setup completes:

- `wp-create <domain>` — provision a new site
- `wp-delete <slug>` — full teardown
- `wp-pause <slug>` / `wp-resume <slug>` — stop/start (free RAM, preserve data)
- `wp-list` — show all sites
- `wp-stats` — pool usage + per-site metrics
- `wp-logs <slug> [-f]` — tail container logs
- `wp-exec <slug> <wp-cli-args>` — passthrough to WP-CLI

Full reference: [docs/cli.md](docs/cli.md). E2E first-site runbook: [docs/first-site-e2e.md](docs/first-site-e2e.md) (pending Phase 2 plan 07).

Wiring smoke test (after install, no Docker engine touched):

```bash
./bin/_smoke-test.sh
```

## What's in `.planning/`

`.planning/` is the [Get Shit Done (GSD)](https://github.com/) project planning directory: PROJECT goals, locked REQUIREMENTS, the phased ROADMAP, per-phase contexts and PLAN files, and per-plan SUMMARY files capturing what shipped and any deviations. Humans don't need to edit it day-to-day, but reading it is the fastest way to understand *why* the stack is shaped the way it is — every implementation decision (MTU 1460, loopback-only ports, no per-site mem cap, log caps, etc.) is traced back to a requirement and a pitfall. Tracked in git on purpose.

## Coexistence with AudioStoryV2

This stack is engineered to live on the **same VM** as the existing `AudioStoryV2` Next.js + Redis stack without interference:

- **Different ports.** AudioStoryV2 uses `3000` (web) and `6379` (Redis). MultiWordpress uses **`127.0.0.1:13306`** (MariaDB), **`127.0.0.1:16379`** (Redis), and per-site FPM containers will bind **`127.0.0.1:18000+`** in Phase 2.
- **Different networks.** AudioStoryV2's `audiostory_app-network` and our `wp-network` are distinct user-defined bridges. No cross-attachment.
- **Different cgroups.** AudioStoryV2 runs in its default cgroup; this stack's per-site WP containers run inside `wp.slice` (4 GiB cap). The slice is precisely what protects AudioStoryV2 from a runaway WP plugin.
- **No automation in this repo modifies AudioStoryV2 or the host Caddy.** Per-site Caddy blocks and Cloudflare DNS rows are *printed* by Phase 2's CLI for the operator to paste manually.

## What's NOT in this repo

- **The host Caddy config.** Lives outside this repo (per-VM, hand-edited per site). Phase 2's `wp-create` will print a ready-to-paste per-site Caddyfile snippet.
- **Cloudflare DNS rules.** Manual paste in the Cloudflare dashboard. Phase 2's CLI prints the exact A/CNAME rows.
- **AudioStoryV2.** Separate repo at `/Users/work/Projects/AudioStoryV2`, untouched and read-only from this project's perspective.
- **Backup / restore tooling.** Out of scope for v1 (operator handles via host snapshots / `wp db export`).
- **CI.** Manual `docker compose up -d` + `docker build image/` validates Phase 1.

## A note on the per-site UID (Alpine vs Debian)

The per-site image runs as `www-data` = **UID/GID 82** (the Alpine convention used by `wordpress:6-php8.3-fpm-alpine`). This is **not** UID 33 (the Debian convention). When Phase 2's `wp-create` provisions a site, it must `chown -R 82:82` the per-site bind-mount target (e.g. `/opt/wp/sites/<slug>/wp-content/`) — chowning to `33:33` will produce "Permission denied" on every upload. `REQUIREMENTS.md` IMG-06 currently documents UID 33 (the Debian convention); a future patch will reconcile that with the Alpine reality. For now, treat **82** as the authoritative number and `image/README.md` as the source of truth.

## Roadmap

- **Phase 1: Foundation** *(complete)* — shared MariaDB + Redis, per-site image template, host `wp.slice` (4 GiB cap), every day-one pitfall (MTU, loopback ports, log caps, image hardening) closed.
- **Phase 2: CLI Core + First Site E2E** *(complete — code shipped; first-real-domain validation pending operator)* — `wp-create` / `wp-delete` / `wp-list` / `wp-stats` / `wp-logs` / `wp-exec` / `wp-pause` / `wp-resume`; full CLI reference at [`docs/cli.md`](docs/cli.md); Cloudflare + Super Page Cache strategy proves out (`cf-cache-status: HIT`, sub-100 ms TTFB for logged-out reads) once operator runs the first real domain through the runbook.
- **Phase 3: Operational Tooling** — staggered host cron (`DISABLE_WP_CRON=true` per site + offset by slug-hash modulo); `wp-metrics-poll` writing 24h rolling peaks to `/opt/wp/state/metrics.json`; budget validated under 5-site real load.
- **Phase 4: Polish — Dashboard + Docs** — thin read-mostly PHP dashboard (cluster + per-site stats, sudoers-whitelisted add/delete buttons); operator runbook (Caddy snippet template, Cloudflare DNS guide, scaling-cliff doc).

## See also

- [`.planning/PROJECT.md`](.planning/PROJECT.md) — full project context, core value, constraints.
- [`.planning/ROADMAP.md`](.planning/ROADMAP.md) — 4-phase plan with success criteria.
- [`.planning/REQUIREMENTS.md`](.planning/REQUIREMENTS.md) — locked v1 requirements (37 IDs across INFRA / IMG / CLI / STATE / PERF / HARD / DASH / DOC).
- [`compose/compose.yaml`](compose/compose.yaml) · [`image/README.md`](image/README.md) · [`host/README.md`](host/README.md) — Phase-1 artifacts.
