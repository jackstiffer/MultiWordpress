# shellcheck shell=bash
# =============================================================================
# bin/_lib.sh — MultiWordpress shared CLI library (v1.0)
# =============================================================================
#
# Sourced by every wp-X verb (wp-create, wp-delete, wp-pause, wp-resume,
# wp-list, wp-stats, wp-logs, wp-exec). NOT meant to be executed directly.
#
# Usage:
#   #!/usr/bin/env bash
#   set -euo pipefail
#   source "$(dirname "$0")/_lib.sh"
#
# Plan:    .planning/phases/02-cli-core-first-site-e2e/02-PLAN-01-shared-lib.md
# Context: .planning/phases/02-cli-core-first-site-e2e/02-CONTEXT.md
#
# Conventions:
#   - No top-level `set -euo pipefail` (caller decides).
#   - Logs to STDERR; user-facing data (creds, JSON, snippets) to STDOUT.
#   - All paths absolute. WP_ROOT overridable via env (default /opt/wp).
#   - State mutations atomic via temp + rename. Allocators serialized via flock.
#   - UID 82 (Alpine www-data) — NOT 33 (Debian). See Phase 1 deviation.
# =============================================================================

# -----------------------------------------------------------------------------
# Constants (overridable via environment for testing)
# -----------------------------------------------------------------------------
WP_ROOT="${WP_ROOT:-/opt/wp}"
STATE_DIR="${WP_ROOT}/state"
STATE_FILE="${STATE_DIR}/sites.json"
ALLOCATOR_LOCK="${STATE_DIR}/allocator.lock"
LOCK_FILE="${ALLOCATOR_LOCK}"   # alias for back-compat with plan task 2
METRICS_FILE="${STATE_DIR}/metrics.json"
SECRETS_DIR="${WP_ROOT}/secrets"
SITES_DIR="${WP_ROOT}/sites"

WP_UID=82                       # Alpine www-data — Phase 1 deviation
WP_GID=82

PORT_RANGE_START=18000
PORT_RANGE_END=18999
REDIS_DB_RANGE_START=1
REDIS_DB_RANGE_END=63
DB_MAX_USER_CONNECTIONS=40

DB_HOST_INTERNAL="wp-mariadb"
REDIS_HOST_INTERNAL="wp-redis"
IMAGE_TAG="multiwp:wordpress-6-php8.3"
COMPOSE_NETWORK="wp-network"

# Reserved slugs — refuse for site naming
_RESERVED_SLUGS=("mariadb" "redis" "network")

# JSON output mode flag — caller flips to 1 when --json passed
_JSON_MODE=0

# -----------------------------------------------------------------------------
# Color helpers
# -----------------------------------------------------------------------------
_color_supported() {
    [[ -t 2 && -z "${NO_COLOR:-}" ]]
}

_color_init() {
    if _color_supported; then
        RED=$'\033[0;31m'
        YELLOW=$'\033[0;33m'
        GREEN=$'\033[0;32m'
        RESET=$'\033[0m'
    else
        RED=""
        YELLOW=""
        GREEN=""
        RESET=""
    fi
}
_color_init

# -----------------------------------------------------------------------------
# Logging — _log <level> <msg>; _die <msg>
# -----------------------------------------------------------------------------
_log() {
    local level="${1:-info}"
    shift || true
    local msg="$*"
    local ts color
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    case "$level" in
        info)  color="$GREEN"  ;;
        warn)  color="$YELLOW" ;;
        error) color="$RED"    ;;
        *)     color=""        ;;
    esac
    printf '%s[%s] [%s]%s %s\n' "$color" "$ts" "${level^^}" "$RESET" "$msg" >&2
}

_die() {
    _log error "$*"
    exit 1
}

# -----------------------------------------------------------------------------
# Reach guard — most verbs require root for state mutations.
# Read-only callers can skip by exporting READ_ONLY=1 before sourcing.
# This is a function callers invoke explicitly; not enforced at source-time.
# -----------------------------------------------------------------------------
_require_root() {
    if [[ "${READ_ONLY:-0}" == "1" ]]; then
        return 0
    fi
    [[ "${EUID:-$(id -u)}" -eq 0 ]] || _die "must run as root (re-run with sudo)"
}

_require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || _die "required command not found: $cmd"
}

# -----------------------------------------------------------------------------
# Slug sanitization — _sanitize_slug <domain>
# Lowercase, '.'/'-' -> '_', strip non-[a-z0-9_], cap 32, refuse reserved/empty.
# -----------------------------------------------------------------------------
_sanitize_slug() {
    local input="${1:-}"
    [[ -n "$input" ]] || { _log error "_sanitize_slug: empty input"; return 1; }

    local s
    s="$(printf '%s' "$input" | tr '[:upper:]' '[:lower:]')"
    s="${s//./_}"
    s="${s//-/_}"
    s="$(printf '%s' "$s" | tr -cd 'a-z0-9_')"

    if [[ -z "$s" ]]; then
        _log error "_sanitize_slug: '$input' sanitizes to empty"
        return 1
    fi

    if (( ${#s} > 32 )); then
        _log warn "_sanitize_slug: '$s' exceeds 32 chars; truncating"
        s="${s:0:32}"
    fi

    local reserved
    for reserved in "${_RESERVED_SLUGS[@]}"; do
        if [[ "$s" == "$reserved" ]]; then
            _log error "_sanitize_slug: '$s' is reserved (mariadb/redis/network)"
            return 1
        fi
    done

    printf '%s\n' "$s"
}

# -----------------------------------------------------------------------------
# Secret generators
# -----------------------------------------------------------------------------
_gen_secret() {
    local len="${1:-32}"
    [[ "$len" =~ ^[0-9]+$ ]] || { _log error "_gen_secret: bad length: $len"; return 1; }
    # Pull plenty of entropy then truncate to alnum of requested length.
    local bytes=$(( len * 2 + 16 ))
    openssl rand -base64 "$bytes" 2>/dev/null \
        | tr -dc 'A-Za-z0-9' \
        | head -c "$len"
    printf '\n'
}

_gen_admin_user() {
    printf 'admin_%s\n' "$(openssl rand -hex 4)"
}

# Emit one 64-char salt suitable for WordPress AUTH_KEY etc.
_gen_wp_salt() {
    openssl rand -base64 96 | tr -d '\n=+/' | head -c 64
    printf '\n'
}

# Emit all 8 WP salts as KEY=value lines (caller can append to .env).
_gen_wp_salts() {
    local k
    for k in WP_AUTH_KEY WP_SECURE_AUTH_KEY WP_LOGGED_IN_KEY WP_NONCE_KEY \
             WP_AUTH_SALT WP_SECURE_AUTH_SALT WP_LOGGED_IN_SALT WP_NONCE_SALT; do
        printf '%s=%s\n' "$k" "$(_gen_wp_salt)"
    done
}

# -----------------------------------------------------------------------------
# State I/O — atomic via temp + rename. All callers must use these helpers.
# -----------------------------------------------------------------------------
_state_skeleton() {
    printf '%s' '{"version":1,"next_port":18000,"next_redis_db":1,"sites":{}}'
}

_init_state() {
    if [[ ! -d "$STATE_DIR" ]]; then
        mkdir -p "$STATE_DIR" || _die "cannot create $STATE_DIR"
    fi
    if [[ ! -f "$STATE_FILE" ]]; then
        local tmp="${STATE_FILE}.tmp.$$"
        _state_skeleton > "$tmp" || _die "cannot write $tmp"
        chmod 644 "$tmp"
        mv "$tmp" "$STATE_FILE" || _die "cannot rename $tmp -> $STATE_FILE"
        _log info "initialized state file: $STATE_FILE"
    fi
}

_load_state() {
    if [[ -f "$STATE_FILE" ]]; then
        cat "$STATE_FILE"
    else
        _state_skeleton
    fi
}

_save_state() {
    local json="${1:-}"
    [[ -n "$json" ]] || { _log error "_save_state: empty input"; return 1; }
    [[ -d "$STATE_DIR" ]] || mkdir -p "$STATE_DIR"
    # Validate JSON before persisting.
    if ! printf '%s' "$json" | jq -e . >/dev/null 2>&1; then
        _log error "_save_state: refusing to write invalid JSON"
        return 1
    fi
    local tmp="${STATE_FILE}.tmp.$$"
    printf '%s\n' "$json" > "$tmp" || { _log error "_save_state: write failed"; return 1; }
    chmod 644 "$tmp"
    mv "$tmp" "$STATE_FILE" || { _log error "_save_state: rename failed"; rm -f "$tmp"; return 1; }
}

_state_get() {
    local filter="${1:-.}"
    _load_state | jq -r "$filter"
}

_get_site() {
    local slug="${1:?_get_site: slug required}"
    _load_state | jq -r --arg s "$slug" '.sites[$s] // empty'
}

# Merge a JSON fragment into .sites[slug]. Creates entry if missing.
_state_set_site() {
    local slug="${1:?_state_set_site: slug required}"
    local fragment="${2:?_state_set_site: fragment required}"
    local cur new
    cur="$(_load_state)"
    new="$(printf '%s' "$cur" | jq --arg s "$slug" --argjson frag "$fragment" \
        '.sites[$s] = ((.sites[$s] // {}) + $frag)')" \
        || { _log error "_state_set_site: jq merge failed"; return 1; }
    _save_state "$new"
}

# Alias matching plan task 2 spec.
_set_site() { _state_set_site "$@"; }

_state_remove_site() {
    local slug="${1:?_state_remove_site: slug required}"
    local cur new
    cur="$(_load_state)"
    new="$(printf '%s' "$cur" | jq --arg s "$slug" 'del(.sites[$s])')" \
        || { _log error "_state_remove_site: jq del failed"; return 1; }
    _save_state "$new"
}

_delete_site() { _state_remove_site "$@"; }

# -----------------------------------------------------------------------------
# Locking — flock on ALLOCATOR_LOCK, FD 200.
# -----------------------------------------------------------------------------
_ensure_lock_file() {
    [[ -d "$STATE_DIR" ]] || mkdir -p "$STATE_DIR"
    if [[ ! -f "$ALLOCATOR_LOCK" ]]; then
        : > "$ALLOCATOR_LOCK" || _die "cannot create lock file: $ALLOCATOR_LOCK"
        chmod 644 "$ALLOCATOR_LOCK" || true
    fi
}

# Run a function (with optional args) under an exclusive flock on FD 200.
_with_lock() {
    local fn="${1:?_with_lock: function name required}"
    shift
    _ensure_lock_file
    (
        exec 200>"$ALLOCATOR_LOCK"
        flock -x 200 || _die "_with_lock: failed to acquire $ALLOCATOR_LOCK"
        "$fn" "$@"
    )
}

# Manual acquire/release for callers that prefer explicit lifecycle.
_acquire_lock() {
    _ensure_lock_file
    exec 200>"$ALLOCATOR_LOCK"
    flock -x 200 || _die "_acquire_lock: failed on $ALLOCATOR_LOCK"
    trap '_release_lock' EXIT
}

_release_lock() {
    flock -u 200 2>/dev/null || true
    exec 200>&- 2>/dev/null || true
    trap - EXIT
}

# -----------------------------------------------------------------------------
# Allocators — must run inside _with_lock.
# Algorithm: find smallest unused integer in range. _die on exhaustion.
# -----------------------------------------------------------------------------
_alloc_port() {
    local used candidate
    used="$(_load_state | jq -r '.sites | to_entries | .[].value.port // empty' | sort -n | uniq)"
    for (( candidate=PORT_RANGE_START; candidate<=PORT_RANGE_END; candidate++ )); do
        if ! grep -qx "$candidate" <<<"$used"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    _die "_alloc_port: range $PORT_RANGE_START-$PORT_RANGE_END exhausted"
}

_alloc_redis_db() {
    local used candidate
    used="$(_load_state | jq -r '.sites | to_entries | .[].value.redis_db // empty' | sort -n | uniq)"
    for (( candidate=REDIS_DB_RANGE_START; candidate<=REDIS_DB_RANGE_END; candidate++ )); do
        if ! grep -qx "$candidate" <<<"$used"; then
            if (( candidate >= 12 )); then
                _log warn "_alloc_redis_db: returning $candidate; bump 'databases 64' in redis.conf if not done"
            fi
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    _die "_alloc_redis_db: range $REDIS_DB_RANGE_START-$REDIS_DB_RANGE_END exhausted"
}

# -----------------------------------------------------------------------------
# DB exec helpers — talk to wp-mariadb container as root.
# -----------------------------------------------------------------------------
_db_root_password() {
    if [[ -n "${MARIADB_ROOT_PASSWORD:-}" ]]; then
        printf '%s' "$MARIADB_ROOT_PASSWORD"
        return 0
    fi
    local env_file
    for env_file in "$WP_ROOT/.env" "$(dirname "${BASH_SOURCE[0]}")/../compose/.env" "compose/.env"; do
        if [[ -f "$env_file" ]]; then
            local pw
            pw="$(grep -E '^MARIADB_ROOT_PASSWORD=' "$env_file" | head -n1 | cut -d= -f2-)"
            # Strip optional surrounding quotes.
            pw="${pw%\"}"; pw="${pw#\"}"
            pw="${pw%\'}"; pw="${pw#\'}"
            if [[ -n "$pw" ]]; then
                printf '%s' "$pw"
                return 0
            fi
        fi
    done
    _die "_db_root_password: MARIADB_ROOT_PASSWORD not in env or compose/.env"
}

_db_exec() {
    local sql="${1:?_db_exec: sql required}"
    local pw
    pw="$(_db_root_password)"
    docker exec -i wp-mariadb mariadb -uroot -p"$pw" -e "$sql"
}

_db_create_site() {
    local slug="${1:?_db_create_site: slug required}"
    local password="${2:?_db_create_site: password required}"
    local db="wp_${slug}"
    local user="wp_${slug}"

    _db_exec "
        CREATE DATABASE IF NOT EXISTS \`${db}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
        CREATE USER IF NOT EXISTS '${user}'@'%' IDENTIFIED BY '${password}';
        ALTER USER '${user}'@'%' IDENTIFIED BY '${password}' WITH MAX_USER_CONNECTIONS ${DB_MAX_USER_CONNECTIONS};
        GRANT ALL PRIVILEGES ON \`${db}\`.* TO '${user}'@'%';
        FLUSH PRIVILEGES;
    " || _die "_db_create_site: SQL failed for $slug"

    # Verify GRANT scope: only one DB granted.
    local grants db_count
    grants="$(_db_exec "SHOW GRANTS FOR '${user}'@'%';" 2>&1)"
    db_count="$(printf '%s\n' "$grants" | grep -c "ON \`${db}\`" || true)"
    if (( db_count < 1 )); then
        _die "_db_create_site: GRANT verification failed for ${user} (no grant on ${db})"
    fi
    # Ensure no grants reference databases other than ours or *.* (besides USAGE).
    if printf '%s\n' "$grants" | grep -E 'GRANT .* ON \*\.\*' | grep -qv 'USAGE ON \*\.\*'; then
        _die "_db_create_site: ${user} has wildcard privileges; aborting"
    fi
}

_db_drop_site() {
    local slug="${1:?_db_drop_site: slug required}"
    local db="wp_${slug}"
    local user="wp_${slug}"
    _db_exec "
        DROP USER IF EXISTS '${user}'@'%';
        DROP DATABASE IF EXISTS \`${db}\`;
        FLUSH PRIVILEGES;
    " || _log warn "_db_drop_site: SQL had errors (continuing)"
}

# -----------------------------------------------------------------------------
# Docker / WP-CLI / per-site compose wrappers
# -----------------------------------------------------------------------------
_wp_exec() {
    local slug="${1:?_wp_exec: slug required}"
    shift
    docker exec -u www-data "wp-${slug}" wp "$@"
}

_compose_site() {
    local slug="${1:?_compose_site: slug required}"
    shift
    local file="${SITES_DIR}/${slug}/compose.yaml"
    [[ -f "$file" ]] || _die "_compose_site: $file not found"
    docker compose -f "$file" "$@"
}

# -----------------------------------------------------------------------------
# JSON output helpers
# -----------------------------------------------------------------------------
_is_json_mode() {
    [[ "${_JSON_MODE:-0}" == "1" || "${JSON_OUTPUT:-0}" == "1" ]]
}

# _emit_json key=value [key=value ...] — emits a flat JSON object via jq.
_emit_json() {
    local args=() pair k v
    args+=(-n)
    local jq_expr='{}'
    local i=0
    for pair in "$@"; do
        k="${pair%%=*}"
        v="${pair#*=}"
        args+=(--arg "k${i}" "$k" --arg "v${i}" "$v")
        jq_expr="${jq_expr} | .[\$k${i}] = \$v${i}"
        i=$((i+1))
    done
    jq "${args[@]}" "$jq_expr"
}

# _emit_json_obj <jq-filter> — caller pipes JSON in, gets transformed output.
_emit_json_obj() {
    local filter="${1:-.}"
    jq "$filter"
}

# -----------------------------------------------------------------------------
# Trap helper — install ERR trap that calls a rollback function with $?.
# -----------------------------------------------------------------------------
_setup_rollback_trap() {
    local fn="${1:?_setup_rollback_trap: function name required}"
    # shellcheck disable=SC2064
    trap "${fn} \$?" ERR
}

# =============================================================================
# End of bin/_lib.sh
# =============================================================================
