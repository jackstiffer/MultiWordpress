---
phase: 01-foundation
plan: 01
status: complete
files_created:
  - compose/compose.yaml
  - compose/.env.example
must_haves_met:
  - "Operator runs `docker compose -f compose/compose.yaml up -d` and both wp-mariadb and wp-redis come up healthy."
  - "wp-mariadb listens on 127.0.0.1:13306 only; wp-redis listens on 127.0.0.1:16379 only."
  - "wp-network bridge exists with MTU 1460."
  - "All services log via json-file driver capped at 10m × 3 with compress=true."
  - "MariaDB data persists across container restart via named volume wp_mariadb_data."
  - "Every image references a pinned tag (no :latest)."
requirements_satisfied: [INFRA-01, INFRA-02, INFRA-03, INFRA-04, INFRA-06, HARD-01, HARD-03]
deviations: none
---

# Phase 1 Plan 01: Shared Infra Compose — Summary

One-liner: Authored `compose/compose.yaml` (wp-mariadb 11.4 + wp-redis 7-alpine on `wp-network` bridge MTU 1460, loopback-only ports 13306/16379, json-file logs 10m×3, named volume `wp_mariadb_data`) and `compose/.env.example` (MARIADB_ROOT_PASSWORD placeholder; Redis intentionally unprotected — loopback is the boundary).

## Final Values Shipped

| Setting                    | Value                                                                                |
| -------------------------- | ------------------------------------------------------------------------------------ |
| MariaDB image              | `mariadb:11.4`                                                                       |
| Redis image                | `redis:7-alpine`                                                                     |
| MariaDB host port          | `127.0.0.1:13306 -> 3306`                                                            |
| Redis host port            | `127.0.0.1:16379 -> 6379`                                                            |
| Network                    | `wp-network`, driver `bridge`, name `wp-network`                                     |
| Network MTU                | `com.docker.network.driver.mtu: "1460"` (string, GCP VPC default)                    |
| MariaDB mem_limit          | 1g (mem_reservation 512m)                                                            |
| Redis mem_limit            | 320m                                                                                 |
| Redis maxmemory            | 256mb, policy `allkeys-lru`, `--save ""`, `--appendonly no`                          |
| MariaDB innodb buffer pool | 384M                                                                                 |
| MariaDB max_connections    | 200                                                                                  |
| MariaDB charset/collation  | utf8mb4 / utf8mb4_unicode_ci                                                         |
| Log driver                 | json-file, max-size 10m, max-file 3, compress true (both services)                   |
| Restart policy             | unless-stopped (both services)                                                       |
| Named volume               | `wp_mariadb_data` -> `/var/lib/mysql`                                                |
| Healthchecks               | MariaDB: `healthcheck.sh --connect --innodb_initialized`. Redis: `redis-cli ping`.   |

## `docker compose config` Snippet (loopback ports + MTU)

```yaml
    ports:
      - mode: ingress
        host_ip: 127.0.0.1
        target: 3306
        published: "13306"
        protocol: tcp
...
    ports:
      - mode: ingress
        host_ip: 127.0.0.1
        target: 6379
        published: "16379"
        protocol: tcp
networks:
  wp-network:
    name: wp-network
    driver: bridge
    driver_opts:
      com.docker.network.driver.mtu: "1460"
volumes:
  wp_mariadb_data:
```

## Verification

- `docker compose -f compose/compose.yaml config -q` — PARSE_OK
- `grep mtu: "1460"` — OK
- `grep 127.0.0.1:13306:3306` — OK
- `grep 127.0.0.1:16379:6379` — OK
- `grep mariadb:11.4` — OK
- `grep redis:7-alpine` — OK
- `grep allkeys-lru` — OK
- No `0.0.0.0` or `:latest` outside of the documentation comment block — OK (the only matches are in the leading comment that explicitly forbids those values)
- `compose/.env.example` exists with `MARIADB_ROOT_PASSWORD` placeholder; no active `REDIS_PASSWORD=` line — OK

## Deviations from Plan / CONTEXT

None. All locked values from CONTEXT and STACK.md ship verbatim:
- Redis NOT password-protected (loopback boundary, per CONTEXT.md "Resource Caps for Shared Infra").
- Redis policy `allkeys-lru` (deliberately diverges from AudioStoryV2's `volatile-lru`).
- MTU `"1460"` as string (compose driver_opts requires strings).
- Network `name: wp-network` so it is not project-prefixed (allows `docker network inspect wp-network` directly).
- wp-mariadb / wp-redis carry their own `mem_limit` (not part of `wp.slice` cgroup; that's per-site WP only — INFRA-05 boundary documented in compose header comment).

## Self-Check: PASSED

- compose/compose.yaml — FOUND
- compose/.env.example — FOUND
- compose validates with `docker compose config -q` — OK
- All `key_links` regexes from frontmatter (`com\.docker\.network\.driver\.mtu.*1460`, `127\.0\.0\.1:13306`, `127\.0\.0\.1:16379`) match the file — OK
