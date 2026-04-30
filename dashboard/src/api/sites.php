<?php
// =============================================================================
// GET /api/sites.json — merged cluster + sites + audiostory snapshot
// =============================================================================
//
// Caching: 4-second file cache at /tmp/wp-dashboard-stats.json. Below the
// dashboard's 5s polling interval so multiple browser tabs share one snapshot
// while still feeling live.
// =============================================================================

require_once __DIR__ . '/../lib/render.php';
require_once __DIR__ . '/../lib/cli.php';
require_once __DIR__ . '/../lib/auth.php';

session_boot();

if (($_SERVER['REQUEST_METHOD'] ?? 'GET') !== 'GET') {
    json_error('Method not allowed', 405);
}

const CACHE_PATH = '/tmp/wp-dashboard-stats.json';
const CACHE_TTL  = 4;

$now = time();
if (is_file(CACHE_PATH)) {
    $mtime = @filemtime(CACHE_PATH);
    if ($mtime !== false && ($now - $mtime) < CACHE_TTL) {
        $cached = @file_get_contents(CACHE_PATH);
        if ($cached !== false && $cached !== '') {
            header('Content-Type: application/json; charset=utf-8');
            header('Cache-Control: no-store');
            header('X-Cache: HIT');
            echo $cached;
            exit;
        }
    }
}

// Fresh fetch — two CLI calls.
$list_r  = call_cli_json('wp-list',  []);
$stats_r = call_cli_json('wp-stats', []);

$sites_payload = ['sites' => []];
if ($list_r !== null && is_array($list_r[0])) {
    $sites_payload = $list_r[0];
}

$cluster_payload = [
    'cluster'              => null,
    'audiostory'           => null,
    'disk'                 => null,
    'metrics_json_present' => false,
    'sites'                => [],
];
if ($stats_r !== null && is_array($stats_r[0])) {
    $cluster_payload = $stats_r[0] + $cluster_payload;
}

// Merge per-site rows: wp-list provides slug/domain/status/port/redis_db, while
// wp-stats provides current/peak mem/cpu/db_conn. Build a map and zip.
$by_slug = [];
foreach ($sites_payload['sites'] ?? [] as $row) {
    if (!is_array($row) || empty($row['slug'])) continue;
    $by_slug[$row['slug']] = $row;
}
foreach ($cluster_payload['sites'] ?? [] as $row) {
    if (!is_array($row) || empty($row['slug'])) continue;
    $slug = $row['slug'];
    if (!isset($by_slug[$slug])) {
        $by_slug[$slug] = $row;
    } else {
        $by_slug[$slug] = array_merge($by_slug[$slug], $row);
    }
}

// Sort by 24h-peak mem descending, with nulls last (matches wp-list/wp-stats convention).
$rows = array_values($by_slug);
usort($rows, function ($a, $b) {
    $ap = $a['peak_mem_bytes_24h'] ?? null;
    $bp = $b['peak_mem_bytes_24h'] ?? null;
    if ($ap === null && $bp === null) return 0;
    if ($ap === null) return 1;
    if ($bp === null) return -1;
    return $bp <=> $ap;
});

$response = [
    'cluster'              => $cluster_payload['cluster']    ?? null,
    'audiostory'           => $cluster_payload['audiostory'] ?? null,
    'disk'                 => $cluster_payload['disk']       ?? null,
    'metrics_json_present' => (bool)($cluster_payload['metrics_json_present'] ?? false),
    'sites'                => $rows,
    'fetched_at'           => gmdate('c', $now),
];

$encoded = json_encode($response, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);

// Write cache atomically (rename). Failures are non-fatal — we still respond.
$tmp = CACHE_PATH . '.tmp.' . getmypid();
if (@file_put_contents($tmp, $encoded) !== false) {
    @chmod($tmp, 0644);
    @rename($tmp, CACHE_PATH);
}

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('X-Cache: MISS');
echo $encoded;
