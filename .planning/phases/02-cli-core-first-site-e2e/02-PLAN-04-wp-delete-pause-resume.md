---
phase: 02-cli-core-first-site-e2e
plan: 04
type: execute
wave: 2
depends_on: [02-01, 02-02]
files_modified:
  - bin/wp-delete
  - bin/wp-pause
  - bin/wp-resume
autonomous: true
requirements: [CLI-06, CLI-14, STATE-01, STATE-02]
must_haves:
  truths:
    - "wp-delete <slug> stops/removes container, drops DB+user, removes site dir, removes secrets, updates sites.json"
    - "wp-delete prints Caddy block + Cloudflare DNS row to remove (cleanup snippets)"
    - "wp-delete requires --yes for non-interactive use; interactive prompts Y/N"
    - "wp-pause <slug> stops container (RAM freed, DB/files/secrets intact), state=paused"
    - "wp-resume <slug> starts container, state back to finalized"
    - "wp-pause is idempotent (already-paused → no-op success); wp-resume on running same"
    - "All three verbs error clearly on non-existent slug (NOT silent success)"
  artifacts:
    - path: "bin/wp-delete"
      provides: "Site teardown CLI verb"
      min_lines: 80
    - path: "bin/wp-pause"
      provides: "Site stop CLI verb"
      min_lines: 40
    - path: "bin/wp-resume"
      provides: "Site start CLI verb"
      min_lines: 40
  key_links:
    - from: "bin/wp-delete"
      to: "wp-mariadb"
      via: "_db_exec for DROP DATABASE / DROP USER"
      pattern: "DROP (DATABASE|USER)"
    - from: "bin/wp-pause"
      to: "/opt/wp/sites/<slug>/compose.yaml"
      via: "_compose_site stop"
      pattern: "stop"
    - from: "bin/wp-resume"
      to: "/opt/wp/sites/<slug>/compose.yaml"
      via: "_compose_site up -d"
      pattern: "up -d"
---

<objective>
Build the three lifecycle verbs that complement wp-create: delete (full teardown), pause (free RAM but keep state), resume (restart paused site).

Purpose: Operator needs to remove sites cleanly, temporarily reclaim pool memory without losing data, and bring sites back online — all without manual docker/mariadb commands.
Output: bin/wp-delete, bin/wp-pause, bin/wp-resume — three executable bash scripts.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/phases/02-cli-core-first-site-e2e/02-CONTEXT.md
@.planning/phases/02-cli-core-first-site-e2e/02-01-SUMMARY.md
@bin/_lib.sh
@templates/caddy-block.tmpl
@templates/cloudflare-dns.tmpl

Canonical spec sections in 02-CONTEXT.md:
- "wp-delete <slug>" — 7-step sequence
- "wp-pause <slug> / wp-resume <slug>" — stop/start + state transitions
- "Specific Ideas" — idempotent verbs, no --force, error on non-existent slug
</context>

<tasks>

<task type="auto">
  <name>Task 1: bin/wp-delete</name>
  <files>bin/wp-delete</files>
  <action>
Create bin/wp-delete. Shebang `#!/usr/bin/env bash`. `set -euo pipefail`. Source _lib.sh. `chmod 755`.

**Args:**
- Positional `<slug>` (required)
- `--yes` (skip interactive confirmation; required when stdin is not a tty)
- `--json` (emit cleanup snippets as JSON)
- `-h | --help`

**Sequence:**
1. `_require_root`. Validate slug. `_get_site $SLUG`; if empty, _die "site not found: $SLUG".
2. Fetch site fields (domain, port, redis_db) for cleanup output.
3. Confirmation:
   - If `--yes`: skip
   - Else if tty: prompt `Delete site $SLUG ($DOMAIN)? [y/N]:`; require literal `y` or `yes`
   - Else (non-tty without --yes): _die "non-interactive: pass --yes"
4. `_compose_site $SLUG down` (best-effort; tolerate missing compose file with warn)
5. `_db_exec "DROP DATABASE IF EXISTS wp_${SLUG};"`
6. `_db_exec "DROP USER IF EXISTS 'wp_${SLUG}'@'%';"`
7. `_db_exec "FLUSH PRIVILEGES;"`
8. `rm -rf "${SITES_DIR}/${SLUG}"` (compose.yaml + wp-content)
9. `rm -f "${SECRETS_DIR}/${SLUG}.env"`
10. `_delete_site $SLUG` (remove from sites.json)
11. Print cleanup snippets (human or JSON):
    - "Remove this Caddy block from your Caddyfile and reload:" + the block (rendered via templates/caddy-block.tmpl with {{slug}}/{{domain}}/{{port}})
    - "Remove this Cloudflare DNS row:" + Type A / Name <subdomain_or_at> / Content <vm_public_ip placeholder> / Proxied
    - "Then: sudo caddy reload --config /etc/caddy/Caddyfile"

**JSON mode:** emit `{slug, domain, port, caddy_block: "...", dns_row: {type, name, content_placeholder, proxy: "Proxied"}}`.

**Error handling:** No trap rollback (delete is destructive by design). If steps 4–9 partially fail, _log warn the specific failure and continue (DB drop failure most concerning — surface clearly). Exit non-zero only if BOTH DB drop AND fs cleanup fail.
  </action>
  <verify>
    <automated>bash -n bin/wp-delete &amp;&amp; bin/wp-delete --help 2>&amp;1 | grep -qi delete &amp;&amp; grep -q "DROP DATABASE" bin/wp-delete &amp;&amp; grep -q "DROP USER" bin/wp-delete &amp;&amp; grep -q '\-\-yes' bin/wp-delete &amp;&amp; test -x bin/wp-delete</automated>
  </verify>
  <done>wp-delete syntax-clean; requires --yes for non-tty; drops DB+user, removes dir, removes secrets, updates sites.json; prints Caddy + Cloudflare cleanup snippets; --json mode works.</done>
</task>

<task type="auto">
  <name>Task 2: bin/wp-pause and bin/wp-resume</name>
  <files>bin/wp-pause, bin/wp-resume</files>
  <action>
Create both scripts. Shebang + set -euo pipefail + source _lib.sh + chmod 755 each.

**bin/wp-pause:**
- Args: `<slug>`, `-h|--help`, `--json`
- _require_root; _get_site $SLUG; _die if empty
- Read current state. If state == `paused`: _log info "site already paused"; exit 0 (idempotent)
- `_compose_site $SLUG stop` (does NOT remove the container per spec — `stop` keeps the stopped container in place; `down` would remove it. Use `stop`.)
  - NOTE: CONTEXT.md says "Container removed but DB/files/secrets intact". Re-reading: "pause: docker compose -f .../compose.yaml stop. Mark state paused. Container removed but DB/files/secrets intact." There's a tension — `compose stop` keeps the container; `compose down` removes it. Choose `stop` (matches the docker compose verb explicitly named in CONTEXT.md); the "Container removed" prose appears to mean "container stopped/freed" colloquially. Document this choice in SUMMARY.
- Update sites.json: state = `paused`, append state_history entry
- Print: "Site $SLUG paused. RAM freed; DB + files + secrets intact. Run wp-resume $SLUG to restart."
- Optional Caddy stub snippet (per CLI-14 spec): print a commented-out alternate Caddy block that returns a "site paused" 503 page — operator can swap in if desired. Format:
  ```
  # Optional: swap your Caddy block for this stub while paused:
  # <domain> {
  #     respond "Site temporarily paused" 503
  # }
  ```

**bin/wp-resume:**
- Args: `<slug>`, `-h|--help`, `--json`
- _require_root; _get_site $SLUG; _die if empty
- Read current state. If state == `finalized` AND container running (`docker ps -q --filter name=wp-${SLUG}` non-empty): _log info "site already running"; exit 0 (idempotent)
- `_compose_site $SLUG "up -d"`
- Wait for container running (poll up to 30s)
- Update sites.json: state = `finalized` (restored), append state_history entry
- Print: "Site $SLUG resumed at https://$DOMAIN."

Both scripts: error on non-existent slug; --json mode emits `{slug, state, message}`.
  </action>
  <verify>
    <automated>bash -n bin/wp-pause &amp;&amp; bash -n bin/wp-resume &amp;&amp; bin/wp-pause --help 2>&amp;1 | grep -qi pause &amp;&amp; bin/wp-resume --help 2>&amp;1 | grep -qi resume &amp;&amp; grep -q "compose.*stop" bin/wp-pause &amp;&amp; grep -q "up -d" bin/wp-resume &amp;&amp; grep -q "paused" bin/wp-pause &amp;&amp; grep -q "finalized" bin/wp-resume &amp;&amp; test -x bin/wp-pause &amp;&amp; test -x bin/wp-resume</automated>
  </verify>
  <done>Both scripts syntax-clean, executable, idempotent on no-op cases, error on missing slug, update sites.json state, print human-readable status; wp-pause includes optional stub Caddy snippet.</done>
</task>

</tasks>

<verification>
- 3 files exist, all chmod 755
- bash -n passes for all
- wp-delete refuses without --yes in non-tty
- wp-pause + wp-resume idempotent (no-op when already in target state)
- All three error with non-zero exit on unknown slug
- wp-delete prints Caddy + Cloudflare cleanup snippets
- wp-pause prints optional stub Caddy snippet
</verification>

<success_criteria>
The three lifecycle verbs cover delete/pause/resume per CONTEXT.md spec; idempotent where applicable; updates sites.json state correctly; surfaces operator-actionable cleanup output for delete; uses _lib.sh helpers consistently.
</success_criteria>

<output>
Create `.planning/phases/02-cli-core-first-site-e2e/02-04-SUMMARY.md` documenting:
- Confirmation that wp-pause uses `compose stop` (not `down`) and the rationale
- Idempotency behaviour for pause/resume
- Whether VM_PUBLIC_IP detection is included in wp-delete cleanup output (likely "use placeholder; operator knows their IP")
</output>
