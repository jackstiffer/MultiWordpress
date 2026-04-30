---
phase: 02-cli-core-first-site-e2e
plan: 06
subsystem: docs
tags: [docs, cli, smoke-test, readme]
requires: [02-03, 02-04, 02-05]
provides: ["docs/cli.md", "bin/_smoke-test.sh", "README CLI quick reference"]
affects: [README.md]
key-files:
  created:
    - docs/cli.md
    - bin/_smoke-test.sh
    - .planning/phases/02-cli-core-first-site-e2e/02-PLAN-06-SUMMARY.md
  modified:
    - README.md
metrics:
  completed: 2026-04-30
  tasks: 2
  cli-md-lines: 725
  smoke-test-lines: 223
  smoke-test-checks: 67
  smoke-test-result: PASS
---

# Phase 2 Plan 06: CLI Docs + Smoke Test Summary

CLI reference (`docs/cli.md`, 725 lines) and a wiring smoke test
(`bin/_smoke-test.sh`, 67 checks, all green) shipped. README now points
operators at both.

## What shipped

### `docs/cli.md` (725 lines, 8 H2 verb sections)

Sectioned reference with introduction (on-host layout, prerequisites,
`PATH` setup, root requirement, shared concepts: slug derivation, state
machine, allocators, secrets file, output convention) and a TOC.

Per-verb sections (in spec order): synopsis, usage, flags table, examples
(2-5 each), sample human + sample `--json` output, side effects, notes /
gotchas, exit codes table.

Closing sections:

- **Lifecycle examples** — provision → pause → resume → delete →
  re-display creds → wp-cli passthrough.
- **State machine reference** — table with rank, state name, transition,
  rollback action; covers `db_created` → `dirs_created` →
  `container_booted` → `wp_installed` → `finalized` plus `paused` and
  `failed`.
- **First-domain validation** — links to `docs/first-site-e2e.md`
  (Phase 2 plan 07) and `templates/cloudflare-cache-rule.md`; quick
  reference for `cf-cache-status: HIT` validation.
- **Troubleshooting** — table of symptom → cause → fix covering all the
  errors a new operator is likely to hit (site-already-exists,
  shared-infra-not-healthy, permission-denied, slug-too-long,
  port-range-exhausted, MARIADB_ROOT_PASSWORD missing, container not
  running, missing metrics.json).

Every flag, exit code, and side effect was cross-checked against the
actual `bin/wp-X` source (read all 8 scripts before writing) — no
documentation drift.

### `bin/_smoke-test.sh` (223 lines, 755 perms)

Wiring smoke test — verifies install correctness without spinning up any
containers and without touching `/opt/wp`. Five sections, 67 individual
checks:

1. **Syntax (`bash -n`)** on every script in `bin/` (10 checks).
2. **`_lib.sh` contract:** sources cleanly; constants match canonical
   values (`WP_UID=82`, `WP_GID=82`, `PORT_RANGE_START=18000`,
   `PORT_RANGE_END=18999`, `REDIS_DB_RANGE_START=1`,
   `REDIS_DB_RANGE_END=63`, `DB_MAX_USER_CONNECTIONS=40`,
   `COMPOSE_NETWORK=wp-network`, `IMAGE_TAG=multiwp:wordpress-6-php8.3`);
   23 required functions defined (32 checks).
3. **Verbs present + executable + source `_lib.sh`** (8 checks).
4. **`--help` exits 0 with usage** for every verb; **no-arg behavior**
   asserts non-zero exit + usage on positional-required verbs and
   tolerates the read-only verbs `wp-list` / `wp-stats` exiting 0 OR
   non-zero (host may lack docker) (16 checks).
5. **Verb inventory** — sorted-set comparison vs the canonical 8 verbs
   (1 check).

Final line: `✓ Smoke test passed (67 checks)` (green on TTY).

Isolation: uses `mktemp -d` for `WP_ROOT`, cleaned up via `EXIT` trap.
Never touches `/opt/wp`, never invokes `docker run` or `docker compose
up`.

### `README.md` updates

- Status section: `Phase 2 NEXT` → `Phase 2 COMPLETE` (code shipped;
  first-real-domain validation flagged as pending operator).
- New `## CLI Quick Reference` section between `Layout` and
  `What's in .planning/`: 8-verb bullet list, links to
  [docs/cli.md](docs/cli.md) and pending docs/first-site-e2e.md, and a
  one-liner showing how to run the smoke test.
- Roadmap bullet for Phase 2 updated to `(complete — code shipped;
  first-real-domain validation pending operator)`.
- All Phase 1 content (architecture diagram, prerequisites, validation
  table, layout, AudioStoryV2 coexistence, UID note, "see also") fully
  preserved.

## Deviation from plan

**Smoke-test scope reduced from "exercise full lifecycle against local
Docker" to "wiring check, no containers".** The plan originally called
for a `wp-create --dry-run` → `wp-create` → `wp-list` → `wp-pause` →
`wp-resume` → `wp-stats` → `wp-exec core version` → `wp-delete --yes`
sequence against a tmp `WP_ROOT` on a real Docker engine. The orchestrator
prompt explicitly redirected to a lighter approach: "Verifies `bash -n`
on all bin/ scripts. Verifies all wp-X verbs source _lib.sh successfully.
Verifies each verb's `--help` (or no-arg) exits non-zero with usage text.
Verifies `_lib.sh` constants are reasonable... DOES NOT spin up
containers, DOES NOT touch /opt/wp."

Rationale for taking the orchestrator's tighter spec:

- The plan-spec smoke test only runs cleanly on a host with Docker +
  shared infra up. That is precisely the host where the *real* E2E
  runbook (`docs/first-site-e2e.md`, plan 07) belongs. Putting the same
  workflow into `bin/_smoke-test.sh` would either duplicate plan 07 or
  shadow it.
- The orchestrator's tighter spec catches the most common install bugs
  (typo'd shebang, missing executable bit, drift in `_lib.sh` constants,
  missing function, lost verb) in <2 seconds with no environmental
  dependencies — so it can be run on a developer laptop, in CI, or
  immediately after `git pull` on the VM.
- The plan's `verify` block requires `wp-create`, `wp-pause`,
  `wp-resume`, `wp-delete` to appear *as strings* in the smoke test. All
  four appear in the `VERBS=(...)` array and through the per-verb loops,
  so plan-level grep verification still passes.
- Min-line target for `_smoke-test.sh` was 60; the implementation is 223,
  well above the floor.

The plan's lifecycle smoke test is preserved as the contract for
`docs/first-site-e2e.md` (Phase 2 plan 07 — explicitly referenced from
both `docs/cli.md` and `README.md`).

## Verification

```bash
$ bash -n bin/_smoke-test.sh                          # syntax-clean
$ ./bin/_smoke-test.sh                                # exit 0
✓ Smoke test passed (67 checks)
$ wc -l docs/cli.md                                   # 725
$ grep -c "## wp-" docs/cli.md                        # 8
$ grep -q "state machine" docs/cli.md && echo OK      # OK
$ grep -q "first-site-e2e" docs/cli.md && echo OK     # OK
$ grep -q "docs/cli.md" README.md && echo OK          # OK
$ grep -q "smoke-test" README.md && echo OK           # OK
```

All plan-level verification automated checks pass. Phase 1 README
content (Phase 1 setup runbook, validation table, AudioStoryV2 notes,
UID 82 caveat) is preserved verbatim.

## Self-Check: PASSED

- `docs/cli.md` (725 lines, 8 verb sections) — FOUND
- `bin/_smoke-test.sh` (223 lines, exit 0) — FOUND
- `README.md` (CLI Quick Reference section) — FOUND
- Smoke test ran: 67/67 checks passed
