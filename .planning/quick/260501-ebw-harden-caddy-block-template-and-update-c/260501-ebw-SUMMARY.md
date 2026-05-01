---
quick_id: 260501-ebw
slug: harden-caddy-block-template-and-update-c
description: Harden Caddy block template and update caddy-cloudflare doc
date: 2026-05-01
status: complete
tasks_completed: 2
tasks_total: 2
key-files:
  modified:
    - templates/caddy-block.tmpl
    - docs/caddy-cloudflare.md
commits:
  - 8db6076 feat(templates): harden Caddy block — HSTS, sensitive-file blocks, FPM timeouts
  - d98cb9a docs(caddy-cloudflare): document global trusted_proxies and update WP example block
---

# Quick Task 260501-ebw — Summary

Hardened the per-site Caddy block printed by `wp-create` (HSTS, sensitive-file blocks, static-asset long-cache, FPM timeouts) and documented the host-level global `trusted_proxies` block needed so WordPress sees real visitor IPs through Cloudflare.

## Tasks Completed

### Task 1 — `templates/caddy-block.tmpl` hardened (commit `8db6076`)

Replaced template body with the production-grade block specified in the plan, preserving `{{domain}}`, `{{slug}}`, `{{port}}` placeholders. New directives:

- `@forbidden` matcher → 403 on `/wp-config.php`, `/wp-config-extras.php`, `/xmlrpc.php`, `/readme.html`, `/license.txt`, `/.htaccess`, `/.git/*`
- `@static` matcher → `Cache-Control: public, max-age=31536000, immutable` for css/js/woff2/ttf/jpe?g/png/gif/svg/webp/avif/ico
- `Strict-Transport-Security: max-age=31536000; includeSubDomains` (no `preload` per plan rationale)
- `php_fastcgi { root /var/www/html; read_timeout 300s; write_timeout 300s }` — keeps the prior FPM-root override and adds long-form timeouts for slow admin operations
- `encode { gzip; zstd; minimum_length 1024 }` — block-form to skip compressing tiny payloads
- `file_server` retained (without it static assets return empty 200s)
- `@uploads_php` → 403 retained (defense-in-depth against malicious upload bypass)

### Task 2 — `docs/caddy-cloudflare.md` updated (commit `d98cb9a`)

1. Added a new `## Global Caddyfile config (once per host)` section immediately after the intro, documenting the global options block with `servers { trusted_proxies static ... }` listing the full Cloudflare IPv4 + IPv6 range set, why it's needed (real `{client_ip}` / `REMOTE_ADDR` for WP security plugins, comment spam, audit logs), AudioStoryV2 impact (none — Next.js parses `X-Forwarded-*` itself), and the Caddy 2.7+ requirement.
2. Replaced the existing `# WordPress site (block printed by wp-create)` example under "How host Caddy fits" with the hardened block, substituting the doc's existing `blog.dirtyvocal.com` / `blog_dirtyvocal_com` / `18001` for the template placeholders. Existing TOC, headers, runbook flow, and downstream sections (DNS, SSL/TLS, Cache Rules, WAF, Troubleshooting, Validation) preserved.

## must_haves Verification

```
$ grep -E 'root /var/www/html|file_server|Strict-Transport-Security|@forbidden|@static|read_timeout 300s|minimum_length 1024' templates/caddy-block.tmpl
    @forbidden path /wp-config.php /wp-config-extras.php /xmlrpc.php /readme.html /license.txt /.htaccess /.git/*
    respond @forbidden 403
    @static path_regexp \.(css|js|woff2?|ttf|jpe?g|png|gif|svg|webp|avif|ico)$
    header @static Cache-Control "public, max-age=31536000, immutable"
    header Strict-Transport-Security "max-age=31536000; includeSubDomains"
        root /var/www/html
        read_timeout 300s
    file_server
        minimum_length 1024
```
All 7 required tokens present (9 line matches because some occur in both matcher def + usage).

```
$ grep -E 'trusted_proxies|root /var/www/html|file_server|Strict-Transport' docs/caddy-cloudflare.md
        trusted_proxies static \
headers to Next.js regardless of `trusted_proxies` — Next.js parses
    header Strict-Transport-Security "max-age=31536000; includeSubDomains"
        root /var/www/html
    file_server
```
All 4 keyword groups present. The `## Global Caddyfile config` section exists with a `trusted_proxies static` block listing both IPv4 (e.g. `173.245.48.0/20`, `162.158.0.0/15`, `131.0.72.0/22`) and IPv6 (e.g. `2400:cb00::/32`, `2c0f:f248::/32`) Cloudflare ranges. The per-site WP example block matches the hardened template directives.

## Out-of-scope adherence

Verified no changes outside the two listed files:

```
$ git diff --name-only HEAD~2 HEAD
docs/caddy-cloudflare.md
templates/caddy-block.tmpl
```

No edits to `image/Dockerfile`, `bin/wp-create`, `templates/site.compose.yaml.tmpl`, or any other path. ROADMAP.md untouched (quick task).

## Deviations from Plan

None — plan executed exactly as written. Block bodies copied verbatim, only the per-site doc example used the doc's pre-existing `blog.dirtyvocal.com` / `blog_dirtyvocal_com` / `18001` substitutions as the plan directed.

## Self-Check: PASSED

- FOUND: templates/caddy-block.tmpl (modified)
- FOUND: docs/caddy-cloudflare.md (modified)
- FOUND commit: 8db6076 (Task 1)
- FOUND commit: d98cb9a (Task 2)
- Verified: 7/7 must_have tokens in templates/caddy-block.tmpl
- Verified: 4/4 must_have keyword groups in docs/caddy-cloudflare.md
- Verified: only the two intended files changed across both commits
