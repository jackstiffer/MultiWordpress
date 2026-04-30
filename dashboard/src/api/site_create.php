<?php
// =============================================================================
// POST /api/site — create a new WordPress site via wp-create.
// Body: {"domain": "...", "admin_email": "..."}
// =============================================================================

require_once __DIR__ . '/../lib/render.php';
require_once __DIR__ . '/../lib/cli.php';
require_once __DIR__ . '/../lib/auth.php';

session_boot();
require_csrf();

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    json_error('Method not allowed', 405);
}

$raw  = file_get_contents('php://input');
$body = json_decode($raw ?: '', true);
if (!is_array($body)) {
    json_error('Invalid JSON body', 400);
}

$domain = trim((string)($body['domain']      ?? ''));
$email  = trim((string)($body['admin_email'] ?? ''));

// Belt-and-suspenders validation BEFORE escapeshellarg.
if ($domain === '' || strlen($domain) > 64 || !preg_match('/^[a-z0-9.-]+$/', $domain)) {
    json_error('Invalid domain (allowed: a-z 0-9 . - , max 64 chars)', 400);
}
if ($email === '' || filter_var($email, FILTER_VALIDATE_EMAIL) === false || strlen($email) > 128) {
    json_error('Invalid admin_email', 400);
}

$args = [$domain, '--admin-email', $email];

$r = call_cli('wp-create', $args, ['timeout_sec' => 300]); // wp-create can take a while

if ($r['exit_code'] !== 0) {
    json_response([
        'success'   => false,
        'error'     => 'wp-create failed',
        'exit_code' => $r['exit_code'],
        'stderr'    => $r['stderr'],
    ], 500);
}

$parsed = json_decode($r['stdout'], true);
if (!is_array($parsed)) {
    // wp-create succeeded but didn't emit JSON — surface raw stdout.
    json_response([
        'success' => true,
        'raw'     => $r['stdout'],
    ]);
}

json_response(['success' => true] + $parsed);
