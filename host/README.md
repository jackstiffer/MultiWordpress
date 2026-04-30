# Host Setup — wp.slice

This directory installs the systemd slice (`wp.slice`) that enforces the
4 GB memory ceiling for all per-site WordPress containers (INFRA-05, INFRA-07).

## Prerequisites

- Linux host with **Docker** + **systemd** + **cgroup v2** (Ubuntu 22.04+,
  Debian 12+; most distros since 2022). Verify with:

      stat -fc %T /sys/fs/cgroup/

  Expected output: `cgroup2fs`. If it returns `tmpfs` or anything else, the
  host is on cgroup v1 — `install-wp-slice.sh` will abort with a clear error.

- `systemctl` (systemd 240+). Slice support is stable since systemd 244.

## Install

    chmod +x host/install-wp-slice.sh
    sudo host/install-wp-slice.sh

This script:

1. Verifies cgroup v2 (`stat -fc %T /sys/fs/cgroup/` == `cgroup2fs`). Aborts
   if not.
2. Copies `wp.slice` → `/etc/systemd/system/wp.slice` (root:root, 0644).
3. `systemctl daemon-reload`.
4. `systemctl start wp.slice`.
5. Verifies `/sys/fs/cgroup/wp.slice/memory.max` == `4294967296` (4 GiB). If
   the actual value differs the script aborts and prints what it saw.

## Verify after install

    systemctl status wp.slice
    cat /sys/fs/cgroup/wp.slice/memory.max    # → 4294967296

## Memory model contract (read before Phase 2)

The slice is the **ONLY** memory ceiling for per-site containers. Phase 2's
`wp-create` MUST:

- Pass `--cgroup-parent=wp.slice` to every per-site `docker run` /
  `docker compose up`.
- NOT set `mem_limit` or `--memory` on per-site services. Compose validation
  in Phase 2 must reject any per-site definition that does (also reject
  `deploy.resources.limits.memory` and the `--memory=` CLI flag).

`wp-mariadb` and `wp-redis` (in `compose/compose.yaml`) are **NOT** in this
slice — they run with their own `mem_limit` (1 GB and 320 MB respectively).
The slice covers only `wp-<site>` containers.

## Coexistence with AudioStoryV2

AudioStoryV2's containers MUST NOT be moved into `wp.slice`. They live in
their own default cgroup. The 4 GB cap on `wp.slice` is precisely what
protects AudioStoryV2 from a runaway WP plugin (PITFALLS §5.2).

## Uninstall

    sudo systemctl stop wp.slice
    sudo rm /etc/systemd/system/wp.slice
    sudo systemctl daemon-reload

## Files

- `wp.slice` — systemd Slice unit (`MemoryMax=4G`, `MemoryHigh=3.5G`,
  `CPUWeight=100`).
- `install-wp-slice.sh` — verifies cgroup v2 and installs the unit.
