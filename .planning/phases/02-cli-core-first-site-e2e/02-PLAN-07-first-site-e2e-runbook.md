---
phase: 02-cli-core-first-site-e2e
plan: 07
type: execute
wave: 3
depends_on: [02-03, 02-05, 02-06]
files_modified:
  - docs/first-site-e2e.md
autonomous: true
requirements: [PERF-02]
must_haves:
  truths:
    - "Runbook walks operator from clean VM (with Phase 1 infra up) to validated cf-cache-status: HIT for the first real domain"
    - "Runbook includes Cloudflare Cache Rule paste-in instructions (verbatim cookie patterns)"
    - "Runbook includes Super Page Cache plugin install via wp-exec"
    - "Runbook includes validation curl commands and expected outputs"
    - "Runbook is documentation only — no code execution required by Claude during this phase"
  artifacts:
    - path: "docs/first-site-e2e.md"
      provides: "Operator runbook for proving the cache strategy on the first real domain"
      min_lines: 100
      contains: "cf-cache-status"
  key_links:
    - from: "docs/first-site-e2e.md"
      to: "templates/cloudflare-cache-rule.md"
      via: "markdown link / inline reference"
      pattern: "cloudflare-cache-rule"
    - from: "docs/first-site-e2e.md"
      to: "wp-create / wp-exec"
      via: "command examples"
      pattern: "wp-create|wp-exec"
---

<objective>
Ship the operator runbook that walks through provisioning the first real domain on the GCP VM and validating the Cloudflare + Super Page Cache strategy. This is a documentation-only deliverable — Claude does NOT deploy. Phase 2 success criterion 5 is satisfied when the operator runs through this runbook on their actual VM and observes cf-cache-status HIT.

Purpose: Encode the validation procedure so the operator (and future re-runs of the runbook for additional domains) has a checkable, repeatable workflow.
Output: docs/first-site-e2e.md.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/phases/02-cli-core-first-site-e2e/02-CONTEXT.md
@.planning/phases/02-cli-core-first-site-e2e/02-03-SUMMARY.md
@.planning/phases/02-cli-core-first-site-e2e/02-05-SUMMARY.md
@.planning/phases/02-cli-core-first-site-e2e/02-06-SUMMARY.md
@templates/cloudflare-cache-rule.md
@templates/caddy-block.tmpl
@templates/cloudflare-dns.tmpl
@docs/cli.md

Canonical spec section in 02-CONTEXT.md: "First-Site E2E Validation (success criterion 5)" — names the validation curl commands, plugin install, and expected cf-cache-status HIT outcome.

Roadmap success criterion 5 (Phase 2): "logged-out homepage requests return cf-cache-status: HIT with TTFB under ~100 ms, while logged-in admin requests bypass cache and hit origin."
</context>

<tasks>

<task type="auto">
  <name>Task 1: Author docs/first-site-e2e.md</name>
  <files>docs/first-site-e2e.md</files>
  <action>
Create docs/first-site-e2e.md. Documentation only — no code execution, no host changes by Claude.

Required sections (in order):

1. **Title + intro paragraph** — name this as the validator for Phase 2 success criterion 5; expected end state: cf-cache-status HIT for logged-out homepage on the first real domain.

2. **Prerequisites checklist:**
   - Phase 1 infra running (compose ps shows wp-mariadb + wp-redis healthy)
   - wp.slice systemd unit loaded (systemctl status wp.slice)
   - Phase 2 CLI installed (which wp-create && which wp-exec)
   - Host Caddy running and serving existing AudioStoryV2 (don't break it)
   - Cloudflare zone live, proxying VM IP
   - Shell access to VM (gcloud compute ssh) and Cloudflare dashboard

3. **Step 1 — Provision the site:**
   - Example: `sudo wp-create blog.example.com --admin-email me@example.com`
   - Save the output (admin user, password, Caddy block, DNS rows)
   - Output also persisted to /opt/wp/secrets/blog_example_com.env (mode 600)
   - Recovery: `sudo wp-create blog.example.com --resume blog_example_com`; reference docs/cli.md#wp-create

4. **Step 2 — Cloudflare DNS:**
   - DNS → Add record: Type A, Name `blog` (or `@`), IPv4 = VM public IP, Proxy = Proxied (orange cloud) — critical
   - Wait ~30s for propagation
   - Verify: `dig +short blog.example.com` returns Cloudflare IPs (104.x), NOT VM IP

5. **Step 3 — Caddy block:**
   - Paste the Caddy block from wp-create output into existing Caddyfile (typically /etc/caddy/Caddyfile)
   - Show example block (with literal port 18001, slug blog_example_com)
   - `sudo caddy reload --config /etc/caddy/Caddyfile`
   - Verify LE cert: `curl -sI https://blog.example.com/ | head -5` shows HTTP/2 200 (or 301 to /wp-admin/install.php on first hit)

6. **Step 4 — Cloudflare Cache Rule:**
   - Reference templates/cloudflare-cache-rule.md
   - Cloudflare → Caching → Cache Rules → Create rule
   - If: Hostname equals blog.example.com AND Cookie does NOT contain any of: `wordpress_logged_in_`, `wp-postpass_`, `comment_author_`
   - Then: Cache eligibility → Eligible for cache; Edge TTL → 2 hours
   - Save

7. **Step 5 — Super Page Cache plugin:**
   - `sudo wp-exec blog_example_com plugin install super-page-cache-for-cloudflare --activate`
   - Plugin handles cache-purge on post publish/update inside WordPress; Cache Rule above handles cookie-bypass at edge
   - Optional: configure plugin's Cloudflare API token in WP admin for programmatic purge

8. **Step 6 — Validate:**
   - Logged-out homepage hits edge: `curl -sI https://blog.example.com/ | grep -i cf-cache-status` → expect HIT (after 1–2 warm-up requests)
   - TTFB under 100ms when HIT
   - Logged-in admin bypasses: `curl -sI -H 'Cookie: wordpress_logged_in_test=1' https://blog.example.com/wp-admin/ | grep -i cf-cache-status` → expect BYPASS or DYNAMIC
   - Pool isolation: `sudo wp-stats` shows cluster line + AudioStoryV2 health + per-site row

9. **Troubleshooting table** (5 rows minimum):
   - cf-cache-status DYNAMIC always → Cache Rule not active or cookie bypass too broad
   - cf-cache-status BYPASS for logged-out → stale wordpress_test_cookie; curl with empty Cookie header
   - 502 Bad Gateway → container not running or wrong port; wp-list to confirm; wp-resume
   - LE cert fails → Cloudflare SSL Strict mode; set to Full (strict) and ensure Caddy :80 reachable
   - Origin slow on MISS → redis-cache not active; `wp-exec <slug> redis status` should say Connected

10. **Done section:** When cf-cache-status HIT for logged-out + BYPASS for /wp-admin/, success criterion 5 is satisfied; record result in 02-VERIFICATION.md.

11. **Repeating for additional domains:** Each new domain repeats steps 1–6; Cache Rule per-domain (no wildcard on free plan); Super Page Cache plugin per-site.

Aim for 120–200 lines of clean markdown. Use code blocks for shell commands. Use tables for troubleshooting and prerequisites.
  </action>
  <verify>
    <automated>test -f docs/first-site-e2e.md &amp;&amp; grep -q "cf-cache-status" docs/first-site-e2e.md &amp;&amp; grep -q "wordpress_logged_in_" docs/first-site-e2e.md &amp;&amp; grep -q "super-page-cache-for-cloudflare" docs/first-site-e2e.md &amp;&amp; grep -q "wp-create" docs/first-site-e2e.md &amp;&amp; grep -q "wp-exec" docs/first-site-e2e.md &amp;&amp; grep -qi "troubleshooting" docs/first-site-e2e.md &amp;&amp; [ "$(wc -l &lt; docs/first-site-e2e.md)" -ge 100 ]</automated>
  </verify>
  <done>docs/first-site-e2e.md exists; covers prerequisites + 6 numbered steps + troubleshooting + done + repeat sections; references cloudflare-cache-rule.md template; lists all 3 cookie patterns; includes validation curl commands; ≥ 100 lines.</done>
</task>

</tasks>

<verification>
- File exists and is ≥ 100 lines
- All 3 cookie patterns named verbatim (wordpress_logged_in_, wp-postpass_, comment_author_)
- super-page-cache-for-cloudflare plugin install command present
- Validation curl commands present for both HIT and BYPASS expectations
- References templates/cloudflare-cache-rule.md
- Troubleshooting table has ≥ 4 rows
</verification>

<success_criteria>
docs/first-site-e2e.md is the single document the operator opens to run the first-domain validation. After following it on their VM, they observe cf-cache-status HIT for logged-out homepage and BYPASS for /wp-admin/, satisfying Phase 2 success criterion 5.
</success_criteria>

<output>
Create `.planning/phases/02-cli-core-first-site-e2e/02-07-SUMMARY.md` noting:
- Final line count + section structure
- Any deviations from the spec sketch above
- Reminder that operator must run this on the actual VM to satisfy success criterion 5; Phase 2 verifier confirms via 02-VERIFICATION.md entry from operator
</output>
