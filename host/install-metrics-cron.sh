#!/usr/bin/env bash
# =============================================================================
# host/install-metrics-cron.sh — install /etc/cron.d/multiwordpress.
# =============================================================================
#
# Installs (or refreshes) the cron file that drives:
#   1. wp-metrics-poll  — every minute
#   2. per-site staggered wp-cron lines (added by wp-create / removed by
#      wp-delete via bin/_cron-mgr.sh)
#
# Idempotent: re-running replaces ONLY the metrics-poll line and the file
# header. Per-site stagger lines added by wp-create are preserved.
#
# Requirements: PERF-03 (cron file shape), PERF-04 (metrics poll cron)
# =============================================================================
set -euo pipefail

CRON_FILE="${CRON_FILE:-/etc/cron.d/multiwordpress}"
WP_BIN_DIR="${WP_BIN_DIR:-/opt/wp/bin}"
METRICS_POLL_BIN="${WP_BIN_DIR}/wp-metrics-poll"

_die() { echo "ERROR: $*" >&2; exit 1; }

# ---- Pre-flight -----------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
    _die "must run as root (try: sudo $0)"
fi

command -v jq >/dev/null 2>&1 || _die "jq required (apt install jq)"

# Cron service: try `cron` (Debian/Ubuntu) then `crond` (RHEL/Alpine).
cron_active=0
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet cron 2>/dev/null; then cron_active=1; fi
    if systemctl is-active --quiet crond 2>/dev/null; then cron_active=1; fi
fi
if (( cron_active == 0 )); then
    echo "WARNING: cron/crond service does not appear active." >&2
    echo "  On Debian/Ubuntu: sudo systemctl enable --now cron" >&2
    echo "  On RHEL/Alpine:   sudo systemctl enable --now crond" >&2
    echo "  Continuing anyway — file installation does not require cron to be running." >&2
fi

# Verify wp-metrics-poll exists at expected install path.
if [[ ! -x "$METRICS_POLL_BIN" ]]; then
    echo "WARNING: $METRICS_POLL_BIN not found or not executable." >&2
    echo "  Expected install path is /opt/wp/bin/wp-metrics-poll." >&2
    echo "  If you're running from the source tree, deploy bin/wp-metrics-poll first." >&2
fi

# ---- Build new cron file content -------------------------------------------
# Header + metrics-poll line. Per-site stagger lines (if any) are preserved
# from the existing file.
HEADER_TMP="$(mktemp)"
cat >"$HEADER_TMP" <<EOF
# MultiWordpress cron entries — managed by /opt/wp/bin/_cron-mgr.sh + host/install-metrics-cron.sh
# DO NOT EDIT MANUALLY — wp-create/wp-delete update per-site lines.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Metrics poll — every minute
* * * * * root ${METRICS_POLL_BIN} >/dev/null 2>&1
EOF

# Extract any existing per-site stagger lines (lines matching
# `<minute> * * * * root docker exec -u www-data wp-<slug> ...`) so we don't
# clobber them on re-run.
SITE_LINES_TMP="$(mktemp)"
if [[ -f "$CRON_FILE" ]]; then
    grep -E '^[0-9]+ \* \* \* \* root docker exec -u www-data wp-' "$CRON_FILE" \
        > "$SITE_LINES_TMP" || true
fi

NEW_TMP="$(mktemp)"
cat "$HEADER_TMP" > "$NEW_TMP"
if [[ -s "$SITE_LINES_TMP" ]]; then
    printf '\n# Per-site wp-cron stagger lines — managed by bin/_cron-mgr.sh\n' >> "$NEW_TMP"
    cat "$SITE_LINES_TMP" >> "$NEW_TMP"
fi

# Cron requires non-executable mode 644 on /etc/cron.d files.
chmod 644 "$NEW_TMP"
mv "$NEW_TMP" "$CRON_FILE"
rm -f "$HEADER_TMP" "$SITE_LINES_TMP"

# ---- Done — print summary --------------------------------------------------
echo
echo "OK: installed $CRON_FILE"
echo "    mode: 644 (cron requires non-executable)"
echo "    metrics-poll bin: $METRICS_POLL_BIN"
echo
echo "Verify:"
echo "  cat $CRON_FILE"
echo "  tail -f /var/log/syslog | grep CRON     # Debian/Ubuntu"
echo "  cat /opt/wp/state/metrics.json | jq '.cluster'"
echo
echo "After ~1 minute:"
echo "  jq '.cluster.pool_used_bytes' /opt/wp/state/metrics.json   # should be > 0"
echo
echo "After 24h+ runtime:"
echo "  jq '.sites' /opt/wp/state/metrics.json                     # peaks populated"
