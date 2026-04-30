# Scaling Cliff — When This Single-VM Design Has Been Outgrown

This stack is designed for ~5–20 personal blogs on a 2 vCPU / 8 GB GCP VM that also runs one Next.js app (AudioStoryV2). When it stops being a good fit, the symptoms are concrete and the migration paths are well-trodden. This doc helps you tell which signal you're seeing and what to do.

## The Four Warning Signs

If two of these are true sustained over 7+ days, you've outgrown the design.

### Sign 1 — Pool saturation

**Detection**:
```bash
# Live %
echo "scale=1; $(cat /sys/fs/cgroup/wp.slice/memory.current) / 4294967296 * 100" | bc

# 24h peak %
cat /opt/wp/state/metrics.json | jq -r '
  (.cluster.pool_used_peak_bytes / 4294967296 * 100) as $pct
  | "\($pct | floor)%"
'

# Or just look at wp-stats — pool line color: green < 75%, yellow 75–90%, red > 90%
wp-stats
```

**What it means**: the 4 GB cluster cap is no longer enough to absorb your read/write workload. Even after pausing the heaviest site, peaks stay near the ceiling.

**What to do**: see migration paths below. Vertical (bigger VM) is the cheapest first step.

### Sign 2 — MariaDB connection saturation

**Detection**:
```bash
# Per-site connection count (live snapshot)
docker exec wp-mariadb mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e \
  "SELECT user, COUNT(*) AS conns FROM information_schema.processlist WHERE user LIKE 'wp_%' GROUP BY user ORDER BY conns DESC;"

# 24h peak via metrics.json
cat /opt/wp/state/metrics.json | jq '.sites | to_entries | map({slug: .key, peak: .value.db_conn_peak}) | sort_by(.peak) | reverse | .[0:5]'
```

**What it means**: at least one site is sustained at the per-user `MAX_USER_CONNECTIONS=40` cap. Either it's genuinely busy, or a plugin is leaking connections.

**What to do**:
- First: `wp-exec <slug> plugin list --status=active` and look for plugins known to leak (some search/analytics plugins do).
- Second: bump that site's connection cap by editing the GRANT manually and bumping the constant in `bin/_lib.sh`. Single-site tunable for now.
- Long-term: split MariaDB to its own VM (or managed Cloud SQL).

### Sign 3 — AudioStoryV2 OOM-killed or restarting

**Detection**:
```bash
# Restart count climbing
docker inspect $(docker ps --filter name=audiostory --format '{{.Names}}' | head -1) \
  --format '{{.RestartCount}}'

# OOM kills in dmesg
sudo dmesg | grep -iE 'killed.*audiostory|out of memory'
```

**What it means**: pool isolation isn't enough. Kernel is reclaiming AudioStoryV2's pages under cluster-wide pressure, or `wp.slice` is still swelling beyond what AudioStoryV2 needs.

**What to do**:
1. Add a hard `mem_limit` on AudioStoryV2's compose service (e.g., 2g) so it's protected by its own cgroup ceiling.
2. Lower `wp.slice` `MemoryMax` from 4G to 3G to leave more headroom.
3. If that's not enough, see migration paths.

### Sign 4 — Disk > 70%

**Detection**:
```bash
df -h /opt/wp /var/lib/docker /
du -sh /opt/wp/sites/*/wp-content/uploads 2>/dev/null | sort -h | tail -5
docker system df
```

**What it means**: log caps are working (10 MB × 3 per container) but uploads or DB are growing faster than expected.

**What to do**: see Disk Hygiene below. If still > 70% after cleanup, attach a separate disk for `/opt/wp/sites/` and bind-mount.

## Migration Paths

In order of complexity, cheapest first:

### A — Bump the VM size (10 minutes)

Cheapest. Most likely the right answer when sign 1 alone is firing.

1. `sudo systemctl stop docker` (warns visitors with cached pages still served by Cloudflare).
2. In GCP console: VM instance → Edit → Machine type → `n2-standard-4` (4 vCPU / 16 GB).
3. SSH back in. `sudo systemctl start docker`.
4. Bump `wp.slice` `MemoryMax` to 8G:
   ```bash
   sudo sed -i 's/MemoryMax=4G/MemoryMax=8G/' /etc/systemd/system/wp.slice
   sudo systemctl daemon-reload
   ```
5. `docker compose -f compose/compose.yaml up -d` to verify infra returns. Run `wp-list` to confirm sites are up.

Cost change: roughly 2× the VM bill.

### B — Move the heaviest site to its own VM

When one specific site is the noisy neighbor.

1. Provision a second VM identical to the first (n2-standard-2).
2. Run Phase 1 + Phase 2 setup (this repo's runbook) on the new VM. Bring up `wp-mariadb`, `wp-redis`, `wp.slice`.
3. On the old VM: `wp-pause <slug>`.
4. `mysqldump --single-transaction wp_<slug> > <slug>.sql` from the old VM.
5. SCP `<slug>.sql` and `/opt/wp/sites/<slug>/wp-content/` and `/opt/wp/secrets/<slug>.env` to the new VM.
6. On the new VM: `mysql ... < <slug>.sql`, restore wp-content, write the secrets file, then run `wp-create --resume <slug>`.
7. Update Cloudflare DNS to point `<domain>` at the new VM.
8. On the old VM: `wp-delete <slug> --yes`.

### C — Move MariaDB to a managed service

When sign 2 is firing and the DB is the bottleneck.

1. Provision Cloud SQL (MySQL or MariaDB-compatible). Same region as the VM.
2. Update `compose/compose.yaml` shared-infra: remove the `wp-mariadb` service.
3. Update `bin/_lib.sh` `DB_HOST_INTERNAL` to the Cloud SQL private IP.
4. Update each site's compose file to point at the new host.
5. `docker compose down wp-mariadb`; verify sites still work via Cloud SQL.

This is real work — 2–4 hours including testing — but it gives you DB scaling without VM size constraints.

### D — Adopt Kubernetes

**Anti-recommendation for this scale.** If you're considering Kubernetes for ~20 personal blogs, you're solving the wrong problem. The complexity tax of k8s (control plane, ingress, persistent volumes, secrets management, monitoring stack) far exceeds the savings unless you're running 100+ sites or doing CI/CD-style frequent deploys.

If you do go this route: GKE Autopilot is the lowest-friction option. Migration would essentially be re-implementing this whole stack as a Helm chart — count on a multi-week rebuild.

## Decision Matrix

| Signal | First action | If insufficient |
|--------|--------------|-----------------|
| Sign 1 alone (pool) | Path A (bump VM) | Path B (split heaviest) |
| Sign 2 alone (DB) | Bump per-site GRANT | Path C (managed DB) |
| Sign 3 alone (AudioStory) | Hard cap AudioStoryV2 + lower wp.slice | Path A (more headroom) |
| Sign 4 alone (disk) | Clean uploads/DB (see hygiene) | Attach separate disk |
| Multiple signs | Path A first (often fixes the others) | Then revisit |

## Disk Hygiene (preempt sign 4)

The 10 MB × 3 log caps prevent log explosion. The non-log growth sources:

```bash
# Largest uploads directories
du -sh /opt/wp/sites/*/wp-content/uploads 2>/dev/null | sort -h | tail -5

# Largest DBs
docker exec wp-mariadb mariadb -uroot -p"$MARIADB_ROOT_PASSWORD" -e "
  SELECT table_schema AS db, ROUND(SUM(data_length + index_length)/1024/1024, 1) AS mb
  FROM information_schema.tables WHERE table_schema LIKE 'wp_%'
  GROUP BY table_schema ORDER BY mb DESC LIMIT 10;
"

# Docker image / build cache bloat
docker system df
docker image prune -a    # interactive — remove unused images
```

Per-site cleanup options:

```bash
# Expired transients (often 50–500 MB on long-running sites)
wp-exec <slug> transient delete --expired

# Old post revisions (also large)
wp-exec <slug> post delete $(wp-exec <slug> post list --post_type=revision --format=ids)

# Regenerate large image thumbnails (if you bumped WP image sizes)
wp-exec <slug> media regenerate --yes

# WooCommerce orders/sessions (if applicable)
wp-exec <slug> wc tool run db_update_routine
```

If `du -sh /opt/wp/sites/*/wp-content/uploads` shows one site at >2 GB and you're not running a media-heavy site, investigate uploads — often a backup plugin writing to wp-content instead of an external location.

## When to Revisit This Doc

- Annually, regardless of signals. The thresholds in this doc were calibrated against n2-standard-2 + WordPress 6.x. PHP/WP/MariaDB versions move; revisit when you bump any of them by a major version.
- Anytime a sign first crosses its threshold — before you act, re-read this doc to confirm the path.
- After any migration (Path A/B/C). Update site count, machine type, etc., in your own notes.

## Out-of-scope escape hatches

If your needs grow beyond what this doc covers (multi-region, blue-green, CI-driven deploys, multi-tenant SaaS): this stack is the wrong tool. Kubernetes (Path D) or a managed WordPress host (WP Engine / Kinsta / Pressable) is what you want at that point. This stack stays focused on "single-owner blog network on a single VM, coexisting with one other app". When that description no longer fits, switch.
