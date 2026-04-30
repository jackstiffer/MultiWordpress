# MultiWordpress per-site WP image (IMG-01, IMG-06, HARD-03).
# Built locally; instantiated per site by Phase 2's wp-create.
# Tag: multiwp:wordpress-6-php8.3

FROM wordpress:6-php8.3-fpm-alpine

# WP-CLI baked in (IMG-01) — installed under root, then we drop back to www-data.
USER root
RUN apk add --no-cache --virtual .wpcli-deps less mysql-client bash curl \
 && curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
        -o /usr/local/bin/wp \
 && chmod +x /usr/local/bin/wp \
 && /usr/local/bin/wp --info --allow-root

# PHP + OPcache overrides (IMG-03, IMG-04).
COPY php.d-zz-wp.ini /usr/local/etc/php/conf.d/zz-wp.ini

# php-fpm pool overrides (IMG-02, IMG-04, IMG-05).
COPY fpm-zz-wp.conf /usr/local/etc/php-fpm.d/zz-wp.conf

# IMG-06: run as www-data. The upstream Alpine image creates www-data at
# UID/GID 82 (Alpine convention — NOT the Debian 33). We explicitly set USER
# so `docker run` defaults to that UID. Phase 2's wp-create MUST chown bind
# mounts to 82:82, not 33:33. See README "UID 82 (www-data)" section.
USER www-data

# Document the FPM port (already EXPOSEd by upstream, redeclared for clarity).
EXPOSE 9000
