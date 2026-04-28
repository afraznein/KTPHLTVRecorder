/* KTP HLTV Recorder v1.6.0
 * Automatic HLTV demo recording triggered by KTPMatchHandler
 *
 * AUTHOR: Nein_
 * VERSION: 1.6.0
 * DATE: 2026-04-28
 *
 * DESCRIPTION:
 * This plugin hooks into KTPMatchHandler's match start/end forwards
 * and sends commands to HLTV servers via HTTP API (FIFO pipe injection).
 *
 * REQUIREMENTS:
 * - KTPMatchHandler v0.10.1+ (for ktp_match_start/ktp_match_end forwards)
 * - Curl module (for HTTP requests)
 *
 * CONFIGURATION (hltv_recorder.ini):
 *   hltv_enabled = 1
 *   hltv_api_url = http://74.91.112.242:8087
 *   hltv_api_key = KTPVPS2026
 *   hltv_port = 27020
 *   hltv_stop_delay = 75
 *
 * DEMO NAMING:
 *   Format: <matchtype>_<matchid>_<half>.dem
 *   Examples:
 *     ktp_KTP-1735052400-dod_anzio_h1.dem (first half)
 *     ktp_KTP-1735052400-dod_anzio_h2.dem (second half)
 *     ktp_KTP-1735052400-dod_anzio_ot1.dem (overtime round 1)
 *
 * RECORDING LIFECYCLE (v1.6.0):
 *   Half 1 starts  -> POLL /state until idle -> record <name>_h1
 *   Half 1 ends    -> map changes -> HLTV keeps recording, delay buffer drains
 *   Half 2 starts  -> stoprecording (safe, buffer drained) -> POLL /state until idle -> record <name>_h2
 *   Match ends     -> delayed stoprecording after hltv_stop_delay seconds
 *                  -> POLL /state to verify HLTV actually stopped
 *
 *   The poll-before-record pattern fixes the demo-bleed bug where HLTV silently
 *   ignored mid-recording `record <new>` commands and kept writing the OLD
 *   basename across match/half boundaries (root-caused 2026-04-28 via journal:
 *   60 misfiled match keys / 350 files / 59 missing-h1 cases fleet-wide).
 *
 * CHANGELOG:
 *   v1.6.0 (2026-04-28):
 *     - Fixed match-id bleed: HLTV silently ignores `record <new>` when already
 *       recording, keeping the original basename across match/half boundaries.
 *       Now polls /state endpoint after stoprecording until HLTV is confirmed
 *       idle, then issues record. Best-effort fallback after 5s timeout.
 *     - Requires hltv-api.py v2.2+ (provides GET /hltv/<port>/state).
 *     - Added post-deferred-stop verification: after match-end stoprecording
 *       fires, poll /state to confirm HLTV actually stopped (alerts if not).
 *   v1.5.5 (2026-03-17):
 *     - Record command now verifies demo file creation via HLTV API (2s check)
 *     - Recording success/failure reported to in-game chat for all players
 *     - HTTP 200 = confirmed, HTTP 422 = demo not created (e.g., filename with spaces)
 *     - Increased curl timeout from 5s to 8s to accommodate API verification delay
 *   v1.5.4 (2026-03-13):
 *     - Fixed delayed recording task had no task ID — back-to-back matches could
 *       overwrite pending globals, causing missed or duplicate recordings
 *     - Fixed 5s recovery delay racing 30s HLTV restart — increased to 35s
 *     - Fixed g_restartRequesterId global corrupted by concurrent .hltvrestart —
 *       now passes requester ID through curl data parameter
 *     - Fixed version message used raw player ID as task ID — now uses offset
 *     - Changed version announcement from all players to admin-only
 *     - Added client_disconnected to clean up version task
 *     - Added port validation (1024-65535) in config loader
 *     - Increased configsDir buffer from 128 to 256
 *   v1.5.3 (2026-03-06):
 *     - Fixed second half demo cutoff (~45-48s lost) — plugin_cfg() sent stoprecording
 *       immediately after match-end map change instead of re-scheduling the delayed stop.
 *       The HLTV delay buffer hadn't drained yet. Now re-schedules task_delayed_match_stop.
 *   v1.5.1 (2026-02-18):
 *     - Fixed segfault on half 2 start caused by shared g_curlHeaders use-after-free
 *     - Curl headers now created once at init and reused (never freed per-request)
 *   v1.5.0 (2026-02-18):
 *     - Fixed HLTV demo cutoff (~47 seconds lost per half)
 *     - Removed premature stoprecording from plugin_end() and plugin_cfg()
 *     - Added delayed stoprecording on match end (configurable hltv_stop_delay)
 *     - Half transitions now stop previous recording before starting new one
 *     - Added localinfo persistence for pending stop across map changes
 *   v1.4.0 (2026-01-31):
 *     - Added pre-match HLTV health check before starting recording
 *     - Added Discord + chat alerts when HLTV API fails
 *     - Added callback failure detection with notifications
 *   v1.3.0 (2026-01-22):
 *     - FIXED: Second half recording now works - each half gets separate demo file
 *     - Demo names now include half suffix (_h1, _h2, _ot1, _ot2, etc.)
 *     - Removed "already recording" skip logic - each half starts fresh recording
 *   v1.2.2 (2026-01-13):
 *     - Fixed orphaned recording bug - sends stoprecording on plugin startup/shutdown
 *   v1.2.1 (2026-01-13):
 *     - Admin .hltvrestart command with Discord audit notification
 */

#include <amxmodx>
#include <amxmisc>
#include <curl>
#include <ktp_discord>
#include <ktp_version_reporter>

#define PLUGIN_NAME    "KTP HLTV Recorder"
#define PLUGIN_VERSION "1.6.0"
#define PLUGIN_AUTHOR  "Nein_"

// Admin flag for HLTV restart command
#define ADMIN_HLTVRESTART ADMIN_RCON

// Task IDs
#define TASK_DELAYED_STOP    5500
#define TASK_DELAYED_RECORD  5501
#define TASK_POLL_RETRY                5502
#define TASK_VERIFY_RECORDING_STARTED  5503
#define TASK_VERIFY_POST_STOP          5504

// State-poll tuning (idle-confirmation before issuing record).
// Total budget = POLL_MAX_ATTEMPTS * POLL_INTERVAL seconds before falling
// back to best-effort fire. Default 10*0.5s = 5s — enough for HLTV's
// stoprecording to settle, short enough to not block the next match start.
#define POLL_MAX_ATTEMPTS   10
#define POLL_INTERVAL       0.5

// Verify-after-stop: how long after delayed stoprecording fires before
// we confirm HLTV actually stopped. Stoprecording flushes the delay buffer
// which can take a second or two depending on length.
#define VERIFY_STOPPED_DELAY 3.0

// Pending poll-then-action types.
#define POLL_ACTION_NONE            0
#define POLL_ACTION_RECORD          1   // poll until idle, then issue record
#define POLL_ACTION_VERIFY_STOPPED  2   // poll once, log + alert if still recording

// Match types (must match KTPMatchHandler enum — verified against v0.10.95)
enum MatchType {
    MATCH_TYPE_COMPETITIVE = 0,
    MATCH_TYPE_SCRIM = 1,
    MATCH_TYPE_12MAN = 2,
    MATCH_TYPE_DRAFT = 3,
    MATCH_TYPE_KTP_OT = 4,
    MATCH_TYPE_DRAFT_OT = 5
};

// Configuration
new g_hltvEnabled = 0;
new g_hltvApiUrl[256];
new g_hltvApiKey[64];
new g_hltvPort = 27020;
new g_hltvStopDelay = 75;  // seconds to wait before stoprecording at match end

// State
new g_currentMatchId[64];
new bool:g_matchActive = false;  // true between match_start and match_end
new g_pendingMatchId[64];        // Match ID waiting for health check
new g_pendingDemoName[128];      // Demo name waiting for health check
new g_pendingHalf;               // Half number waiting for health check
new g_lastRecordDemoName[128];   // Demo name for record callback chat notification (set before perform, read in callback)

// Curl state - headers are created once and reused for all requests.
// IMPORTANT: Do NOT free/recreate these per-request. Multiple async curl handles
// reference this slist concurrently. Freeing while a request is in flight causes
// use-after-free segfaults. The headers never change (same Content-Type + API key).
new curl_slist:g_curlHeaders = SList_Empty;

// Idle-poll state machine (v1.6.0). Only one poll active at a time —
// match flow guarantees this (one stoprecording at a time, one record at a time).
new bool:g_pollActive = false;
new g_pollAttempts = 0;
new g_pollAction = POLL_ACTION_NONE;
new g_pollDemoName[128];

public plugin_init() {
    register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);
    KTP_RegisterVersion(PLUGIN_NAME, PLUGIN_VERSION);

    // Load configuration first — init_curl_headers() needs g_hltvApiKey from config
    load_config();

    // Build persistent curl headers (reused for all requests)
    init_curl_headers();

    // Register admin command for HLTV restart
    register_clcmd("say .hltvrestart", "cmd_hltv_restart");
    register_clcmd("say_team .hltvrestart", "cmd_hltv_restart");
    register_clcmd("say /hltvrestart", "cmd_hltv_restart");

}

// Create persistent header list - called ONCE after config is loaded.
// NEVER call this again while async requests may be in flight — the slist
// is shared across all concurrent curl handles. See v1.5.1 segfault fix.
stock init_curl_headers() {
    if (g_curlHeaders != SList_Empty)
        return;  // Already initialized — do not rebuild

    // Skip if API key not configured (avoids building useless auth header)
    if (!g_hltvApiKey[0]) {
        log_amx("[KTP HLTV] WARNING: hltv_api_key not configured — curl headers not built");
        return;
    }

    g_curlHeaders = curl_slist_append(SList_Empty, "Content-Type: application/json");

    new authHeader[128];
    formatex(authHeader, charsmax(authHeader), "X-Auth-Key: %s", g_hltvApiKey);
    g_curlHeaders = curl_slist_append(g_curlHeaders, authHeader);
}

public plugin_cfg() {
    // Load shared Discord configuration
    ktp_discord_load_config();

    // Check if a delayed stop was pending from before the map change
    // (match ended, delayed stop task was scheduled, but map changed before it fired)
    if (g_hltvEnabled) {
        new pendingStop[8];
        get_localinfo("_ktp_hltv_pending_stop", pendingStop, charsmax(pendingStop));

        if (equal(pendingStop, "1")) {
            // Check if there's an active match — if so, ktp_match_start will handle it
            new matchId[64];
            get_localinfo("_ktp_mid", matchId, charsmax(matchId));

            if (!matchId[0]) {
                // No active match — re-schedule delayed stop to let HLTV buffer drain.
                // The original delayed task was destroyed by the map change.
                // We can't send stoprecording immediately — the HLTV delay buffer (~60s)
                // still has content that hasn't been written to the demo file yet.
                log_amx("[KTP HLTV] Pending stop detected (no active match) - scheduling delayed stoprecording (%ds)", g_hltvStopDelay);
                remove_task(TASK_DELAYED_STOP);
                set_task(float(g_hltvStopDelay), "task_delayed_match_stop", TASK_DELAYED_STOP);
            } else {
                log_amx("[KTP HLTV] Pending stop detected but match active (mid=%s) - deferring to match_start", matchId);
            }
        }
    }
}

public plugin_end() {
    // v1.5.0: Do NOT send stoprecording here.
    // HLTV has a delay buffer (~60 seconds). Sending stoprecording during a map change
    // immediately kills the buffer, losing ~47 seconds of gameplay content.
    // Instead, we let HLTV keep recording through map changes and stop it at the
    // appropriate time (next half start, or delayed stop after match end).

    if (g_matchActive && g_hltvEnabled) {
        log_amx("[KTP HLTV] Plugin ending during active match - HLTV will keep recording (buffer drain)");
    }
}

// Version broadcast removed — no need to send plugin info to players

// Forward from KTPMatchHandler - match/half started
// half: 1=1st half, 2=2nd half, 101+=OT round (101, 102, 103...)
public ktp_match_start(const matchId[], const map[], MatchType:matchType, half) {
    new halfStr[16];
    new halfSuffix[8];

    if (half <= 2) {
        formatex(halfStr, charsmax(halfStr), "half=%d", half);
        formatex(halfSuffix, charsmax(halfSuffix), "h%d", half);
    } else {
        formatex(halfStr, charsmax(halfStr), "OT%d", half - 100);
        formatex(halfSuffix, charsmax(halfSuffix), "ot%d", half - 100);
    }
    log_amx("[KTP HLTV] ktp_match_start received: matchId=%s map=%s type=%d %s enabled=%d", matchId, map, matchType, halfStr, g_hltvEnabled);

    if (!g_hltvEnabled) {
        log_amx("[KTP HLTV] Recording disabled (hltv_enabled=0)");
        return;
    }

    // Cancel any pending tasks from previous match
    remove_task(TASK_DELAYED_RECORD);

    // If a delayed stop is pending from a previous match, let it fire naturally
    // so the HLTV delay buffer finishes draining. The stop will close the old demo,
    // and then our new record command (sent after health check) will start fresh.
    // Don't cancel TASK_DELAYED_STOP here — the buffer drain must complete.
    // TIMING SAFETY: The 75s delayed stop always fires before a new match reaches
    // the record phase. Minimum path: forcereset (~5s) + confirm (~30s) + ready (~60s)
    // = 95s. The g_matchActive guard in task_delayed_match_stop is the structural
    // backstop if timing ever collapses.
    set_localinfo("_ktp_hltv_pending_stop", "");

    // For half > 1 (2nd half, OT rounds): stop previous recording first.
    // By the time ktp_match_start fires for half 2 (60-120+ seconds after map change),
    // the HLTV delay buffer from the previous half has fully drained, so stoprecording
    // is safe — all previous content has been written to the demo file.
    if (half > 1) {
        log_amx("[KTP HLTV] Stopping previous half recording before starting %s", halfStr);
        send_hltv_command("stoprecording");
    }

    g_matchActive = true;

    // Build demo name based on match type
    new demoName[128];
    new typeStr[16];

    switch (matchType) {
        case MATCH_TYPE_COMPETITIVE: copy(typeStr, charsmax(typeStr), "ktp");
        case MATCH_TYPE_SCRIM:       copy(typeStr, charsmax(typeStr), "scrim");
        case MATCH_TYPE_12MAN:       copy(typeStr, charsmax(typeStr), "12man");
        case MATCH_TYPE_DRAFT:       copy(typeStr, charsmax(typeStr), "draft");
        case MATCH_TYPE_KTP_OT:      copy(typeStr, charsmax(typeStr), "ktpOT");
        case MATCH_TYPE_DRAFT_OT:    copy(typeStr, charsmax(typeStr), "draftOT");
        default:                     copy(typeStr, charsmax(typeStr), "match");
    }

    // Demo name format: type_matchid_half (e.g., ktp_KTP-123456-dod_anzio_h1)
    formatex(demoName, charsmax(demoName), "%s_%s_%s", typeStr, matchId, halfSuffix);

    // Store pending info for health check callback
    copy(g_pendingMatchId, charsmax(g_pendingMatchId), matchId);
    copy(g_pendingDemoName, charsmax(g_pendingDemoName), demoName);
    g_pendingHalf = half;
    copy(g_currentMatchId, charsmax(g_currentMatchId), matchId);

    // First, do a health check on HLTV API before starting recording
    log_amx("[KTP HLTV] Checking HLTV health before recording...");
    send_hltv_health_check();
}

// Send health check to HLTV API
stock send_hltv_health_check() {
    if (!g_hltvApiUrl[0]) {
        log_amx("[KTP HLTV] ERROR: hltv_api_url not configured");
        alert_hltv_failure("HLTV API URL not configured");
        return;
    }

    // Build URL: http://api/health
    new url[256];
    formatex(url, charsmax(url), "%s/health", g_hltvApiUrl);

    // Create cURL handle
    new CURL:curl = curl_easy_init();
    if (!curl) {
        log_amx("[KTP HLTV] ERROR: curl_easy_init() failed for health check");
        alert_hltv_failure("Failed to initialize HTTP client");
        return;
    }

    // Set URL
    curl_easy_setopt(curl, CURLOPT_URL, url);

    // Set persistent headers (auth required for some API endpoints)
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, g_curlHeaders);

    // GET request (no POST data)
    curl_easy_setopt(curl, CURLOPT_HTTPGET, 1);

    // Set timeout (3 seconds for health check)
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 3);

    // Debug log
    log_amx("[KTP HLTV] Sending health check to %s", url);

    // Perform request asynchronously
    curl_easy_perform(curl, "hltv_health_callback");
}

// Callback for HLTV health check
public hltv_health_callback(CURL:curl, CURLcode:code) {
    if (code != CURLE_OK) {
        new error[128];
        curl_easy_strerror(code, error, charsmax(error));
        log_amx("[KTP HLTV] Health check FAILED: code=%d error='%s'", _:code, error);
        curl_easy_cleanup(curl);

        // Alert and attempt recovery
        new msg[256];
        formatex(msg, charsmax(msg), "HLTV API not responding: %s. Attempting restart...", error);
        alert_hltv_failure(msg);

        // Try to restart HLTV instance (may help if instance is stuck)
        log_amx("[KTP HLTV] Attempting HLTV instance restart as recovery...");
        send_hltv_restart();

        // Still try to start recording after a delay (HLTV might recover)
        remove_task(TASK_DELAYED_RECORD);
        set_task(35.0, "task_delayed_recording_start", TASK_DELAYED_RECORD);
        return;
    }

    // Check HTTP response code (transport OK doesn't mean API OK)
    new httpCode;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, httpCode);
    curl_easy_cleanup(curl);

    if (httpCode < 200 || httpCode >= 300) {
        log_amx("[KTP HLTV] Health check FAILED: HTTP %d", httpCode);

        new msg[256];
        formatex(msg, charsmax(msg), "HLTV API returned HTTP %d. Attempting restart...", httpCode);
        alert_hltv_failure(msg);

        log_amx("[KTP HLTV] Attempting HLTV instance restart as recovery...");
        send_hltv_restart();

        remove_task(TASK_DELAYED_RECORD);
        set_task(35.0, "task_delayed_recording_start", TASK_DELAYED_RECORD);
        return;
    }

    // Health check passed
    log_amx("[KTP HLTV] Health check passed (HTTP %d), starting recording", httpCode);

    // Now start the actual recording
    start_recording();
}

// Delayed recording attempt after HLTV recovery
public task_delayed_recording_start(taskid) {
    if (g_pendingDemoName[0]) {
        log_amx("[KTP HLTV] Attempting delayed recording start after recovery attempt");
        start_recording();
    }
}

// ============================================================================
// /state polling state machine (v1.6.0)
//
// HLTV silently ignores `record <new>` when already recording, keeping the
// original basename and bleeding subsequent matches into wrong demo files.
// We can only safely issue `record` when HLTV reports it is NOT recording.
//
// The poll machine has two modes:
//   POLL_ACTION_RECORD          — wait for idle, then issue record + post-verify
//   POLL_ACTION_VERIFY_STOPPED  — one-shot poll after stoprecording, alert if
//                                 still recording (HLTV stuck / process dead)
// ============================================================================

// Begin: poll /state until HLTV is idle, then fire `record <demoName>`.
stock poll_idle_then_record(const demoName[]) {
    if (g_pollActive) {
        // Should not happen — match flow serializes record/stop. Override.
        log_amx("[KTP HLTV] WARNING: poll already active when starting new poll, overriding");
        remove_task(TASK_POLL_RETRY);
    }
    g_pollActive = true;
    g_pollAttempts = 0;
    g_pollAction = POLL_ACTION_RECORD;
    copy(g_pollDemoName, charsmax(g_pollDemoName), demoName);
    request_state();
}

// One-shot: poll /state to confirm HLTV stopped after delayed stoprecording.
stock poll_verify_stopped() {
    if (g_pollActive) {
        log_amx("[KTP HLTV] WARNING: poll already active; verify-stopped overlapping with active poll");
        remove_task(TASK_POLL_RETRY);
    }
    g_pollActive = true;
    g_pollAttempts = 0;
    g_pollAction = POLL_ACTION_VERIFY_STOPPED;
    g_pollDemoName[0] = EOS;
    request_state();
}

// Issue GET /hltv/<port>/state. Async; response handled in state_poll_callback.
stock request_state() {
    if (!g_hltvApiUrl[0]) {
        log_amx("[KTP HLTV] ERROR: hltv_api_url not configured (state poll)");
        on_state_failed();
        return;
    }

    new url[256];
    formatex(url, charsmax(url), "%s/hltv/%d/state", g_hltvApiUrl, g_hltvPort);

    new CURL:curl = curl_easy_init();
    if (!curl) {
        log_amx("[KTP HLTV] ERROR: curl_easy_init() failed for state poll");
        on_state_failed();
        return;
    }

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, g_curlHeaders);
    curl_easy_setopt(curl, CURLOPT_HTTPGET, 1);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 3);
    // No WRITEFUNCTION set — module auto-buffers, retrievable via curl_get_response_body
    curl_easy_perform(curl, "state_poll_callback");
}

public state_poll_callback(CURL:curl, CURLcode:code) {
    if (code != CURLE_OK) {
        new error[64];
        curl_easy_strerror(code, error, charsmax(error));
        log_amx("[KTP HLTV] State poll curl error: %s", error);
        curl_easy_cleanup(curl);
        on_state_failed();
        return;
    }

    new httpCode;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, httpCode);

    new body[512];
    curl_get_response_body(curl, body, charsmax(body));
    curl_easy_cleanup(curl);

    if (httpCode != 200) {
        log_amx("[KTP HLTV] State poll HTTP %d: %s", httpCode, body);
        on_state_failed();
        return;
    }

    // Simple substring match against JSON body. json.dumps emits
    // "recording": false / true (with space) and "process_running": false / true.
    new bool:idle = (contain(body, "^"recording^": false") != -1);
    new bool:processDown = (contain(body, "^"process_running^": false") != -1);
    new bool:alreadyRecording = (contain(body, "^"already_recording_warning^": true") != -1);

    if (alreadyRecording) {
        // Bleed signal — HLTV's most recent journal event was "Already recording".
        // Worth surfacing even when we're about to retry.
        log_amx("[KTP HLTV] WARNING: HLTV journal shows 'Already recording' — bleed in progress");
    }

    if (idle || processDown) {
        on_state_idle(processDown);
        return;
    }

    // HLTV still recording — extract the current basename for diagnostic
    // logging and retry until timeout.
    new currentBase[128];
    extract_state_basename(body, currentBase, charsmax(currentBase));

    g_pollAttempts++;
    if (g_pollAttempts < POLL_MAX_ATTEMPTS) {
        log_amx("[KTP HLTV] State poll: HLTV still recording '%s' (attempt %d/%d), retrying in %.1fs",
            currentBase, g_pollAttempts, POLL_MAX_ATTEMPTS, POLL_INTERVAL);
        set_task(POLL_INTERVAL, "task_poll_retry", TASK_POLL_RETRY);
    } else {
        // Timeout. For RECORD action: fire anyway as best-effort and warn.
        // For VERIFY_STOPPED: this IS a failure — HLTV didn't stop after our stoprecording.
        log_amx("[KTP HLTV] State poll exhausted (still recording '%s' after %d attempts)",
            currentBase, POLL_MAX_ATTEMPTS);
        on_state_idle(false);  // Treat as idle for fallback purposes; caller logic handles warning
        new msg[256];
        formatex(msg, charsmax(msg), "HLTV did not become idle (still recording '%s') — recording may bleed", currentBase);
        alert_hltv_failure(msg);
    }
}

public task_poll_retry(taskid) {
    request_state();
}

// Pull "basename" string out of the /state JSON body. Tolerant — returns "" on parse miss.
stock extract_state_basename(const body[], output[], maxlen) {
    output[0] = EOS;
    new pos = contain(body, "^"basename^":");
    if (pos == -1) return;
    pos += 11;  // past "basename":
    // Skip whitespace
    while (pos < strlen(body) && (body[pos] == ' ' || body[pos] == '^t')) pos++;
    if (pos >= strlen(body)) return;
    if (body[pos] != '"') return;  // null or other non-string
    pos++;
    new outIdx = 0;
    while (pos < strlen(body) && body[pos] != '"' && outIdx < maxlen) {
        output[outIdx++] = body[pos++];
    }
    output[outIdx] = EOS;
}

// HLTV is idle (or process down) — fire the pending action.
stock on_state_idle(bool:processDown) {
    g_pollActive = false;
    new action = g_pollAction;
    new demoName[128];
    copy(demoName, charsmax(demoName), g_pollDemoName);

    g_pollAction = POLL_ACTION_NONE;
    g_pollDemoName[0] = EOS;

    switch (action) {
        case POLL_ACTION_RECORD: {
            if (processDown) {
                log_amx("[KTP HLTV] HLTV process is DOWN — cannot record %s", demoName);
                client_print(0, print_chat, "[KTP HLTV] ERROR: HLTV is not running — recording disabled for this match");
                alert_hltv_failure("HLTV process down, demo not recorded");
                return;
            }
            log_amx("[KTP HLTV] HLTV idle confirmed — issuing record %s", demoName);
            send_record_command_actual(demoName);
        }
        case POLL_ACTION_VERIFY_STOPPED: {
            // Reaching this branch with idle=true means stoprecording took effect.
            log_amx("[KTP HLTV] Post-stop verify OK: HLTV is idle");
        }
    }
}

// Curl/HTTP layer failure — retry up to budget then give up gracefully.
stock on_state_failed() {
    g_pollAttempts++;
    if (g_pollAttempts < POLL_MAX_ATTEMPTS) {
        log_amx("[KTP HLTV] State poll transport failed (attempt %d/%d), retrying in %.1fs",
            g_pollAttempts, POLL_MAX_ATTEMPTS, POLL_INTERVAL);
        set_task(POLL_INTERVAL, "task_poll_retry", TASK_POLL_RETRY);
        return;
    }

    log_amx("[KTP HLTV] State poll failed after %d attempts — proceeding without idle confirmation", POLL_MAX_ATTEMPTS);
    alert_hltv_failure("HLTV state API unreachable — recording may bleed");

    g_pollActive = false;
    new action = g_pollAction;
    new demoName[128];
    copy(demoName, charsmax(demoName), g_pollDemoName);
    g_pollAction = POLL_ACTION_NONE;
    g_pollDemoName[0] = EOS;

    // Best-effort fallback: fire record anyway. v1.5.x semantics for the
    // unreachable-API case (no worse than current behavior).
    if (action == POLL_ACTION_RECORD && demoName[0]) {
        log_amx("[KTP HLTV] Best-effort record (state unknown): %s", demoName);
        send_record_command_actual(demoName);
    }
}

// Begin the recording flow. v1.6.0+: polls /state until HLTV is idle BEFORE
// issuing record, so the previous match's stoprecording has actually settled
// and HLTV won't silently ignore the new basename.
stock start_recording() {
    if (!g_pendingDemoName[0]) {
        log_amx("[KTP HLTV] ERROR: No pending demo name for recording");
        return;
    }

    if (!g_hltvApiUrl[0]) {
        log_amx("[KTP HLTV] ERROR: hltv_api_url not configured");
        alert_hltv_failure("HLTV API URL not configured");
        return;
    }

    // Hand off to the poll-then-record state machine. It owns g_pollDemoName
    // and will issue the actual `record` command once HLTV is confirmed idle.
    new demoName[128];
    copy(demoName, charsmax(demoName), g_pendingDemoName);

    // Clear the start_recording-side pending state — poll machine has its own
    g_pendingDemoName[0] = EOS;
    g_pendingMatchId[0] = EOS;

    poll_idle_then_record(demoName);
}

// Issue the record command. Called from on_state_idle() after polling confirms
// HLTV is not currently writing to a demo file. Also schedules a post-record
// verification poll to surface basename-bleed in real time.
stock send_record_command_actual(const demoName[]) {
    new halfStr[16];
    if (g_pendingHalf <= 2) {
        formatex(halfStr, charsmax(halfStr), "half=%d", g_pendingHalf);
    } else {
        formatex(halfStr, charsmax(halfStr), "OT%d", g_pendingHalf - 100);
    }

    // Save demo name for callback chat notification + post-record verify
    copy(g_lastRecordDemoName, charsmax(g_lastRecordDemoName), demoName);

    new command[256];
    formatex(command, charsmax(command), "record %s", demoName);

    new url[256];
    formatex(url, charsmax(url), "%s/hltv/%d/command", g_hltvApiUrl, g_hltvPort);

    new payload[512];
    formatex(payload, charsmax(payload), "{^"command^":^"%s^"}", command);

    new CURL:curl = curl_easy_init();
    if (!curl) {
        log_amx("[KTP HLTV] ERROR: curl_easy_init() failed for record");
        alert_hltv_failure("Failed to initialize HTTP client");
        return;
    }

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, g_curlHeaders);
    curl_easy_setopt(curl, CURLOPT_COPYPOSTFIELDS, payload);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 8);

    log_amx("[KTP HLTV] Sending record command: %s", payload);
    log_amx("[KTP HLTV] Recording: %s.dem (%s)", demoName, halfStr);

    curl_easy_perform(curl, "hltv_record_callback");
}

// Callback for record command — reports result to in-game chat.
// v1.6.0: HTTP 200 means the API delivered the command to HLTV's FIFO; it does
// NOT mean HLTV actually started a new recording. Schedule a post-record
// verification poll so we surface bleed (HLTV ignored the command and is
// still recording the OLD basename) to players + Discord in real time.
public hltv_record_callback(CURL:curl, CURLcode:code) {
    if (code != CURLE_OK) {
        new error[128];
        curl_easy_strerror(code, error, charsmax(error));
        log_amx("[KTP HLTV] Record command failed: code=%d error='%s'", _:code, error);
        curl_easy_cleanup(curl);

        client_print(0, print_chat, "[KTP HLTV] ERROR: Recording failed - %s", error);
        alert_hltv_failure("Recording command failed");
        return;
    }

    new httpCode;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, httpCode);
    curl_easy_cleanup(curl);

    if (httpCode == 200) {
        log_amx("[KTP HLTV] Record command accepted by API (HTTP 200): %s", g_lastRecordDemoName);
        // Schedule post-record verification — confirms HLTV is actually recording
        // the basename we asked for, not bleeding to a previous match's name.
        remove_task(TASK_VERIFY_RECORDING_STARTED);
        set_task(VERIFY_STOPPED_DELAY, "task_verify_recording_started", TASK_VERIFY_RECORDING_STARTED);
    } else if (httpCode == 422) {
        log_amx("[KTP HLTV] Recording NOT confirmed (HTTP 422): %s", g_lastRecordDemoName);
        client_print(0, print_chat, "[KTP HLTV] ERROR: Recording failed for %s - demo file not created", g_lastRecordDemoName);
        alert_hltv_failure("HLTV rejected record command (demo file not created)");
    } else {
        log_amx("[KTP HLTV] Record command HTTP error: %d", httpCode);
        client_print(0, print_chat, "[KTP HLTV] ERROR: Recording may have failed (HTTP %d)", httpCode);

        new msg[256];
        formatex(msg, charsmax(msg), "HLTV API returned HTTP %d for record command", httpCode);
        alert_hltv_failure(msg);
    }
}

// Post-record verification: confirm HLTV is actually recording the basename
// we asked for. Runs ~3s after `record` to allow HLTV to log its first
// "Start recording to ..." or "Already recording to ..." entry.
public task_verify_recording_started(taskid) {
    if (!g_lastRecordDemoName[0]) return;

    if (!g_hltvApiUrl[0]) return;

    new url[256];
    formatex(url, charsmax(url), "%s/hltv/%d/state", g_hltvApiUrl, g_hltvPort);

    new CURL:curl = curl_easy_init();
    if (!curl) return;

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, g_curlHeaders);
    curl_easy_setopt(curl, CURLOPT_HTTPGET, 1);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 3);
    curl_easy_perform(curl, "verify_recording_callback");
}

public verify_recording_callback(CURL:curl, CURLcode:code) {
    if (code != CURLE_OK) {
        // Transport failure — silent; the next match will re-verify.
        curl_easy_cleanup(curl);
        return;
    }

    new httpCode;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, httpCode);
    new body[512];
    curl_get_response_body(curl, body, charsmax(body));
    curl_easy_cleanup(curl);

    if (httpCode != 200) return;

    new bool:recording = (contain(body, "^"recording^": true") != -1);
    new bool:alreadyRecording = (contain(body, "^"already_recording_warning^": true") != -1);
    new currentBase[128];
    extract_state_basename(body, currentBase, charsmax(currentBase));

    if (!recording) {
        // We issued record + got HTTP 200 but HLTV is NOT recording. This is
        // the silent-failure case — HLTV ignored the command or process died.
        log_amx("[KTP HLTV] VERIFY FAIL: record sent for '%s' but HLTV reports not recording", g_lastRecordDemoName);
        client_print(0, print_chat, "[KTP HLTV] WARNING: Recording NOT active for %s - admin notified", g_lastRecordDemoName);
        new msg[256];
        formatex(msg, charsmax(msg), "Recording verification FAILED — HLTV reports idle after `record %s`", g_lastRecordDemoName);
        alert_hltv_failure(msg);
        return;
    }

    if (alreadyRecording || (currentBase[0] && !equal(currentBase, g_lastRecordDemoName))) {
        // Bleed signal: HLTV is recording but with the WRONG basename.
        // Either it's still recording the previous match's basename, or our
        // record command was silently ignored.
        log_amx("[KTP HLTV] VERIFY FAIL: requested '%s' but HLTV recording '%s' (already_recording=%d)",
            g_lastRecordDemoName, currentBase, alreadyRecording);
        client_print(0, print_chat, "[KTP HLTV] WARNING: Demo bleed detected - recording is %s instead of %s. Admin notified.",
            currentBase, g_lastRecordDemoName);
        new msg[384];
        formatex(msg, charsmax(msg), "Demo bleed: requested `record %s`, HLTV is recording `%s`",
            g_lastRecordDemoName, currentBase);
        alert_hltv_failure(msg);
        return;
    }

    // Verified: HLTV is recording the correct basename.
    log_amx("[KTP HLTV] Recording verified: %s", g_lastRecordDemoName);
    client_print(0, print_chat, "[KTP HLTV] Recording: %s", g_lastRecordDemoName);
}

// Alert about HLTV failure via Discord and chat
stock alert_hltv_failure(const reason[]) {
    // Get server hostname
    new hostname[64];
    get_cvar_string("hostname", hostname, charsmax(hostname));

    // Chat alert to all players
    client_print(0, print_chat, "[KTP HLTV] WARNING: HLTV recording may not work - %s", reason);

    // Discord alert with hostname
    new desc[384];
    formatex(desc, charsmax(desc), "**Server:** %s^n**HLTV Port:** %d^n**Error:** %s", hostname, g_hltvPort, reason);
    ktp_discord_send_embed_audit("<:ktp:1105490705188659272> HLTV Recording Issue", desc, KTP_DISCORD_COLOR_RED);
}

// Forward from KTPMatchHandler - match ended
public ktp_match_end(const matchId[], const map[], MatchType:matchType, team1Score, team2Score) {
    if (!g_hltvEnabled) return;

    g_matchActive = false;

    // Set pending stop flag as safety net (persists across map changes via localinfo)
    set_localinfo("_ktp_hltv_pending_stop", "1");

    // Schedule delayed stoprecording to allow HLTV delay buffer to drain
    // The buffer is ~60 seconds; we wait g_hltvStopDelay (default 75s) to be safe
    remove_task(TASK_DELAYED_STOP);  // Cancel any existing delayed stop
    set_task(float(g_hltvStopDelay), "task_delayed_match_stop", TASK_DELAYED_STOP);

    server_print("[KTP HLTV] Match ended (match_id=%s, score=%d-%d) - stoprecording scheduled in %ds", matchId, team1Score, team2Score, g_hltvStopDelay);
    log_amx("[KTP HLTV] Match ended: match_id=%s score=%d-%d - delayed stop in %ds", matchId, team1Score, team2Score, g_hltvStopDelay);

    g_currentMatchId[0] = EOS;
}

// Delayed stop task - fires g_hltvStopDelay seconds after match end.
// v1.6.0: schedules a verify-stopped poll a few seconds later to confirm
// HLTV actually transitioned to idle (alerts if not — HLTV stuck/dead).
public task_delayed_match_stop() {
    // Guard: if a new match started before this fires, don't kill the new recording
    if (g_matchActive) {
        log_amx("[KTP HLTV] Delayed stop skipped — new match already active");
        set_localinfo("_ktp_hltv_pending_stop", "");
        return;
    }
    log_amx("[KTP HLTV] Delayed stop firing - sending stoprecording (buffer drain complete)");
    send_hltv_command("stoprecording");
    set_localinfo("_ktp_hltv_pending_stop", "");

    // Schedule verify-stopped a few seconds out (no concurrent record op
    // since g_matchActive is false here).
    set_task(VERIFY_STOPPED_DELAY, "task_verify_post_deferred_stop", TASK_VERIFY_POST_STOP);
}

public task_verify_post_deferred_stop(taskid) {
    if (g_matchActive) {
        // A new match started during the delay window — verify is moot;
        // the new match's poll_idle_then_record will own correctness.
        return;
    }
    poll_verify_stopped();
}

// Load configuration from hltv_recorder.ini
stock load_config() {
    new configsDir[256], configPath[320];
    get_configsdir(configsDir, charsmax(configsDir));
    formatex(configPath, charsmax(configPath), "%s/hltv_recorder.ini", configsDir);

    if (!file_exists(configPath)) {
        server_print("[KTP HLTV] Config not found: %s - HLTV recording disabled", configPath);
        return;
    }

    new file = fopen(configPath, "r");
    if (!file) {
        server_print("[KTP HLTV] Failed to open config: %s", configPath);
        return;
    }

    new line[256], key[64], value[128];
    while (fgets(file, line, charsmax(line))) {
        trim(line);

        // Skip comments and empty lines
        if (line[0] == ';' || line[0] == '/' || line[0] == '#' || line[0] == EOS)
            continue;

        // Find the = sign and split key/value
        new eqPos = contain(line, "=");
        if (eqPos < 1) continue;

        // Extract key (before =)
        copy(key, min(eqPos, charsmax(key)), line);
        trim(key);

        // Extract value (after =)
        copy(value, charsmax(value), line[eqPos + 1]);
        trim(value);

        if (equali(key, "hltv_enabled")) {
            g_hltvEnabled = str_to_num(value);
        } else if (equali(key, "hltv_api_url")) {
            copy(g_hltvApiUrl, charsmax(g_hltvApiUrl), value);
        } else if (equali(key, "hltv_api_key")) {
            copy(g_hltvApiKey, charsmax(g_hltvApiKey), value);
        } else if (equali(key, "hltv_port")) {
            g_hltvPort = str_to_num(value);
            if (g_hltvPort < 1024 || g_hltvPort > 65535) {
                server_print("[KTP HLTV] WARNING: Invalid hltv_port %d, defaulting to 27020", g_hltvPort);
                g_hltvPort = 27020;
            }
        } else if (equali(key, "hltv_stop_delay")) {
            g_hltvStopDelay = str_to_num(value);
            if (g_hltvStopDelay < 10) g_hltvStopDelay = 10;  // minimum 10 seconds
            if (g_hltvStopDelay > 300) g_hltvStopDelay = 300;  // maximum 5 minutes
        }
    }

    fclose(file);
    server_print("[KTP HLTV] Config loaded: api=%s port=%d enabled=%d stop_delay=%d", g_hltvApiUrl, g_hltvPort, g_hltvEnabled, g_hltvStopDelay);
}

// Send command to HLTV server via HTTP API
stock bool:send_hltv_command(const command[]) {
    if (!g_hltvApiUrl[0]) {
        log_amx("[KTP HLTV] ERROR: hltv_api_url not configured");
        return false;
    }

    // Build URL: http://api/hltv/<port>/command
    new url[256];
    formatex(url, charsmax(url), "%s/hltv/%d/command", g_hltvApiUrl, g_hltvPort);

    // Build JSON payload
    new payload[512];
    formatex(payload, charsmax(payload), "{^"command^":^"%s^"}", command);

    // Create cURL handle
    new CURL:curl = curl_easy_init();
    if (!curl) {
        log_amx("[KTP HLTV] ERROR: curl_easy_init() failed");
        return false;
    }

    // Set URL
    curl_easy_setopt(curl, CURLOPT_URL, url);

    // Set persistent headers (created once in init_curl_headers, never freed per-request)
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, g_curlHeaders);

    // Set POST data
    curl_easy_setopt(curl, CURLOPT_COPYPOSTFIELDS, payload);

    // Set timeout (5 seconds)
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 5);

    // Debug log
    log_amx("[KTP HLTV] Sending HTTP POST to %s: %s", url, payload);

    // Perform request asynchronously
    curl_easy_perform(curl, "hltv_api_callback");

    return true;  // Request sent (async - actual success determined in callback)
}

// Callback for HTTP API response
public hltv_api_callback(CURL:curl, CURLcode:code) {
    if (code != CURLE_OK) {
        new error[128];
        curl_easy_strerror(code, error, charsmax(error));
        log_amx("[KTP HLTV] HTTP API error: code=%d error='%s'", _:code, error);
        curl_easy_cleanup(curl);

        // Alert on recording command failure
        new msg[256];
        formatex(msg, charsmax(msg), "Recording command failed: %s", error);
        alert_hltv_failure(msg);
        return;
    }

    // Check HTTP response code
    new httpCode;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, httpCode);
    curl_easy_cleanup(curl);

    if (httpCode < 200 || httpCode >= 300) {
        log_amx("[KTP HLTV] HTTP API error: HTTP %d", httpCode);

        new msg[256];
        formatex(msg, charsmax(msg), "HLTV API returned HTTP %d", httpCode);
        alert_hltv_failure(msg);
        return;
    }

    log_amx("[KTP HLTV] HTTP API request successful (HTTP %d)", httpCode);
}

// ============================================================================
// Admin Commands
// ============================================================================

// Admin command to restart paired HLTV instance
public cmd_hltv_restart(id) {
    // Check admin access
    if (!(get_user_flags(id) & ADMIN_HLTVRESTART)) {
        client_print(id, print_chat, "[KTP HLTV] You don't have permission to restart HLTV.");
        return PLUGIN_HANDLED;
    }

    // Check if HLTV is configured
    if (!g_hltvApiUrl[0]) {
        client_print(id, print_chat, "[KTP HLTV] HLTV not configured for this server.");
        return PLUGIN_HANDLED;
    }

    // Get admin info for logging
    new adminName[32], adminAuth[35];
    get_user_name(id, adminName, charsmax(adminName));
    get_user_authid(id, adminAuth, charsmax(adminAuth));

    // Log the restart request
    log_amx("[KTP HLTV] Admin %s <%s> requested HLTV restart (port %d)", adminName, adminAuth, g_hltvPort);

    // Send Discord notification to audit channels
    new description[256];
    formatex(description, charsmax(description),
        "**Admin:** %s (`%s`)^n**HLTV Port:** %d",
        adminName, adminAuth, g_hltvPort);
    ktp_discord_send_embed_audit("<:ktp:1105490705188659272> HLTV Restart", description, KTP_DISCORD_COLOR_ORANGE);

    // Send restart request (pass requester ID to callback via data parameter)
    client_print(id, print_chat, "[KTP HLTV] Restarting HLTV on port %d...", g_hltvPort);
    send_hltv_restart(id);

    return PLUGIN_HANDLED;
}

// Send restart request to HLTV API
// requesterId: player ID of admin who requested (0 = automated recovery)
stock send_hltv_restart(requesterId = 0) {
    if (!g_hltvApiUrl[0]) {
        log_amx("[KTP HLTV] ERROR: hltv_api_url not configured");
        return;
    }

    // Build URL: http://api/hltv/<port>/restart
    new url[256];
    formatex(url, charsmax(url), "%s/hltv/%d/restart", g_hltvApiUrl, g_hltvPort);

    // Create cURL handle
    new CURL:curl = curl_easy_init();
    if (!curl) {
        log_amx("[KTP HLTV] ERROR: curl_easy_init() failed for restart");
        return;
    }

    // Set URL
    curl_easy_setopt(curl, CURLOPT_URL, url);

    // Set persistent headers (created once in init_curl_headers, never freed per-request)
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, g_curlHeaders);

    // POST with empty body (restart doesn't need payload)
    curl_easy_setopt(curl, CURLOPT_POST, 1);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, 0);

    // Set timeout (30 seconds for restart)
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 30);

    // Debug log
    log_amx("[KTP HLTV] Sending restart request to %s", url);

    // Perform request asynchronously (pass requester ID via data parameter)
    new data[1];
    data[0] = requesterId;
    curl_easy_perform(curl, "hltv_restart_callback", data, sizeof(data));
}

// Callback for HLTV restart response
public hltv_restart_callback(CURL:curl, CURLcode:code, const data[]) {
    new requesterId = data[0];
    new bool:success = true;

    if (code != CURLE_OK) {
        new error[128];
        curl_easy_strerror(code, error, charsmax(error));
        log_amx("[KTP HLTV] Restart failed: code=%d error='%s'", _:code, error);
        curl_easy_cleanup(curl);
        success = false;
    } else {
        // Check HTTP response code
        new httpCode;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, httpCode);
        curl_easy_cleanup(curl);

        if (httpCode < 200 || httpCode >= 300) {
            log_amx("[KTP HLTV] Restart failed: HTTP %d (port %d)", httpCode, g_hltvPort);
            success = false;
        } else {
            log_amx("[KTP HLTV] HLTV restart successful (port %d, HTTP %d)", g_hltvPort, httpCode);
        }
    }

    // Notify the admin who requested the restart (0 = automated recovery, skip)
    if (requesterId > 0 && requesterId <= MAX_PLAYERS && is_user_connected(requesterId)) {
        if (success) {
            client_print(requesterId, print_chat, "[KTP HLTV] HLTV on port %d restarted successfully.", g_hltvPort);
        } else {
            client_print(requesterId, print_chat, "[KTP HLTV] HLTV restart failed! Check server logs.");
        }
    }
}
