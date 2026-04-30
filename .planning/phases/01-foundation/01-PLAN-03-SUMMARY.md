---
phase: 01-foundation
plan: 03
subsystem: host
tags: [systemd, cgroup, memory, infra, host]
requires: []
provides:
  - "host/wp.slice — 4 GB cluster cgroup for per-site WP containers"
  - "host/install-wp-slice.sh — cgroup-v2 verifier + slice installer"
  - "host/README.md — host setup runbook + Phase-2 hand-off contract"
affects:
  - "Phase 2 wp-create: must pass --cgroup-parent=wp.slice on every per-site docker run/compose"
  - "Phase 2 compose validation: must reject mem_limit, deploy.resources.limits.memory, and --memory on per-site services"
tech-stack:
  added:
    - "systemd Slice unit (cgroup v2)"
  patterns:
    - "fail-fast install: abort before mutation if cgroup v2 absent"
    - "post-install assertion: verify memory.max equals expected bytes"
key-files:
  created:
    - "host/wp.slice"
    - "host/install-wp-slice.sh"
    - "host/README.md"
  modified: []
decisions:
  - "Slice file includes Documentation= URL with <repo> placeholder per plan canonical content; will be filled when repo URL is finalized"
  - "Install script chmod is operator's responsibility (documented in README); script ships without +x bit so chmod is explicit in the install steps"
  - "Slice has no [Install] section — slices activate on demand from members"
  - "wp-mariadb and wp-redis stay outside wp.slice (per CONTEXT decisions); they own their own mem_limit caps"
  - "AudioStoryV2 explicitly NOT in wp.slice; documented as coexistence rule"
metrics:
  duration: "~5 min"
  completed: "2026-04-30"
  tasks: 2
  files: 3
requirements: [INFRA-05, INFRA-07, HARD-01]
---

# Phase 1 Plan 3: wp.slice cgroup Summary

Shipped the host-level systemd slice (`wp.slice`) that imposes the 4 GB
cluster memory ceiling on all per-site WordPress containers, plus an
install script that fail-fast verifies cgroup v2 before mutating system
state and asserts `memory.max == 4294967296` after activation.

## What Was Built

### host/wp.slice
Systemd Slice unit. `[Unit] Description=...; Before=slices.target;`
`[Slice] MemoryMax=4G; MemoryHigh=3.5G; CPUWeight=100`. No `[Install]`
section (slices activate on demand from members). Verified against the
plan's automated grep checks (Description, [Slice], MemoryMax=4G,
MemoryHigh=3.5G, CPUWeight=100, no [Install]).

### host/install-wp-slice.sh
Bash installer with `set -euo pipefail`. Flow:

1. EUID root check (aborts with sudo hint if not).
2. cgroup v2 check: `stat -fc %T /sys/fs/cgroup/` must equal `cgroup2fs`,
   else abort with the actual fs type printed and a GRUB hint for Ubuntu
   v1 hosts (exit 2).
3. `cp` slice → `/etc/systemd/system/wp.slice`, set 0644 root:root.
4. `systemctl daemon-reload`.
5. `systemctl start wp.slice`.
6. Read `/sys/fs/cgroup/wp.slice/memory.max`; abort with the actual value
   if it does not equal `4294967296` (exit 3).
7. Print success summary `wp.slice installed; MemoryMax=4G; CPUWeight=100`
   plus the Phase-2 contract reminder.

`bash -n host/install-wp-slice.sh` parses cleanly.

### host/README.md
Operator runbook covering:

- Prerequisites (Docker, systemd, cgroup v2; Ubuntu 22.04+, Debian 12+).
- Install steps (`chmod +x` then `sudo host/install-wp-slice.sh`).
- Verify-after-install commands.
- **Memory model contract for Phase 2:** per-site `--cgroup-parent=wp.slice`
  required; `mem_limit` / `--memory` / `deploy.resources.limits.memory`
  forbidden on per-site services; wp-mariadb and wp-redis are outside the
  slice with their own caps.
- **AudioStoryV2 coexistence rule:** its containers MUST NOT be moved into
  `wp.slice`. The slice is precisely what protects them from runaway WP
  sites (PITFALLS §5.2).
- Uninstall steps.

## Phase 2 Hand-off Contract

When Phase 2 (`wp-create`) is implemented, the compose validation layer
must reject any per-site service that sets:

- `mem_limit:` (compose v2 short form)
- `memory:` under `deploy.resources.limits` (compose v3 long form)
- `--memory=` on `docker run` if shelling out
- `--memory-swap`, `--memory-reservation` (sibling caps)

And every per-site invocation MUST set `--cgroup-parent=wp.slice` (or the
equivalent compose `cgroup_parent: wp.slice`). Without it, the kernel will
not enforce the cluster cap and a runaway plugin can OOM-kill AudioStoryV2.

## Deviations from Plan

None — plan executed exactly as written. The plan's canonical wp.slice body
includes a `Documentation=` URL with literal `<repo>` placeholder; that was
preserved verbatim per "Read the plan first for canonical content; don't
paraphrase." (The orchestrator-prompt's simplified body without the
`Documentation=` line was not used; the plan is canonical.)

## Verification Results

Automated checks (run from repo root):

- `bash -n host/install-wp-slice.sh` → parses cleanly.
- `host/wp.slice` contains all required directives (Description, [Slice],
  MemoryMax=4G, MemoryHigh=3.5G, CPUWeight=100); no [Install] section.
- `host/install-wp-slice.sh` contains `cgroup2fs`, `4294967296`,
  `systemctl daemon-reload`, `systemctl start wp.slice`.
- `host/README.md` documents `--cgroup-parent=wp.slice` and `cgroup v2`.

End-to-end `sudo bash host/install-wp-slice.sh` cannot be exercised in the
executor environment (no Linux host, no systemd); deferred to VM
integration testing per the plan's verification §2.

## Self-Check: PASSED
- host/wp.slice — FOUND
- host/install-wp-slice.sh — FOUND
- host/README.md — FOUND
- All plan-defined automated `<verify>` checks pass.
