---
phase: 01-foundation
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - compose/compose.yaml
  - compose/.env.example
autonomous: true
requirements: [INFRA-01, INFRA-02, INFRA-03, INFRA-04, INFRA-06, HARD-01, HARD-03]
must_haves:
  truths:
    - "Operator runs `docker compose -f compose/compose.yaml up -d` and both wp-mariadb and wp-redis come up healthy."
    - "wp-mariadb listens on 127.0.0.1:13306 only; wp-redis listens on 127.0.0.1:16379 only."
    - "wp-network bridge exists with MTU 1460."
    - "All services log via json-file driver capped at 10m × 3 with compress=true."
    - "MariaDB data persists across container restart via named volume wp_mariadb_data."
    - "Every image references a pinned tag (no :latest)."
  artifacts:
    - path: "compose/compose.yaml"
      provides: "Shared infra: wp-mariadb, wp-redis, wp-network"
      contains: "wp-mariadb, wp-redis, wp-network, mtu, 1460, 13306, 16379, json-file"
    - path: "compose/.env.example"
      provides: "Template for MARIADB_ROOT_PASSWORD"
      contains: "MARIADB_ROOT_PASSWORD"
  key_links:
    - from: "compose/compose.yaml: networks.wp-network"
      to: "driver_opts com.docker.network.driver.mtu=1460"
      via: "compose driver_opts"
      pattern: "com\\.docker\\.network\\.driver\\.mtu.*1460"
    - from: "compose/compose.yaml: wp-mariadb.ports"
      to: "127.0.0.1:13306"
      via: "loopback-only port binding"
      pattern: "127\\.0\\.0\\.1:13306"
    - from: "compose/compose.yaml: wp-redis.ports"
      to: "127.0.0.1:16379"
      via: "loopback-only port binding"
      pattern: "127\\.0\\.0\\.1:16379"
---

<objective>
Author the shared-infrastructure Docker Compose file and its env template. This stack provides the MariaDB engine and Redis cache that every per-site WP container (built in Phase 2) will share.

Purpose: Lock down the day-one infra pitfalls (MTU mismatch, port collision with AudioStoryV2, log-driven disk fill, image tag drift) before any site exists.
Output: `compose/compose.yaml` + `compose/.env.example` that pass the success criteria in ROADMAP.md §Phase 1 #1, #2.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/REQUIREMENTS.md
@.planning/research/STACK.md
@.planning/research/ARCHITECTURE.md
@.planning/research/PITFALLS.md
@.planning/phases/01-foundation/01-CONTEXT.md

<reference_only>
The following file is a READ-ONLY reference from a sibling project. Use it ONLY to mirror logging-driver shape, healthcheck pattern, and `restart: unless-stopped` convention. DO NOT modify it. Note that AudioStoryV2 uses `volatile-lru` and password-protected redis on 0.0.0.0:6379 — we deliberately diverge.

@/Users/work/Projects/AudioStoryV2/compose.yaml
</reference_only>
</context>

<tasks>

<task type="auto">
  <name>Task 1: Write compose/compose.yaml</name>
  <files>compose/compose.yaml</files>
  <action>
Create the shared-infra compose file. Exact requirements (do not paraphrase — these are spec):

Top-level structure:
- `services:` with two services: `wp-mariadb` and `wp-redis`
- `networks:` with one network: `wp-network`
- `volumes:` with one named volume: `wp_mariadb_data`

Service `wp-mariadb`:
- `image: mariadb:11.4` (HARD-03: pinned tag, never :latest)
- `container_name: wp-mariadb`
- `restart: unless-stopped` (INFRA-06)
- `command:` arguments to set:
  - `--innodb-buffer-pool-size=384M`
  - `--max-connections=200`
  - `--character-set-server=utf8mb4`
  - `--collation-server=utf8mb4_unicode_ci`
  - `--innodb-flush-log-at-trx-commit=2`
  - `--innodb-flush-method=O_DIRECT`
- `environment:`
  - `MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}` (sourced from .env)
  - `MARIADB_AUTO_UPGRADE: "1"`
- `ports: ["127.0.0.1:13306:3306"]` (HARD-01: loopback only — never 0.0.0.0)
- `volumes: ["wp_mariadb_data:/var/lib/mysql"]` (named volume per CONTEXT decision; INFRA-01)
- `networks: [wp-network]`
- `mem_limit: 1g` and `mem_reservation: 512m` (per CONTEXT — MariaDB has its own cap, NOT in wp.slice)
- `healthcheck:` (INFRA-01)
  - `test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]`
  - `interval: 10s`
  - `timeout: 5s`
  - `retries: 5`
  - `start_period: 30s`
- `logging:` json-file driver with `max-size: "10m"`, `max-file: "3"`, `compress: "true"` (INFRA-01, project log-cap convention)

Service `wp-redis`:
- `image: redis:7-alpine` (HARD-03)
- `container_name: wp-redis`
- `restart: unless-stopped` (INFRA-06)
- `command: >` block with these flags exactly (per CONTEXT — diverges from AudioStoryV2's volatile-lru):
  ```
  redis-server
    --maxmemory 256mb
    --maxmemory-policy allkeys-lru
    --save ""
    --appendonly no
    --tcp-backlog 511
    --tcp-keepalive 300
    --lazyfree-lazy-eviction yes
    --lazyfree-lazy-expire yes
    --loglevel notice
  ```
- `ports: ["127.0.0.1:16379:6379"]` (INFRA-02 + HARD-01: loopback only on alt port to avoid AudioStoryV2's 6379)
- `networks: [wp-network]`
- `mem_limit: 320m` (per CONTEXT — Redis has its own cap, NOT in wp.slice)
- `healthcheck:`
  - `test: ["CMD", "redis-cli", "ping"]`
  - `interval: 5s`
  - `timeout: 3s`
  - `retries: 5`
- `logging:` json-file driver with `max-size: "10m"`, `max-file: "3"`, `compress: "true"`
- DO NOT password-protect (per CONTEXT — loopback-only is the boundary)

Network `wp-network` (INFRA-03):
- `driver: bridge`
- `name: wp-network` (so `docker network inspect wp-network` works directly; not project-prefixed)
- `driver_opts:`
  - `com.docker.network.driver.mtu: "1460"` (closes PITFALLS §4.5 — GCP VPC MTU; the value is a string, not int)

Volume `wp_mariadb_data`:
- Default Docker-managed named volume (no driver options).

Top of file: include a leading comment block listing the requirements this file covers (INFRA-01, INFRA-02, INFRA-03, INFRA-04, INFRA-06, HARD-01, HARD-03) and noting that wp-mariadb/wp-redis run with their own `mem_limit` and are NOT in wp.slice (INFRA-05 boundary — that's per-site WP only).

DO NOT add: any wp-* per-site service (Phase 2), any 0.0.0.0 binding, any `:latest` tag, password on Redis, separate redis.conf file, or persistence volume on Redis.
  </action>
  <verify>
    <automated>docker compose -f compose/compose.yaml config -q && grep -q 'mtu: "1460"' compose/compose.yaml && grep -q '127.0.0.1:13306:3306' compose/compose.yaml && grep -q '127.0.0.1:16379:6379' compose/compose.yaml && grep -q 'mariadb:11.4' compose/compose.yaml && grep -q 'redis:7-alpine' compose/compose.yaml && grep -q 'allkeys-lru' compose/compose.yaml && ! grep -E '0\.0\.0\.0|:latest' compose/compose.yaml</automated>
  </verify>
  <done>
`docker compose -f compose/compose.yaml config` parses successfully. File contains exact tags `mariadb:11.4` and `redis:7-alpine`, MTU `"1460"`, loopback-only port mappings, and no `:latest` or `0.0.0.0`.
  </done>
</task>

<task type="auto">
  <name>Task 2: Write compose/.env.example</name>
  <files>compose/.env.example</files>
  <action>
Create `compose/.env.example` as the template the operator copies to `compose/.env` (or `/opt/wp/.env` on the VM, mode 600). Contents:

```
# MultiWordpress shared infrastructure secrets.
# Copy to compose/.env (chmod 600) before running `docker compose up -d`.
# Phase 1 only requires MARIADB_ROOT_PASSWORD; per-site DB user passwords are
# generated and managed by Phase 2's wp-create.

# MariaDB root credential. Generate with: openssl rand -hex 24
MARIADB_ROOT_PASSWORD=replace-with-openssl-rand-hex-24
```

DO NOT include: real secrets, REDIS_PASSWORD (we don't use one — loopback-only is the boundary), per-site placeholders.
  </action>
  <verify>
    <automated>test -f compose/.env.example && grep -q 'MARIADB_ROOT_PASSWORD' compose/.env.example && ! grep -E 'REDIS_PASSWORD' compose/.env.example</automated>
  </verify>
  <done>
File exists, contains a placeholder for MARIADB_ROOT_PASSWORD, contains a comment instructing operator to copy to .env with mode 600, contains no REDIS_PASSWORD entry.
  </done>
</task>

</tasks>

<verification>
After both tasks complete, the operator should be able to (manual smoke test, run by executor where possible):
1. `cp compose/.env.example compose/.env` and fill MARIADB_ROOT_PASSWORD.
2. `docker compose -f compose/compose.yaml config` — parses cleanly.
3. (On VM) `docker compose -f compose/compose.yaml up -d` brings both services up healthy within ~30s.
4. `docker network inspect wp-network --format '{{.Options}}'` includes `com.docker.network.driver.mtu:1460`.
5. `ss -ltn | grep -E ':(13306|16379)'` shows binds on 127.0.0.1, never 0.0.0.0.
6. AudioStoryV2 `docker compose ps` (in its own dir) still shows web + redis healthy on :3000 / :6379.
</verification>

<success_criteria>
- ROADMAP §Phase 1 success criteria #1, #2 satisfied by this plan's artifacts.
- `docker compose config` validates the file (CI-equivalent check).
- All listed requirements (INFRA-01, INFRA-02, INFRA-03, INFRA-04, INFRA-06, HARD-01, HARD-03) traceable to specific lines in compose.yaml.
</success_criteria>

<output>
Create `.planning/phases/01-foundation/01-01-SUMMARY.md` documenting:
- Final values shipped (image tags, ports, MTU, log caps).
- Any deviation from CONTEXT and why (expected: none).
- The exact `docker compose config` output snippet showing MTU + ports.
</output>
