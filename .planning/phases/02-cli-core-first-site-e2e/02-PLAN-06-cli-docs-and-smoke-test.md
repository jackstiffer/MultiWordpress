---
phase: 02-cli-core-first-site-e2e
plan: 06
type: execute
wave: 3
depends_on: [02-03, 02-04, 02-05]
files_modified:
  - docs/cli.md
  - bin/_smoke-test.sh
  - README.md
autonomous: true
requirements: [CLI-01, CLI-02, CLI-06, CLI-08, CLI-09, CLI-10, CLI-11, CLI-14]
must_haves:
  truths:
    - "docs/cli.md has one section per verb (8 verbs) with synopsis, flags, examples, exit codes"
    - "bin/_smoke-test.sh exists and is documented as optional/best-effort against a local Docker engine"
    - "README.md links to docs/cli.md as the CLI reference"
  artifacts:
    - path: "docs/cli.md"
      provides: "CLI reference, one section per verb"
      min_lines: 200
      contains: "wp-create"
    - path: "bin/_smoke-test.sh"
      provides: "Optional smoke test that creates → lists → pauses → resumes → deletes a fake site"
      min_lines: 60
    - path: "README.md"
      provides: "Updated root README pointing to docs/cli.md"
      contains: "docs/cli.md"
  key_links:
    - from: "README.md"
      to: "docs/cli.md"
      via: "markdown link"
      pattern: "\\(docs/cli\\.md\\)"
    - from: "bin/_smoke-test.sh"
      to: "wp-create / wp-list / wp-pause / wp-resume / wp-delete"
      via: "shell invocation"
      pattern: "wp-(create|list|pause|resume|delete)"
---

<objective>
Document the CLI surface (one canonical reference for all 8 verbs) and ship an optional smoke-test that exercises the lifecycle locally. Update README.md to link to the new docs.

Purpose: Future-self and any new operator opens docs/cli.md to learn the surface. The smoke-test gives confidence after install without touching production state.
Output: docs/cli.md + bin/_smoke-test.sh + README.md update.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/phases/02-cli-core-first-site-e2e/02-CONTEXT.md
@.planning/phases/02-cli-core-first-site-e2e/02-03-SUMMARY.md
@.planning/phases/02-cli-core-first-site-e2e/02-04-SUMMARY.md
@.planning/phases/02-cli-core-first-site-e2e/02-05-SUMMARY.md
@README.md
@bin/wp-create
@bin/wp-delete
@bin/wp-pause
@bin/wp-resume
@bin/wp-list
@bin/wp-stats
@bin/wp-logs
@bin/wp-exec

Canonical spec section: every "wp-X" decision in 02-CONTEXT.md is the source of truth for the corresponding doc section.
</context>

<tasks>

<task type="auto">
  <name>Task 1: docs/cli.md — full CLI reference</name>
  <files>docs/cli.md</files>
  <action>
Create docs/cli.md. Markdown reference, one H2 section per verb. Cover all 8 verbs in this order:

1. wp-create
2. wp-delete
3. wp-pause
4. wp-resume
5. wp-list
6. wp-stats
7. wp-logs
8. wp-exec

For each verb, include:
- **Synopsis** (one-line summary)
- **Usage** (`wp-X <args> [flags]`)
- **Flags** (table: name, default, description)
- **Examples** (2–4 realistic invocations with expected output snippets)
- **Exit codes** (0 = success; 1 = generic failure; 2 = bad arguments; document any verb-specific codes)
- **Side effects** (what files/state get touched)
- **Notes / gotchas** (e.g., wp-create requires root; wp-exec requires container running)

Open the doc with:
- Title: `# MultiWordpress CLI Reference`
- 1-paragraph overview of /opt/wp layout (state/secrets/sites)
- Table of contents linking to each verb section

Close the doc with:
- **Lifecycle examples** section showing common workflows:
  - "Create a new site": `sudo wp-create blog.example.com`
  - "Pause a site to free RAM": `sudo wp-pause blog_example_com`
  - "Resume": `sudo wp-resume blog_example_com`
  - "Delete completely": `sudo wp-delete blog_example_com --yes`
  - "Re-display creds": `sudo wp-list --secrets blog_example_com`
  - "Run a wp-cli command": `sudo wp-exec blog_example_com plugin list`
- **First-domain validation** section: link to docs/first-site-e2e.md and templates/cloudflare-cache-rule.md
- **State machine reference** section: list the 5 states (db_created → dirs_created → container_booted → wp_installed → finalized) and rollback ordering

Aim for 250–400 lines total. Do not duplicate the runbook content from first-site-e2e.md — link to it.
  </action>
  <verify>
    <automated>test -f docs/cli.md &amp;&amp; for v in wp-create wp-delete wp-pause wp-resume wp-list wp-stats wp-logs wp-exec; do grep -q "## $v" docs/cli.md || (echo "missing section: $v" &amp;&amp; exit 1); done &amp;&amp; grep -q "state machine" docs/cli.md &amp;&amp; grep -q "first-site-e2e" docs/cli.md &amp;&amp; [ "$(wc -l &lt; docs/cli.md)" -ge 200 ]</automated>
  </verify>
  <done>docs/cli.md has all 8 verb sections, lifecycle examples, state machine reference, and links to first-site-e2e.md + cloudflare-cache-rule.md; ≥ 200 lines.</done>
</task>

<task type="auto">
  <name>Task 2: bin/_smoke-test.sh + README.md update</name>
  <files>bin/_smoke-test.sh, README.md</files>
  <action>
**bin/_smoke-test.sh:**
Shebang `#!/usr/bin/env bash`. `set -euo pipefail`. chmod 755.

Header comment: this is an OPTIONAL post-install smoke test. It creates a fake site against the local Docker engine, exercises pause/resume/list, then deletes it. Best-effort — failures are reported but do not necessarily indicate a broken CLI (could be Docker engine state, network MTU, etc.).

Test sequence:
1. `_log info "[smoke] preflight: docker ps, jq, openssl"` — verify required commands
2. Determine FAKE_DOMAIN (e.g., `smoketest-$(date +%s).example.invalid` — .invalid TLD never resolves; safe)
3. FAKE_SLUG via _sanitize_slug
4. `_log info "[smoke] step 1: wp-create --dry-run"` — invoke wp-create with --dry-run, expect exit 0
5. `_log info "[smoke] step 2: wp-create"` — provision the fake site (will fail at Caddy/Cloudflare DNS step since domain is invalid; we accept failure here OR add a `--no-caddy-print` skip flag — actually wp-create only PRINTS the snippet, doesn't validate DNS, so it should succeed end-to-end as long as the container boots)
6. `_log info "[smoke] step 3: wp-list"` — assert FAKE_SLUG appears in output
7. `_log info "[smoke] step 4: wp-list --secrets $FAKE_SLUG"` — assert it prints DB_NAME=wp_$FAKE_SLUG
8. `_log info "[smoke] step 5: wp-pause"` — exit 0
9. `_log info "[smoke] step 6: wp-list"` — assert status = paused
10. `_log info "[smoke] step 7: wp-resume"` — exit 0
11. `_log info "[smoke] step 8: wp-stats"` — exit 0; assert FAKE_SLUG appears in output
12. `_log info "[smoke] step 9: wp-exec $FAKE_SLUG core version"` — assert WP version printed
13. `_log info "[smoke] step 10: wp-delete --yes"` — exit 0
14. `_log info "[smoke] step 11: wp-list"` — assert FAKE_SLUG no longer present
15. Print `[smoke] PASS` (green if tty)

On any failure (set -e): print `[smoke] FAIL at step N` and attempt cleanup: `wp-delete $FAKE_SLUG --yes 2>/dev/null || true`.

Source _lib.sh; require root; require docker engine reachable; refuse to run if any real sites exist in sites.json (`if jq -e '.sites | length > 0' "$STATE_FILE"`: abort with "smoke test refuses to run with existing sites; use a clean /opt/wp or override with WP_ROOT").

Document at top: `# Run with: sudo WP_ROOT=/tmp/wp-smoke ./bin/_smoke-test.sh` (using a tmp WP_ROOT keeps it isolated from real /opt/wp).

**README.md update:**
- Read existing README.md to preserve Phase 1 content
- Add a new section `## CLI` after the existing setup sections, with content:
  ```
  ## CLI

  Phase 2 ships 8 CLI verbs for site lifecycle and inspection. Full reference:
  [docs/cli.md](docs/cli.md).

  Provisioning your first real domain: [docs/first-site-e2e.md](docs/first-site-e2e.md).

  Smoke test (optional, post-install):
  ```bash
  sudo WP_ROOT=/tmp/wp-smoke ./bin/_smoke-test.sh
  ```
  ```
- Do not delete any existing Phase 1 README content.
  </action>
  <verify>
    <automated>test -f bin/_smoke-test.sh &amp;&amp; bash -n bin/_smoke-test.sh &amp;&amp; test -x bin/_smoke-test.sh &amp;&amp; grep -q "wp-create" bin/_smoke-test.sh &amp;&amp; grep -q "wp-pause" bin/_smoke-test.sh &amp;&amp; grep -q "wp-resume" bin/_smoke-test.sh &amp;&amp; grep -q "wp-delete" bin/_smoke-test.sh &amp;&amp; grep -q "docs/cli.md" README.md &amp;&amp; grep -q "smoke-test" README.md</automated>
  </verify>
  <done>bin/_smoke-test.sh exists, executable, syntax-clean, exercises full lifecycle on isolated WP_ROOT; README.md has CLI section linking to docs/cli.md and docs/first-site-e2e.md; existing Phase 1 README content preserved.</done>
</task>

</tasks>

<verification>
- docs/cli.md has 8 verb sections + lifecycle examples + state-machine reference + ≥ 200 lines
- bin/_smoke-test.sh syntax-clean, executable, refuses to run with real sites
- README.md links to docs/cli.md and docs/first-site-e2e.md
- README.md still contains Phase 1 setup content (do not regress)
</verification>

<success_criteria>
A new operator opens docs/cli.md and learns the entire CLI surface without reading source. A returning operator runs bin/_smoke-test.sh against a tmp WP_ROOT and gets PASS confirmation. README.md is the front door pointing to both.
</success_criteria>

<output>
Create `.planning/phases/02-cli-core-first-site-e2e/02-06-SUMMARY.md` documenting:
- Final docs/cli.md line count and section structure
- Smoke test isolation strategy (tmp WP_ROOT)
- Whether the smoke test ran cleanly during this plan's verification (note: requires Docker engine; may be deferred to Phase 2 verification step)
</output>
