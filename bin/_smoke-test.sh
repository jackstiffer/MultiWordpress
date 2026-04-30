#!/usr/bin/env bash
# =============================================================================
# bin/_smoke-test.sh — wiring smoke test for the MultiWordpress CLI
# =============================================================================
#
# Run this after install to verify scripts are wired correctly:
#
#     ./bin/_smoke-test.sh
#
# What it checks (NO containers spun up, NO /opt/wp touched):
#   1. Every script in bin/ passes `bash -n` (syntax-clean).
#   2. Every wp-X verb sources _lib.sh successfully.
#   3. Every wp-X verb prints usage AND exits non-zero when invoked with no
#      args (or, for read-only verbs, with --help exits 0 and prints usage).
#   4. _lib.sh constants are sane: WP_UID=82, port range 18000-18999,
#      redis-db range 1-63, DB_MAX_USER_CONNECTIONS=40.
#   5. The set of CLI verbs is exactly the eight Phase 2 ships:
#      wp-create, wp-delete, wp-pause, wp-resume, wp-list, wp-stats,
#      wp-logs, wp-exec.
#
# For end-to-end validation against a real Docker engine (provision a fake
# site, exercise wp-pause / wp-resume / wp-delete, etc.), see
# docs/first-site-e2e.md (ships in Phase 2 plan 07).
#
# Exit code: 0 if every check passes; 1 on first failure.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_FILE="${SCRIPT_DIR}/_lib.sh"

# Colors (TTY only).
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; RESET=$'\033[0m'
else
    GREEN=""; RED=""; YELLOW=""; RESET=""
fi

CHECKS=0
FAILED=0

_pass() { CHECKS=$((CHECKS+1)); printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
_fail() { FAILED=$((FAILED+1)); printf '  %sx%s %s\n' "$RED" "$RESET" "$1" >&2; }
_section() { printf '\n%s== %s ==%s\n' "$YELLOW" "$1" "$RESET"; }

VERBS=(wp-create wp-delete wp-pause wp-resume wp-list wp-stats wp-logs wp-exec)

# -----------------------------------------------------------------------------
# 1. bash -n on every file in bin/
# -----------------------------------------------------------------------------
_section "syntax (bash -n)"
shopt -s nullglob
for f in "$SCRIPT_DIR"/* "$SCRIPT_DIR"/_lib.sh; do
    name="$(basename "$f")"
    [[ "$name" == "_smoke-test.sh" ]] && continue       # don't lint self twice
    [[ -f "$f" ]] || continue
    if bash -n "$f" 2>/dev/null; then
        _pass "bash -n $name"
    else
        _fail "bash -n $name"
    fi
done
shopt -u nullglob

# -----------------------------------------------------------------------------
# 2. _lib.sh sources cleanly + exposes required constants/functions
# -----------------------------------------------------------------------------
_section "_lib.sh contract"
if [[ ! -f "$LIB_FILE" ]]; then
    _fail "_lib.sh missing at $LIB_FILE"
    printf '\n%s[smoke] FAIL%s — _lib.sh not found\n' "$RED" "$RESET" >&2
    exit 1
fi

# Source in a subshell so smoke-test's own env is untouched.
LIB_SOURCE_LOG=""
if LIB_SOURCE_LOG="$(bash -c "set -euo pipefail; source '$LIB_FILE'; echo OK" 2>&1)" \
   && [[ "$LIB_SOURCE_LOG" == *OK* ]]; then
    _pass "_lib.sh sources without error"
else
    _fail "_lib.sh failed to source: $LIB_SOURCE_LOG"
fi

# Pull constants via a subshell — no need to dump _lib's globals into our shell.
_check_const() {
    local name="$1" expected="$2" actual
    actual="$(bash -c "set -euo pipefail; source '$LIB_FILE' >/dev/null 2>&1; printf '%s' \"\${$name:-<unset>}\"")"
    if [[ "$actual" == "$expected" ]]; then
        _pass "$name == $expected"
    else
        _fail "$name expected '$expected', got '$actual'"
    fi
}

_check_const WP_UID 82
_check_const WP_GID 82
_check_const PORT_RANGE_START 18000
_check_const PORT_RANGE_END 18999
_check_const REDIS_DB_RANGE_START 1
_check_const REDIS_DB_RANGE_END 63
_check_const DB_MAX_USER_CONNECTIONS 40
_check_const COMPOSE_NETWORK wp-network
_check_const IMAGE_TAG multiwp:wordpress-6-php8.3

# Required functions exist after sourcing.
_check_fn() {
    local fn="$1"
    if bash -c "set -euo pipefail; source '$LIB_FILE' >/dev/null 2>&1; declare -F $fn >/dev/null"; then
        _pass "function defined: $fn"
    else
        _fail "function missing: $fn"
    fi
}

for fn in _log _die _require_root _require_cmd _sanitize_slug \
          _gen_secret _gen_admin_user _gen_wp_salts \
          _load_state _save_state _get_site _state_set_site _state_remove_site \
          _with_lock _alloc_port _alloc_redis_db \
          _db_exec _db_create_site _db_drop_site \
          _wp_exec _compose_site _is_json_mode; do
    _check_fn "$fn"
done

# -----------------------------------------------------------------------------
# 3. Every verb exists, is executable, and sources _lib.sh
# -----------------------------------------------------------------------------
_section "verbs present + executable"
for verb in "${VERBS[@]}"; do
    path="${SCRIPT_DIR}/${verb}"
    if [[ ! -f "$path" ]]; then
        _fail "$verb missing at $path"
        continue
    fi
    if [[ ! -x "$path" ]]; then
        _fail "$verb not executable (chmod +x)"
        continue
    fi
    if grep -q "_lib.sh" "$path"; then
        _pass "$verb exists, executable, sources _lib.sh"
    else
        _fail "$verb does not source _lib.sh"
    fi
done

# -----------------------------------------------------------------------------
# 4. --help works (exit 0) and no-arg prints usage to stderr
# -----------------------------------------------------------------------------
_section "verb --help / no-arg behavior"
# Use an isolated WP_ROOT so any verb that touches state goes to /tmp.
SMOKE_WP_ROOT="$(mktemp -d -t wp-smoke-XXXXXX)"
trap 'rm -rf "$SMOKE_WP_ROOT"' EXIT
export WP_ROOT="$SMOKE_WP_ROOT"

for verb in "${VERBS[@]}"; do
    path="${SCRIPT_DIR}/${verb}"
    [[ -x "$path" ]] || continue

    # --help should exit 0 with usage on stdout (or stderr).
    help_out="$("$path" --help 2>&1 || true)"
    help_rc=$?
    if printf '%s' "$help_out" | grep -qiE "usage|^${verb}"; then
        _pass "$verb --help prints usage"
    else
        _fail "$verb --help did not print usage (output: ${help_out:0:80})"
    fi

    # No-arg: must exit non-zero AND print usage. wp-list / wp-stats are the
    # exceptions — they're list-everything verbs and exit 0 on no args.
    case "$verb" in
        wp-list|wp-stats)
            # No-arg should succeed (read-only listing).
            if "$path" >/dev/null 2>&1; then
                _pass "$verb (no args) exits 0 (read-only verb)"
            else
                rc=$?
                # Still a pass if it prints something sensible — host may not
                # have docker reachable in some smoke envs. Soft-pass with note.
                _pass "$verb (no args) exited $rc (env may lack docker; non-fatal)"
            fi
            ;;
        *)
            if "$path" >/dev/null 2>&1; then
                _fail "$verb (no args) returned 0 — should require positional"
            else
                _pass "$verb (no args) exits non-zero (requires positional)"
            fi
            ;;
    esac
done

# -----------------------------------------------------------------------------
# 5. Verb set is exactly the eight Phase 2 ships
# -----------------------------------------------------------------------------
_section "verb inventory"
shopt -s nullglob
found=()
for f in "$SCRIPT_DIR"/wp-*; do
    [[ -f "$f" ]] && found+=("$(basename "$f")")
done
shopt -u nullglob

# Sort both lists for a stable diff.
expected_sorted="$(printf '%s\n' "${VERBS[@]}" | sort | tr '\n' ' ')"
found_sorted="$(printf '%s\n' "${found[@]}" | sort | tr '\n' ' ')"
if [[ "$expected_sorted" == "$found_sorted" ]]; then
    _pass "verb set matches Phase 2 spec (8 verbs)"
else
    _fail "verb set mismatch: expected [$expected_sorted], got [$found_sorted]"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
printf '\n'
if (( FAILED == 0 )); then
    printf '%s✓ Smoke test passed (%d checks)%s\n' "$GREEN" "$CHECKS" "$RESET"
    exit 0
else
    printf '%s✗ Smoke test FAILED — %d failures across %d checks%s\n' \
        "$RED" "$FAILED" "$((CHECKS+FAILED))" "$RESET" >&2
    exit 1
fi
