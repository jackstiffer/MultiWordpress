# =============================================================================
# dashboard/Dockerfile — MultiWordpress thin operator dashboard
# =============================================================================
#
# Pinned to php:8.3-cli (HARD-03 inheritance — never :latest).
# Runs PHP's built-in dev server with a router. No build step, no nginx, no fpm.
# Image is intentionally small and read-mostly — write paths go through the
# sudoers-whitelisted CLI verbs on the host (NOT a docker.sock mount).
#
# Build:  docker build -t multiwp:dashboard dashboard/
# Run:    via dashboard/compose.yaml
# =============================================================================

FROM php:8.3-cli

WORKDIR /app

# Copy source verbatim. No composer, no extensions needed beyond core PHP.
COPY src/ /app/src/

# Loopback-only via compose (127.0.0.1:18900:80). The container itself listens
# on :80 and trusts the compose port mapping for binding scope.
EXPOSE 80

# Built-in dev server with router for path-based dispatch.
CMD ["php", "-S", "0.0.0.0:80", "-t", "/app/src", "/app/src/router.php"]
