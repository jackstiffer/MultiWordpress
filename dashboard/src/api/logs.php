<?php
// =============================================================================
// GET /api/logs?slug=<slug> — last 200 lines of a site's container logs
// =============================================================================

require_once __DIR__ . '/../lib/render.php';
require_once __DIR__ . '/../lib/cli.php';
require_once __DIR__ . '/../lib/auth.php';

session_boot();

if (($_SERVER['REQUEST_METHOD'] ?? 'GET') !== 'GET') {
    json_error('Method not allowed', 405);
}

$slug = $_GET['slug'] ?? '';
if (!is_string($slug) || $slug === '' || !preg_match('/^[a-z0-9_]+$/', $slug)) {
    json_error('Invalid slug', 400);
}

// wp-logs has its own --tail flag; we don't append --json (it's text output).
$r = call_cli('wp-logs', [$slug, '--tail', '200'], ['append_json' => false, 'timeout_sec' => 30]);

if ($r['exit_code'] !== 0) {
    json_response([
        'slug'      => $slug,
        'logs'      => $r['stdout'],
        'error'     => trim($r['stderr']) !== '' ? 'wp-logs failed' : null,
        'exit_code' => $r['exit_code'],
    ], 200);
}

json_response([
    'slug' => $slug,
    'logs' => $r['stdout'],
]);
