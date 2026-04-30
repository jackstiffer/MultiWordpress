#!/usr/bin/env bash
# =============================================================================
# host/install-dashboard.sh — provision the MultiWordpress dashboard
# =============================================================================
#
# Steps:
#   1. Verify prerequisites (Phase 1 wp.slice, Phase 2 CLI verbs, Phase 3 metrics).
#   2. Create the wpdash service account (UID/GID 1500) — fixed UID so the
#      compose file doesn't drift between hosts.
#   3. Install /etc/sudoers.d/wp-dashboard (validated with visudo -cf).
#   4. Build the multiwp:dashboard image.
#   5. docker compose up -d.
#   6. Print the Caddy snippet the operator must add to their host Caddyfile.
#
# Re-runnable: existing user / sudoers entries are preserved.
# =============================================================================

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARD_DIR="$REPO_ROOT/dashboard"
SUDOERS_SRC="$REPO_ROOT/host/wp-dashboard.sudoers"
SUDOERS_DST="/etc/sudoers.d/wp-dashboard"

WPDASH_USER="wpdash"
WPDASH_UID=1500
WPDASH_GID=1500

log()   { printf '\033[1;34m[install-dashboard]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[install-dashboard]\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m[install-dashboard]\033[0m %s\n' "$*" >&2; exit 1; }

# -----------------------------------------------------------------------------
# 1. Prerequisites
# -----------------------------------------------------------------------------
log "Checking prerequisites…"

[[ -e /sys/fs/cgroup/wp.slice ]] \
    || die "wp.slice not active — run host/install-wp-slice.sh (Phase 1) first"

for verb in wp-create wp-delete wp-pause wp-resume wp-list wp-stats wp-logs; do
    [[ -x "/opt/wp/bin/$verb" ]] \
        || die "/opt/wp/bin/$verb missing or not executable — install Phase 2 CLI first"
done

[[ -f /opt/wp/state/metrics.json ]] \
    || warn "/opt/wp/state/metrics.json not found — Phase 3 metrics-poll may not be running yet (peaks will show '-')"

command -v docker  >/dev/null || die "docker not installed"
docker compose version >/dev/null 2>&1 || die "docker compose plugin not available"

# -----------------------------------------------------------------------------
# 2. wpdash user
# -----------------------------------------------------------------------------
log "Ensuring service account ${WPDASH_USER} (UID/GID ${WPDASH_UID})…"

if ! getent group "$WPDASH_USER" >/dev/null; then
    sudo groupadd -r -g "$WPDASH_GID" "$WPDASH_USER" \
        || die "groupadd failed"
fi
if ! id -u "$WPDASH_USER" >/dev/null 2>&1; then
    sudo useradd -r -s /usr/sbin/nologin -u "$WPDASH_UID" -g "$WPDASH_GID" "$WPDASH_USER" \
        || die "useradd failed"
fi

# -----------------------------------------------------------------------------
# 3. Sudoers fragment
# -----------------------------------------------------------------------------
log "Installing sudoers fragment…"
[[ -f "$SUDOERS_SRC" ]] || die "missing source file: $SUDOERS_SRC"

sudo install -o root -g root -m 0440 "$SUDOERS_SRC" "$SUDOERS_DST"

if command -v visudo >/dev/null; then
    sudo visudo -cf "$SUDOERS_DST" \
        || { sudo rm -f "$SUDOERS_DST"; die "visudo validation failed; sudoers fragment removed"; }
    log "visudo: $SUDOERS_DST OK"
else
    warn "visudo not found — skipping sudoers syntax validation"
fi

# -----------------------------------------------------------------------------
# 4. State files for the read-only mounts
# -----------------------------------------------------------------------------
# The compose mounts sites.json + metrics.json read-only. They MUST exist on
# the host or compose will create them as DIRECTORIES (Docker default behavior
# when bind-mount source is missing). Pre-create empty files if absent.
log "Ensuring state files exist for ro mounts…"
sudo touch /opt/wp/state/sites.json /opt/wp/state/metrics.json
sudo chmod 644 /opt/wp/state/sites.json /opt/wp/state/metrics.json

# -----------------------------------------------------------------------------
# 5. Build image + start
# -----------------------------------------------------------------------------
log "Building multiwp:dashboard image…"
( cd "$DASHBOARD_DIR" && docker build -t multiwp:dashboard . )

log "Starting wp-dashboard via compose…"
( cd "$DASHBOARD_DIR" && docker compose up -d )

# -----------------------------------------------------------------------------
# 6. Print Caddy snippet
# -----------------------------------------------------------------------------
cat <<'EOF'

================================================================================
  wp-dashboard is up at 127.0.0.1:18900 (loopback only)
================================================================================

Add the following block to your host Caddyfile (replace the domain + hash):

  dashboard.example.com {
      basic_auth {
          admin {{bcrypt-hashed-password}}
      }
      reverse_proxy 127.0.0.1:18900
  }

Generate a bcrypt hash with one of:

  # On the host (recommended — Caddy is already installed):
  caddy hash-password

  # Or inside the dashboard container (uses PHP):
  docker exec wp-dashboard php -r 'echo password_hash("YOUR_PASSWORD", PASSWORD_BCRYPT) . "\n";'

After editing the Caddyfile:
  sudo systemctl reload caddy   # or: caddy reload --config /etc/caddy/Caddyfile

Then visit https://dashboard.example.com — Caddy will challenge for basic_auth.

================================================================================
EOF
