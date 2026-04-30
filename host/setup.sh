#!/usr/bin/env bash
#
# MultiWordpress one-shot orchestrator.
#
# Walks an operator through everything needed to take a fresh GCP VM
# (Ubuntu 22.04+ or Debian 12+) from "just SSH'd in" to "wp-create works."
# Idempotent: detects what's already installed/configured and skips it,
# so re-running on a partially-set-up VM only does the missing pieces.
#
# Each step asks for confirmation (y/N) unless --yes is passed.
# Each step is independent — answering "n" skips just that step.
#
# Usage:
#   sudo bash host/setup.sh                 # interactive (recommended)
#   sudo bash host/setup.sh --yes           # non-interactive (CI / re-runs)
#   sudo bash host/setup.sh --check         # just survey state, change nothing
#

set -euo pipefail

# -----------------------------------------------------------------------------
# Constants and arg parsing
# -----------------------------------------------------------------------------
WP_ROOT="${WP_ROOT:-/opt/wp}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

ASSUME_YES=0
CHECK_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --yes|-y)   ASSUME_YES=1 ;;
        --check|-n) CHECK_ONLY=1 ;;
        --help|-h)
            sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "Unknown arg: $arg (use --help)" >&2
            exit 2 ;;
    esac
done

# -----------------------------------------------------------------------------
# Pretty output helpers
# -----------------------------------------------------------------------------
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; RESET=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; RESET=""
fi

step_banner() { printf '\n%s━━━ %s ━━━%s\n' "$BOLD$BLUE" "$1" "$RESET"; }
ok()    { printf '%s ✓%s %s\n' "$GREEN" "$RESET" "$1"; }
miss()  { printf '%s ◯%s %s\n' "$YELLOW" "$RESET" "$1"; }
warn()  { printf '%s ⚠%s %s\n' "$YELLOW" "$RESET" "$1" >&2; }
err()   { printf '%s ✗%s %s\n' "$RED" "$RESET" "$1" >&2; }
die()   { err "$1"; exit 1; }

confirm() {
    # confirm "<prompt>"  →  returns 0 (yes) or 1 (no)
    if [ "$ASSUME_YES" -eq 1 ]; then return 0; fi
    local ans
    read -r -p "  $1 [y/N] " ans </dev/tty
    [[ "$ans" =~ ^[Yy]$ ]]
}

# -----------------------------------------------------------------------------
# Preflight
# -----------------------------------------------------------------------------
step_banner "PREFLIGHT"

# Root
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "Must run as root: sudo bash host/setup.sh"
fi
ok "running as root"

# Distro detect
if [ ! -r /etc/os-release ]; then
    die "Cannot read /etc/os-release — unsupported OS"
fi
. /etc/os-release
case "$ID" in
    ubuntu) DOCKER_DISTRO=ubuntu ;;
    debian) DOCKER_DISTRO=debian ;;
    *)      die "Unsupported distro: $ID (only ubuntu/debian)" ;;
esac
ok "distro: $PRETTY_NAME (codename: $VERSION_CODENAME)"

# Cgroup v2 (required by wp.slice)
CGROUP_FS="$(stat -fc %T /sys/fs/cgroup/ 2>/dev/null || echo unknown)"
if [ "$CGROUP_FS" = "cgroup2fs" ]; then
    ok "cgroup v2 (required for wp.slice)"
else
    die "cgroup v2 NOT detected (got: $CGROUP_FS) — recreate VM with Ubuntu 22.04+ or Debian 12+"
fi

# Repo location: this script must run from the cloned repo
if [ ! -f "$REPO_ROOT/compose/compose.yaml" ]; then
    die "Repo not laid out correctly — expected $REPO_ROOT/compose/compose.yaml"
fi
ok "repo at $REPO_ROOT"

# /opt/wp expectation
if [ "$REPO_ROOT" != "$WP_ROOT" ]; then
    warn "repo is at $REPO_ROOT but CLI expects $WP_ROOT"
    warn "the CLI hardcodes /opt/wp paths — symlink or move the repo there"
fi

# -----------------------------------------------------------------------------
# Survey: what's installed/configured?
# -----------------------------------------------------------------------------
step_banner "SURVEY (current state)"

declare -A NEEDS

# Base packages
for pkg in curl jq openssl ca-certificates gnupg; do
    if command -v "$pkg" >/dev/null 2>&1 || dpkg -s "$pkg" >/dev/null 2>&1; then
        ok "$pkg installed"
    else
        miss "$pkg missing"
        NEEDS[base]=1
    fi
done

# Docker
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    DOCKER_VER="$(docker --version | awk '{print $3}' | tr -d ',')"
    ok "Docker installed ($DOCKER_VER)"
else
    miss "Docker missing or no compose plugin"
    NEEDS[docker]=1
fi

# Caddy intentionally NOT checked or managed here.
# Host Caddy is the operator's responsibility (shared with AudioStoryV2);
# this stack prints snippets to paste and never edits Caddyfile programmatically.

# .env / secrets
if [ -f "$WP_ROOT/.env" ] && grep -qE '^MARIADB_ROOT_PASSWORD=[^[:space:]]' "$WP_ROOT/.env" \
   && ! grep -qE '^MARIADB_ROOT_PASSWORD=replace-with-' "$WP_ROOT/.env"; then
    ok "secrets initialized at $WP_ROOT/.env"
else
    miss "secrets not initialized (no real MARIADB_ROOT_PASSWORD)"
    NEEDS[secrets]=1
fi

# wp.slice — check the file + the live cgroup directly. systemctl
# list-unit-files doesn't reliably show slice units that omit [Install].
if [ -f /etc/systemd/system/wp.slice ]; then
    SLICE_MAX="$(cat /sys/fs/cgroup/wp.slice/memory.max 2>/dev/null || true)"
    if [ "$SLICE_MAX" = "4294967296" ]; then
        ok "wp.slice installed and active (4 GB cap)"
    elif [ -n "$SLICE_MAX" ]; then
        miss "wp.slice unit installed but memory.max=$SLICE_MAX (expected 4294967296)"
        NEEDS[wp_slice]=1
    else
        miss "wp.slice unit file present but slice not active — try: sudo systemctl start wp.slice"
        NEEDS[wp_slice]=1
    fi
else
    miss "wp.slice not installed (no /etc/systemd/system/wp.slice)"
    NEEDS[wp_slice]=1
fi

# Shared infra (containers running)
INFRA_RUNNING=0
if docker ps --filter name=wp-mariadb --format '{{.Names}}' 2>/dev/null | grep -q '^wp-mariadb$' \
   && docker ps --filter name=wp-redis --format '{{.Names}}' 2>/dev/null | grep -q '^wp-redis$'; then
    ok "shared infra running (wp-mariadb + wp-redis)"
    INFRA_RUNNING=1
else
    miss "shared infra not running"
    NEEDS[infra]=1
fi

# DB password validation: if infra is running AND we have a real password,
# verify it actually works. Catches the trap where MariaDB seeded with one
# password but .env was rotated afterward (yields silent 'Access denied').
if [ "$INFRA_RUNNING" -eq 1 ] && [ -f "$WP_ROOT/.env" ] && \
   grep -qE '^MARIADB_ROOT_PASSWORD=[^[:space:]]' "$WP_ROOT/.env" && \
   ! grep -qE '^MARIADB_ROOT_PASSWORD=replace-with-' "$WP_ROOT/.env"; then
    ROOT_PW="$(grep ^MARIADB_ROOT_PASSWORD "$WP_ROOT/.env" | cut -d= -f2-)"
    if docker exec wp-mariadb mariadb -uroot -p"$ROOT_PW" -e "SELECT 1;" >/dev/null 2>&1; then
        ok "MariaDB root password matches /opt/wp/.env"
    else
        miss "MariaDB root password DOES NOT match /opt/wp/.env (volume seeded with stale password)"
        NEEDS[db_reset]=1
    fi
fi

# Per-site image
if docker images multiwp:wordpress-6-php8.3 --format '{{.ID}}' 2>/dev/null | grep -q .; then
    ok "per-site image multiwp:wordpress-6-php8.3 built"
else
    miss "per-site image not built"
    NEEDS[image]=1
fi

# Metrics cron
if [ -f /etc/cron.d/multiwordpress ] && grep -q wp-metrics-poll /etc/cron.d/multiwordpress; then
    ok "metrics-poll cron installed"
else
    miss "metrics-poll cron not installed"
    NEEDS[metrics_cron]=1
fi

# Dashboard (optional)
if docker ps --filter name=wp-dashboard --format '{{.Names}}' 2>/dev/null | grep -q '^wp-dashboard$'; then
    ok "dashboard running (optional)"
    DASHBOARD_RUNNING=1
else
    miss "dashboard not running (optional)"
    DASHBOARD_RUNNING=0
fi

# Wrappers for sudo PATH (NOT symlinks — symlinks break BASH_SOURCE-based
# _lib.sh resolution since dirname of the symlink path is /usr/local/bin)
if [ -f /usr/local/bin/wp-create ] && \
   ! [ -L /usr/local/bin/wp-create ] && \
   grep -q '/opt/wp/bin/wp-create' /usr/local/bin/wp-create 2>/dev/null; then
    ok "CLI wrappers installed in /usr/local/bin (sudo PATH friendly)"
elif [ -L /usr/local/bin/wp-create ]; then
    miss "CLI symlinks present (broken — must be replaced with wrappers)"
    NEEDS[wrappers]=1
else
    miss "CLI wrappers missing in /usr/local/bin"
    NEEDS[wrappers]=1
fi

# -----------------------------------------------------------------------------
# Done if --check
# -----------------------------------------------------------------------------
if [ "$CHECK_ONLY" -eq 1 ]; then
    step_banner "CHECK ONLY — no changes made"
    if [ ${#NEEDS[@]} -eq 0 ]; then
        ok "everything is configured"
    else
        warn "${#NEEDS[@]} item(s) missing — run again without --check to install"
    fi
    exit 0
fi

# -----------------------------------------------------------------------------
# Plan
# -----------------------------------------------------------------------------
step_banner "PLAN"
if [ ${#NEEDS[@]} -eq 0 ]; then
    ok "everything is already configured — running smoke test only"
else
    echo "  Missing items will be set up if you confirm each:"
    [ -n "${NEEDS[base]:-}" ]         && echo "    • install base packages (curl jq openssl etc.)"
    [ -n "${NEEDS[docker]:-}" ]       && echo "    • install Docker Engine + Compose plugin"
    [ -n "${NEEDS[secrets]:-}" ]      && echo "    • generate /opt/wp/.env (MARIADB_ROOT_PASSWORD)"
    [ -n "${NEEDS[wp_slice]:-}" ]     && echo "    • install host/wp.slice systemd unit (4 GB cap)"
    [ -n "${NEEDS[infra]:-}" ]        && echo "    • bring up shared infra (wp-mariadb + wp-redis)"
    [ -n "${NEEDS[db_reset]:-}" ]     && echo "    • RESET MariaDB volume (stale password) — wipes any existing site DBs!"
    [ -n "${NEEDS[image]:-}" ]        && echo "    • build per-site image multiwp:wordpress-6-php8.3"
    [ -n "${NEEDS[metrics_cron]:-}" ] && echo "    • install metrics-poll cron"
    [ -n "${NEEDS[wrappers]:-}" ]     && echo "    • install wrapper scripts in /usr/local/bin/wp-*"
    echo ""
    if [ "$ASSUME_YES" -eq 0 ]; then
        confirm "Proceed step-by-step?" || { echo "Aborted."; exit 0; }
    fi
fi

# -----------------------------------------------------------------------------
# Steps
# -----------------------------------------------------------------------------

if [ -n "${NEEDS[base]:-}" ]; then
    step_banner "Install base packages"
    if confirm "apt install curl jq openssl ca-certificates gnupg ?"; then
        apt update
        apt install -y curl jq openssl ca-certificates gnupg
        ok "base packages installed"
    else
        warn "skipped — later steps may fail"
    fi
fi

if [ -n "${NEEDS[docker]:-}" ]; then
    step_banner "Install Docker Engine"
    echo "  Will use the official Docker apt repo for $DOCKER_DISTRO ($VERSION_CODENAME)."
    if confirm "Install Docker?"; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" \
            -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_DISTRO} ${VERSION_CODENAME} stable" \
            > /etc/apt/sources.list.d/docker.list
        apt update
        apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        systemctl enable --now docker
        ok "Docker installed: $(docker --version)"
    else
        warn "skipped — most subsequent steps will fail without Docker"
    fi
fi

if [ -n "${NEEDS[secrets]:-}" ]; then
    step_banner "Generate shared-infra secrets"
    if confirm "Generate /opt/wp/.env with random MARIADB_ROOT_PASSWORD?"; then
        bash "$REPO_ROOT/host/init-secrets.sh"
    else
        warn "skipped — wp-create will fail without DB credentials"
    fi
fi

if [ -n "${NEEDS[wp_slice]:-}" ]; then
    step_banner "Install wp.slice systemd unit (4 GB cluster cap)"
    if confirm "Install /etc/systemd/system/wp.slice?"; then
        bash "$REPO_ROOT/host/install-wp-slice.sh"
    else
        warn "skipped — per-site containers will refuse to start without wp.slice"
    fi
fi

if [ -n "${NEEDS[infra]:-}" ]; then
    step_banner "Bring up shared infra (wp-mariadb + wp-redis)"
    if confirm "docker compose -f compose/compose.yaml up -d ?"; then
        cd "$REPO_ROOT"
        docker compose -f compose/compose.yaml up -d
        echo "  Waiting up to 30s for healthchecks..."
        for i in $(seq 1 30); do
            if docker ps --filter name=wp-mariadb --filter health=healthy --format '{{.Names}}' \
                | grep -q '^wp-mariadb$'; then
                ok "shared infra healthy"
                break
            fi
            sleep 1
            [ "$i" -eq 30 ] && warn "wp-mariadb did not become healthy within 30s — investigate with: docker compose logs"
        done
    else
        warn "skipped — wp-create needs wp-mariadb running"
    fi
fi

if [ -n "${NEEDS[db_reset]:-}" ]; then
    step_banner "Reset MariaDB volume (stale password)"
    err "MariaDB's data volume was seeded with a different password than /opt/wp/.env."
    echo "  Common cause: compose came up before init-secrets.sh ran, OR .env was"
    echo "  rotated after first boot. The data volume retains the OLD password."
    echo ""
    echo "  Resolution: stop infra, delete the wp_mariadb_data volume, restart."
    echo ""
    echo "  ${RED}WARNING:${RESET} this PERMANENTLY deletes all per-site DBs."
    echo "  Safe to do during initial setup (no real sites yet)."
    if confirm "Nuke wp_mariadb_data volume + restart infra?"; then
        cd "$REPO_ROOT"
        docker compose -f compose/compose.yaml down -v
        docker compose -f compose/compose.yaml up -d
        echo "  Waiting for healthcheck..."
        for i in $(seq 1 30); do
            if docker ps --filter name=wp-mariadb --filter health=healthy --format '{{.Names}}' \
                | grep -q '^wp-mariadb$'; then
                ok "MariaDB re-seeded with current /opt/wp/.env password"
                break
            fi
            sleep 1
            [ "$i" -eq 30 ] && warn "wp-mariadb did not become healthy within 30s"
        done

        # Also clean up any half-provisioned site state (sites.json + secrets/)
        if [ -f "$WP_ROOT/state/sites.json" ]; then
            stale_sites="$(jq -r '.sites | keys | length' "$WP_ROOT/state/sites.json" 2>/dev/null || echo 0)"
            if [ "${stale_sites:-0}" -gt 0 ]; then
                warn "sites.json had ${stale_sites} entries from before the reset — clearing"
                echo '{"version":1,"next_port":18000,"next_redis_db":1,"sites":{}}' \
                    > "$WP_ROOT/state/sites.json"
                rm -f "$WP_ROOT/secrets/"*.env 2>/dev/null || true
                ok "site registry + secrets cleared"
            fi
        fi
    else
        warn "skipped — wp-create will continue to fail with 'Access denied' until resolved"
    fi
fi

if [ -n "${NEEDS[image]:-}" ]; then
    step_banner "Build per-site image multiwp:wordpress-6-php8.3"
    echo "  Takes ~2 minutes; pulls wordpress:6-php8.3-fpm-alpine and bakes WP-CLI."
    if confirm "docker build -t multiwp:wordpress-6-php8.3 image/ ?"; then
        cd "$REPO_ROOT"
        docker build -t multiwp:wordpress-6-php8.3 image/
        ok "image built"
    else
        warn "skipped — wp-create will fail without the per-site image"
    fi
fi

if [ -n "${NEEDS[metrics_cron]:-}" ]; then
    step_banner "Install metrics-poll cron (24h rolling peaks)"
    if confirm "Install /etc/cron.d/multiwordpress + enable per-site wp-cron stagger?"; then
        bash "$REPO_ROOT/host/install-metrics-cron.sh"
    else
        warn "skipped — wp-stats peak columns will show '-' indefinitely"
    fi
fi

if [ -n "${NEEDS[wrappers]:-}" ]; then
    step_banner "Install CLI wrappers in /usr/local/bin/"
    echo "  Lets 'sudo wp-create ...' work without typing the full path."
    echo "  Wrappers (not symlinks) so BASH_SOURCE-based _lib.sh resolution works."
    if confirm "Install wrappers?"; then
        # Symlinks would break: 'source \"\$SCRIPT_DIR/_lib.sh\"' resolves SCRIPT_DIR
        # from BASH_SOURCE[0] which is the symlink path = /usr/local/bin/, where
        # _lib.sh doesn't exist. Wrappers exec the real script directly.
        for v in wp-create wp-delete wp-pause wp-resume wp-list wp-stats wp-logs wp-exec; do
            # Remove any pre-existing symlink first
            [ -L "/usr/local/bin/$v" ] && rm -f "/usr/local/bin/$v"
            cat > "/usr/local/bin/$v" <<EOF
#!/usr/bin/env bash
exec $WP_ROOT/bin/$v "\$@"
EOF
            chmod 755 "/usr/local/bin/$v"
        done
        ok "wrappers installed"
    else
        warn "skipped — use full path: sudo $WP_ROOT/bin/wp-create ..."
    fi
fi

# -----------------------------------------------------------------------------
# Optional: dashboard
# -----------------------------------------------------------------------------
if [ "$DASHBOARD_RUNNING" -eq 0 ]; then
    step_banner "Optional: Dashboard"
    echo "  The dashboard is a thin PHP UI for stats + add/delete buttons."
    echo "  It runs in its own container behind Caddy basic_auth."
    echo "  Skip this if you only want the CLI."
    if confirm "Install dashboard?"; then
        bash "$REPO_ROOT/host/install-dashboard.sh"
    else
        echo "  (you can install it later: sudo bash host/install-dashboard.sh)"
    fi
fi

# -----------------------------------------------------------------------------
# Smoke test
# -----------------------------------------------------------------------------
step_banner "SMOKE TEST"
if [ -x "$REPO_ROOT/bin/_smoke-test.sh" ]; then
    if "$REPO_ROOT/bin/_smoke-test.sh"; then
        ok "smoke test passed"
    else
        err "smoke test FAILED — investigate above"
    fi
else
    warn "bin/_smoke-test.sh not executable — skipping"
fi

# -----------------------------------------------------------------------------
# Final summary
# -----------------------------------------------------------------------------
step_banner "DONE"

VM_IP="$(curl -s --max-time 3 ifconfig.me 2>/dev/null || echo '<your-VM-public-IP>')"

cat <<EOF

  ${BOLD}Next steps:${RESET}
  1. Provision your first site:
       sudo wp-create blog.example.com --admin-email you@example.com

  2. The output prints a Caddy block + Cloudflare DNS row.
     Paste them as instructed.

  3. Validate end-to-end with the runbook:
       cat $REPO_ROOT/docs/first-site-e2e.md

  ${BOLD}Useful commands:${RESET}
     sudo wp-list                  # show all sites
     sudo wp-stats                 # cluster + per-site usage
     sudo bash host/setup.sh --check    # re-survey state anytime

  VM IP (for Cloudflare A records): ${BOLD}$VM_IP${RESET}

EOF
