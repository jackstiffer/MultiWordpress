# From-Zero Deployment Guide

Take a fresh GCP VM (Ubuntu 22.04+ or Debian 12+) from "just SSH'd in" to "first site live with `cf-cache-status: HIT`" in ~30 minutes.

The whole install is automated by `host/setup.sh`. The orchestrator detects what's already configured, asks before each step, and only does what's missing — safe to re-run.

---

## Part 1 — Provision the VM

### 1.1 Create the GCP VM

In GCP console → **Compute Engine** → **VM instances** → **Create instance**:

| Setting | Value |
|---|---|
| Name | `multiwp-test` (anything) |
| Region/Zone | Same region as your production VM |
| Machine type | **`n2-standard-2`** (2 vCPU, 8 GB) |
| Boot disk | **Ubuntu 22.04+ LTS** *or* **Debian 12 (bookworm)** — both have cgroup v2. **20 GB**, balanced PD. |
| Firewall | Allow HTTP traffic, Allow HTTPS traffic |

Or via `gcloud` from your local machine:

```bash
gcloud compute instances create multiwp-test \
  --zone=us-central1-c \
  --machine-type=n2-standard-2 \
  --image-family=ubuntu-2204-lts \
  --image-project=ubuntu-os-cloud \
  --boot-disk-size=20GB \
  --boot-disk-type=pd-balanced \
  --tags=http-server,https-server
```

(For Debian, use `--image-family=debian-12 --image-project=debian-cloud`.)

### 1.2 SSH in

```bash
gcloud compute ssh multiwp-test --zone=us-central1-c
```

You're on the VM now. Everything below runs there as root (or `sudo`).

---

## Part 2 — Get the Repo onto the VM

The CLI hardcodes `/opt/wp/...` paths.

### Option A — HTTPS clone (public repo, simplest)

```bash
sudo git clone https://github.com/jackstiffer/MultiWordpress.git /opt/wp
```

### Option B — HTTPS clone with a fine-grained PAT (private repo)

Generate a read-only fine-grained PAT in GitHub → Settings → Developer settings → Fine-grained tokens. Then:

```bash
sudo git clone https://<TOKEN>@github.com/jackstiffer/MultiWordpress.git /opt/wp
```

### Option C — `scp` from your Mac (no GitHub auth on the VM)

On your **Mac**:
```bash
cd ~/Projects/MultiWordpress
tar czf /tmp/multiwp.tar.gz --exclude='.git' .
gcloud compute scp /tmp/multiwp.tar.gz multiwp-test:~/multiwp.tar.gz --zone=us-central1-c
```

On the VM:
```bash
sudo mkdir -p /opt/wp
sudo tar xzf ~/multiwp.tar.gz -C /opt/wp
sudo chown -R root:root /opt/wp
```

---

## Part 3 — Run the Setup Orchestrator

```bash
cd /opt/wp
sudo bash host/setup.sh
```

The script:

1. **Preflight** — verifies you're root, detects Ubuntu/Debian + codename, confirms cgroup v2.
2. **Survey** — checks every component (Docker, Caddy, secrets, wp.slice, shared infra, image, cron, symlinks, dashboard) and lists `✓ installed` / `◯ missing`.
3. **Plan** — shows you exactly what it will install, asks "Proceed?".
4. **Step-by-step** — each missing piece gets its own `[y/N]` prompt with a one-line description. Answer `n` to skip just that step (e.g., skip the dashboard if you only want the CLI).
5. **Smoke test** — runs the 70-check verifier at the end.

Re-running on a partially-configured VM is safe — already-installed pieces are detected and skipped automatically.

### Quick variants

```bash
sudo bash host/setup.sh --check    # survey only, change nothing
sudo bash host/setup.sh --yes      # non-interactive (CI / automation)
```

When the orchestrator finishes, it prints your VM's public IP and the next command:

```bash
sudo wp-create blog.example.com --admin-email you@example.com
```

---

## Part 4 — Provision your first site

After `setup.sh` exits cleanly:

```bash
sudo wp-create test1.dirtyvocal.com --admin-email you@example.com
```

Output prints:
- Admin URL + username + password (also saved to `/opt/wp/secrets/<slug>.env`).
- The Cloudflare DNS row to paste.
- The Caddy block to paste into your Caddyfile.
- Reference to the Cloudflare Cache Rule (one-time per zone).

### 4.1 Cloudflare DNS

In Cloudflare dashboard → **DNS → Records → Add Record**:

| Field | Value |
|---|---|
| Type | A |
| Name | `test1` (or whatever sub) |
| IPv4 | Your VM's external IP |
| Proxy | **Proxied** (orange cloud) |
| TTL | Auto |

Wait ~30s for propagation:
```bash
dig +short test1.dirtyvocal.com    # returns Cloudflare IPs (104.x or 172.x)
```

### 4.2 Cloudflare SSL/TLS mode

Cloudflare → **SSL/TLS → Overview → Full (Strict)**.

This *must* be Full (Strict). Flexible causes redirect loops with Caddy auto-HTTPS.

### 4.3 Paste the Caddy block

```bash
sudo nano /etc/caddy/Caddyfile     # paste at end
sudo systemctl reload caddy
sudo journalctl -u caddy -n 20     # check for errors
```

### 4.4 Cache Rule (one-time per zone)

Cloudflare → **Caching → Cache Rules → Create Rule** with the bypass cookie list from `templates/cloudflare-cache-rule.md`. Wildcard hostname (`*.dirtyvocal.com`) covers every WP site in the zone — make this rule once.

### 4.5 (Optional) Activate the page-cache plugin

```bash
sudo wp-exec test1_dirtyvocal_com plugin install super-page-cache-for-cloudflare --activate
```

### 4.6 Validate

```bash
# Site responds 200
curl -sI https://test1.dirtyvocal.com/ | head -5

# Cache: first MISS, second HIT
curl -sI https://test1.dirtyvocal.com/ | grep -i cf-cache-status
sleep 1
curl -sI https://test1.dirtyvocal.com/ | grep -i cf-cache-status
# expect: HIT

# Logged-in bypasses cache
curl -sI -H 'Cookie: wordpress_logged_in_x=y' https://test1.dirtyvocal.com/wp-admin/ | grep -i cf-cache-status
# expect: BYPASS or DYNAMIC

# Cached TTFB
curl -o /dev/null -s -w 'time_starttransfer: %{time_starttransfer}s\n' https://test1.dirtyvocal.com/
# expect: < 100ms
```

If `cf-cache-status: HIT` and TTFB < 100ms cached — **the stack works.**

---

## Part 5 — (Optional) Dashboard

If you skipped the dashboard during `setup.sh`, install it later:

```bash
sudo bash host/install-dashboard.sh
```

Then add a Caddy block (the install script prints it). Generate a basic_auth hash:

```bash
caddy hash-password
```

Paste the hash into the dashboard's Caddy block, reload Caddy, visit `https://dashboard.<your-domain>`.

---

## Part 6 — Cleanup (when test is done)

```bash
sudo wp-delete test1.dirtyvocal.com --yes
# Then in Cloudflare: remove DNS row + Caddy block.
```

To tear down the VM:
```bash
gcloud compute instances delete multiwp-test --zone=us-central1-c
```

---

## Common Errors

| Symptom | Cause | Fix |
|---|---|---|
| `cgroup v2 not detected` during preflight | Older Ubuntu (20.04 or earlier) or Debian 10 | Recreate VM with Ubuntu 22.04+ or Debian 12+ |
| `404 Not Found` on `download.docker.com/.../<codename>/Release` | (only if you're installing Docker manually outside of `setup.sh`) wrong distro path | Use `setup.sh` — it auto-detects. Or recover with `sudo rm /etc/apt/sources.list.d/docker.list` and re-run the orchestrator. |
| `port is already allocated` on `docker compose up` | Another stack already using 13306 / 16379 / etc. | Use a *dummy* VM for testing. Production VM coexists if AudioStoryV2 only uses 3000/6379 — verify first with `sudo ss -tlnp`. |
| `522 Connection Timed Out` from Cloudflare | Caddy not reloaded, or firewall blocking 443 | `sudo systemctl reload caddy`; verify GCP firewall has http-server + https-server tags |
| `502 Bad Gateway` from Cloudflare | Caddy can't reach FPM | `wp-list` PORT column must match `php_fastcgi 127.0.0.1:<port>` in the Caddy block |
| `ERR_TOO_MANY_REDIRECTS` | Cloudflare SSL/TLS = Flexible | Change to **Full (Strict)** |
| `cf-cache-status: MISS` always | Cache Rule missing or page-cache plugin not active | Verify rule in Cloudflare dashboard; install `super-page-cache-for-cloudflare` plugin |
| `wp-create` says "site already exists" | Slug already in `sites.json` from a partial run | `sudo wp-delete <slug> --yes` then retry, or `sudo wp-create <domain> --resume <slug>` |
| `Access denied for user 'root'@'localhost'` from `wp-create` | MariaDB volume seeded with old password (e.g., placeholder) before `.env` was rotated | **Nuke + restart** (safe if no real sites): `sudo docker compose -f compose/compose.yaml down -v` → `sudo bash host/setup.sh` re-runs cleanly. |
| `sudo wp-create: command not found` | `secure_path` strips PATH | `setup.sh` symlinks to `/usr/local/bin` automatically. If skipped: `sudo ln -s /opt/wp/bin/wp-* /usr/local/bin/`. |

---

## What `setup.sh` Doesn't Do

- **Cloudflare DNS / Cache Rule paste** — manual on purpose (anti-feature: no Cloudflare API tokens on the VM).
- **Caddyfile edits** — host Caddy is shared with AudioStoryV2; programmatic edits are too risky. The CLI prints exact blocks for you to paste.
- **Domain ownership / cert provisioning** — Caddy auto-provisions Let's Encrypt on first request; nothing to configure here.
- **Backups** — explicitly out of scope (use VM snapshots or `wp-exec <slug> wp db export`).

---

## Quick Reference (after deploy)

```bash
sudo wp-create <domain>            # provision a site
sudo wp-list                       # show all sites
sudo wp-stats                      # cluster + per-site usage
sudo wp-pause <slug>               # stop a site (frees RAM)
sudo wp-resume <slug>              # start it back
sudo wp-logs <slug> -f             # tail logs
sudo wp-exec <slug> <wp-cli-args>  # passthrough
sudo wp-delete <slug>              # full teardown

sudo bash host/setup.sh --check    # re-survey state anytime
```

---

## Cross-references

- [`docs/cli.md`](cli.md) — full CLI reference (every flag, every output)
- [`docs/first-site-e2e.md`](first-site-e2e.md) — operator runbook for the cache-promise validation
- [`docs/operational.md`](operational.md) — cron + metrics troubleshooting
- [`docs/caddy-cloudflare.md`](caddy-cloudflare.md) — reverse proxy + edge cache details
- [`docs/scaling-cliff.md`](scaling-cliff.md) — when this single-VM design has been outgrown
- [`dashboard/README.md`](../dashboard/README.md) — dashboard install + Caddy basic_auth
