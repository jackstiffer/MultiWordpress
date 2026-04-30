// =============================================================================
// dashboard/src/static/app.js — vanilla JS UI logic
// =============================================================================
//
// - Polls /api/sites.json every 5s (DASH-01).
// - Renders cluster header + sites table.
// - Add-site form -> POST /api/site -> shows creds + Caddy block in modal.
// - Pause/Resume/Delete buttons -> confirm -> POST/DELETE -> refresh.
// - Logs button -> GET /api/logs?slug=... -> shows in modal.
// - All write fetches send X-CSRF header from <meta name="csrf">.
// - Any non-2xx response surfaces as a red banner.
// =============================================================================

(function () {
    'use strict';

    const POLL_MS = 5000;

    const $ = (sel) => document.querySelector(sel);
    const csrfMeta = document.querySelector('meta[name="csrf"]');
    let csrf = csrfMeta ? csrfMeta.getAttribute('content') : '';

    function showError(msg) {
        const b = $('#error-banner');
        b.textContent = msg;
        b.hidden = false;
        clearTimeout(showError._t);
        showError._t = setTimeout(() => { b.hidden = true; }, 6000);
    }

    function fmtMB(bytes) {
        if (bytes == null) return '—';
        return Math.round(bytes / 1048576) + ' MB';
    }
    function fmtGB(bytes) {
        if (bytes == null) return '—';
        return (bytes / 1073741824).toFixed(2) + ' GB';
    }
    function fmtPct(p) {
        if (p == null) return '—';
        return p + '%';
    }

    function statusBadge(status) {
        const s = (status || '').toLowerCase();
        const cls = ['running','paused','stopped','partial'].includes(s) ? s : 'partial';
        return `<span class="badge badge-${cls}">${s || '?'}</span>`;
    }

    function renderCluster(data) {
        const cluster = data.cluster || {};
        const audio   = data.audiostory || {};
        const disk    = data.disk || {};

        $('#pool-now').textContent = (cluster.pool_used_now_bytes != null && cluster.pool_max_bytes)
            ? `${fmtGB(cluster.pool_used_now_bytes)} / ${fmtGB(cluster.pool_max_bytes)} (${fmtPct(cluster.pool_pct_now)})`
            : '—';

        $('#pool-peak').textContent = (cluster.pool_peak_24h_bytes != null)
            ? `${fmtGB(cluster.pool_peak_24h_bytes)} (${fmtPct(cluster.pool_pct_peak)})`
            : '—';

        $('#audiostory').textContent = audio.detected
            ? `${audio.status} (restarts: ${audio.restart_count != null ? audio.restart_count : '—'})`
            : 'not detected';

        $('#disk').textContent = (disk.used && disk.total)
            ? `${disk.used} / ${disk.total} (${disk.percent_used})`
            : '—';

        // Pool bar.
        const pct = cluster.pool_pct_now;
        const bar = $('#pool-bar-fill');
        bar.style.width = (pct != null ? pct : 0) + '%';
        bar.classList.remove('warn', 'crit');
        const peakPct = cluster.pool_pct_peak;
        if (peakPct != null && peakPct >= 100) bar.classList.add('crit');
        else if (peakPct != null && peakPct >= 90) bar.classList.add('warn');
        $('#pool-bar-label').textContent = `pool: now ${fmtPct(pct)} | 24h peak ${fmtPct(peakPct)}`;

        const card = $('#cluster-card');
        card.classList.remove('warn', 'crit');
        if (peakPct != null && peakPct >= 100) card.classList.add('crit');
        else if (peakPct != null && peakPct >= 90) card.classList.add('warn');
    }

    function renderSites(sites) {
        const tbody = $('#sites-tbody');
        if (!sites || sites.length === 0) {
            tbody.innerHTML = '<tr><td colspan="8" class="empty">No sites registered. Click "+ Add site" to create one.</td></tr>';
            return;
        }
        const rows = sites.map((s) => {
            const slug   = String(s.slug || '');
            const domain = String(s.domain || '');
            const status = String(s.status || 'unknown');
            const memNow  = fmtMB(s.current_mem_bytes);
            const memPeak = fmtMB(s.peak_mem_bytes_24h);
            const cpuPeak = (s.peak_cpu_pct_24h != null) ? s.peak_cpu_pct_24h + '%' : '—';
            const dbConn  = (s.db_conn_now != null) ? s.db_conn_now : '—';

            const isPaused = status === 'paused';
            const toggleLbl = isPaused ? 'Resume' : 'Pause';
            const toggleAct = isPaused ? 'resume' : 'pause';

            const safeSlug   = escapeHtml(slug);
            const safeDomain = escapeHtml(domain);

            return `<tr data-slug="${safeSlug}">
                <td>${safeSlug}</td>
                <td>${safeDomain}</td>
                <td>${statusBadge(status)}</td>
                <td class="num">${memNow}</td>
                <td class="num">${memPeak}</td>
                <td class="num">${cpuPeak}</td>
                <td class="num">${dbConn}</td>
                <td>
                    <button class="btn btn-small" data-action="logs">Logs</button>
                    <button class="btn btn-small" data-action="${toggleAct}">${toggleLbl}</button>
                    <button class="btn btn-small btn-danger" data-action="delete">Delete</button>
                </td>
            </tr>`;
        }).join('');
        tbody.innerHTML = rows;
    }

    function escapeHtml(s) {
        return String(s).replace(/[&<>"']/g, (c) => ({
            '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
        }[c]));
    }

    async function fetchSites() {
        try {
            const r = await fetch('/api/sites.json', { credentials: 'same-origin' });
            if (!r.ok) throw new Error(`HTTP ${r.status}`);
            const data = await r.json();
            renderCluster(data);
            renderSites(data.sites || []);
            const ts = new Date();
            $('#last-updated').textContent = 'updated ' + ts.toLocaleTimeString();
        } catch (e) {
            showError('Failed to refresh sites: ' + e.message);
        }
    }

    // Initial paint from server-embedded data (avoids first-fetch flash).
    if (window.__INITIAL_DATA__) {
        renderCluster(window.__INITIAL_DATA__);
        renderSites(window.__INITIAL_DATA__.sites || []);
        $('#last-updated').textContent = 'initial render';
    }

    // Polling.
    setInterval(fetchSites, POLL_MS);
    fetchSites(); // refresh once after initial render to get fresher data

    // -------------------------------------------------------------------------
    // Modal helpers
    // -------------------------------------------------------------------------
    function openModal(id)  { document.getElementById(id).hidden = false; }
    function closeModal(id) { document.getElementById(id).hidden = true; }
    document.body.addEventListener('click', (ev) => {
        const close = ev.target.closest('[data-close]');
        if (close) closeModal(close.getAttribute('data-close'));
    });

    // -------------------------------------------------------------------------
    // Add-site flow
    // -------------------------------------------------------------------------
    $('#btn-add-site').addEventListener('click', () => {
        $('#form-add-site').reset();
        $('#add-site-progress').hidden = true;
        $('#add-site-result').hidden = true;
        $('#add-site-result').innerHTML = '';
        $('#form-add-site').hidden = false;
        $('#btn-submit-add').disabled = false;
        openModal('modal-add');
    });

    $('#form-add-site').addEventListener('submit', async (ev) => {
        ev.preventDefault();
        const fd = new FormData(ev.target);
        const body = {
            domain: String(fd.get('domain') || '').trim(),
            admin_email: String(fd.get('admin_email') || '').trim(),
        };
        $('#btn-submit-add').disabled = true;
        $('#add-site-progress').hidden = false;
        try {
            const r = await fetch('/api/site', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'X-CSRF': csrf },
                body: JSON.stringify(body),
                credentials: 'same-origin',
            });
            const data = await r.json();
            $('#add-site-progress').hidden = true;
            if (!r.ok || !data.success) {
                $('#add-site-result').hidden = false;
                $('#add-site-result').innerHTML =
                    `<div class="banner banner-error">Failed: ${escapeHtml(data.error || 'unknown error')}</div>` +
                    (data.stderr ? `<pre class="logs-pre">${escapeHtml(data.stderr)}</pre>` : '');
                $('#btn-submit-add').disabled = false;
                return;
            }
            // Success: render creds + DNS + Caddy block.
            $('#form-add-site').hidden = true;
            $('#add-site-result').hidden = false;
            $('#add-site-result').innerHTML =
                `<div class="creds-warn">Save these now — they will not be shown again.</div>` +
                `<div><strong>Site URL:</strong> https://${escapeHtml(data.domain || body.domain)}</div>` +
                `<div><strong>Admin user:</strong> ${escapeHtml(data.admin_user || '')}</div>` +
                `<div><strong>Admin password:</strong> ${escapeHtml(data.admin_password || '')}</div>` +
                `<div><strong>Admin email:</strong> ${escapeHtml(data.admin_email || '')}</div>` +
                (data.cloudflare_dns ? `<h4>Cloudflare DNS row</h4><pre class="creds-block">${escapeHtml(data.cloudflare_dns)}</pre>` : '') +
                (data.caddy_block    ? `<h4>Caddy block</h4><pre class="creds-block">${escapeHtml(data.caddy_block)}</pre>` : '') +
                `<div class="modal-actions"><button class="btn" data-close="modal-add">Close</button></div>`;

            // Refresh CSRF token from a fresh page-meta refresh:
            // the server rotated the token after a successful write op. Easiest
            // is to refetch / on next reload, but for now refresh sites table.
            fetchSites();
        } catch (e) {
            $('#add-site-progress').hidden = true;
            $('#add-site-result').hidden = false;
            $('#add-site-result').innerHTML =
                `<div class="banner banner-error">Network error: ${escapeHtml(e.message)}</div>`;
            $('#btn-submit-add').disabled = false;
        }
    });

    // -------------------------------------------------------------------------
    // Per-row actions (logs / pause / resume / delete)
    // -------------------------------------------------------------------------
    document.querySelector('#sites-tbody').addEventListener('click', async (ev) => {
        const btn = ev.target.closest('button[data-action]');
        if (!btn) return;
        const tr = btn.closest('tr[data-slug]');
        if (!tr) return;
        const slug = tr.getAttribute('data-slug');
        const action = btn.getAttribute('data-action');

        if (action === 'logs') {
            $('#logs-title').textContent = 'Logs — ' + slug;
            $('#logs-content').textContent = 'Loading…';
            openModal('modal-logs');
            try {
                const r = await fetch('/api/logs?slug=' + encodeURIComponent(slug), { credentials: 'same-origin' });
                const data = await r.json();
                $('#logs-content').textContent = data.logs || data.error || '(no output)';
            } catch (e) {
                $('#logs-content').textContent = 'Error: ' + e.message;
            }
            return;
        }

        if (action === 'pause' || action === 'resume') {
            if (!confirm(`${action === 'pause' ? 'Pause' : 'Resume'} site "${slug}"?`)) return;
            await mutateSite(slug, action, 'POST');
            return;
        }

        if (action === 'delete') {
            const confirmText = prompt(`Type the slug "${slug}" to confirm DELETE (this drops the DB and removes the container):`);
            if (confirmText !== slug) {
                showError('Delete cancelled — slug did not match.');
                return;
            }
            await mutateSite(slug, '', 'DELETE');
            return;
        }
    });

    async function mutateSite(slug, action, method) {
        const path = action ? `/api/site/${encodeURIComponent(slug)}/${action}` : `/api/site/${encodeURIComponent(slug)}`;
        try {
            const r = await fetch(path, {
                method,
                headers: { 'X-CSRF': csrf },
                credentials: 'same-origin',
            });
            const data = await r.json();
            if (!r.ok || !data.success) {
                showError(`${action || 'delete'} failed: ${data.stderr || data.error || 'unknown'}`);
                return;
            }
            // After a successful write, the server rotated the CSRF token. We
            // need a fresh one for any subsequent write. Reload page meta.
            await refreshCsrf();
            fetchSites();
        } catch (e) {
            showError('Request failed: ' + e.message);
        }
    }

    // After a successful write, fetch a fresh page to read the rotated CSRF.
    // Cheaper alternative: hit a tiny endpoint — but for simplicity we re-fetch
    // index.php and read meta. We avoid full reload to keep modal state.
    async function refreshCsrf() {
        try {
            const r = await fetch('/', { credentials: 'same-origin' });
            const html = await r.text();
            const m = html.match(/<meta name="csrf" content="([^"]+)"/);
            if (m) csrf = m[1];
        } catch (_) { /* non-fatal */ }
    }

})();
