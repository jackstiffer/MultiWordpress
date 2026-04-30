# MultiWordpress Dashboard

Thin, single-page operator dashboard for MultiWordpress. Reads `wp-list` /
`wp-stats` JSON, renders cluster + per-site stats, exposes Add / Pause /
Resume / Delete / Logs actions through a sudoers-whitelisted CLI bridge
(no Docker socket).

Implements **DASH-01 / DASH-02 / DASH-03** from `.planning/REQUIREMENTS.md`.

---

## Architecture

```
Browser ──HTTPS──► host Caddy (basic_auth) ──127.0.0.1:18900──► wp-dashboard container
                                                                       │
                                                                       │ sudo /opt/wp/bin/wp-* (whitelist)
                                                                       ▼
                                                               host CLI verbs ──► docker / mariadb / redis
```

**Security boundary:**

- The dashboard container does NOT mount `/var/run/docker.sock`. RCE in PHP
  cannot equal root-on-host.
- Host writes happen through seven whitelisted verbs in
  `/etc/sudoers.d/wp-dashboard` (NOPASSWD, no shell metachars accepted).
- State files (`sites.json`, `metrics.json`) are mounted **read-only**.
- The container listens on `127.0.0.1:18900` only — Caddy reverse-proxies and
  enforces `basic_auth`.
- Every write endpoint requires CSRF (`X-CSRF` header from `<meta>` tag).

---

## Install

Prerequisites: Phase 1 (wp.slice), Phase 2 (CLI verbs at `/opt/wp/bin/`),
Phase 3 (metrics-poll for 24h peaks — optional but recommended).

```bash
sudo host/install-dashboard.sh
```

The script:

1. Verifies prerequisites.
2. Creates the `wpdash` service account (UID/GID 1500, no shell).
3. Installs `/etc/sudoers.d/wp-dashboard` (mode 440, validated with `visudo -cf`).
4. Builds `multiwp:dashboard`.
5. Starts the container via `dashboard/compose.yaml`.
6. Prints the Caddy snippet you must paste into your Caddyfile.

---

## Configure Caddy

Add to your host Caddyfile:

```
dashboard.example.com {
    basic_auth {
        admin {{bcrypt-hashed-password}}
    }
    reverse_proxy 127.0.0.1:18900
}
```

Generate a bcrypt hash:

```bash
caddy hash-password
# or:
docker exec wp-dashboard php -r 'echo password_hash("YOUR_PASSWORD", PASSWORD_BCRYPT) . "\n";'
```

Then `sudo systemctl reload caddy`.

---

## Verify

1. Visit `https://dashboard.example.com` — Caddy challenges for basic_auth.
2. After login you should see:
   - Cluster header: `wp.slice` pool now / 24h peak, AudioStoryV2 health, disk %.
   - Sites table with status badges, mem now / mem peak / cpu peak / db conn.
3. Click **+ Add site** → enter domain + admin email → confirm the modal shows
   creds + Caddy block + DNS row after ~30–90 s.
4. Click **Logs** on a site row → modal shows last 200 log lines.

---

## Polling & cache

- Browser polls `/api/sites.json` every 5 seconds (DASH-01).
- Server caches the merged `wp-list` + `wp-stats` JSON at
  `/tmp/wp-dashboard-stats.json` for 4 seconds. Multiple browser tabs share
  one snapshot; pressure on the host CLI is bounded.

---

## Troubleshooting

**Dashboard shows "Loading…" forever / red banner:**
- Open DevTools → Network → `/api/sites.json`. Look at the response body.
- `sudo: a password is required` → the sudoers fragment was not installed
  correctly. Re-run `host/install-dashboard.sh`. Verify
  `/etc/sudoers.d/wp-dashboard` exists (mode 440) and `sudo visudo -cf` passes.

**`visudo -cf` fails during install:**
- The shipped fragment `host/wp-dashboard.sudoers` should never fail. If it
  does, your sudo binary is older than the `Defaults:user` syntax — bump the
  base OS or remove that line manually.

**`wp-create` from the dashboard times out:**
- The default timeout is 300 s. A first run can be slow if Docker has to pull
  the WP base image. Run `wp-create` once from the CLI to warm the cache, or
  bump `timeout_sec` in `src/api/site_create.php`.

**Container can't reach `/opt/wp/state/sites.json`:**
- The compose file bind-mounts the path read-only. If the file does not exist
  on the host, Docker creates it as a DIRECTORY (which then fails the read).
  `host/install-dashboard.sh` pre-touches both files; if you skipped the
  install script, run `sudo touch /opt/wp/state/sites.json /opt/wp/state/metrics.json`.

**CSRF errors after a successful action:**
- The token rotates after every write. The JS refetches `/` to read the new
  token. If your browser blocks third-party cookies for the dashboard origin,
  ensure same-origin cookies are allowed — basic_auth uses HTTPS so the
  `Secure` cookie flag is required.

---

## Files

| Path                              | Purpose                                  |
| --------------------------------- | ---------------------------------------- |
| `dashboard/Dockerfile`            | `php:8.3-cli` image                      |
| `dashboard/compose.yaml`          | Loopback port, ro state mounts, mem 64m  |
| `dashboard/src/router.php`        | Path dispatch                            |
| `dashboard/src/index.php`         | SSR shell + initial data                 |
| `dashboard/src/api/*.php`         | JSON endpoints                           |
| `dashboard/src/lib/cli.php`       | Sudoers-whitelisted shell-out            |
| `dashboard/src/lib/auth.php`      | CSRF token gen/check                     |
| `dashboard/src/lib/render.php`    | Tiny `e()` / `json_response()` helpers   |
| `dashboard/src/static/style.css`  | Dark monospace theme                     |
| `dashboard/src/static/app.js`     | Polling, modals, write actions           |
| `host/install-dashboard.sh`       | One-shot installer                       |
| `host/wp-dashboard.sudoers`       | The whitelist (copied to /etc/sudoers.d) |

---

## What this dashboard intentionally does NOT do

- No multi-user / role system. Single shared basic_auth credential.
- No WebSocket / SSE — 5 s polling is sufficient.
- No log search / aggregation across sites — SSH is the right tool.
- No embedded terminal — security risk.
- No Docker socket access — sudoers whitelist is the only bridge.
