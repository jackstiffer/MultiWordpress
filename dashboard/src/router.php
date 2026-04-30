<?php
// =============================================================================
// dashboard/src/router.php — PHP built-in dev server router
// =============================================================================
//
// Dispatches:
//   GET    /                              -> index.php
//   GET    /static/<file>                 -> static asset (style.css, app.js)
//   GET    /api/sites.json                -> api/sites.php
//   GET    /api/logs?slug=...             -> api/logs.php
//   POST   /api/site                      -> api/site_create.php
//   POST   /api/site/<slug>/pause         -> api/site_pause.php
//   POST   /api/site/<slug>/resume        -> api/site_resume.php
//   DELETE /api/site/<slug>               -> api/site_delete.php
//
// All POST/DELETE on /api/* require CSRF (handled by the endpoint via
// require_csrf()). The router only does path dispatch.
// =============================================================================

$uri    = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';

// 1. Static files. The PHP built-in server normally serves these directly when
//    a router is NOT specified — but with a router, we must opt in. Returning
//    `false` tells the dev server to serve the file from -t docroot.
if (strpos($uri, '/static/') === 0) {
    $path = __DIR__ . $uri;
    if (is_file($path)) {
        // Let the built-in server handle MIME / sendfile.
        return false;
    }
    http_response_code(404);
    echo "Not found";
    return true;
}

// 2. API routes.
if ($uri === '/api/sites.json' && $method === 'GET') {
    require __DIR__ . '/api/sites.php';
    return true;
}
if ($uri === '/api/logs' && $method === 'GET') {
    require __DIR__ . '/api/logs.php';
    return true;
}
if ($uri === '/api/site' && $method === 'POST') {
    require __DIR__ . '/api/site_create.php';
    return true;
}

// /api/site/<slug>/pause | /resume | DELETE
if (preg_match('#^/api/site/([a-z0-9_]+)(?:/(pause|resume))?$#', $uri, $m)) {
    $slug = $m[1];
    $action = $m[2] ?? '';
    $_GET['slug'] = $slug;

    if ($action === 'pause' && $method === 'POST') {
        require __DIR__ . '/api/site_pause.php';
        return true;
    }
    if ($action === 'resume' && $method === 'POST') {
        require __DIR__ . '/api/site_resume.php';
        return true;
    }
    if ($action === '' && $method === 'DELETE') {
        require __DIR__ . '/api/site_delete.php';
        return true;
    }
    http_response_code(405);
    header('Content-Type: application/json');
    echo json_encode(['error' => 'Method not allowed for this resource']);
    return true;
}

// 3. Root: index page.
if ($uri === '/' || $uri === '/index.php') {
    require __DIR__ . '/index.php';
    return true;
}

// 4. 404 fallback.
http_response_code(404);
header('Content-Type: text/plain');
echo "Not found: {$uri}";
return true;
