---
phase: 01-foundation
plan: 03
type: execute
wave: 1
depends_on: []
files_modified:
  - host/wp.slice
  - host/install-wp-slice.sh
  - host/README.md
autonomous: true
requirements: [INFRA-05, INFRA-07, HARD-01]
must_haves:
  truths:
    - "host/wp.slice is a valid systemd Slice unit declaring MemoryMax=4G, MemoryHigh=3.5G, CPUWeight=100."
    - "host/install-wp-slice.sh refuses to install on a host without cgroup v2."
    - "After running the install script, `cat /sys/fs/cgroup/wp.slice/memory.max` returns 4294967296."
    - "host/README.md documents the per-site --cgroup-parent=wp.slice contract for Phase 2."
  artifacts:
    - path: "host/wp.slice"
      provides: "systemd slice unit for the WP cluster cgroup"
      contains: "[Slice], MemoryMax=4G, CPUWeight=100"
    - path: "host/install-wp-slice.sh"
      provides: "cgroup v2 verification + slice install script"
      contains: "cgroup2fs, systemctl daemon-reload, systemctl start wp.slice"
    - path: "host/README.md"
      provides: "Host setup runbook"
      contains: "wp.slice, cgroup v2, --cgroup-parent"
  key_links:
    - from: "host/install-wp-slice.sh"
      to: "host/wp.slice"
      via: "cp host/wp.slice /etc/systemd/system/wp.slice"
      pattern: "cp.*wp\\.slice.*/etc/systemd/system"
    - from: "host/install-wp-slice.sh"
      to: "/sys/fs/cgroup/wp.slice/memory.max"
      via: "verification step reads memory.max == 4294967296"
      pattern: "memory\\.max"
---

<objective>
Author the host-level systemd slice that enforces the 4 GB memory ceiling for all per-site WP containers, plus the install script that verifies cgroup v2 is active before activation, plus the README that documents the operator runbook and the Phase-2 hand-off contract.

Purpose: This is the ONLY memory ceiling for per-site containers (INFRA-05). Without `wp.slice`, a runaway plugin in one site can OOM-kill AudioStoryV2. With it, the kernel enforces a hard cluster cap regardless of how many sites are running.
Output: `host/wp.slice` + `host/install-wp-slice.sh` + `host/README.md` satisfying ROADMAP §Phase 1 success criterion #5.
</objective>

<execution_context>
@$HOME/.claude/get-shit-done/workflows/execute-plan.md
@$HOME/.claude/get-shit-done/templates/summary.md
</execution_context>

<context>
@.planning/REQUIREMENTS.md
@.planning/research/PITFALLS.md
@.planning/phases/01-foundation/01-CONTEXT.md
</context>

<tasks>

<task type="auto">
  <name>Task 1: Write host/wp.slice systemd unit</name>
  <files>host/wp.slice</files>
  <action>
Create the systemd Slice unit file. Path on VM after install: `/etc/systemd/system/wp.slice`. Repo path: `host/wp.slice`.

Exact contents (these values are spec from CONTEXT.md and REQUIREMENTS.md INFRA-05/INFRA-07 — do not paraphrase):

```ini
[Unit]
Description=Cluster cgroup for MultiWordpress per-site containers
Documentation=https://github.com/<repo>/blob/main/host/README.md
Before=slices.target

[Slice]
# 4 GB hard cap on combined memory of all wp-<site> containers.
# Per-site containers MUST run with `--cgroup-parent=wp.slice` and MUST NOT
# set their own `mem_limit` / `--memory`. wp-mariadb and wp-redis are NOT
# in this slice — they have their own caps in compose/compose.yaml.
MemoryMax=4G
MemoryHigh=3.5G
CPUWeight=100
```

DO NOT add: `[Install]` section (slices don't take Install/WantedBy — they're activated by the units that drop into them, i.e., docker containers passing `--cgroup-parent=wp.slice`), per-site memory limits, MemoryLow (we want bursts to compete fairly within the slice, not be reserved per-process).
  </action>
  <verify>
    <automated>test -f host/wp.slice && grep -q '^MemoryMax=4G' host/wp.slice && grep -q '^MemoryHigh=3.5G' host/wp.slice && grep -q '^CPUWeight=100' host/wp.slice && grep -q '^\[Slice\]' host/wp.slice && grep -q '^Description=' host/wp.slice && ! grep -q '^\[Install\]' host/wp.slice</automated>
  </verify>
  <done>
File exists with [Unit] + [Slice] sections, MemoryMax=4G, MemoryHigh=3.5G, CPUWeight=100, no [Install] section. `systemd-analyze verify host/wp.slice` (run during execute) reports no errors.
  </done>
</task>

<task type="auto">
  <name>Task 2: Write host/install-wp-slice.sh + host/README.md</name>
  <files>host/install-wp-slice.sh, host/README.md</files>
  <action>
**`host/install-wp-slice.sh`** — bash install script. Must be `chmod +x` (the executor will run `chmod +x host/install-wp-slice.sh` after writing).

Exact behavior (per CONTEXT decisions):

```bash
#!/usr/bin/env bash
# Install /etc/systemd/system/wp.slice (INFRA-07) on the host.
# Must run as root (or via sudo). Verifies cgroup v2 BEFORE installing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLICE_SRC="${SCRIPT_DIR}/wp.slice"
SLICE_DST="/etc/systemd/system/wp.slice"
EXPECTED_MAX_BYTES=4294967296   # 4 GiB exactly

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: must run as root (try: sudo $0)" >&2
  exit 1
fi

if [[ ! -f "${SLICE_SRC}" ]]; then
  echo "ERROR: ${SLICE_SRC} not found" >&2
  exit 1
fi

# Step 1: verify cgroup v2 (INFRA-07).
fs_type="$(stat -fc %T /sys/fs/cgroup/ 2>/dev/null || true)"
if [[ "${fs_type}" != "cgroup2fs" ]]; then
  echo "ERROR: /sys/fs/cgroup is '${fs_type}', expected 'cgroup2fs'." >&2
  echo "  This host is not running cgroup v2. wp.slice requires cgroup v2." >&2
  echo "  On Ubuntu, ensure 'systemd.unified_cgroup_hierarchy=1' in /etc/default/grub." >&2
  exit 2
fi
echo "OK: cgroup v2 detected (cgroup2fs)."

# Step 2: install the unit.
echo "Installing ${SLICE_DST}..."
cp "${SLICE_SRC}" "${SLICE_DST}"
chmod 0644 "${SLICE_DST}"
chown root:root "${SLICE_DST}"

# Step 3: reload systemd.
echo "Reloading systemd..."
systemctl daemon-reload

# Step 4: activate the slice (a slice is "started" by activation; subsequent
# containers passing --cgroup-parent=wp.slice will attach to it).
echo "Starting wp.slice..."
systemctl start wp.slice

# Step 5: verify memory.max.
sleep 1
actual_max="$(cat /sys/fs/cgroup/wp.slice/memory.max 2>/dev/null || echo MISSING)"
if [[ "${actual_max}" != "${EXPECTED_MAX_BYTES}" ]]; then
  echo "ERROR: /sys/fs/cgroup/wp.slice/memory.max = '${actual_max}', expected '${EXPECTED_MAX_BYTES}'" >&2
  exit 3
fi
echo "OK: /sys/fs/cgroup/wp.slice/memory.max = ${actual_max} (4 GiB)."

# Step 6: show status.
systemctl status wp.slice --no-pager || true

echo
echo "wp.slice installed and active."
echo "Phase 2's per-site containers must run with --cgroup-parent=wp.slice"
echo "and MUST NOT set mem_limit / --memory."
```

DO NOT add: `--enable` (slices don't enable — they activate on demand from members), modification of GRUB config (we just detect and abort if v1), automatic systemd reboot.

**`host/README.md`** — host setup runbook:

```markdown
# Host Setup — wp.slice

This directory installs the systemd slice (`wp.slice`) that enforces the
4 GB memory ceiling for all per-site WordPress containers (INFRA-05, INFRA-07).

## Prerequisites

- Linux host with **cgroup v2** (most distros since 2022). On Ubuntu 22.04+
  this is the default; on older boxes verify with:

      stat -fc %T /sys/fs/cgroup/

  Expected output: `cgroup2fs`. If it returns `tmpfs` or anything else, the
  host is on cgroup v1 — `install-wp-slice.sh` will abort with a clear error.

- `systemctl` (systemd 240+). Slice support is stable since systemd 244.

## Install

    sudo ./install-wp-slice.sh

This script:

1. Verifies cgroup v2 (`stat -fc %T /sys/fs/cgroup/` == `cgroup2fs`). Aborts
   if not.
2. Copies `wp.slice` → `/etc/systemd/system/wp.slice` (root:root, 0644).
3. `systemctl daemon-reload`.
4. `systemctl start wp.slice`.
5. Verifies `/sys/fs/cgroup/wp.slice/memory.max` == `4294967296` (4 GiB).

## Verify after install

    systemctl status wp.slice
    cat /sys/fs/cgroup/wp.slice/memory.max    # → 4294967296

## Memory model contract (read before Phase 2)

The slice is the **ONLY** memory ceiling for per-site containers. Phase 2's
`wp-create` MUST:

- Pass `--cgroup-parent=wp.slice` to every per-site `docker run` /
  `docker compose up`.
- NOT set `mem_limit` or `--memory` on per-site services. Compose validation
  in Phase 2 must reject any per-site definition that does.

`wp-mariadb` and `wp-redis` (in `compose/compose.yaml`) are NOT in this slice
— they run with their own `mem_limit` (1 GB and 320 MB respectively). The
slice covers only `wp-<site>` containers.

## Coexistence with AudioStoryV2

AudioStoryV2's containers are NOT in `wp.slice`. They live in their own
default cgroup. The 4 GB cap on `wp.slice` is what protects them from a
runaway WP site (PITFALLS §5.2).

## Files

- `wp.slice` — systemd Slice unit (`MemoryMax=4G`, `MemoryHigh=3.5G`,
  `CPUWeight=100`).
- `install-wp-slice.sh` — verifies cgroup v2 and installs the unit.
```
  </action>
  <verify>
    <automated>test -f host/install-wp-slice.sh && test -f host/README.md && bash -n host/install-wp-slice.sh && grep -q 'cgroup2fs' host/install-wp-slice.sh && grep -q '4294967296' host/install-wp-slice.sh && grep -q 'systemctl daemon-reload' host/install-wp-slice.sh && grep -q 'systemctl start wp.slice' host/install-wp-slice.sh && grep -q -- '--cgroup-parent=wp.slice' host/README.md && grep -q 'cgroup v2' host/README.md</automated>
  </verify>
  <done>
`bash -n host/install-wp-slice.sh` parses successfully. Script verifies cgroup v2, installs to /etc/systemd/system/wp.slice, runs daemon-reload + start, asserts memory.max value. README documents the Phase-2 contract (--cgroup-parent=wp.slice, no mem_limit on per-site).
  </done>
</task>

</tasks>

<verification>
After both tasks complete:
1. `bash -n host/install-wp-slice.sh` parses cleanly (executor verification).
2. (On VM, manual) `sudo bash host/install-wp-slice.sh` runs end-to-end on a cgroup-v2 host: detects cgroup2fs, installs the unit, daemon-reloads, starts the slice, verifies memory.max == 4294967296.
3. `systemctl status wp.slice` shows loaded + active.
4. `systemd-analyze verify host/wp.slice` reports no errors.
</verification>

<success_criteria>
- ROADMAP §Phase 1 success criterion #5 satisfied.
- INFRA-05 (memory model contract documented), INFRA-07 (unit installed with verified value) both traceable.
- HARD-01 reinforced via README cross-reference (the slice is part of why we don't need per-container mem caps that could collide with AudioStoryV2).
</success_criteria>

<output>
Create `.planning/phases/01-foundation/01-03-SUMMARY.md` documenting:
- Final wp.slice contents shipped.
- Phase-2 hand-off contract: `--cgroup-parent=wp.slice` on every per-site `docker run`; reject any per-site `mem_limit`.
- Note for Phase 2: when implementing compose validation, the regex/check must reject `mem_limit:` AND `memory:` (under `deploy.resources.limits`) AND `--memory=` flag.
</output>
