<?php
// =============================================================================
// DELETE /api/site/<slug>
// =============================================================================

require_once __DIR__ . '/../lib/render.php';
require_once __DIR__ . '/../lib/cli.php';
require_once __DIR__ . '/../lib/auth.php';

session_boot();
require_csrf();

$method = $_SERVER['REQUEST_METHOD'] ?? '';
if ($method !== 'DELETE') {
    json_error('Method not allowed', 405);
}

$slug = $_GET['slug'] ?? '';
if (!is_string($slug) || $slug === '' || !preg_match('/^[a-z0-9_]+$/', $slug)) {
    json_error('Invalid slug', 400);
}

$r = call_cli('wp-delete', [$slug, '--yes'], ['timeout_sec' => 120]);

$parsed = json_decode($r['stdout'], true);
$success = ($r['exit_code'] === 0);

json_response([
    'success'   => $success,
    'slug'      => $slug,
    'exit_code' => $r['exit_code'],
    'result'    => is_array($parsed) ? $parsed : null,
    'raw'       => is_array($parsed) ? null : $r['stdout'],
    'stderr'    => $success ? null : $r['stderr'],
], $success ? 200 : 500);
