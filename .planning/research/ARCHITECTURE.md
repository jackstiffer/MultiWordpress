# Architecture Research

**Domain:** Multi-WordPress hosting on a single VM with shared infra (Docker Compose, host Caddy)
**Researched:** 2026-04-30
**Confidence:** HIGH (well-trodden patterns; verified against Docker, MariaDB, Redis, WordPress official docs and AudioStoryV2 in-repo conventions)

---

## Standard Architecture

### System Overview

```
                       ┌─────────────────────────────────────────┐
                       │         Cloudflare (DNS + CDN)          │
                       └────────────────────┬────────────────────┘
                                            │ :443
                                            ▼
┌───────────────────────────────────────────────────────────────────────────┐
│                       GCP VM (dirtyvocal-nextjs)                          │
│                                                                            │
│   ┌──────────────────────────────────────────────────────────────────┐    │
│   │  Host Caddy  (NOT in our stack — manually edited per site)        │    │
│   │   blog1.example.com → reverse_proxy 127.0.0.1:<wp-port>           │    │
│   │   blog2.example.com → reverse_proxy 127.0.0.1:<wp-port>           │    │
│   └──────────┬───────────────────┬────────────────────┬───────────────┘    │
│              │ loopback          │ loopback           │ loopback           │
│              ▼                   ▼                    ▼                    │
│   ┌────────────────────────────────────────────────────────────────────┐   │
│   │              Docker Network: wp-network (bridge)                   │   │
│   │                                                                    │   │
│   │  ┌─────────┐  ┌─────────┐  ┌─────────┐         ┌────────────┐     │   │
│   │  │ wp-blog1│  │ wp-blog2│  │ wp-blogN│ ───────▶│ wp-mariadb │     │   │
│   │  │ :80→host│  │ :80→host│  │ :80→host│         │   :3306    │     │   │
│   │  │ wp+fpm  │  │ wp+fpm  │  │ wp+fpm  │         └────────────┘     │   │
│   │  │ +nginx  │  │ +nginx  │  │ +nginx  │ ───────▶┌────────────┐     │   │
│   │  └────┬────┘  └────┬────┘  └────┬────┘         │  wp-redis  │     │   │
│   │       │            │            │              │   :6379    │     │   │
│   │       │ bind-mount │ bind-mount │ bind-mount   └────────────┘     │   │
│   └───────┼────────────┼────────────┼──────────────────────────────────┘   │
│           ▼            ▼            ▼                                       │
│   /opt/wp/sites/blog1  /blog2  /blogN   (wp-content per site)              │
│   /opt/wp/data/mariadb  (named volume)                                     │
│   /opt/wp/data/redis    (named volume — ephemeral cache, OK to lose)       │
│   /opt/wp/secrets/*.env (per-site env files, 600 perms)                    │
│   /opt/wp/backups/<site>/<timestamp>.tar.gz                                │
│   /opt/wp/bin/{wp-create,wp-delete,wp-list,wp-stats,wp-backup}             │
│                                                                            │
│   ┌─────────────────────────────────────────────────────┐                 │
│   │  Existing AudioStoryV2 stack (untouched)            │                 │
│   │   audiostory_app-network ← separate bridge          │                 │
│   │   web :3000, redis :6379 (different network)        │                 │
│   └─────────────────────────────────────────────────────┘                 │
└───────────────────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

| Component | Responsibility | Implementation |
|-----------|----------------|----------------|
| **Host Caddy** | TLS termination, vhost routing, ACME. NOT touched by our automation. | Existing — we only print snippets to paste. |
| **wp-network** | Single user-defined bridge for all `wp-*` containers. Isolates from `audiostory_app-network`. | `docker network create wp-network` |
| **wp-mariadb** | Shared DB engine. One DB + one user per site, grants scoped to that DB. | `mariadb:11-lts` image, named volume `wp_mariadb_data` |
| **wp-redis** | Shared object cache. One Redis DB index per site (0..15 default; 16..255 via `databases` directive). | `redis:7-alpine`, no persistence (cache only) |
| **wp-\<site\>** | Single container per site: nginx + php-fpm + WP code. Bind-mounts only `wp-content`. | Custom image (or `wordpress:php8.3-fpm-alpine` + nginx sidecar — see trade-off below) |
| **CLI (`/opt/wp/bin/*`)** | Source of truth for provisioning. Idempotent where possible; rollback on partial failure. | Bash scripts; uses `docker`, `docker exec`, `wp-cli` inside container |
| **Per-site env file** | Holds DB password, WP salts, admin creds. Loaded by compose `env_file:`. | `/opt/wp/secrets/<site>.env`, mode 600, root-owned |
| **Site registry** | Authoritative list of provisioned sites (slug, domain, port, created_at). | `/opt/wp/state/sites.json` (CLI-managed; lockfile to serialize writes) |
| **Dashboard (optional)** | Read-only viewer + thin shell-out for create/delete buttons. | Containerized PHP behind host Caddy + basic auth |

---

## Detailed Decisions

### 1. Docker Network Topology

**Decision: ONE user-defined bridge `wp-network` for all `wp-*` + shared infra. Host Caddy reaches WP containers via per-site published port on `127.0.0.1`.**

#### Trade-off: Network isolation model

| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| **Single bridge `wp-network`** | Containers reach `wp-mariadb` and `wp-redis` by alias. Trivial to add a new site. Single network in `docker network ls`. | Sites can technically reach each other on the bridge. | **Chosen** — single owner, no real tenancy threat; DB user grants and Redis DB index already isolate the meaningful surface. |
| Per-site network + shared infra also attached | Stronger network isolation between sites. | Each new site = `docker network connect wp-mariadb <net>`. 20 sites = 20 networks attached to MariaDB. iptables rule explosion. | Rejected — operationally heavy for marginal isolation. |
| Shared with `audiostory_app-network` | One fewer network. | Couples lifecycles; risks port/name collision; AudioStoryV2 must remain untouched. | Rejected — violates project constraint. |

#### Trade-off: How host Caddy reaches WP containers

| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| **Per-site published port on `127.0.0.1:<port>`** (e.g. `127.0.0.1:18001:80`) | Caddy snippet is trivial: `reverse_proxy 127.0.0.1:18001`. No Caddy config changes for the docker network. Works with the existing Caddy install. | Need a port allocator (start at 18000, increment). At 20 sites that's 20 ports — fine. | **Chosen** |
| Caddy joins `wp-network` (Caddy in docker, or `--network` on host Caddy) | No published ports. Caddy uses container DNS names. | Host Caddy is *on the host*, not in Docker. Putting it in Docker is a refactor we explicitly rejected. | Rejected |
| Unix domain socket per site | No TCP at all; very fast. | Caddy `reverse_proxy unix//...` works, but containers don't share a unix socket dir with host without a bind mount per site. Adds file-perms complexity. | Rejected — port-on-loopback is simpler and just as fast over `lo`. |

**Port allocation:** CLI maintains `state/sites.json` with `port: 18001..18999`. Bind to `127.0.0.1` only — never `0.0.0.0` — so Cloudflare/Caddy is the only ingress.

### 2. MariaDB Sharing Model

**Decision: One `wp-mariadb` instance. One DB `wp_<slug>` + one user `wp_<slug>` per site, with grants scoped to its own DB.**

```sql
CREATE DATABASE wp_blog1 CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'wp_blog1'@'%' IDENTIFIED BY '<random32>';
GRANT ALL PRIVILEGES ON wp_blog1.* TO 'wp_blog1'@'%';
FLUSH PRIVILEGES;
```

| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| **Shared MariaDB, DB+user per site** | Single InnoDB buffer pool serves all sites efficiently. Scoped grants give meaningful isolation. Standard pattern. | One MariaDB restart blinks every site. | **Chosen** |
| Per-site MariaDB container | True isolation; per-site config. | Each MariaDB ~150 MB RAM idle × 20 sites = 3 GB just for DB engines. Defeats the budget. | Rejected |
| MariaDB on host (not Docker) | Slightly less overhead. | Complicates backup, breaks "one stack to manage", host pollution. | Rejected |
| Single DB + table prefix | One DB, one user. | WordPress isolation across prefixes is leaky (options table, multisite confusion, plugin assumptions). Cross-site SQL injection risk if any plugin is sloppy. | Rejected |

**Volume:** named volume `wp_mariadb_data` (Docker-managed, easier to back up via `docker run --rm -v wp_mariadb_data:/data ...`). Bind mount only if the operator explicitly wants to inspect raw files.

**Buffer pool sizing:** `innodb_buffer_pool_size=512M` initially; revisit when site count > 10. With 4 GB budget for WP stack, this leaves room for php-fpm.

**Healthcheck on MariaDB is mandatory** — `mariadb-admin ping`. WP containers should `depends_on: condition: service_healthy` to avoid race-on-cold-boot.

### 3. Redis Sharing Model

**Decision: One `wp-redis`. Each site uses a separate Redis logical DB index. Start with default 16; raise `databases 64` when needed.**

```
wp-config.php (per site):
  WP_REDIS_HOST = wp-redis
  WP_REDIS_DATABASE = <site_index>   # 0..N
  WP_REDIS_PASSWORD = <shared password>
  WP_REDIS_PREFIX = <slug>:           # belt + suspenders
```

| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| **DB index per site (`SELECT n`)** | Built-in, zero plugin config beyond one constant. `FLUSHDB` per site is clean. | Redis docs caution that multi-DB is "discouraged" but it's still fully supported and widely used for small multi-tenant cases. | **Chosen for ≤ ~50 sites** |
| Key-prefix only, all in DB 0 | Works at unlimited scale; what Redis itself recommends. | Per-site flush is `SCAN + DEL` (slower; risk of partial flush). Cross-site key collision possible if a plugin ignores `WP_REDIS_PREFIX`. | Use as **belt-and-suspenders alongside DB index** (set `WP_REDIS_PREFIX`). |
| Redis ACLs (one user per site) | Real isolation. | Object-cache-pro and `redis-cache` plugin have variable ACL support; adds complexity. | **Graduate to ACLs only if** the project ever onboards untrusted tenants. Single-owner scope = overkill. |
| Per-site Redis container | Total isolation. | Each Redis is small but multiplied = wasted RSS. | Rejected. |

**Persistence:** `--save "" --appendonly no` (cache only — same convention as AudioStoryV2 redis). Loss of Redis = sites refill cache; no data loss. Volume optional.

**Maxmemory:** `--maxmemory 512mb --maxmemory-policy allkeys-lru` (object cache eviction).

### 4. Filesystem Layout

```
/opt/wp/
├── compose/
│   ├── compose.yaml                # shared infra ONLY: network, mariadb, redis
│   └── .env                        # shared infra secrets (mariadb root pw, redis pw)
├── sites/
│   ├── blog1/
│   │   ├── compose.yaml            # generated: wp-blog1 service
│   │   ├── wp-content/             # bind-mounted into container
│   │   ├── nginx.conf              # generated per site (FastCGI cache rules)
│   │   └── php-fpm.conf            # generated per site (pool tuning if needed)
│   └── blog2/...
├── secrets/
│   ├── blog1.env                   # mode 600, contains DB pass, WP salts, admin creds
│   └── blog2.env
├── data/
│   └── (named docker volumes live in /var/lib/docker/volumes — not here)
├── backups/
│   ├── blog1/2026-04-30T12-00.tar.gz
│   └── blog2/...
├── state/
│   ├── sites.json                  # CLI-managed registry: slug, domain, port, redis_db
│   └── sites.json.lock
├── bin/
│   ├── wp-create
│   ├── wp-delete
│   ├── wp-list
│   ├── wp-stats
│   ├── wp-backup
│   └── wp-restore
└── logs/                           # symlinked-in WP/PHP internal logs (rotated by logrotate or forwarded to docker driver)
```

| Decision | Rationale |
|----------|-----------|
| **Bind-mount `wp-content` per site, NOT named volume** | Operator needs to `cp` themes, edit `wp-config-extras.php`, inspect uploads. Named volumes hide files in `/var/lib/docker/volumes`. WP core stays inside the image (immutable; upgrade by image bump). |
| **Named volume for MariaDB data** | DB files don't need host-level inspection; backup is via `mysqldump` not file copy. |
| **Shared compose + per-site compose** | Shared infra = one `compose.yaml` with `wp-mariadb` + `wp-redis` + `wp-network`. Each site gets its own generated `compose.yaml` referencing the external `wp-network`. CLI runs `docker compose -f sites/blog1/compose.yaml up -d`. Avoids one-monolithic-compose churn on every add/delete. |
| **CLI lives in `/opt/wp/bin`, on `$PATH` via `/etc/profile.d/wp.sh`** | Operator runs `wp-create blog.example.com` from any pwd. |

### 5. Secrets Management

**Decision: Per-site `.env` file in `/opt/wp/secrets/<slug>.env` (mode 600, root-owned). Compose loads via `env_file:`. Central `state/sites.json` records non-secret metadata only.**

| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| **Per-site `.env` files** | Trivial; `env_file:` directive is native; easy to rotate one site. | Files on disk — but that's true of everything else here. | **Chosen** |
| Docker secrets | Designed for this. | Requires Swarm mode. We're not on Swarm. | Rejected |
| Central JSON managed by CLI | One file to back up. | Single blast radius; harder to rotate one site without rewriting the whole file. | Rejected (use only for non-secret state registry) |
| HashiCorp Vault / SOPS | Industrial. | Massive overkill for single-owner blogs. | Rejected |

**`wp-list` UX:** by default shows slug + domain + status only. `wp-list --secrets <slug>` reads the env file directly and prints — no shell-history exposure (creds aren't passed as args).

**WP salts:** generate via `curl -s https://api.wordpress.org/secret-key/1.1/salt/` and write to per-site env (then loaded via `define()` in `wp-config.php` template). Re-run rotates everyone out.

### 6. Provisioning Flow (`wp-create blog.example.com`)

```
┌──────────────────────────────────────────────────────────────────────┐
│  wp-create blog.example.com                                          │
└──────────────────────────────────────────────────────────────────────┘
        │
   [1]  ▼  Validate + derive slug
        │   - domain valid? slug = "blog" (or "blog_example_com" if collision)
        │   - slug unique in state/sites.json? (lockfile held)
        │   - allocate next port (18001+) and next redis_db (0+)
        │
   [2]  ▼  Generate secrets
        │   - DB password: openssl rand -hex 24
        │   - WP_AUTH_KEY..NONCE_SALT: api.wordpress.org/secret-key
        │   - admin password: openssl rand -base64 18
        │   - write /opt/wp/secrets/<slug>.env (mode 600)
        │
   [3]  ▼  Provision DB
        │   docker exec wp-mariadb mariadb -uroot -p$ROOT_PW \
        │     -e "CREATE DATABASE wp_<slug>; CREATE USER 'wp_<slug>'..."
        │   ROLLBACK POINT A: drop DB+user on later failure
        │
   [4]  ▼  Materialize site directory + compose
        │   mkdir /opt/wp/sites/<slug>/wp-content
        │   render compose.yaml from template (port, env_file, volume, redis_db)
        │   render nginx.conf, php-fpm.conf
        │   ROLLBACK POINT B: rm -rf on later failure
        │
   [5]  ▼  Boot container
        │   docker compose -f .../compose.yaml up -d
        │   wait for container healthcheck (HTTP 200 on / inside container)
        │   ROLLBACK POINT C: docker compose down + rm
        │
   [6]  ▼  Install WordPress
        │   docker exec wp-<slug> wp core install \
        │     --url=https://<domain> --title=... \
        │     --admin_user=admin --admin_password=$ADMIN_PW --admin_email=...
        │
   [7]  ▼  Configure caching + baseline
        │   wp plugin install redis-cache --activate
        │   wp redis enable
        │   wp rewrite structure '/%postname%/'
        │   wp option update blog_public 1
        │   (optional) wp plugin install w3-total-cache OR enable nginx FastCGI cache
        │
   [8]  ▼  Register in state
        │   write to state/sites.json: { slug, domain, port, redis_db, created_at }
        │
   [9]  ▼  Print operator handoff
        │   - admin URL + creds
        │   - Cloudflare DNS rows to add (A or CNAME)
        │   - Caddy block to paste into /etc/caddy/Caddyfile.d/<slug>.caddy
        │   - "now reload caddy: sudo systemctl reload caddy"
        ▼
      DONE
```

**Failure semantics:** each ROLLBACK POINT is reverse-ordered cleanup. Steps 1–2 are pure-local (no rollback). Steps 3–8 each have a corresponding undo. CLI traps `ERR` and runs the appropriate teardown. **Idempotent re-run with same slug must detect "already provisioned" and exit cleanly** (no double-create).

### 7. Deletion Flow (`wp-delete <slug>`)

```
[1] Confirm (interactive unless --yes)
[2] Optional archive: wp-backup <slug> --to /opt/wp/backups/<slug>/pre-delete-<ts>.tar.gz
    (mysqldump + tar of wp-content + env file)
[3] docker compose -f sites/<slug>/compose.yaml down -v
[4] docker exec wp-mariadb mariadb -e "DROP DATABASE wp_<slug>; DROP USER 'wp_<slug>'@'%';"
[5] docker exec wp-redis redis-cli -n <redis_db> FLUSHDB
[6] rm -rf /opt/wp/sites/<slug>            (only if --purge; default keeps wp-content)
[7] rm /opt/wp/secrets/<slug>.env
[8] Update state/sites.json (remove entry, free port + redis_db)
[9] Print Caddy + Cloudflare cleanup snippets to remove
```

`wp-delete` defaults to **archive + drop DB + keep wp-content on disk** (operator can `rm -rf` later). Destructive `--purge` flag for full removal.

### 8. Dashboard Architecture

**Decision: Standalone container on `wp-network`, behind host Caddy + Caddy basic auth. Calls CLI via a *narrow* sudo-wrapper (NOT the docker socket).**

```
Browser ──▶ Host Caddy (basic_auth) ──▶ wp-dashboard (PHP) ──┬─▶ docker stats (read-only, requires socket)
                                                              ├─▶ /opt/wp/bin/wp-list  (shell-out, read-only)
                                                              └─▶ sudo /opt/wp/bin/wp-create-confirmed <slug>
                                                                  (whitelisted in sudoers; NOT raw shell)
```

| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| Mount docker socket into dashboard | Native API access. | Mounting `/var/run/docker.sock` = root-on-host equivalent. With basic auth as the only barrier, this is risky. | Rejected for write ops; **acceptable read-only** for `docker stats` if mounted via a `docker-socket-proxy` (read-only sidecar). |
| Sudo wrapper for narrow CLI commands | Principle of least privilege. Auditable in `/var/log/auth.log`. | Slightly more code (one `sudoers.d/wp-dashboard` file). | **Chosen** |
| Separate provisioner HTTP API | Clean boundary. | Yet another component to maintain. Overkill for solo-owner internal tool. | Defer until justified. |
| Drop on host nginx | Avoids a container. | Adds host-PHP setup; couples to host. We're container-first everywhere else. | Rejected |

**Auth:** Caddy `basic_auth` is sufficient for an internal tool. Anything heavier (SSO, OAuth) is rejected per project scope.

### 9. Failure Modes & Mitigations

| Failure | Blast radius | Mitigation |
|---------|--------------|------------|
| One WP container OOMs | That site only | `mem_limit: 512m`, `memswap_limit: 512m`, `restart: unless-stopped` per site. PHP `memory_limit=256M`. Docker kills the offender; others unaffected. |
| Shared MariaDB restarts | All sites blink | `restart: unless-stopped`, healthcheck, sites have `depends_on: condition: service_healthy`. WP retries on transient connect errors (default behavior). Plan maintenance windows; auto-restart is fast (~3 s). |
| Disk fill from logs | Whole VM | Already mitigated: docker logging driver `max-size: 10m, max-file: 3` on every service (matches AudioStoryV2). WP `debug.log` and php-fpm error log go through stdout → docker driver, no separate file rotation needed. |
| Disk fill from uploads | Whole VM | `df` warning in `wp-stats`. Operator-triage; not auto-mitigated. |
| Port collision with future service | New site fails to bind | CLI checks `state/sites.json` AND `ss -ltn` on the chosen port before publishing. |
| Redis OOM | Cache misses, all sites slower | `--maxmemory 512mb --maxmemory-policy allkeys-lru` — well-defined eviction, no OOM kill. |
| Backup corruption | Catastrophic on restore | Verify after backup: `gzip -t` + `mysqldump` parse-check. `wp-backup --verify` flag default-on. |

### 10. Build Order / Dependency Graph

```
Phase 1 (Foundation)
  ├─ Docker network: wp-network
  ├─ wp-mariadb (with healthcheck, named volume)
  └─ wp-redis (no persistence, password-protected)
        │
        ▼
Phase 2 (CLI Core)
  ├─ /opt/wp/bin/wp-create  (full provisioning flow, rollback)
  ├─ /opt/wp/bin/wp-delete  (with archive)
  ├─ /opt/wp/bin/wp-list
  └─ state/sites.json registry + lockfile
        │
        ▼
Phase 3 (First Site E2E)
  ├─ Compose template + nginx/php-fpm/wp-config templates
  ├─ Per-site image strategy locked in (single container vs nginx+php-fpm sidecar)
  ├─ FastCGI cache config validated
  └─ Caddy + Cloudflare snippets verified by hand on one real domain
        │
        ▼
Phase 4 (Operational Tooling)
  ├─ wp-stats (docker stats wrapper + df + per-site disk)
  ├─ wp-backup / wp-restore
  └─ logrotate or driver-config audit
        │
        ▼
Phase 5 (Polish)
  ├─ Dashboard container (read-only first, then add/delete buttons via sudo-wrapper)
  └─ Docs: Caddy snippet template, Cloudflare runbook, restore drill
```

**Critical ordering:**
- Shared infra MUST be up **and healthy** before any `wp-create` runs.
- CLI must exist **before** Phase 3 — first site is created via the real CLI, not by hand. (Validates the CLI on the first use, not the 5th.)
- Dashboard is **last** — it depends on a stable CLI surface to shell out to.
- Backup tooling exists **before** any site holds non-trivial content. Don't build the 3rd site without `wp-backup`.

---

## Recommended Project Structure (repo)

```
MultiWordpress/
├── compose/
│   ├── compose.yaml                # shared infra (mariadb, redis, network)
│   └── .env.example
├── bin/                            # → installs to /opt/wp/bin on the VM
│   ├── wp-create
│   ├── wp-delete
│   ├── wp-list
│   ├── wp-stats
│   ├── wp-backup
│   └── wp-restore
├── lib/                            # shared bash helpers sourced by bin/*
│   ├── state.sh                    # sites.json read/write w/ lockfile
│   ├── docker.sh                   # wrappers
│   ├── mariadb.sh                  # CREATE/DROP DB+user
│   ├── redis.sh                    # FLUSHDB by index
│   ├── secrets.sh                  # generation + env file management
│   └── rollback.sh                 # trap-based teardown
├── templates/
│   ├── site.compose.yaml.tmpl      # rendered per site
│   ├── nginx.conf.tmpl
│   ├── php-fpm.conf.tmpl
│   ├── wp-config-extras.php.tmpl
│   └── caddy-snippet.tmpl          # printed to operator
├── images/
│   └── wp-site/                    # if we build a custom image
│       ├── Dockerfile
│       └── entrypoint.sh
├── dashboard/                      # phase 5
│   ├── Dockerfile
│   ├── compose.yaml
│   └── public/
├── deploy/
│   ├── install.sh                  # bootstrap on a fresh VM (creates /opt/wp tree)
│   └── sudoers.d-wp-dashboard
├── docs/
│   ├── caddy-setup.md
│   ├── cloudflare-runbook.md
│   ├── backup-restore.md
│   └── disaster-recovery.md
└── .planning/
```

---

## Per-Site Image Trade-off (call out for STACK.md)

| Option | Pros | Cons |
|--------|------|------|
| **Single container: nginx + php-fpm + WP** (custom image based on `wordpress:php8.3-fpm-alpine` + nginx layer) | One container per site = one entry in `docker stats`. Simpler compose. nginx FastCGI cache lives next to fpm. | Two processes in one container (s6-overlay or supervisord) — slight anti-pattern, manageable. |
| Sidecar: `wp-<site>-fpm` + `wp-<site>-nginx` | "One process per container" purity. | 2× container count. At 20 sites = 40 containers + 40 docker-stats lines. Networking between them adds complexity. |

**Recommendation: single-container per site** for this project's "lightweight, scales to 20" goal. Defer to STACK.md for image specifics.

---

## Anti-Patterns

### Anti-Pattern 1: Reverse proxy inside the WP stack

**What people do:** Spin up `wp-caddy` or `wp-traefik` to front the WP containers.
**Why it's wrong:** Host Caddy already does this for the Next.js app. Two reverse proxies chained = double TLS termination question, double access logs, double config surface.
**Do this instead:** Publish each WP container on `127.0.0.1:<unique-port>` and have host Caddy `reverse_proxy` to it. CLI prints the snippet.

### Anti-Pattern 2: One mega-compose for all sites

**What people do:** A single `compose.yaml` with all 20 site services, regenerated on every add/delete.
**Why it's wrong:** Every `docker compose up` re-evaluates the full file; bugs ripple across sites. Diff/audit is painful.
**Do this instead:** Shared infra in one compose; each site in its own compose file referencing the external `wp-network`. Touching one site is independent.

### Anti-Pattern 3: Storing WP core in a bind-mounted volume

**What people do:** Bind-mount the entire WordPress directory from host into the container.
**Why it's wrong:** Slow on Docker-for-Mac (irrelevant on Linux but still bad practice). Conflates immutable artifacts (core) with mutable data (uploads). Upgrades become file copies on host.
**Do this instead:** WP core in the image (upgrade = image bump). Bind-mount **only `wp-content`** (themes, plugins, uploads, mu-plugins).

### Anti-Pattern 4: Skipping Redis prefix when using DB index

**What people do:** Trust the DB-index isolation alone, skip `WP_REDIS_PREFIX`.
**Why it's wrong:** A misbehaving plugin that calls `redis-cli -n 0` directly bypasses your assumption. Belt and suspenders cost nothing.
**Do this instead:** Set both `WP_REDIS_DATABASE` and `WP_REDIS_PREFIX = '<slug>:'`.

### Anti-Pattern 5: Passing secrets as `docker run -e` args

**What people do:** `docker run -e WP_DB_PASSWORD=foo ...`.
**Why it's wrong:** Visible in `ps`, in shell history, in any monitoring agent that captures process args.
**Do this instead:** `env_file:` directive in compose, env file mode 600.

---

## Integration Points

### External Services

| Service | Integration Pattern | Notes |
|---------|---------------------|-------|
| Cloudflare DNS | **Manual** — CLI prints rows to add | Per project scope; no API automation. |
| Host Caddy | **Manual** — CLI prints Caddy block to paste; operator runs `systemctl reload caddy` | Caddy file lives on host (e.g. `/etc/caddy/Caddyfile.d/<slug>.caddy`). Untouched by automation. |
| Let's Encrypt | Implicit via host Caddy auto-HTTPS | Nothing for our stack to do. |

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| Host Caddy ↔ wp-\<site\> | TCP on `127.0.0.1:<port>` | Loopback only; never bind `0.0.0.0`. |
| wp-\<site\> ↔ wp-mariadb | TCP via docker DNS `wp-mariadb:3306` | On `wp-network` only. |
| wp-\<site\> ↔ wp-redis | TCP via docker DNS `wp-redis:6379` | Password-auth + DB index. |
| CLI ↔ MariaDB | `docker exec wp-mariadb mariadb` | Uses root credentials from `compose/.env`; never over network. |
| CLI ↔ Redis | `docker exec wp-redis redis-cli` | Same pattern. |
| Dashboard ↔ CLI | Narrow sudo-wrapper for write ops; direct read for `wp-list` | Whitelisted commands in `sudoers.d/wp-dashboard`. |
| Dashboard ↔ docker stats | Read-only docker-socket-proxy sidecar (Phase 5+) | No raw socket exposure. |

---

## Scaling Considerations

| Scale | Architecture Adjustments |
|-------|--------------------------|
| 1–5 sites (today) | Default config. MariaDB buffer pool 512M. Redis 512M. Each WP `mem_limit: 512m`. |
| 5–20 sites (target) | Bump MariaDB buffer pool to 1G. Watch `docker stats` for php-fpm pile-up; consider lowering `pm.max_children` per site. Redis still 512M (LRU absorbs it). |
| 20+ sites (out of project scope but worth knowing) | At this point: (a) raise Redis `databases 64`, (b) consider per-host MariaDB tuning (`innodb_buffer_pool_instances`), (c) start asking whether VM size is still right. **This project doesn't promise this scale** — VM is `n2-standard-2` (2 vCPU / 8 GB) and stack is budgeted to 50% of it. |

### What breaks first (predicted)

1. **php-fpm worker exhaustion** during a traffic spike on any one site → that site queues, others fine due to per-container limits. Fix: tune `pm.max_children` per site.
2. **MariaDB connection limit** (`max_connections=151` default) at ~10 sites × 15 connections each. Fix: bump to 500.
3. **Disk** — uploads dir growth across sites. Fix: per-site disk usage in `wp-stats`; offload to object storage if it ever matters (out of scope today).

---

## Sources

- Docker official docs — user-defined bridge networks, healthchecks, logging drivers
- MariaDB official docs — `GRANT`, `mariadb-admin ping`, `innodb_buffer_pool_size` tuning
- Redis official docs — multiple databases (`databases` directive, `SELECT`), discouragement note, ACLs
- WordPress Codex — `wp-config.php` constants, secret keys API, WP-CLI `core install`
- `redis-cache` plugin (Till Krüss / Object Cache Pro) — `WP_REDIS_DATABASE`, `WP_REDIS_PREFIX`
- AudioStoryV2 in-repo `compose.yaml` — log driver convention (`max-size: 10m, max-file: 3`), bridge network naming, healthcheck pattern
- Project: `/Users/work/Projects/MultiWordpress/.planning/PROJECT.md` — constraints, scope, anti-patterns

---
*Architecture research for: Multi-WordPress hosting on single VM*
*Researched: 2026-04-30*
