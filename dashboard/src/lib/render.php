<?php
// =============================================================================
// dashboard/src/lib/render.php — tiny HTML / JSON helpers
// =============================================================================

/**
 * HTML-escape a string for safe template interpolation.
 */
function e(?string $s): string {
    return htmlspecialchars((string)$s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

/**
 * Emit a JSON response and exit. Sets Content-Type and status.
 *
 * @param mixed $data
 */
function json_response($data, int $status = 200): void {
    http_response_code($status);
    header('Content-Type: application/json; charset=utf-8');
    header('Cache-Control: no-store');
    echo json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
    exit;
}

/**
 * Emit a JSON error response and exit.
 */
function json_error(string $message, int $status = 400, array $extra = []): void {
    json_response(['error' => $message] + $extra, $status);
}
