# Cloudflare Cache Rule — WordPress Cookie Bypass

After provisioning a site with `wp-create`, paste the Caddy block, add the
Cloudflare DNS row (Proxied), then create this Cache Rule in the Cloudflare
dashboard so logged-out reads hit the edge cache while logged-in admin
traffic bypasses it.

## Cache Rules vs Page Rules

Use **Cache Rules** (Caching → Cache Rules), not Page Rules. Page Rules are
legacy and Cloudflare is sunsetting them — Cache Rules are the supported
2026 surface and offer finer-grained cookie matching.

## Where

Cloudflare Dashboard → (zone) → **Caching → Cache Rules → Create rule**.

## When to apply (rule expression)

- **If incoming requests match**: Hostname equals `<your-domain>` AND
  Request Method equals `GET`
- **AND** Cookie does NOT contain any of:
  - `wordpress_logged_in_`
  - `wp-postpass_`
  - `comment_author_`
  - `woocommerce_items_in_cart`
  - `woocommerce_cart_hash`

## Then (cache settings)

- **Cache eligibility**: Eligible for cache
- **Edge TTL**: Override origin → `4 hours`
- **Browser TTL**: Respect origin headers
- **Cache key**: Include all query strings
- **Cache by device type**: off

## Why these cookies

- `wordpress_logged_in_*` — set when an editor/admin is signed in; serving
  a cached anonymous page to them would hide the admin bar and break
  edit links.
- `wp-postpass_*` — set when a visitor unlocks a password-protected post;
  caching would either leak the protected post to anonymous users or
  re-prompt an unlocked visitor.
- `comment_author_*` — set after a visitor leaves a comment so they see
  their own pending comment immediately; caching would hide it until
  approval.
- `woocommerce_items_in_cart`, `woocommerce_cart_hash` — set when a
  WooCommerce cart is non-empty; caching would show a stale "empty cart"
  to a shopper mid-checkout.

## Validation

After saving the rule and waiting ~30s for propagation:

```bash
# Logged-out homepage should HIT after 1–2 warm-up requests.
curl -sI https://<your-domain>/ | grep -i cf-cache-status
# Expect: cf-cache-status: HIT

# Logged-in / admin requests must bypass.
curl -sI -H 'Cookie: wordpress_logged_in_test=1' https://<your-domain>/wp-admin/ \
  | grep -i cf-cache-status
# Expect: cf-cache-status: BYPASS (or DYNAMIC)
```

## Anti-pattern: do NOT enable APO simultaneously

Cloudflare's **Automatic Platform Optimization (APO)** for WordPress is a
parallel cache layer with its own cookie logic. Running APO alongside this
Cache Rule causes double-caching, conflicting bypass rules, and confusing
purge behavior. Pick one — for full control, the Cache Rule above wins.

## Companion plugin

Activate Super Page Cache for Cloudflare inside WordPress so post
publish/update events trigger automatic cache purges:

```bash
wp-exec <slug> plugin install super-page-cache-for-cloudflare --activate
```

The plugin handles purge-on-write; the Cache Rule above handles
serve-time bypass logic.
