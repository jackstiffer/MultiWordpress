<?php
// =============================================================================
// dashboard/src/index.php — main page (server-rendered shell + JS hydration)
// =============================================================================
//
// Renders the static page chrome and embeds the initial /api/sites.json
// payload inline (window.__INITIAL_DATA__) so the first paint shows real data
// without an extra round-trip. JS then takes over and polls every 5s.
// =============================================================================

require_once __DIR__ . '/lib/render.php';
require_once __DIR__ . '/lib/auth.php';
require_once __DIR__ . '/lib/cli.php';

session_boot();
$csrf = csrf_token();

// Best-effort initial fetch — same logic as /api/sites.json but inline so we
// can render server-side without a self-HTTP loopback. Failures degrade to an
// empty payload; JS will refetch on first poll.
$initial = ['cluster' => null, 'audiostory' => null, 'disk' => null, 'sites' => [], 'metrics_json_present' => false];
$list_r  = call_cli_json('wp-list',  []);
$stats_r = call_cli_json('wp-stats', []);
if ($stats_r !== null && is_array($stats_r[0])) {
    $initial = $stats_r[0] + $initial;
}
$by_slug = [];
if ($list_r !== null && is_array($list_r[0])) {
    foreach ($list_r[0]['sites'] ?? [] as $row) {
        if (is_array($row) && !empty($row['slug'])) $by_slug[$row['slug']] = $row;
    }
}
foreach ($initial['sites'] ?? [] as $row) {
    if (is_array($row) && !empty($row['slug'])) {
        $s = $row['slug'];
        $by_slug[$s] = isset($by_slug[$s]) ? array_merge($by_slug[$s], $row) : $row;
    }
}
$rows = array_values($by_slug);
usort($rows, function ($a, $b) {
    $ap = $a['peak_mem_bytes_24h'] ?? null;
    $bp = $b['peak_mem_bytes_24h'] ?? null;
    if ($ap === null && $bp === null) return 0;
    if ($ap === null) return 1;
    if ($bp === null) return -1;
    return $bp <=> $ap;
});
$initial['sites'] = $rows;

?><!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <meta name="csrf" content="<?= e($csrf) ?>">
    <title>MultiWordpress Dashboard</title>
    <link rel="stylesheet" href="/static/style.css">
</head>
<body>

<header class="topbar">
    <h1>MultiWordpress</h1>
    <div class="meta">
        <span id="last-updated">—</span>
        <span class="user">user: <?= e(getenv('DASHBOARD_USER') ?: 'wpdash') ?></span>
    </div>
</header>

<div id="error-banner" class="banner banner-error" hidden></div>

<section class="card cluster" id="cluster-card">
    <h2>Cluster</h2>
    <div class="cluster-grid">
        <div class="stat">
            <div class="label">wp.slice pool — now</div>
            <div class="value" id="pool-now">—</div>
        </div>
        <div class="stat">
            <div class="label">wp.slice pool — 24h peak</div>
            <div class="value" id="pool-peak">—</div>
        </div>
        <div class="stat">
            <div class="label">AudioStoryV2</div>
            <div class="value" id="audiostory">—</div>
        </div>
        <div class="stat">
            <div class="label">Disk /opt/wp</div>
            <div class="value" id="disk">—</div>
        </div>
    </div>
    <div class="pool-bar-wrapper">
        <div class="pool-bar"><div id="pool-bar-fill" class="pool-bar-fill"></div></div>
        <div class="pool-bar-label" id="pool-bar-label">—</div>
    </div>
</section>

<section class="card sites">
    <div class="card-header">
        <h2>Sites</h2>
        <button id="btn-add-site" class="btn btn-primary">+ Add site</button>
    </div>
    <table class="sites-table">
        <thead>
            <tr>
                <th>SLUG</th>
                <th>DOMAIN</th>
                <th>STATUS</th>
                <th class="num">MEM-NOW</th>
                <th class="num">MEM-PEAK-24H</th>
                <th class="num">CPU-PEAK-24H</th>
                <th class="num">DB-CONN</th>
                <th>ACTIONS</th>
            </tr>
        </thead>
        <tbody id="sites-tbody">
            <tr><td colspan="8" class="empty">Loading…</td></tr>
        </tbody>
    </table>
</section>

<!-- Add-site modal -->
<div id="modal-add" class="modal" hidden>
    <div class="modal-body">
        <div class="modal-head">
            <h3>Add new site</h3>
            <button class="modal-close" data-close="modal-add">×</button>
        </div>
        <form id="form-add-site">
            <label>
                <span>Domain</span>
                <input type="text" name="domain" required pattern="[a-z0-9.\-]+" maxlength="64"
                       placeholder="blog.example.com">
            </label>
            <label>
                <span>Admin email</span>
                <input type="email" name="admin_email" required maxlength="128"
                       placeholder="me@example.com">
            </label>
            <div class="modal-actions">
                <button type="button" class="btn" data-close="modal-add">Cancel</button>
                <button type="submit" class="btn btn-primary" id="btn-submit-add">Create site</button>
            </div>
        </form>
        <div id="add-site-progress" class="progress" hidden>
            Provisioning… this can take 30–90 seconds. Do not close this tab.
        </div>
        <div id="add-site-result" hidden></div>
    </div>
</div>

<!-- Logs modal -->
<div id="modal-logs" class="modal" hidden>
    <div class="modal-body modal-wide">
        <div class="modal-head">
            <h3 id="logs-title">Logs</h3>
            <button class="modal-close" data-close="modal-logs">×</button>
        </div>
        <pre id="logs-content" class="logs-pre">Loading…</pre>
    </div>
</div>

<script>
window.__INITIAL_DATA__ = <?= json_encode($initial, JSON_UNESCAPED_SLASHES | JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT) ?>;
</script>
<script src="/static/app.js"></script>
</body>
</html>
