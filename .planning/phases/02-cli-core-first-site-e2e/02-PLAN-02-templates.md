---
phase: 02-cli-core-first-site-e2e
plan: 02
type: execute
wave: 1
depends_on: []
files_modified:
  - templates/site.compose.yaml.tmpl
  - templates/wp-config-extras.php.tmpl
  - templates/caddy-block.tmpl
  - templates/cloudflare-dns.tmpl
  - templates/cloudflare-cache-rule.md
autonomous: true
requirements: [HARD-02, PERF-01, PERF-02, STATE-03]
must_haves:
  truths:
    - "Per-site compose template renders with envsubst given {SLUG, PORT, REDIS_DB, DOMAIN}"
    - "wp-config-extras.php disables XML-RPC, sets DISABLE_WP_CRON, configures redis prefix/db, points debug log to fd/2"
    - "Caddy block template uses php_fastcgi to 127.0.0.1:<port>"
    - "Cloudflare DNS template documents the A-record-proxied row"
    - "Cloudflare Cache Rule doc names the three cookie-bypass patterns verbatim"
  artifacts:
    - path: "templates/site.compose.yaml.tmpl"
      provides: "Per-site compose snippet with placeholders"
      contains: "cgroup_parent: wp.slice"
    - path: "templates/wp-config-extras.php.tmpl"
      provides: "wp-config.php hardening additions"
      contains: "XMLRPC_REQUEST"
    - path: "templates/caddy-block.tmpl"
      provides: "Caddy site block to paste"
      contains: "php_fastcgi"
    - path: "templates/cloudflare-dns.tmpl"
      provides: "Cloudflare DNS row reference"
      contains: "Proxied"
    - path: "templates/cloudflare-cache-rule.md"
      provides: "Cloudflare Cache Rule paste-in instructions"
      contains: "wordpress_logged_in_"
  key_links:
    - from: "templates/site.compose.yaml.tmpl"
      to: "wp.slice cgroup"
      via: "cgroup_parent directive"
      pattern: "cgroup_parent:\\s*wp.slice"
    - from: "templates/wp-config-extras.php.tmpl"
      to: "Redis per-site DB"
      via: "WP_REDIS_DATABASE / WP_REDIS_PREFIX"
      pattern: "WP_REDIS_(DATABASE|PREFIX)"
---

<objective>
Ship the four .tmpl files and the Cloudflare Cache Rule reference doc that wp-create renders or prints. Templates are the canonical paste-in artifacts for Caddy + Cloudflare, and they encode the hardening decisions (XML-RPC off, no mem_limit, shared cgroup, redis per-site DB).

Purpose: Decouple template content from script logic; let executors verify templates against CONTEXT.md before wp-create touches them.
Output: 4 .tmpl files + 1 .md, all under templates/.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/phases/02-cli-core-first-site-e2e/02-CONTEXT.md
@.planning/phases/01-foundation/01-CONTEXT.md
@compose/compose.yaml
@image/Dockerfile

Canonical spec sections in 02-CONTEXT.md:
- "Per-Site Compose Template (site.compose.yaml.tmpl)" — verbatim source
- "Security" — XML-RPC, admin user, secrets mode
- "wp-create" sequence step 13 — wp-config extras content
- Step 14 summary block — Caddy block + Cloudflare rows + Cache Rule cookies (verbatim)
</context>

<tasks>

<task type="auto">
  <name>Task 1: Render the four templates</name>
  <files>templates/site.compose.yaml.tmpl, templates/wp-config-extras.php.tmpl, templates/caddy-block.tmpl, templates/cloudflare-dns.tmpl</files>
  <action>
Create all four templates. Use `{{slug}}`, `{{port}}`, `{{redis_db}}`, `{{domain}}`, `{{vm_public_ip}}` as placeholders (wp-create will substitute via sed or envsubst with envsubst-friendly conversion).

**templates/site.compose.yaml.tmpl** — copy verbatim from CONTEXT.md "Per-Site Compose Template" section. CRITICAL invariants:
- `cgroup_parent: wp.slice` — DO NOT add `mem_limit` (HARD requirement; INFRA-05 enforced)
- `image: multiwp:wordpress-6-php8.3` (the tag Phase 1 built; verify image/Dockerfile if uncertain)
- `ports: - "127.0.0.1:{{port}}:9000"` — loopback only (HARD-01)
- `env_file: - /opt/wp/secrets/{{slug}}.env`
- `volumes: - /opt/wp/sites/{{slug}}/wp-content:/var/www/html/wp-content`
- `networks: wp-network: external: true; name: wp-network`
- `logging: driver: json-file; options: max-size "10m" max-file "3" compress "true"`
- `restart: unless-stopped`
- `depends_on: [wp-mariadb, wp-redis]`

**templates/wp-config-extras.php.tmpl** — PHP snippet that wp-create injects above the `/* That's all, stop editing! */` line in wp-config.php. Contents:
```php
<?php
// MultiWordpress hardening — injected by wp-create

// XML-RPC disabled (HARD-02)
add_filter('xmlrpc_enabled', '__return_false');
add_filter('wp_headers', function($headers) {
    unset($headers['X-Pingback']);
    return $headers;
});

// Disable WP-Cron (host cron will run wp-cron staggered — Phase 3)
define('DISABLE_WP_CRON', true);

// WP_HOME / WP_SITEURL from environment
if (!defined('WP_HOME'))    define('WP_HOME',    getenv('WORDPRESS_HOME'));
if (!defined('WP_SITEURL')) define('WP_SITEURL', getenv('WORDPRESS_SITEURL'));

// Redis object cache — per-site DB index + key prefix (PERF-01)
define('WP_REDIS_HOST',     getenv('WORDPRESS_REDIS_HOST'));
define('WP_REDIS_DATABASE', (int) getenv('WORDPRESS_REDIS_DATABASE'));
define('WP_REDIS_PREFIX',   getenv('WORDPRESS_REDIS_PREFIX'));

// Debug log -> stderr (inherits docker driver rotation)
if (defined('WP_DEBUG') && WP_DEBUG) {
    define('WP_DEBUG_LOG', '/proc/self/fd/2');
    define('WP_DEBUG_DISPLAY', false);
}
```
(No `{{placeholders}}` needed — values come from env vars at PHP runtime.)

**templates/caddy-block.tmpl** — verbatim from CONTEXT.md step 14:
```
{{domain}} {
    php_fastcgi 127.0.0.1:{{port}}
    root * /opt/wp/sites/{{slug}}/wp-content
    encode gzip
    log {
        output discard
    }
}
```

**templates/cloudflare-dns.tmpl** — header + tabular rows:
```
── Cloudflare DNS rows ──
Type   Name                      Content              Proxy
A      {{subdomain_or_at}}       {{vm_public_ip}}     Proxied
```
Include a comment at the top explaining `{{subdomain_or_at}}` is derived by wp-create from the domain (apex → `@`, subdomain → label).
  </action>
  <verify>
    <automated>test -f templates/site.compose.yaml.tmpl && test -f templates/wp-config-extras.php.tmpl && test -f templates/caddy-block.tmpl && test -f templates/cloudflare-dns.tmpl && grep -q "cgroup_parent: wp.slice" templates/site.compose.yaml.tmpl && grep -q "xmlrpc_enabled" templates/wp-config-extras.php.tmpl && grep -q "DISABLE_WP_CRON" templates/wp-config-extras.php.tmpl && grep -q "WP_REDIS_DATABASE" templates/wp-config-extras.php.tmpl && grep -q "php_fastcgi 127.0.0.1:{{port}}" templates/caddy-block.tmpl && grep -q "Proxied" templates/cloudflare-dns.tmpl && ! grep -q "mem_limit" templates/site.compose.yaml.tmpl</automated>
  </verify>
  <done>All four templates exist with required content; no mem_limit anywhere in compose template; XML-RPC + DISABLE_WP_CRON + redis env-derived constants in wp-config extras; Caddy + Cloudflare blocks match CONTEXT.md verbatim shape.</done>
</task>

<task type="auto">
  <name>Task 2: Cloudflare Cache Rule reference doc</name>
  <files>templates/cloudflare-cache-rule.md</files>
  <action>
Create templates/cloudflare-cache-rule.md — operator paste-in reference for the Cloudflare Cache Rule (PERF-02). Content:

```markdown
# Cloudflare Cache Rule — WordPress Cookie Bypass

After provisioning a site with `wp-create`, paste the Caddy block, add the
Cloudflare DNS row (Proxied), then create this Cache Rule in the Cloudflare
dashboard so logged-out reads hit the edge cache while logged-in admin
traffic bypasses it.

## Where
Cloudflare Dashboard → (zone) → Caching → Cache Rules → Create rule.

## When to apply
- **If incoming requests match**: Hostname equals `<your-domain>`
- **AND** Cookie does NOT contain any of:
  - `wordpress_logged_in_`
  - `wp-postpass_`
  - `comment_author_`

## Then
- **Cache eligibility**: Eligible for cache
- **Edge TTL**: Override origin → `2 hours` (or your preference)
- **Browser TTL**: Respect origin headers
- **Cache by device type**: off

## Why these three cookies
- `wordpress_logged_in_*` — set when an editor/admin is signed in
- `wp-postpass_*` — set when a visitor unlocks a password-protected post
- `comment_author_*` — set after a visitor leaves a comment (so they see their own pending comment)

## Validation
After saving the rule and waiting ~30s for propagation:
```bash
curl -sI https://<your-domain>/ | grep -i cf-cache-status
# Expect: cf-cache-status: HIT (after 1–2 warm-up requests)

curl -sI -H 'Cookie: wordpress_logged_in_test=1' https://<your-domain>/wp-admin/ | grep -i cf-cache-status
# Expect: cf-cache-status: BYPASS (or DYNAMIC)
```

## Companion plugin
Activate Super Page Cache for Cloudflare inside WordPress:
```bash
wp-exec <slug> plugin install super-page-cache-for-cloudflare --activate
```
The plugin handles cache-purge on post publish/update; the rule above handles
the bypass logic.
```
  </action>
  <verify>
    <automated>test -f templates/cloudflare-cache-rule.md && grep -q "wordpress_logged_in_" templates/cloudflare-cache-rule.md && grep -q "wp-postpass_" templates/cloudflare-cache-rule.md && grep -q "comment_author_" templates/cloudflare-cache-rule.md && grep -q "super-page-cache-for-cloudflare" templates/cloudflare-cache-rule.md</automated>
  </verify>
  <done>cloudflare-cache-rule.md exists; names all three cookie patterns; documents validation curl commands; references Super Page Cache plugin.</done>
</task>

</tasks>

<verification>
- All 5 files under templates/ exist
- compose template has `cgroup_parent: wp.slice` AND no `mem_limit`
- wp-config extras file has XML-RPC disable + DISABLE_WP_CRON + WP_REDIS_DATABASE
- Caddy block uses `php_fastcgi 127.0.0.1:{{port}}`
- Cache rule doc lists the 3 cookie patterns verbatim
</verification>

<success_criteria>
templates/ directory contains the 4 paste-in templates + 1 reference doc; templates are placeholder-substitutable by wp-create; encode all hardening decisions from CONTEXT.md.
</success_criteria>

<output>
Create `.planning/phases/02-cli-core-first-site-e2e/02-02-SUMMARY.md` listing the placeholder set used (so wp-create knows exactly which sed substitutions to perform).
</output>
