---
quick_id: 260501-ebw
slug: harden-caddy-block-template-and-update-c
description: Harden Caddy block template and update caddy-cloudflare doc
date: 2026-05-01
status: planned
---

# Quick Plan 260501-ebw — Harden Caddy block + doc

## Context

The current Caddy block printed by `wp-create` is functionally minimal. Real-world testing of `blog1.stlash.com` exposed two missing pieces (already fixed in earlier turns of this session):

1. `root /var/www/html` override inside `php_fastcgi { }` — without it FPM 404s because the bind-mount creates a host↔container path mismatch.
2. `file_server` — without it static assets (JS modules, CSS, woff2 fonts, images) return empty 200s with no `Content-Type`, breaking wp-admin entirely.

This quick task layers production hardening on top of those fixes, verified against authoritative Caddy v2 docs (caddyserver.com/docs/caddyfile/directives/{php_fastcgi,file_server,encode}, trusted_proxies on the global servers block).

## Tasks

### Task 1 — Update `templates/caddy-block.tmpl` to production-grade per-site block

**Files:** `templates/caddy-block.tmpl`

**Action:** Replace the current template body with the hardened block below. Keep the `{{domain}}`, `{{slug}}`, `{{port}}` placeholders.

```caddy
{{domain}} {
    root * /opt/wp/sites/{{slug}}

    # Defense-in-depth: deny direct access to sensitive files. WordPress
    # itself never serves these as text, but a future config bug could.
    @forbidden path /wp-config.php /wp-config-extras.php /xmlrpc.php /readme.html /license.txt /.htaccess /.git/*
    respond @forbidden 403

    # Block PHP execution under uploads/ in case a malicious upload bypasses
    # WordPress's MIME sanitization.
    @uploads_php path_regexp ^/wp-content/uploads/.*\.php$
    respond @uploads_php 403

    # Long-cache static assets. Cloudflare honors this and so do browsers.
    @static path_regexp \.(css|js|woff2?|ttf|jpe?g|png|gif|svg|webp|avif|ico)$
    header @static Cache-Control "public, max-age=31536000, immutable"

    # HSTS — force HTTPS for a year. (Skip `preload` until every subdomain
    # is HTTPS; preload is hard to undo.)
    header Strict-Transport-Security "max-age=31536000; includeSubDomains"

    # Dynamic requests → php-fpm in the per-site container. The FPM-side
    # webroot is /var/www/html (compose bind-mount target). Override the
    # SCRIPT_FILENAME root so it matches what FPM sees, otherwise FPM
    # returns "File not found".
    php_fastcgi 127.0.0.1:{{port}} {
        root /var/www/html
        read_timeout 300s
        write_timeout 300s
    }

    # Serve static assets directly from the host bind-mount. Required —
    # without this, non-PHP requests return empty 200s with no Content-Type
    # and wp-admin module scripts fail to load.
    file_server

    encode {
        gzip
        zstd
        minimum_length 1024
    }
}
```

**Verify:** `grep -E 'root /var/www/html|file_server|Strict-Transport|@forbidden|@static' templates/caddy-block.tmpl` — every match should be present.

**Done when:** Template file rendered the new block; placeholders `{{domain}}`, `{{slug}}`, `{{port}}` preserved.

### Task 2 — Update `docs/caddy-cloudflare.md`

**Files:** `docs/caddy-cloudflare.md`

**Action:**

1. Update the example WordPress block in the "How host Caddy fits" section to match the new template (same content as Task 1's block, but with the example slug `blog_dirtyvocal_com` and port `18001` already present in the doc).
2. Add a **new section** above "How host Caddy fits" (or immediately after the intro paragraph) titled **"Global Caddyfile config (once per host)"** that documents the global `trusted_proxies` block for Cloudflare, and explains why it's needed (real client IP for WP, AudioStoryV2 unaffected).

   Use this content:

   ```markdown
   ## Global Caddyfile config (once per host)

   At the top of `/etc/caddy/Caddyfile`, add a global options block so Caddy
   trusts Cloudflare's `X-Forwarded-For` and reports the real visitor IP to
   every site (WordPress, AudioStoryV2, dashboard):

   ```
   {
       servers {
           trusted_proxies static \
               173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 \
               141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 \
               188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 \
               162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 \
               172.64.0.0/13 131.0.72.0/22 \
               2400:cb00::/32 2606:4700::/32 2803:f800::/32 \
               2405:b500::/32 2405:8100::/32 2a06:98c0::/29 \
               2c0f:f248::/32
       }
   }
   ```

   Source: `https://www.cloudflare.com/ips-v4` and `/ips-v6`. Refresh once
   a year — Cloudflare changes ranges rarely.

   **Effect:** Caddy's `{client_ip}` placeholder and FPM's `REMOTE_ADDR` env
   var resolve to the real visitor IP (parsed from `CF-Connecting-IP` /
   `X-Forwarded-For`) instead of a Cloudflare edge IP. Without this,
   WordPress security plugins, comment spam detection, and audit logs see
   only Cloudflare's IPs and become useless.

   **AudioStoryV2 impact:** None. Caddy still proxies `X-Forwarded-*`
   headers to Next.js regardless of `trusted_proxies` — Next.js parses
   them itself. This setting only changes Caddy's *own* client_ip
   resolution, which only affects access logs and FPM's REMOTE_ADDR.

   Requires Caddy 2.7 or newer.
   ```

3. Where the doc currently shows the `# WordPress site (block printed by wp-create)` example, replace it with the full hardened block from Task 1 (substituting `blog.dirtyvocal.com` / `blog_dirtyvocal_com` / `18001` for the placeholders).

**Verify:** `grep -E 'trusted_proxies|root /var/www/html|file_server|Strict-Transport' docs/caddy-cloudflare.md` shows all four keywords present.

**Done when:** Both edits applied; existing doc structure (TOC, headers, runbook flow) preserved.

## must_haves

- `templates/caddy-block.tmpl` contains: `root /var/www/html`, `file_server`, `Strict-Transport-Security`, `@forbidden`, `@static`, `read_timeout 300s`, `minimum_length 1024`.
- `docs/caddy-cloudflare.md` contains a `## Global Caddyfile config` section with a `trusted_proxies static` block listing both IPv4 and IPv6 Cloudflare ranges.
- `docs/caddy-cloudflare.md` per-site WP example block matches the new template (same hardening directives).
- No changes to `image/Dockerfile`, `bin/wp-create`, or `templates/site.compose.yaml.tmpl`.

## Out of scope

- Modifying `wp-create` to print the global trusted_proxies block (the doc covers it; printing it on every site-create would be noisy).
- Updating other docs (`docs/first-site-e2e.md`, etc.) — they reference the per-site block by link, not by inlined content.
- Verifying on the live VM — that's a deploy step, not a quick task.
