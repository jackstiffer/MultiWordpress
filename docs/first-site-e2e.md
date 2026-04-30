# First-Site E2E Runbook

**Purpose:** Phase 2 success criterion #5 says: the first real domain proves the
cache promise. This runbook walks through that proof. Run it on your GCP VM
(`dirtyvocal-nextjs`) AFTER Phase 1 is deployed and the Phase 2 CLI is in place.
End state: `cf-cache-status: HIT` for the logged-out homepage and `BYPASS` (or
`DYNAMIC`) for `/wp-admin/`, with TTFB under ~100 ms on a cached request.

**Approximate time:** 20–30 minutes including DNS propagation and a couple of
warm-up requests.

This runbook is documentation only — Claude does not deploy. The operator runs
each step on the VM (or in the Cloudflare dashboard) and ticks the sign-off
checklist at the bottom.

---

## Prerequisites

| Check | Command / Where | Expected |
| --- | --- | --- |
| Phase 1 infra running | `docker compose -f /opt/wp/compose/compose.yaml ps` | `wp-mariadb` healthy, `wp-redis` running |
| `wp.slice` cgroup active | `systemctl status wp.slice` | `loaded` (active or inactive both fine) |
| Phase 2 CLI on PATH | `which wp-create && which wp-exec && which wp-list` | three paths printed |
| Host Caddy serving existing AudioStoryV2 | `curl -sI https://open.dirtyvocal.com/` | `HTTP/2 200` |
| Cloudflare zone live | Dashboard → zone status | Active, Proxied |
| `MARIADB_ROOT_PASSWORD` set | `sudo grep MARIADB_ROOT_PASSWORD /opt/wp/.env` | non-empty |
| One spare domain | e.g. `blog.dirtyvocal.com` | DNS managed by Cloudflare |
| VM public IP known | `curl -s ifconfig.me` | e.g. `34.x.y.z` |

If any of these fail, fix before proceeding — the runbook assumes them.

---

## Step 1 — Provision the site with `wp-create`

```bash
sudo wp-create blog.dirtyvocal.com --admin-email you@example.com
```

Expected duration: ~30 seconds end-to-end. The script:

1. Allocates a port (range 18000–18999) and a Redis DB index.
2. Creates the per-site DB + scoped MariaDB user.
3. Renders `compose.yaml`, brings up the FPM container in `wp.slice`.
4. Runs `wp core install`, installs and activates `redis-cache`.
5. Injects `wp-config-extras.php` (DISABLE_WP_CRON, XML-RPC off, etc).
6. Prints the summary block with admin credentials, Caddy snippet, and
   Cloudflare DNS row.

Sample output (anonymized):

```
✓ Site created: https://blog.dirtyvocal.com

Admin URL:      https://blog.dirtyvocal.com/wp-admin/
Admin user:     wpadmin_a8f3
Admin password: <24-char random>
Admin email:    you@example.com

Saved to: /opt/wp/secrets/blog_dirtyvocal_com.env (mode 600 — re-read with `wp-list --secrets blog_dirtyvocal_com`)

── Cloudflare DNS ──
Type: A   Name: blog   Content: 34.x.y.z   Proxy: Proxied (orange cloud)

── Caddy block ──
blog.dirtyvocal.com {
    reverse_proxy 127.0.0.1:18001 {
        transport fastcgi {
            root /var/www/html
            split .php
        }
    }
}

── Cloudflare Cache Rule ──
See templates/cloudflare-cache-rule.md (one-time per zone).
Required cookies to bypass: wordpress_logged_in_*, wp-postpass_*, comment_author_*
```

**Save this output.** The credentials and Caddy block are needed below. The
secrets file is also persisted at `/opt/wp/secrets/<slug>.env` (mode 600) and
can be re-read with `sudo wp-list --secrets <slug>`.

**Recovery:** if `wp-create` fails partway through, re-run with `--resume`:

```bash
sudo wp-create blog.dirtyvocal.com --resume blog_dirtyvocal_com
```

See `docs/cli.md` (`wp-create` section) for the full state machine.

---

## Step 2 — Add the Cloudflare DNS row

In the Cloudflare dashboard for the zone (`dirtyvocal.com`):

1. **DNS → Records → Add record**
2. **Type:** `A`
3. **Name:** the subdomain printed by `wp-create` (e.g. `blog`) — or `@` for
   apex.
4. **IPv4 address:** the VM public IP printed by `wp-create`.
5. **Proxy status:** **Proxied (orange cloud)** — this is critical. Without
   the orange cloud, no Cloudflare cache happens at all.
6. Save.

Wait ~30 seconds for propagation, then verify:

```bash
dig +short blog.dirtyvocal.com
# Expect Cloudflare IPs (104.x.y.z or 172.x.y.z), NOT your VM IP.
```

If `dig` still returns the VM IP after a minute, the proxy toggle is off —
flip it on.

---

## Step 3 — Paste the Caddy block

The host Caddy is the same one already serving AudioStoryV2 at
`open.dirtyvocal.com`. We add a block, not a new server.

1. Open the existing Caddyfile (typically `/etc/caddy/Caddyfile`):

   ```bash
   sudo nano /etc/caddy/Caddyfile
   ```

2. Paste the Caddy block from `wp-create` output at the end of the file.

3. Reload Caddy in place (no restart — keeps the existing site up):

   ```bash
   sudo caddy reload --config /etc/caddy/Caddyfile
   # or:
   sudo systemctl reload caddy
   ```

4. Verify HTTPS comes up (Let's Encrypt cert issuance happens on first hit):

   ```bash
   curl -sI https://blog.dirtyvocal.com/ | head -5
   # Expect: HTTP/2 200  (or HTTP/2 301 to /wp-admin/install.php on a fresh site)
   ```

If you see `HTTP/2 502`, the FPM container is unreachable — see Troubleshooting
below.

---

## Step 4 — Apply the Cloudflare Cache Rule (once per zone)

Reference: `templates/cloudflare-cache-rule.md` for the canonical spec and
the rationale for each cookie. This step is **one-time per zone** —
subsequent sites in the same zone inherit the rule.

In the Cloudflare dashboard:

1. **Caching → Cache Rules → Create rule**
2. **Rule name:** `WordPress — bypass on auth/preview/comment/cart cookies`
3. **If incoming requests match:**
   - Hostname **equals** `blog.dirtyvocal.com` (or **wildcard** `*.dirtyvocal.com`
     if you want it to cover all sites in the zone) **AND**
   - Request Method **equals** `GET`
4. **AND Cookie does NOT contain** any of:
   - `wordpress_logged_in_`
   - `wp-postpass_`
   - `comment_author_`
   - `woocommerce_items_in_cart`
   - `woocommerce_cart_hash`
5. **Then:**
   - **Cache eligibility:** Eligible for cache
   - **Edge TTL:** Override origin → `4 hours`
   - **Browser TTL:** Respect origin headers
   - **Cache key:** Include all query strings
6. Save. Wait ~30 seconds for the rule to propagate to edge.

**Anti-pattern:** do NOT also enable Cloudflare APO (Automatic Platform
Optimization for WordPress). APO is a parallel cache layer with its own
cookie logic; running it alongside this rule produces double-caching and
confusing purge behavior.

---

## Step 5 — Install Super Page Cache for Cloudflare

The plugin handles **purge-on-write** inside WordPress (when a post is
published or updated, it tells Cloudflare to purge that URL). The Cache Rule
in Step 4 handles **serve-time bypass** at the edge. Together = working cache.

```bash
sudo wp-exec blog_dirtyvocal_com plugin install super-page-cache-for-cloudflare --activate
```

Optional (configure programmatic purge via Cloudflare API token):

1. Cloudflare dashboard → My Profile → API Tokens → Create Token
   - Permissions: `Zone: Cache Purge: Purge`
   - Zone Resources: include `dirtyvocal.com`
2. WP admin → Super Page Cache for Cloudflare → enter token + zone ID
3. Test: publish a draft post and confirm the plugin reports a successful
   purge in its log.

The Cache Rule from Step 4 works without the API token — purge will simply be
manual (Cloudflare dashboard → Caching → Configuration → Purge Everything)
until it's wired up.

If WP plugin install fails with a network error, the WordPress.org plugin
repository may be unreachable from the VM; retry, or download the plugin
zip and pass it via `wp-exec <slug> plugin install /path/to/plugin.zip`.

---

## Step 6 — Validate the cache

The actual proof. Run these from your laptop (or any host outside the VM —
running them on the VM may bypass Cloudflare entirely depending on your DNS).

### Cold request (first hit warms the edge)

```bash
curl -sI https://blog.dirtyvocal.com/ | grep -i cf-cache-status
# Expect: cf-cache-status: MISS    (first request)
# Or:     cf-cache-status: EXPIRED (if a prior test populated the cache)
```

### Warm request (the success criterion)

```bash
curl -sI https://blog.dirtyvocal.com/ | grep -i cf-cache-status
# Expect: cf-cache-status: HIT
```

If the second request still returns `MISS` or `DYNAMIC`, see Troubleshooting.

### Logged-in bypass

```bash
curl -sI -H 'Cookie: wordpress_logged_in_test=1' \
    https://blog.dirtyvocal.com/wp-admin/ \
  | grep -i cf-cache-status
# Expect: cf-cache-status: BYPASS   (or DYNAMIC)
```

### TTFB measurement

```bash
curl -o /dev/null -s \
    -w 'time_total: %{time_total}s\ntime_starttransfer: %{time_starttransfer}s\n' \
    https://blog.dirtyvocal.com/
# Expect (cached): time_starttransfer < 0.100 s
```

---

## Step 7 — Validate isolation

Confirm the new site is contained in `wp.slice` and AudioStoryV2 is unaffected.

```bash
# Pool memory ceiling (4 GiB) and current usage:
cat /sys/fs/cgroup/wp.slice/memory.max      # 4294967296
cat /sys/fs/cgroup/wp.slice/memory.current  # well under 4 GiB after one site

# AudioStoryV2 still healthy:
docker ps --filter name=audiostory          # still running
curl -sI https://open.dirtyvocal.com/       # HTTP/2 200

# New site's container is in wp.slice:
docker inspect wp-blog_dirtyvocal_com --format '{{.HostConfig.CgroupParent}}'
# Expect: wp.slice

# wp.slice cgroup contains the FPM process(es):
cat /sys/fs/cgroup/wp.slice/cgroup.procs    # one or more PIDs
```

---

## Step 8 — Sanity-check the CLI

```bash
sudo wp-list
# Expect: blog_dirtyvocal_com row, status=running, port=18001 (or whatever was allocated)

sudo wp-stats
# Expect: cluster line + per-site row.
# 24h peak will show '-' until Phase 3 metrics-poll cron is shipped.

sudo wp-logs blog_dirtyvocal_com
# Expect: recent FPM/access log lines from the container.
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `522 Connection Timed Out` from Cloudflare | Docker network MTU > 1460 (GCE-specific) | `docker network inspect wp-network` — confirm MTU 1460. If wrong, recreate network with `--opt com.docker.network.driver.mtu=1460`. |
| `502 Bad Gateway` from Caddy | FPM container down, or Caddy points at wrong port | `sudo wp-list` to confirm container running and port; fix Caddy block to match. `sudo wp-resume <slug>` if paused. |
| `cf-cache-status: DYNAMIC` always | Cache Rule not active, hostname mismatch, or cookie bypass too broad | Cloudflare → Cache Rules → confirm rule is enabled and hostname matches. Wait 60 s for propagation. |
| `cf-cache-status: BYPASS` for logged-out | Stale `wordpress_test_cookie` set by WP on first visit | `curl -sI` with no `Cookie` header (the commands above do this). In a real browser, clear cookies for the domain and reload. |
| `cf-cache-status: HIT` but TTFB > 200 ms | Edge not in your region, or curl over a slow link | Run from a different network. Cached HIT TTFB target is regional. |
| Let's Encrypt cert fails | Cloudflare SSL mode is "Flexible" or "Off" | Cloudflare → SSL/TLS → set to **Full (strict)**. Ensure host Caddy can reach `:80` from the internet (firewall). |
| Origin slow on MISS | `redis-cache` not active inside the site | `sudo wp-exec <slug> redis status` should report `Connected`. If not, `sudo wp-exec <slug> redis enable`. |
| `Permission denied` writing uploads | UID mismatch on bind mount | `sudo chown -R 82:82 /opt/wp/sites/<slug>/wp-content` (Phase 1 image runs as UID 82). |
| WooCommerce cart shows stale empty cart | `woocommerce_*` cookies not in bypass list | Step 4 includes both `woocommerce_items_in_cart` and `woocommerce_cart_hash` — verify both are in the rule. |
| Plugin install network error | WP.org repo unreachable from VM | Retry; or download zip and `wp-exec <slug> plugin install /path/to/plugin.zip`. |

---

## Sign-off Checklist

When all 8 boxes are checked, **Phase 2 success criterion #5 is satisfied**.
Record the result in `.planning/phases/02-cli-core-first-site-e2e/02-VERIFICATION.md`
(operator-attested entry — Phase 2 verifier reads it from there).

- [ ] `wp-create` completed without error
- [ ] DNS resolves to a Cloudflare IP (Proxied)
- [ ] HTTPS responds `HTTP/2 200` (or 301 to install on a fresh site)
- [ ] `cf-cache-status: HIT` confirmed for logged-out homepage
- [ ] `cf-cache-status: BYPASS` (or `DYNAMIC`) confirmed for `/wp-admin/` with
      `wordpress_logged_in_*` cookie
- [ ] TTFB < 100 ms on a cached request
- [ ] AudioStoryV2 still healthy at `https://open.dirtyvocal.com/`
- [ ] Pool memory `/sys/fs/cgroup/wp.slice/memory.current` < 1 GiB after first site

---

## Repeating for Additional Domains

Each new domain repeats Steps 1–3, 5, 6 (Steps 4 and 7 are zone-wide /
infrastructure-wide checks done once):

1. `sudo wp-create <new-domain>` — provisions DB, container, WP install.
2. Add Cloudflare DNS row (Proxied).
3. Paste Caddy block + reload.
4. Cache Rule — only if the new domain is in a **different** zone, or you used
   a hostname-equals match in Step 4 instead of a wildcard. Wildcard matches
   (e.g. `*.dirtyvocal.com`) cover new sub-sites automatically.
5. `sudo wp-exec <slug> plugin install super-page-cache-for-cloudflare --activate`.
6. Validate `cf-cache-status: HIT` as in Step 6.

The pool's 4 GiB ceiling is shared across all sites — `wp-stats` shows how
close to the limit you are. Phase 3 ships peak-tracking metrics so you can
spot a noisy site before it pressures the pool.

---

## References

- `templates/cloudflare-cache-rule.md` — canonical Cache Rule spec + cookie
  rationale
- `docs/cli.md` — full CLI reference (every command, every flag)
- `.planning/phases/02-cli-core-first-site-e2e/02-CONTEXT.md` — "First-Site E2E
  Validation" canonical section
- `.planning/research/PITFALLS.md` §7.1, §7.2 — cache strategy + cookie list
  with rationale
- `.planning/ROADMAP.md` — Phase 2 success criterion #5
