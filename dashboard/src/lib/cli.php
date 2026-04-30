<?php
// =============================================================================
// dashboard/src/lib/cli.php — sudoers-whitelisted CLI bridge
// =============================================================================
//
// SECURITY MODEL (DASH-02 — KEY decision):
//   - The dashboard NEVER mounts /var/run/docker.sock. RCE in this PHP layer
//     must NOT equal root-on-host.
//   - Every host-side action goes through one of seven whitelisted CLI verbs
//     in /opt/wp/bin/ via sudo. /etc/sudoers.d/wp-dashboard contains the
//     exact NOPASSWD list.
//   - Verb names are validated against a hard whitelist BEFORE shell-out.
//   - Every argument is passed through escapeshellarg() AFTER per-arg regex
//     validation in the calling endpoint (belt-and-suspenders).
//   - We use proc_open (NOT shell_exec) so we can capture stdout, stderr,
//     and exit code separately — useful for surfacing errors to the UI
//     without leaking secrets.
// =============================================================================

const CLI_BIN_DIR = '/opt/wp/bin';

const CLI_VERB_WHITELIST = [
    'wp-create',
    'wp-delete',
    'wp-pause',
    'wp-resume',
    'wp-list',
    'wp-stats',
    'wp-logs',
];

/**
 * Invoke a whitelisted CLI verb under sudo.
 *
 * @param string $verb     One of CLI_VERB_WHITELIST.
 * @param array  $args     Already-validated string arguments (no shell metachars).
 *                         Each is run through escapeshellarg() here.
 * @param array  $opts     Optional:
 *                           timeout_sec (int, default 60)
 *                           append_json (bool, default true) — append --json
 *                           stdin (string|null, default null)
 *
 * @return array{stdout: string, stderr: string, exit_code: int, command: string}
 */
function call_cli(string $verb, array $args = [], array $opts = []): array {
    if (!in_array($verb, CLI_VERB_WHITELIST, true)) {
        error_log("call_cli: rejected non-whitelisted verb: " . $verb);
        return [
            'stdout'    => '',
            'stderr'    => "verb not in whitelist: {$verb}",
            'exit_code' => 127,
            'command'   => '',
        ];
    }

    $verb_path = CLI_BIN_DIR . '/' . $verb;
    // The host install script puts the verbs at this exact path; they must be
    // executable. This is verified at installation, not per-request.

    $timeout    = (int)($opts['timeout_sec'] ?? 60);
    $append_json = (bool)($opts['append_json'] ?? true);
    $stdin       = $opts['stdin'] ?? null;

    $parts = ['sudo', '-n', $verb_path];
    foreach ($args as $a) {
        $parts[] = (string)$a;
    }
    if ($append_json) {
        $parts[] = '--json';
    }

    // Build the final command. escapeshellarg every component except the
    // literal `sudo` / `-n` (those are safe constants).
    $cmd = 'sudo -n ' . escapeshellarg($verb_path);
    foreach ($args as $a) {
        $cmd .= ' ' . escapeshellarg((string)$a);
    }
    if ($append_json) {
        $cmd .= ' --json';
    }

    $descriptors = [
        0 => ['pipe', 'r'],  // stdin
        1 => ['pipe', 'w'],  // stdout
        2 => ['pipe', 'w'],  // stderr
    ];

    $proc = @proc_open($cmd, $descriptors, $pipes, null, null);
    if (!is_resource($proc)) {
        error_log("call_cli: proc_open failed for: {$cmd}");
        return [
            'stdout'    => '',
            'stderr'    => 'proc_open failed',
            'exit_code' => 127,
            'command'   => $cmd,
        ];
    }

    if ($stdin !== null) {
        fwrite($pipes[0], (string)$stdin);
    }
    fclose($pipes[0]);

    // Non-blocking read with timeout.
    stream_set_blocking($pipes[1], false);
    stream_set_blocking($pipes[2], false);

    $stdout = '';
    $stderr = '';
    $deadline = microtime(true) + $timeout;
    $timed_out = false;

    while (true) {
        $status = proc_get_status($proc);
        $chunk_out = stream_get_contents($pipes[1]);
        $chunk_err = stream_get_contents($pipes[2]);
        if ($chunk_out !== false) $stdout .= $chunk_out;
        if ($chunk_err !== false) $stderr .= $chunk_err;

        if (!$status['running']) {
            break;
        }
        if (microtime(true) >= $deadline) {
            $timed_out = true;
            @proc_terminate($proc, 15); // SIGTERM
            usleep(200000);
            $status = proc_get_status($proc);
            if ($status['running']) {
                @proc_terminate($proc, 9); // SIGKILL
            }
            break;
        }
        usleep(50000); // 50ms
    }

    // Drain any remaining bytes after process exit.
    $tail_out = stream_get_contents($pipes[1]);
    $tail_err = stream_get_contents($pipes[2]);
    if ($tail_out !== false) $stdout .= $tail_out;
    if ($tail_err !== false) $stderr .= $tail_err;

    fclose($pipes[1]);
    fclose($pipes[2]);

    $exit = proc_close($proc);
    if ($timed_out) {
        $exit = 124;
        $stderr .= "\n[call_cli: timed out after {$timeout}s]";
    }

    if ($exit !== 0) {
        // Log — but do NOT echo stderr to the user verbatim (may contain paths).
        error_log("call_cli: {$verb} exit={$exit} stderr=" . substr($stderr, 0, 500));
    }

    return [
        'stdout'    => $stdout,
        'stderr'    => $stderr,
        'exit_code' => $exit,
        'command'   => $cmd,
    ];
}

/**
 * Convenience: parse JSON stdout, returning [parsed, raw_stdout] or null on fail.
 *
 * @return array{0: mixed, 1: string}|null
 */
function call_cli_json(string $verb, array $args = [], array $opts = []): ?array {
    $r = call_cli($verb, $args, $opts);
    if ($r['exit_code'] !== 0) {
        return null;
    }
    $parsed = json_decode($r['stdout'], true);
    if ($parsed === null && trim($r['stdout']) !== '') {
        error_log("call_cli_json: invalid JSON from {$verb}");
        return null;
    }
    return [$parsed, $r['stdout']];
}
