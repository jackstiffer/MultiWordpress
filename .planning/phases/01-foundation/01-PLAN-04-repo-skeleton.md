---
phase: 01-foundation
plan: 04
type: execute
wave: 2
depends_on: [01, 02, 03]
files_modified:
  - .gitignore
  - README.md
autonomous: true
requirements: [INFRA-04, INFRA-07, HARD-01]
must_haves:
  truths:
    - ".gitignore prevents accidental commit of compose/.env (which contains MARIADB_ROOT_PASSWORD)."
    - "Root README documents the full Phase-1 setup flow: clone → install slice → configure .env → compose up → build image → validate."
    - "README's validation section reproduces the six ROADMAP §Phase 1 success criteria as runnable commands."
  artifacts:
    - path: ".gitignore"
      provides: "Ignore secrets, OS junk, build artifacts"
      contains: ".env, !*.env.example"
    - path: "README.md"
      provides: "Root project README with Phase-1 setup + validation"
      contains: "compose/compose.yaml, host/install-wp-slice.sh, multiwp:wordpress-6-php8.3, MTU 1460, 13306, 16379, wp.slice"
  key_links:
    - from: "README.md: Setup section"
      to: "host/install-wp-slice.sh, compose/compose.yaml, image/Dockerfile"
      via: "step-by-step references to each Phase-1 plan's artifacts"
      pattern: "host/install-wp-slice\\.sh.*compose/compose\\.yaml.*image"
    - from: "README.md: Validation section"
      to: "ROADMAP §Phase 1 success criteria #1–#6"
      via: "each criterion expressed as a runnable command"
      pattern: "docker network inspect|/sys/fs/cgroup/wp\\.slice/memory\\.max"
---

<objective>
Land the repo skeleton: `.gitignore` and the root `README.md` that ties together the artifacts produced by plans 01–03 into a one-page operator runbook with validation commands.

Purpose: A new operator (or future-you after six months) needs one document that explains how to bring up Phase 1, in what order, and how to confirm each piece works. Without it, the artifacts from plans 01–03 are correct but undiscoverable.
Output: `.gitignore` protecting `.env`; `README.md` walking from clone → live shared infra + buildable image + active wp.slice, with validation commands for every ROADMAP §Phase 1 success criterion.

This plan is in **Wave 2** because it documents what plans 01–03 produce — the README cannot be authoritatively written until those file paths and contents are known.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/PROJECT.md
@.planning/ROADMAP.md
@.planning/REQUIREMENTS.md
@.planning/phases/01-foundation/01-CONTEXT.md
@.planning/phases/01-foundation/01-01-SUMMARY.md
@.planning/phases/01-foundation/01-02-SUMMARY.md
@.planning/phases/01-foundation/01-03-SUMMARY.md
</context>

<tasks>

<task type="auto">
  <name>Task 1: Write .gitignore</name>
  <files>.gitignore</files>
  <action>
Create `.gitignore` at repo root. Must:

- Ignore any `.env` file at any depth (compose/.env contains the MariaDB root password).
- Explicitly NOT ignore `*.env.example` (template files we want tracked).
- Ignore common OS / editor junk (.DS_Store, *.swp, .idea/, .vscode/).
- Track `.planning/` (project decision: planning artifacts are tracked).

Contents:

```gitignore
# Secrets — NEVER commit
.env
*.env
!*.env.example
!.env.example

# OS / editor junk
.DS_Store
Thumbs.db
*.swp
*.swo
*~
.idea/
.vscode/

# Build / runtime artifacts (none yet in Phase 1, but reserved)
*.log
*.pid

# Note: .planning/ is intentionally tracked (project decision artifacts).
```

DO NOT add: ignores for `.planning/`, `node_modules/` (no JS), `__pycache__/` (no Python), or any phase-2 artifacts.
  </action>
  <verify>
    <automated>test -f .gitignore && grep -q '^\.env$' .gitignore && grep -q '^\*\.env$' .gitignore && grep -q '^!\*\.env\.example$' .gitignore && grep -q '\.DS_Store' .gitignore && ! grep -q '^\.planning' .gitignore</automated>
  </verify>
  <done>
.gitignore exists, ignores .env and *.env, allow-lists *.env.example, ignores common OS junk, does not ignore .planning/.
  </done>
</task>

<task type="auto">
  <name>Task 2: Write root README.md</name>
  <files>README.md</files>
  <action>
Create the root `README.md`. The document is the single-source operator runbook for Phase 1.

Required sections (in this order):

1. **Title + one-sentence purpose** — quote PROJECT.md core value.
2. **What's in this repo (Phase 1)** — three-bullet summary pointing at compose/, image/, host/.
3. **Prerequisites** — Linux host with Docker engine + cgroup v2 + sufficient privilege for systemctl.
4. **Setup (in order)** — five numbered steps:
   1. Install `wp.slice`: `cd host && sudo ./install-wp-slice.sh`. Refer to `host/README.md`.
   2. Configure secrets: `cp compose/.env.example compose/.env && chmod 600 compose/.env` then fill `MARIADB_ROOT_PASSWORD` with `openssl rand -hex 24`.
   3. Bring up shared infra: `docker compose -f compose/compose.yaml up -d`.
   4. Build the per-site image: `docker build -t multiwp:wordpress-6-php8.3 image/`. Refer to `image/README.md`.
   5. Validate (next section).
5. **Validation — Phase 1 success criteria** — reproduce ROADMAP §Phase 1 #1–#6 as runnable commands, each with the expected output. Format as a table:

   | # | Criterion | Command | Expected |
   |---|-----------|---------|----------|
   | 1 | Shared infra healthy | `docker compose -f compose/compose.yaml ps` | `wp-mariadb` and `wp-redis` STATE=`running`, STATUS contains `healthy` |
   | 2a | MTU 1460 on wp-network | `docker network inspect wp-network --format '{{(index .Options "com.docker.network.driver.mtu")}}'` | `1460` |
   | 2b | Loopback-only ports | `ss -ltn \| grep -E ':(13306\|16379)\b'` | both rows show `127.0.0.1:13306` / `127.0.0.1:16379`, no `0.0.0.0` |
   | 3 | Image built with WP-CLI + correct PHP/FPM | `docker run --rm multiwp:wordpress-6-php8.3 sh -c 'wp --info --allow-root && php -i \| grep -E "opcache.memory_consumption\|opcache.jit\|memory_limit" && cat /usr/local/etc/php-fpm.d/zz-wp.conf'` | shows wp-cli version, opcache.memory_consumption=96, opcache.jit=disable, memory_limit=256M, pm = ondemand, max_children = 10 |
   | 4 | Container runs as UID 33 + log redirection | `docker run --rm multiwp:wordpress-6-php8.3 sh -c 'id -u && grep error_log /usr/local/etc/php/conf.d/zz-wp.ini'` | `33` then `error_log = /proc/self/fd/2` |
   | 5a | cgroup v2 active | `stat -fc %T /sys/fs/cgroup/` | `cgroup2fs` |
   | 5b | wp.slice loaded with 4 GB cap | `systemctl status wp.slice && cat /sys/fs/cgroup/wp.slice/memory.max` | status shows loaded + active; memory.max = `4294967296` |
   | 6 | AudioStoryV2 unaffected | `docker network ls \| grep -E 'wp-network\|audiostory_app-network'` and `docker stats --no-stream` | both networks present and distinct; no port conflicts on 3000/6379; wp infra cluster well under 1 GB resident |

6. **Project structure (current — Phase 1)** — tree showing:
   ```
   .
   ├── compose/
   │   ├── compose.yaml
   │   └── .env.example
   ├── image/
   │   ├── Dockerfile
   │   ├── php.d-zz-wp.ini
   │   ├── fpm-zz-wp.conf
   │   └── README.md
   ├── host/
   │   ├── wp.slice
   │   ├── install-wp-slice.sh
   │   └── README.md
   ├── .gitignore
   ├── README.md
   └── .planning/         (planning artifacts, tracked)
   ```

7. **What's next (Phase 2 preview)** — one paragraph: CLI tools (`wp-create`, `wp-delete`, ...) live in Phase 2 and will use the Phase-1 artifacts unchanged. They will run per-site containers with `--cgroup-parent=wp.slice` and pin to the locally-built `multiwp:wordpress-6-php8.3` tag.

8. **Coexistence note** — one paragraph reaffirming AudioStoryV2 at `/Users/work/Projects/AudioStoryV2` is read-only and untouched: separate network (`audiostory_app-network`), separate ports (3000, 6379), separate cgroup (not in wp.slice).

DO NOT add: badge ribbons, license boilerplate (defer), CI status, contribution guide, marketing copy, or any reference to features in Phases 2–4 beyond the one-paragraph preview.
  </action>
  <verify>
    <automated>test -f README.md && grep -q 'compose/compose.yaml' README.md && grep -q 'host/install-wp-slice.sh' README.md && grep -q 'multiwp:wordpress-6-php8.3' README.md && grep -q '1460' README.md && grep -q '13306' README.md && grep -q '16379' README.md && grep -q '4294967296' README.md && grep -q 'wp.slice' README.md && grep -q 'cgroup2fs' README.md && grep -q 'AudioStoryV2' README.md</automated>
  </verify>
  <done>
README.md exists with all eight required sections. Validation table reproduces all six ROADMAP §Phase 1 success criteria as runnable commands. Project tree matches the actual repo state after plans 01–03 ship.
  </done>
</task>

</tasks>

<verification>
After both tasks complete:
1. `git status` shows `.gitignore` and `README.md` as new tracked files.
2. `git check-ignore compose/.env` returns 0 (would-be-ignored). `git check-ignore compose/.env.example` returns 1 (not ignored).
3. Read README.md end-to-end and confirm: every Phase-1 ROADMAP success criterion appears in the validation table; project tree matches what plans 01–03 produced; no Phase 2/3/4 features are described except the one-paragraph "what's next" preview.
</verification>

<success_criteria>
- A new operator can clone the repo and run Phase 1 end-to-end using ONLY the README + the linked sub-READMEs (host/, image/).
- All six ROADMAP §Phase 1 success criteria are validate-able from commands in the README.
- `.env` cannot be accidentally committed.
</success_criteria>

<output>
Create `.planning/phases/01-foundation/01-04-SUMMARY.md` documenting:
- Final README structure shipped.
- Confirmation that all six ROADMAP success criteria appear in the validation table.
- Note for Phase 2: README will need a new section once CLI ships; this Phase-1 README's "What's next" paragraph is the placeholder.
</output>
