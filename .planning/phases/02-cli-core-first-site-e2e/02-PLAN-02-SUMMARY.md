---
phase: 02-cli-core-first-site-e2e
plan: 02
subsystem: cli/templates
status: complete
tags: [templates, compose, wp-config, caddy, cloudflare, hardening]
requirements_covered: [HARD-02, PERF-01, PERF-02, STATE-03]
files_created:
  - templates/site.compose.yaml.tmpl
  - templates/wp-config-extras.php.tmpl
  - templates/caddy-block.tmpl
  - templates/cloudflare-dns.tmpl
  - templates/cloudflare-cache-rule.md
files_modified: []
must_haves_met:
  - "Per-site compose template renders with envsubst given {SLUG, PORT, REDIS_DB, DOMAIN}"
  - "wp-config-extras.php disables XML-RPC, sets DISABLE_WP_CRON, configures redis prefix/db, points debug log to fd/2 (commented production-default)"
  - "Caddy block template uses php_fastcgi to 127.0.0.1:<port>"
  - "Cloudflare DNS template documents the A-record-proxied row"
  - "Cloudflare Cache Rule doc names the cookie-bypass patterns verbatim"
  - "Compose template has cgroup_parent: wp.slice and NO per-container memory cap directive"
deviations:
  - "[Rule 1 - Bug] Removed `depends_on: [wp-mariadb, wp-redis]` from per-site compose template. The shared infra services live in a SEPARATE compose project (compose/compose.yaml); Docker Compose `depends_on` cannot reference services across projects, so retaining the directive caused `docker compose config` to error with `service \"wp-X\" depends on undefined service \"wp-mariadb\": invalid compose project`. Replaced with a comment explaining that wp-create must assert shared infra is healthy before launching the per-site compose. CONTEXT.md `Per-Site Compose Template` showed depends_on, so this is a correction to the plan spec."
  - "[Rule 2 - Critical] Added Caddy block hardening absent from CONTEXT.md verbatim block: 403 on /xmlrpc.php (matches the wp-config XML-RPC stance) and a path_regexp 403 for /wp-content/uploads/*.php (defense in depth against PHP execution from upload writes). Also added `zstd` alongside `gzip` for the encode directive — modern Caddy supports both, no cost."
  - "[Rule 2 - Critical] wp-config-extras.php template adds the 8 WP secret-key/salt defines (AUTH_KEY..NONCE_SALT) sourcing from .env getenv. Plan listing of extras did not enumerate these but the per-site .env spec in CONTEXT.md ships WP_AUTH_KEY..WP_NONCE_SALT and they MUST be wired into wp-config or WordPress falls back to default constants which is a security flaw."
  - "Plan output spec named the SUMMARY `02-02-SUMMARY.md`; existing Phase 2 convention (see 02-PLAN-01-SUMMARY.md) uses `02-PLAN-NN-SUMMARY.md`. Followed existing convention."
key_decisions:
  - "Placeholder syntax: `{{slug}}`, `{{port}}`, `{{redis_db}}`, `{{domain}}` for *.tmpl; `{{subdomain_or_at}}` and `{{vm_public_ip}}` for cloudflare-dns.tmpl. wp-create will substitute via sed (safe since slug is sanitized to [a-z0-9_], port is integer, redis_db is integer, domain is validated)."
  - "wp-config-extras.php uses both `add_filter('xmlrpc_enabled', '__return_false')` AND a Caddy 403 on /xmlrpc.php. Caddy is authoritative; the wp-config filters are belt-and-suspenders for any path that bypasses the edge (internal cron, debug shells, REST calls)."
  - "All WP_DEBUG defaults are off in production. A commented block shows how to flip on debug logging to /proc/self/fd/2 so Docker's json-file driver picks it up — no on-disk debug.log to forget about."
metrics:
  duration_minutes: ~6
  completed_date: 2026-04-30
---

# Phase 2 Plan 02: Templates Summary

**One-liner:** Five paste-in / render-in artifacts under `templates/` that encode every per-site hardening decision (XML-RPC off, no per-container memory cap, shared cgroup, Redis per-site DB+prefix) and produce the operator-facing snippets for Caddy + Cloudflare DNS + Cloudflare Cache Rule with cookie-bypass.

## Placeholder Set (for wp-create sed substitution)

| Placeholder           | Source                          | Used in                              |
| --------------------- | ------------------------------- | ------------------------------------ |
| `{{slug}}`            | sanitized domain                | site.compose.yaml.tmpl, caddy-block.tmpl |
| `{{port}}`            | port allocator (18000–18999)    | site.compose.yaml.tmpl, caddy-block.tmpl |
| `{{redis_db}}`        | redis-db allocator (1–63)       | site.compose.yaml.tmpl (env injection) |
| `{{domain}}`          | original domain arg             | site.compose.yaml.tmpl, caddy-block.tmpl, cloudflare-dns.tmpl, cloudflare-cache-rule.md |
| `{{subdomain_or_at}}` | derived from domain (apex → @)  | cloudflare-dns.tmpl                  |
| `{{vm_public_ip}}`    | env / config                    | cloudflare-dns.tmpl                  |

`wp-config-extras.php.tmpl` has no placeholders — all values come from the per-site `.env` via `getenv()` at PHP runtime.

## Files

### `templates/site.compose.yaml.tmpl`
Per-site compose. `cgroup_parent: wp.slice`, port 127.0.0.1:{{port}}:9000, env_file /opt/wp/secrets/{{slug}}.env, volumes /opt/wp/sites/{{slug}}/wp-content, json-file logging (10m × 3, compressed), restart unless-stopped. External `wp-network`. NO per-container memory cap (HARD-02 invariant). depends_on omitted (cross-project limitation — see deviation 1).

### `templates/wp-config-extras.php.tmpl`
PHP fragment injected above `/* That's all, stop editing! */`:
- `add_filter('xmlrpc_enabled', '__return_false')` + X-Pingback header strip + `XMLRPC_REQUEST=false` constant
- `DISABLE_WP_CRON=true`
- `WP_HOME` / `WP_SITEURL` from env
- `WP_REDIS_HOST` / `WP_REDIS_DATABASE` (cast int) / `WP_REDIS_PREFIX` from env
- All 8 WP secret keys/salts from env (AUTH_KEY, SECURE_AUTH_KEY, LOGGED_IN_KEY, NONCE_KEY, AUTH_SALT, SECURE_AUTH_SALT, LOGGED_IN_SALT, NONCE_SALT)
- WP_DEBUG defaults to false, with a commented block showing how to enable fd/2 logging.

### `templates/caddy-block.tmpl`
Reverse-proxy block: `php_fastcgi 127.0.0.1:{{port}}`, root at wp-content, 403 on /wp-content/uploads/*.php and /xmlrpc.php, gzip+zstd encoding, log discard.

### `templates/cloudflare-dns.tmpl`
Tabular A-record reference (Proxied) with `{{subdomain_or_at}}` and `{{vm_public_ip}}` placeholders.

### `templates/cloudflare-cache-rule.md`
Reference doc for the once-per-zone Cache Rule: hostname + GET match, bypass on cookies `wordpress_logged_in_`, `wp-postpass_`, `comment_author_`, `woocommerce_items_in_cart`, `woocommerce_cart_hash`. Edge TTL 4h. Validation curls (cf-cache-status HIT vs BYPASS). Anti-pattern note: don't enable APO simultaneously. Companion: Super Page Cache for Cloudflare plugin via wp-exec.

## Verification

- All 5 files exist under `templates/`.
- `cgroup_parent: wp.slice` present, no `mem_limit` / `mem_reservation` in compose template.
- `xmlrpc_enabled`, `XMLRPC_REQUEST`, `DISABLE_WP_CRON`, `WP_REDIS_DATABASE` present in wp-config-extras.
- `php_fastcgi 127.0.0.1:{{port}}` present in caddy-block.
- `Proxied` present in cloudflare-dns.
- `wordpress_logged_in_`, `wp-postpass_`, `comment_author_`, `super-page-cache-for-cloudflare` present in cloudflare-cache-rule.md.
- Compose template renders with sed substitution and `docker compose config` produces only the expected `env_file not found` runtime-only error (template syntax is valid).

## Self-Check: PASSED

- [x] templates/site.compose.yaml.tmpl exists
- [x] templates/wp-config-extras.php.tmpl exists
- [x] templates/caddy-block.tmpl exists
- [x] templates/cloudflare-dns.tmpl exists
- [x] templates/cloudflare-cache-rule.md exists
- [x] All grep invariants from plan `<verify>` blocks pass
- [x] Compose template parses (only env_file runtime error, expected)
