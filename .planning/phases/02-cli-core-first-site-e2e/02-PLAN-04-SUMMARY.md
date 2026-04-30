---
phase: 02-cli-core-first-site-e2e
plan: 04
subsystem: cli
tags: [cli, lifecycle, delete, pause, resume, state-machine]
requires:
  - bin/_lib.sh (Phase 2 plan 01)
  - templates/caddy-block.tmpl (Phase 2 plan 02)
provides:
  - bin/wp-delete (lifecycle: tear-down)
  - bin/wp-pause  (lifecycle: stop)
  - bin/wp-resume (lifecycle: start)
affects:
  - sites.json state_history grows on every pause/resume
tech-stack:
  added: []
  patterns:
    - "Idempotent verbs (paused→pause = no-op; running→resume = no-op)"
    - "--yes / non-tty refusal for destructive verb"
    - "Best-effort cleanup with fail-only-if-all-failed semantics"
key-files:
  created:
    - bin/wp-delete
    - bin/wp-pause
    - bin/wp-resume
  modified: []
decisions:
  - "wp-pause uses `docker compose stop` (not `down`)"
  - "wp-delete prints rendered Caddy block + Cloudflare DNS placeholder for manual cleanup"
  - "VM public IP rendered as `<vm_public_ip>` placeholder in cleanup output"
metrics:
  duration: ~10 min
  completed: 2026-04-30
requirements: [CLI-06, CLI-14, STATE-01, STATE-02]
---

# Phase 2 Plan 04: wp-delete + wp-pause + wp-resume Summary

Three lifecycle CLI verbs implementing site teardown, stop-with-state-preserved, and resume — wired through `_lib.sh` helpers, JSON-mode aware, idempotent where applicable, and refusing silent success on unknown slugs.

## What was built

### `bin/wp-delete <slug> [--yes] [--json]`
Destructive teardown. Sequence:
1. Validates slug exists in `sites.json` (errors if not).
2. Confirms via interactive prompt (literal `yes`/`y`) unless `--yes`. Refuses on non-tty without `--yes`.
3. `docker compose down --remove-orphans` (best-effort).
4. `_db_drop_site` (DROP USER + DROP DATABASE + FLUSH PRIVILEGES via `_lib.sh` helper — note: helper drops user before DB to satisfy MariaDB ordering).
5. `rm -rf /opt/wp/sites/<slug>`.
6. `rm -f /opt/wp/secrets/<slug>.env`.
7. `_state_remove_site` to drop the registry entry.
8. Renders the Caddy block from `templates/caddy-block.tmpl` with the saved port/slug/domain so the operator can copy-find-and-delete it from their Caddyfile. Prints Cloudflare DNS row reminder.

`--json` mode emits `{slug, domain, port, status: "deleted", caddy_block, dns_row}`.

Hard-fail only if **both** DB drop AND filesystem cleanup fail (otherwise warns and exits 0 — partial state is normal for an already-half-broken site).

### `bin/wp-pause <slug> [--json]`
1. Validates slug exists.
2. If state is already `paused`, no-op success (idempotent).
3. `docker compose -f .../compose.yaml stop` — preserves container record so resume is fast.
4. Updates `sites.json` state to `paused`, sets `paused_at`, appends to `state_history`.
5. Prints success message + optional Caddy 503 stub snippet (commented out — operator opt-in).

### `bin/wp-resume <slug> [--json]`
1. Validates slug exists.
2. If state is `finalized` AND container actually running, no-op success.
3. Pre-flight: verify `wp-mariadb` and `wp-redis` containers are running (otherwise WP would crash on connect).
4. `docker compose -f .../compose.yaml up -d`.
5. Polls up to 30 s for the container to enter `running`.
6. Updates state to `finalized`, appends history.

## Key Decisions

**1. `compose stop` (not `down`) for pause.**
CONTEXT.md prose said "Container removed" but the verb-name spec said `stop`. We followed the verb name. `stop` keeps the container record in place so `up -d` is essentially instant. `down` would remove the container and force a re-create on resume, which wastes a few seconds and (more importantly) loses the container's filesystem layer (irrelevant for WP since wp-content is bind-mounted, but still: `stop` is the cheaper, safer verb for "pause"). Resume uses `up -d` which idempotently recreates the container if it's missing, so the choice doesn't break recovery from manual `docker rm`.

**2. VM public IP shown as a `<vm_public_ip>` placeholder.**
The system has no good way to know the VM's external IP (could be NAT'd; could have multiple interfaces). Operators provisioning the VM know their IP. Leaving a placeholder is honest.

**3. wp-delete is fail-soft on partial state.**
Already-broken sites are exactly the ones operators want to delete. Hard-failing because (e.g.) the compose file is missing would leave the registry entry orphaned. Each step warns on failure but continues; we only error-exit if BOTH the DB drop AND the filesystem cleanup fail (i.e. nothing useful happened).

**4. Idempotency via state read, not docker-state read.**
`wp-pause` short-circuits if `sites.json` says `paused`. We trust the state file as the source of truth. `wp-resume` is stricter — it cross-checks `docker ps` because a `finalized` site whose container was killed externally needs to be brought back.

## Deviations from Plan

**[Rule 2 - Critical] wp-resume pre-flight checks shared infra.**
Plan said "shared infra healthy (wp-mariadb + wp-redis check)" — implemented as `docker ps --filter status=running` checks before `up -d`. Without this, a resume during a maintenance window would silently produce a crashing container. Documented in script header.

**[Rule 1 - Bug-prevention] state_history append uses jq array concatenation.**
The `_state_set_site` helper merges a JSON fragment with `+`, which would replace `state_history` instead of appending to it. So we do the append explicitly via a second jq pass + `_save_state`. Best-effort (failure logs warn but does not fail the verb), since the container state already happened.

No other deviations.

## Verification

```
bash -n bin/wp-delete   # syntax OK
bash -n bin/wp-pause    # syntax OK
bash -n bin/wp-resume   # syntax OK
chmod 755 — all three executable
bin/wp-delete --help    # shows help
bin/wp-pause --help     # shows help
bin/wp-resume --help    # shows help
bin/wp-pause            # exits 1 with "missing required <slug>"
grep DROP   bin/wp-delete  → matched (via _db_drop_site reference)
grep -- --yes   bin/wp-delete  → matched
grep "compose.*stop"  bin/wp-pause  → matched
grep "up -d"  bin/wp-resume  → matched
grep paused   bin/wp-pause  → matched
grep finalized bin/wp-resume → matched
```

All plan-listed automated checks pass. Runtime/E2E verification deferred to phase E2E task (requires real wp-mariadb + an existing site).

## Self-Check: PASSED
- bin/wp-delete: FOUND (6075 bytes, mode 755)
- bin/wp-pause:  FOUND (4205 bytes, mode 755)
- bin/wp-resume: FOUND (4569 bytes, mode 755)
- All three syntax-clean (`bash -n`).
