# From-Zero Deployment Guide

Step-by-step setup of MultiWordpress on a fresh GCP VM. Assumes nothing — installs Docker, all dependencies, and walks through to a working first site. Use this on a *dummy* VM first to validate the stack, then on your production VM.

**Time:** ~30 minutes from clicking "Create VM" to `cf-cache-status: HIT`.

---

## Part 1: Provision the VM

### 1.1 Create the GCP VM

In GCP console → **Compute Engine** → **VM instances** → **Create instance**:

| Setting | Value |
|---|---|
| Name | `multiwp-test` (or whatever) |
| Region/Zone | Same region as your production VM (`us-central1` for `dirtyvocal-nextjs`) |
| Machine type | **`n2-standard-2`** (2 vCPU, 8 GB) — match production for realistic test |
| Boot disk | **Ubuntu 22.04+ LTS** *or* **Debian 12 (bookworm)** — both have cgroup v2 by default. **20 GB** standard persistent disk (SSD). |
| Firewall | Allow HTTP traffic, Allow HTTPS traffic (both checked) |

Or via `gcloud` CLI from your local machine:

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

### 1.2 SSH in

```bash
gcloud compute ssh multiwp-test --zone=us-central1-c
```

You're now on the VM. Everything below runs there.

---

## Part 2: OS Prerequisites

### 2.1 Update + install base tools

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y \
  ca-certificates \
  curl \
  gnupg \
  git \
  jq \
  unzip
```

### 2.2 Verify cgroup v2

```bash
stat -fc %T /sys/fs/cgroup/
```

Must return **`cgroup2fs`**. Ubuntu 22.04+ uses cgroup v2 by default — if you got `tmpfs` (cgroup v1), you're on an older Ubuntu and the `wp.slice` install will refuse to run.

### 2.3 Install Docker (official Docker Engine, not docker.io)

The distro-shipped `docker.io` package is older. Use Docker's official apt repo. **The repo path differs by distro** (Debian and Ubuntu have separate URLs), so detect it:

```bash
# Detect distro family — sets DOCKER_DISTRO to "ubuntu" or "debian"
. /etc/os-release
case "$ID" in
  ubuntu) DOCKER_DISTRO=ubuntu ;;
  debian) DOCKER_DISTRO=debian ;;
  *)
    echo "Unsupported distro: $ID. This guide covers Ubuntu and Debian only."
    exit 1
    ;;
esac
echo "Using Docker repo for: $DOCKER_DISTRO ($VERSION_CODENAME)"

# Add Docker's GPG key
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL "https://download.docker.com/linux/${DOCKER_DISTRO}/gpg" -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add Docker repo (correct distro path)
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${DOCKER_DISTRO} \
  ${VERSION_CODENAME} stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

# Start + enable
sudo systemctl enable --now docker

# Verify
docker --version
docker compose version       # plugin form, not docker-compose binary
```

**If you got a `404 Not Found` on `download.docker.com/.../bookworm/Release`** during a previous run, that's the symptom of pointing at the wrong distro path (`ubuntu` URL with a Debian codename like `bookworm`, or vice versa). Recover with:

```bash
sudo rm /etc/apt/sources.list.d/docker.list
# Then re-run the block above — it auto-detects this time.
```

### 2.4 Install Caddy

The host reverse proxy. The stack does **not** ship its own Caddy; this is a host-level dep.

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
  sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
  sudo tee /etc/apt/sources.list.d/caddy-stable.list

sudo apt update
sudo apt install -y caddy

# Verify
caddy version
sudo systemctl status caddy           # should be active
```

Caddy auto-creates `/etc/caddy/Caddyfile` with a default placeholder. You'll edit it later.

### 2.5 Verify cron

Should already be installed. Confirm:

```bash
sudo systemctl status cron        # active (running)
```

If not running: `sudo systemctl enable --now cron`.

---

## Part 3: Clone the Repo

The CLI assumes the repo lives at `/opt/wp/` — paths are baked in.

```bash
sudo mkdir -p /opt/wp
sudo chown $USER:$USER /opt/wp        # temporary — for the clone
git clone git@github.com:jackstiffer/MultiWordpress.git /opt/wp
# OR via HTTPS if no SSH key on the VM:
# git clone https://github.com/jackstiffer/MultiWordpress.git /opt/wp

cd /opt/wp
ls         # should see compose/ image/ host/ bin/ templates/ docs/ dashboard/
```

If you used `chown` to your user, switch back to root for the install scripts:

```bash
sudo chown -R root:root /opt/wp
```

---

## Part 4: Install the Stack

### 4.1 Install `wp.slice` (cluster cgroup)

```bash
cd /opt/wp
sudo bash host/install-wp-slice.sh
```

Expected output: cgroup v2 verified, slice installed, `memory.max=4294967296` confirmed.

If it fails with "cgroup v1 detected" — your VM is older than expected. Either bump to Ubuntu 22.04+, or recreate the VM with the right image family.

### 4.2 Generate shared-infra secrets

One script handles it — generates a random `MARIADB_ROOT_PASSWORD`, writes
`/opt/wp/compose/.env` (mode 600), and symlinks `/opt/wp/.env` so the CLI
finds the secret at the expected path. Idempotent: re-running on a host
that already has a real password is a no-op.

```bash
cd /opt/wp
sudo bash host/init-secrets.sh
```

Verify:

```bash
sudo cat /opt/wp/.env       # MARIADB_ROOT_PASSWORD=<48-hex-chars>
ls -la /opt/wp/.env         # symlink → compose/.env
ls -la /opt/wp/compose/.env # mode 600, owner root
```

### 4.3 Bring up shared infra

```bash
cd /opt/wp
sudo docker compose -f compose/compose.yaml up -d

# Wait ~10s for healthchecks
sleep 10
sudo docker compose -f compose/compose.yaml ps      # both healthy
```

Verify:
```bash
docker network inspect wp-network | grep -i mtu     # 1460
sudo ss -tlnp | grep -E ':(13306|16379)'             # bound to 127.0.0.1 only
```

### 4.4 Build the per-site image

```bash
cd /opt/wp
sudo docker build -t multiwp:wordpress-6-php8.3 image/
```

Build takes ~2 minutes. Confirms WP-CLI baked in (`wp --info` smoke test runs during build).

```bash
sudo docker images | grep multiwp           # tag visible
```

### 4.5 Install metrics-poll cron

```bash
cd /opt/wp
sudo bash host/install-metrics-cron.sh
```

Expected: `/etc/cron.d/multiwordpress` created with the metrics-poll line. After 60 seconds, `/opt/wp/state/metrics.json` should appear.

```bash
sleep 90
sudo cat /opt/wp/state/metrics.json | jq '.cluster'
```

### 4.6 (Optional) Install dashboard

```bash
cd /opt/wp
sudo bash host/install-dashboard.sh
```

The script:
- Creates `wpdash` user (UID 1500)
- Installs sudoers fragment (validated with visudo)
- Builds dashboard image
- Brings up `wp-dashboard` container on `127.0.0.1:18900`

Then add a Caddy block for it (see Part 5.4 below).

### 4.7 Run the smoke test

```bash
sudo /opt/wp/bin/_smoke-test.sh
```

Should output **`✓ Smoke test passed (67 checks)`**.

### 4.8 Add `bin/` to PATH (convenience)

```bash
echo 'export PATH=/opt/wp/bin:$PATH' | sudo tee -a /etc/bash.bashrc
echo 'export PATH=/opt/wp/bin:$PATH' >> ~/.bashrc
# new sessions will pick this up; for current session:
export PATH=/opt/wp/bin:$PATH
```

Now `sudo wp-list` works from anywhere instead of `sudo /opt/wp/bin/wp-list`.

---

## Part 5: Test with a Real Domain

You need:
- A domain you control with DNS managed by Cloudflare.
- The VM's external IP: `gcloud compute instances describe multiwp-test --zone=us-central1-c --format='get(networkInterfaces[0].accessConfigs[0].natIP)'` (run on your local machine).

For a *dummy test*, use a sub-sub-domain you don't care about — e.g., `test1.dirtyvocal.com` if your zone is `dirtyvocal.com`.

### 5.1 Provision the site

```bash
sudo wp-create test1.dirtyvocal.com --admin-email you@example.com
```

Output prints the admin password, Caddy block, and DNS row. Copy them somewhere — you'll need them for the next steps.

### 5.2 Add the Cloudflare DNS row

In Cloudflare dashboard for the zone:
- **DNS → Records → Add Record**
- Type: A
- Name: `test1` (matches the subdomain you used)
- IPv4: your VM's external IP
- Proxy status: **Proxied** (orange cloud)
- TTL: Auto
- Save

Wait ~30 seconds for propagation:
```bash
dig +short test1.dirtyvocal.com         # returns Cloudflare IPs (104.x or 172.x)
```

### 5.3 Set Cloudflare SSL/TLS mode

In Cloudflare → **SSL/TLS** → **Overview** → set to **Full (Strict)**.

This must be Full (Strict). Flexible causes redirect loops with Caddy auto-HTTPS.

### 5.4 Paste the Caddy block

```bash
sudo nano /etc/caddy/Caddyfile      # or vi if you prefer
```

Paste the printed Caddy block at the end of the file. Save. Then:

```bash
sudo systemctl reload caddy
sudo journalctl -u caddy -n 20         # check for errors
```

If you also installed the dashboard, add its block too — `host/install-dashboard.sh` printed it. You'll need to generate a basic_auth password hash:

```bash
caddy hash-password
# Type a password, get bcrypt hash
```

Paste that hash into the dashboard's Caddy block.

### 5.5 Apply Cloudflare Cache Rule (one-time per zone)

In Cloudflare → **Caching** → **Cache Rules** → **Create Rule**:

- **Match**: hostname matches `*.dirtyvocal.com` (your zone), method = GET
- **Action**: Cache eligibility = Eligible, Edge TTL = Override = 4 hours
- **Bypass cache when** any of these cookies present:
  - `wordpress_logged_in_*`
  - `wp-postpass_*`
  - `comment_author_*`
  - `woocommerce_items_in_cart`
  - `woocommerce_cart_hash`

Save. Wait ~30 seconds for the rule to deploy.

### 5.6 (Optional) Activate the page-cache plugin

```bash
sudo wp-exec test1.dirtyvocal.com plugin install super-page-cache-for-cloudflare --activate
```

The plugin emits the right `Cache-Control` headers so Cloudflare actually caches.

### 5.7 Validate

```bash
# Site responds 200
curl -sI https://test1.dirtyvocal.com/ | head -5

# First request: MISS, second: HIT
curl -sI https://test1.dirtyvocal.com/ | grep -i cf-cache-status
sleep 1
curl -sI https://test1.dirtyvocal.com/ | grep -i cf-cache-status
# expect: HIT

# Logged-in request bypasses cache
curl -sI -H 'Cookie: wordpress_logged_in_x=y' https://test1.dirtyvocal.com/wp-admin/ | grep -i cf-cache-status
# expect: BYPASS or DYNAMIC

# TTFB cached (< 100ms)
curl -o /dev/null -s -w 'time_starttransfer: %{time_starttransfer}s\n' https://test1.dirtyvocal.com/
```

If you got `cf-cache-status: HIT` and TTFB < 100ms cached — **the stack works. Phase 2 success criterion #5 satisfied.**

### 5.8 (Optional) Visit the dashboard

If you installed it in 4.6 and added the Caddy block in 5.4:

```
https://dashboard.dirtyvocal.com
```

Log in with the basic_auth credentials you set. You'll see:
- Cluster: `wp.slice` pool used / 4 GB
- Sites table: just the one (test1)
- Add-site form, pause/resume/delete buttons, logs modal

---

## Part 6: Cleanup (when done testing)

### 6.1 Remove the test site

```bash
sudo wp-delete test1.dirtyvocal.com --yes
# Prints Caddy/DNS removal hints
```

Then in Cloudflare: remove the DNS row + Caddy block.

### 6.2 Tear down the VM

If you're done with the dummy test entirely:

```bash
# From your local machine
gcloud compute instances delete multiwp-test --zone=us-central1-c
```

---

## Common Errors

| Symptom | Cause | Fix |
|---|---|---|
| `cgroup v2 not detected` during install-wp-slice.sh | Older Ubuntu (20.04 or earlier) or Debian 10 | Recreate VM with Ubuntu 22.04+ or Debian 12+ |
| `404 Not Found` on `download.docker.com/.../<codename>/Release` during Docker install | Wrong distro path in `/etc/apt/sources.list.d/docker.list` (Ubuntu URL with Debian codename, or vice versa) | `sudo rm /etc/apt/sources.list.d/docker.list` then re-run the auto-detecting Docker install block in §2.3 |
| `Permission denied` reaching `/opt/wp/secrets/` | Not running as root | `sudo` everything |
| `port is already allocated` on `docker compose up` | AudioStoryV2 already running on this VM with conflicting port (only happens if you deploy on the prod VM directly) | Use a *dummy* VM for testing |
| `522 Connection Timed Out` from Cloudflare | Caddy not reloaded, or firewall blocking 443 | `sudo systemctl reload caddy`; verify GCP firewall has http-server + https-server tags |
| `502 Bad Gateway` from Cloudflare | Caddy can't reach FPM | Check `wp-list` PORT column matches `php_fastcgi 127.0.0.1:<port>` in Caddy block |
| `ERR_TOO_MANY_REDIRECTS` | Cloudflare SSL/TLS = Flexible | Change to **Full (Strict)** |
| `cf-cache-status: MISS` always | Cache Rule not applied or plugin missing | Verify rule in Cloudflare dashboard; install `super-page-cache-for-cloudflare` |
| `wp-create` says "site already exists" | Slug already in `/opt/wp/state/sites.json` from a partial run | `sudo wp-delete <slug> --yes` then retry, or `sudo wp-create <domain> --resume <slug>` |
| `docker compose up` hangs on healthcheck | `MARIADB_ROOT_PASSWORD` not set in `/opt/wp/.env` | `sudo cat /opt/wp/.env` to verify; restart with `docker compose down && docker compose up -d` |

---

## What This Doc Doesn't Cover

- **Production deployment alongside AudioStoryV2** — same install steps but you must ensure ports don't collide. AudioStoryV2 uses 3000 and 6379; this stack uses 13306, 16379, 18000+. Verify with `ss -tlnp` before bringing up shared infra.
- **Custom Caddy + Cloudflare integrations** (DNS-01 wildcard certs, etc.) — see [`docs/caddy-cloudflare.md`](caddy-cloudflare.md).
- **Day-to-day CLI usage** — see [`docs/cli.md`](cli.md).
- **Cron + metrics validation in production** — see [`docs/operational.md`](operational.md).
- **When to outgrow this stack** — see [`docs/scaling-cliff.md`](scaling-cliff.md).

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
```
