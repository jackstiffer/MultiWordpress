# shellcheck shell=bash
# =============================================================================
# bin/_cron-mgr.sh — host wp-cron stagger registration helpers.
# =============================================================================
#
# Sourced by bin/wp-create and bin/wp-delete. NOT meant to be executed.
#
# Functions:
#   _cron_register   <slug>   — append/replace a stagger line in
#                               /etc/cron.d/multiwordpress.
#   _cron_unregister <slug>   — remove the stagger line for <slug>.
#
# Stagger algorithm (LOCKED, not discretionary):
#   minute = (first 8 hex chars of sha256(slug)) mod 60
# Deterministic; spreads load across the hour.
#
# Cron line format:
#   <minute> * * * * root docker exec -u www-data wp-<slug> wp cron event run --due-now >/dev/null 2>&1
#
# Concurrency: flock on /var/lock/multiwordpress-cron.lock — wp-create and
# wp-delete may otherwise race when run in parallel.
#
# Phase: 03 (PERF-03)
# =============================================================================

CRON_FILE="${CRON_FILE:-/etc/cron.d/multiwordpress}"
CRON_LOCK="${CRON_LOCK:-/var/lock/multiwordpress-cron.lock}"

# -----------------------------------------------------------------------------
# Compute stagger minute for a slug. Deterministic.
# Algorithm: first 8 hex chars of sha256(slug), hex → decimal, mod 60.
# -----------------------------------------------------------------------------
_cron_stagger_minute() {
    local slug="${1:?_cron_stagger_minute: slug required}"
    local hex8 dec
    hex8="$(printf '%s' "$slug" | sha256sum | tr -d ' -' | head -c 8)"
    # Convert hex → decimal via printf (bash). 8 hex chars fit in 32 bits.
    dec="$(printf '%d' "0x${hex8}")"
    printf '%d' $(( dec % 60 ))
}

# -----------------------------------------------------------------------------
# Internal — ensure cron file exists with header. No-op if already present.
# -----------------------------------------------------------------------------
_cron_ensure_file() {
    if [[ ! -f "$CRON_FILE" ]]; then
        local tmp="${CRON_FILE}.tmp.$$"
        cat >"$tmp" <<'EOF'
# MultiWordpress cron entries — managed by /opt/wp/bin/_cron-mgr.sh + host/install-metrics-cron.sh
# DO NOT EDIT MANUALLY — wp-create/wp-delete update per-site lines.
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

EOF
        chmod 644 "$tmp"
        mv "$tmp" "$CRON_FILE"
    fi
}

# -----------------------------------------------------------------------------
# Internal — ensure lock file exists.
# -----------------------------------------------------------------------------
_cron_ensure_lock() {
    if [[ ! -e "$CRON_LOCK" ]]; then
        : > "$CRON_LOCK" 2>/dev/null || true
        chmod 644 "$CRON_LOCK" 2>/dev/null || true
    fi
}

# -----------------------------------------------------------------------------
# _cron_register <slug>
# Idempotent: replaces any existing line for `wp-<slug>` rather than dup'ing.
# Preserves all other lines (metrics-poll, other sites' stagger lines).
# -----------------------------------------------------------------------------
_cron_register() {
    local slug="${1:?_cron_register: slug required}"
    _cron_ensure_lock
    (
        exec 202>"$CRON_LOCK"
        flock -x 202 || { _log warn "_cron_register: could not acquire $CRON_LOCK"; exit 1; }

        _cron_ensure_file
        local minute line tmp marker
        minute="$(_cron_stagger_minute "$slug")"
        line="${minute} * * * * root docker exec -u www-data wp-${slug} wp cron event run --due-now >/dev/null 2>&1"
        marker="docker exec -u www-data wp-${slug} "
        tmp="${CRON_FILE}.tmp.$$"

        # Filter out any prior line for this slug (match the exact "wp-<slug> "
        # token to avoid matching "wp-foo" when the slug is "foo_bar"). Then
        # append the new line.
        grep -vF "$marker" "$CRON_FILE" > "$tmp" || true
        printf '%s\n' "$line" >> "$tmp"
        chmod 644 "$tmp"
        mv "$tmp" "$CRON_FILE"
    )
}

# -----------------------------------------------------------------------------
# _cron_unregister <slug>
# Idempotent: succeeds even if the line is already absent.
# Preserves all other lines.
# -----------------------------------------------------------------------------
_cron_unregister() {
    local slug="${1:?_cron_unregister: slug required}"
    _cron_ensure_lock
    (
        exec 202>"$CRON_LOCK"
        flock -x 202 || { _log warn "_cron_unregister: could not acquire $CRON_LOCK"; exit 1; }

        [[ -f "$CRON_FILE" ]] || exit 0

        local marker tmp
        marker="docker exec -u www-data wp-${slug} "
        tmp="${CRON_FILE}.tmp.$$"
        grep -vF "$marker" "$CRON_FILE" > "$tmp" || true
        chmod 644 "$tmp"
        mv "$tmp" "$CRON_FILE"
    )
}

# =============================================================================
# End of bin/_cron-mgr.sh
# =============================================================================
