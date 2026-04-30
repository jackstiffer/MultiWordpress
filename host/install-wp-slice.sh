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
echo "wp.slice installed; MemoryMax=4G; CPUWeight=100"
echo "Phase 2's per-site containers must run with --cgroup-parent=wp.slice"
echo "and MUST NOT set mem_limit / --memory."
