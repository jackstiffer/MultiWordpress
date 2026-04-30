# Caddy + Cloudflare Runbook

Operator runbook for the reverse-proxy + edge-cache layer that sits in front of every WordPress site, AudioStoryV2, and the dashboard. This stack does **not** ship its own reverse proxy — host Caddy (already running for AudioStoryV2) handles everything.

## How host Caddy fits

Single Caddyfile on the VM (typically `/etc/caddy/Caddyfile`). Sites coexist under one config:

```
# Existing — AudioStoryV2 (do not modify)
open.dirtyvocal.com {
    reverse_proxy 127.0.0.1:3000
}

# WordPress site (block printed by `wp-create`)
blog.dirtyvocal.com {
    root * /opt/wp/sites/blog_dirtyvocal_com
    php_fastcgi 127.0.0.1:18001

    @uploads_php path_regexp ^/wp-content/uploads/.*\.php$
    respond @uploads_php 403

    encode gzip zstd
}

# Dashboard (Phase 4)
dashboard.dirtyvocal.com {
    basic_auth {
        admin <bcrypt-hash>
    }
    reverse_proxy 127.0.0.1:18900
}
```

`caddy reload --config /etc/caddy/Caddyfile` applies the new block. Caddy auto-provisions Let's Encrypt certs on first request.

## Cloudflare DNS setup

For each new WordPress site, add one DNS row:

| Type | Name | Content | Proxy | TTL |
|------|------|---------|-------|-----|
| A | `<sub>` (or `@`) | `<VM public IP>` | **Proxied** (orange cloud) | Auto |

**Recommended: Proxied** — gives you Cloudflare's CDN cache + DDoS shield for free. The whole "lightweight, lightning fast" promise rides on this.

Unproxied (gray cloud) only if you specifically want to bypass Cloudflare for that hostname (e.g., dashboard you only access from your office IP).

For the dashboard: proxied is fine, but you may also gate it with **Cloudflare Access** (Zero Trust) for second-factor auth in front of basic_auth.

## SSL/TLS modes — must be Full (Strict)

In Cloudflare dashboard → **SSL/TLS** → **Overview**:

| Mode | Result |
|------|--------|
| Off | Visitor → CF over HTTP, no encryption. Don't. |
| Flexible | CF → origin over HTTP. Causes redirect loops with Caddy auto-HTTPS. **Don't.** |
| Full | CF → origin over HTTPS but accepts self-signed. Acceptable but loose. |
| **Full (Strict)** | CF → origin over HTTPS validating cert. **This is the right answer** because Caddy auto-provisions a real Let's Encrypt cert. |

If you accidentally set Flexible, you'll see "Too many redirects" (ERR_TOO_MANY_REDIRECTS) — change to Full (Strict).

## Per-new-site checklist

After running `sudo wp-create blog.example.com` and getting the printed snippets:

1. **Add the DNS row** in Cloudflare → DNS → Records (Proxied).
2. **Paste the Caddy block** at the end of `/etc/caddy/Caddyfile`.
3. **Reload Caddy**: `sudo systemctl reload caddy` (or `caddy reload --config /etc/caddy/Caddyfile`).
4. **Validate**: `curl -sI https://blog.example.com/` returns `200 OK` (or `301`/`302` if WP redirects). After 30–60s for cert provisioning.

If step 4 returns a TLS error, wait — Caddy is fetching the cert, takes up to a minute on first request.

## Cache Rules — one-time per zone

See [`templates/cloudflare-cache-rule.md`](../templates/cloudflare-cache-rule.md) for the full canonical rule. Summary:

- Set in Cloudflare → **Caching** → **Cache Rules** → Create Rule.
- Match: hostname matches your zone, method = GET.
- Action: Cache eligibility = Eligible. Edge TTL = 4 hours (override).
- **Bypass cache when any of these cookies present**:
  - `wordpress_logged_in_*`
  - `wp-postpass_*`
  - `comment_author_*`
  - `woocommerce_items_in_cart`
  - `woocommerce_cart_hash`

A wildcard hostname match (`*.dirtyvocal.com`) covers every WP site in the zone — you create the rule **once**, not per-site.

**Anti-pattern**: do NOT enable Cloudflare APO simultaneously. APO + this rule = cache poisoning. Pick one.

## WAF rules to consider

Cloudflare → **Security** → **WAF** → Custom Rules. Worth adding:

1. **Block /xmlrpc.php at edge** (defense in depth — Caddy already 403s it):
   - When: `URI Path equals /xmlrpc.php` → Block.

2. **Rate limit /wp-login.php** (brute-force shield):
   - When: `URI Path equals /wp-login.php` → Rate limit: 10 requests / 1 minute / IP.

3. **Block known scanner User-Agents**:
   - When: `User Agent contains "wpscan"` OR `"sqlmap"` OR `"nikto"` → Block.

4. **Block /wp-admin/admin-ajax.php XML-RPC bypass attempts**:
   - When: `URI Path equals /wp-admin/admin-ajax.php` AND `Cookie does not contain "wordpress_logged_in"` → Challenge (CAPTCHA).

These are belt-and-suspenders. Caddy handles the basics; Cloudflare's edge handles them at scale before your origin sees the request.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `522 Connection Timed Out` | MTU mismatch (GCP VPC = 1460, Docker default = 1500) | `docker network inspect wp-network` should show `"com.docker.network.driver.mtu": "1460"`. If not, recreate network. |
| `502 Bad Gateway` | Caddy can't reach FPM container | Check `wp-list` PORT column matches Caddy block's `php_fastcgi 127.0.0.1:<port>`. |
| `ERR_TOO_MANY_REDIRECTS` | Cloudflare SSL mode = Flexible | Change to Full (Strict). |
| `526 Invalid SSL Certificate` | Caddy hasn't issued cert yet, or LE rate-limit hit | Wait 60s; check `journalctl -u caddy` for cert errors. |
| Wildcard `*.dirtyvocal.com` cert fails | Caddy needs DNS-01 challenge for wildcards (HTTP-01 doesn't work for wildcards) | Use Cloudflare API token with caddy-dns/cloudflare plugin; document path is out of scope here. |
| `cf-cache-status: MISS` always | Plugin setting `Cache-Control: no-cache` or extra cookie pre-login | Inspect with `curl -sI https://<domain>/`. Disable the offending plugin or add the cookie name to bypass list. |
| `cf-cache-status: BYPASS` always | Cookie that triggers bypass is set | Same — find it in browser DevTools → Application → Cookies. |
| Caddy log shows "no certificate available" for new site | DNS not propagated yet, or DNS row is "DNS only" not "Proxied" | Wait for DNS; verify with `dig <domain>`. |
| WordPress redirects to wrong domain | `WP_HOME`/`WP_SITEURL` not picked up from env | Verify `wp-config-extras.php` is `require_once`d in `wp-config.php`; check `wp option get siteurl` matches. |
| Caddy reload reports "address already in use :443" | Another service binding 443 | `sudo ss -tlnp | grep :443` to find culprit. |

## Validation commands (paste-and-run)

```bash
# DNS resolves through Cloudflare
dig +short blog.example.com
# (returns Cloudflare IPs — 104.x or 172.x)

# HTTPS reaches origin
curl -sI https://blog.example.com/ | head -5
# (200 OK + cf-ray header present)

# Cache hit (run twice; second should HIT)
curl -sI https://blog.example.com/ | grep -i cf-cache-status
curl -sI https://blog.example.com/ | grep -i cf-cache-status

# Logged-in bypass works
curl -sI -H 'Cookie: wordpress_logged_in_abc=xyz' https://blog.example.com/wp-admin/ | grep -i cf-cache-status
# expect: BYPASS or DYNAMIC

# TTFB measurement (cached)
curl -o /dev/null -s -w 'time_starttransfer: %{time_starttransfer}s\n' https://blog.example.com/
# expect < 100ms when cached
```

## Cross-references

- First-site provisioning: [docs/first-site-e2e.md](first-site-e2e.md)
- CLI reference: [docs/cli.md](cli.md)
- Cron + metrics setup: [docs/operational.md](operational.md)
- Cloudflare Cache Rule canonical doc: [templates/cloudflare-cache-rule.md](../templates/cloudflare-cache-rule.md)
- Dashboard install: [dashboard/README.md](../dashboard/README.md)
