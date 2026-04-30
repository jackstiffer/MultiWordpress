<?php
// =============================================================================
// dashboard/src/lib/auth.php — CSRF token helpers
// =============================================================================
//
// Front-line auth is host Caddy basic_auth (DASH-03). This module adds CSRF
// protection on top so that a stolen session cookie alone cannot trigger
// site_create / site_delete / pause / resume.
// =============================================================================

/**
 * Start the PHP session if not already started. Hardens cookie flags.
 */
function session_boot(): void {
    if (session_status() === PHP_SESSION_ACTIVE) {
        return;
    }
    // Caddy in front sets HTTPS so Secure works end-to-end.
    session_set_cookie_params([
        'lifetime' => 0,
        'path'     => '/',
        'secure'   => true,
        'httponly' => true,
        'samesite' => 'Strict',
    ]);
    session_name('wpdash_sid');
    @session_start();
}

/**
 * Return the session CSRF token, generating one on first access.
 */
function csrf_token(): string {
    session_boot();
    if (empty($_SESSION['csrf']) || !is_string($_SESSION['csrf'])) {
        $_SESSION['csrf'] = bin2hex(random_bytes(32));
    }
    return $_SESSION['csrf'];
}

/**
 * Verify the X-CSRF header matches the session token. Returns false if not.
 * Side effect on success: regenerates the token (one-shot semantics for write
 * operations — the next request gets a fresh token via the next page load).
 */
function csrf_check(): bool {
    session_boot();
    $hdr = $_SERVER['HTTP_X_CSRF'] ?? '';
    $expected = $_SESSION['csrf'] ?? '';
    if (!is_string($hdr) || !is_string($expected) || $expected === '') {
        return false;
    }
    if (!hash_equals($expected, $hdr)) {
        return false;
    }
    // Rotate token after a successful write op.
    $_SESSION['csrf'] = bin2hex(random_bytes(32));
    return true;
}

/**
 * Helper for endpoints: 403 + exit if CSRF fails.
 */
function require_csrf(): void {
    if (!csrf_check()) {
        require_once __DIR__ . '/render.php';
        json_error('CSRF check failed', 403);
    }
}
