/* KTP HLTV Recorder v1.3.0
 * Automatic HLTV demo recording triggered by KTPMatchHandler
 *
 * AUTHOR: Nein_
 * VERSION: 1.3.0
 * DATE: 2026-01-22
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
 *
 * DEMO NAMING:
 *   Format: <matchtype>_<matchid>_<half>.dem
 *   Examples:
 *     ktp_KTP-1735052400-dod_anzio_h1.dem (first half)
 *     ktp_KTP-1735052400-dod_anzio_h2.dem (second half)
 *     ktp_KTP-1735052400-dod_anzio_ot1.dem (overtime round 1)
 *
 * CHANGELOG:
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

#define PLUGIN_NAME    "KTP HLTV Recorder"
#define PLUGIN_VERSION "1.3.0"
#define PLUGIN_AUTHOR  "Nein_"

// Admin flag for HLTV restart command
#define ADMIN_HLTVRESTART ADMIN_RCON

// Match types (must match KTPMatchHandler enum)
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
new g_hltvApiUrl[128];
new g_hltvApiKey[64];
new g_hltvPort = 27020;

// State
new bool:g_isRecording = false;
new g_currentMatchId[64];

// Curl state
new curl_slist:g_curlHeaders = SList_Empty;

public plugin_init() {
    register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);

    // Load configuration
    load_config();

    // Register admin command for HLTV restart
    register_clcmd("say .hltvrestart", "cmd_hltv_restart");
    register_clcmd("say_team .hltvrestart", "cmd_hltv_restart");
    register_clcmd("say /hltvrestart", "cmd_hltv_restart");

    server_print("[KTP HLTV] %s v%s loaded - API: %s port=%d (enabled=%d)",
        PLUGIN_NAME, PLUGIN_VERSION, g_hltvApiUrl, g_hltvPort, g_hltvEnabled);
}

public plugin_cfg() {
    // Load shared Discord configuration
    ktp_discord_load_config();

    // Cleanup orphaned recordings from previous server session
    // If server crashed/restarted while HLTV was recording, the recording continues
    // but plugin state is lost. Send stoprecording to clean up any orphaned session.
    if (g_hltvEnabled) {
        set_task(3.0, "task_cleanup_orphaned_recording");
    }
}

// Cleanup task - delayed to ensure HTTP module is ready
public task_cleanup_orphaned_recording() {
    log_amx("[KTP HLTV] Sending stoprecording to cleanup any orphaned session");
    send_hltv_command("stoprecording");
}

public plugin_end() {
    // Stop any active recording before plugin unloads (server restart, map change, etc.)
    // This ensures HLTV demo is properly finalized even if match didn't end cleanly
    if (g_isRecording && g_hltvEnabled) {
        log_amx("[KTP HLTV] Plugin ending - stopping active recording");
        // Note: This is synchronous call before shutdown, may or may not complete
        send_hltv_command("stoprecording");
    }
}

// Player joined - schedule version display
public client_putinserver(id) {
    // Skip bots and HLTV
    if (is_user_bot(id) || is_user_hltv(id))
        return;

    // Delayed version announcement (5 seconds)
    set_task(5.0, "fn_version_display", id);
}

public fn_version_display(id) {
    // Safety check - player may have disconnected during delay
    if (!is_user_connected(id))
        return;

    // Version announcement
    client_print(id, print_chat, "%s version %s by %s", PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);
}

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

    // Each half gets its own recording - no "already recording" skip
    // Plugin state is lost during map changes, so we start fresh each half

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

    // Store match ID for logging
    copy(g_currentMatchId, charsmax(g_currentMatchId), matchId);

    // Send record command to HLTV via HTTP API
    new command[256];
    formatex(command, charsmax(command), "record %s", demoName);

    if (send_hltv_command(command)) {
        g_isRecording = true;
        server_print("[KTP HLTV] Started recording: %s.dem (%s)", demoName, halfStr);
        log_amx("[KTP HLTV] Recording started: %s.dem (match_id=%s %s)", demoName, matchId, halfStr);
    } else {
        server_print("[KTP HLTV] Failed to start recording!");
        log_amx("[KTP HLTV] ERROR: Failed to start recording (match_id=%s %s)", matchId, halfStr);
    }
}

// Forward from KTPMatchHandler - match ended
public ktp_match_end(const matchId[], const map[], MatchType:matchType, team1Score, team2Score) {
    if (!g_hltvEnabled || !g_isRecording) return;

    // Send stoprecording command to HLTV
    if (send_hltv_command("stoprecording")) {
        g_isRecording = false;
        server_print("[KTP HLTV] Stopped recording (match_id=%s, score=%d-%d)", matchId, team1Score, team2Score);
        log_amx("[KTP HLTV] Recording stopped: match_id=%s score=%d-%d", matchId, team1Score, team2Score);
    } else {
        server_print("[KTP HLTV] Failed to stop recording!");
        log_amx("[KTP HLTV] ERROR: Failed to stop recording (match_id=%s)", matchId);
    }

    g_currentMatchId[0] = EOS;
}

// Load configuration from hltv_recorder.ini
stock load_config() {
    new configsDir[128], configPath[192];
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
        }
    }

    fclose(file);
    server_print("[KTP HLTV] Config loaded: api=%s port=%d enabled=%d", g_hltvApiUrl, g_hltvPort, g_hltvEnabled);
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

    // Free any previous headers
    if (g_curlHeaders != SList_Empty) {
        curl_slist_free_all(g_curlHeaders);
        g_curlHeaders = SList_Empty;
    }

    // Set URL
    curl_easy_setopt(curl, CURLOPT_URL, url);

    // Set headers
    g_curlHeaders = curl_slist_append(SList_Empty, "Content-Type: application/json");

    new authHeader[128];
    formatex(authHeader, charsmax(authHeader), "X-Auth-Key: %s", g_hltvApiKey);
    g_curlHeaders = curl_slist_append(g_curlHeaders, authHeader);

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
    } else {
        log_amx("[KTP HLTV] HTTP API request successful");
    }

    // Cleanup curl handle
    curl_easy_cleanup(curl);

    // Free headers
    if (g_curlHeaders != SList_Empty) {
        curl_slist_free_all(g_curlHeaders);
        g_curlHeaders = SList_Empty;
    }
}

// ============================================================================
// Admin Commands
// ============================================================================

// Store ID of admin who requested restart (for callback notification)
new g_restartRequesterId = 0;

// Admin command to restart paired HLTV instance
public cmd_hltv_restart(id) {
    // Check admin access
    if (!(get_user_flags(id) & ADMIN_HLTVRESTART)) {
        client_print(id, print_chat, "[KTP HLTV] You don't have permission to restart HLTV.");
        return PLUGIN_HANDLED;
    }

    // Check if HLTV is configured
    if (!g_hltvApiUrl[0] || g_hltvPort <= 0) {
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

    // Store requester ID for callback
    g_restartRequesterId = id;

    // Send restart request
    client_print(id, print_chat, "[KTP HLTV] Restarting HLTV on port %d...", g_hltvPort);
    send_hltv_restart();

    return PLUGIN_HANDLED;
}

// Send restart request to HLTV API
stock send_hltv_restart() {
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

    // Free any previous headers
    if (g_curlHeaders != SList_Empty) {
        curl_slist_free_all(g_curlHeaders);
        g_curlHeaders = SList_Empty;
    }

    // Set URL
    curl_easy_setopt(curl, CURLOPT_URL, url);

    // Set headers
    g_curlHeaders = curl_slist_append(SList_Empty, "Content-Type: application/json");

    new authHeader[128];
    formatex(authHeader, charsmax(authHeader), "X-Auth-Key: %s", g_hltvApiKey);
    g_curlHeaders = curl_slist_append(g_curlHeaders, authHeader);

    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, g_curlHeaders);

    // POST with empty body (restart doesn't need payload)
    curl_easy_setopt(curl, CURLOPT_POST, 1);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, 0);

    // Set timeout (30 seconds for restart)
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 30);

    // Debug log
    log_amx("[KTP HLTV] Sending restart request to %s", url);

    // Perform request asynchronously
    curl_easy_perform(curl, "hltv_restart_callback");
}

// Callback for HLTV restart response
public hltv_restart_callback(CURL:curl, CURLcode:code) {
    new success = (code == CURLE_OK);

    if (!success) {
        new error[128];
        curl_easy_strerror(code, error, charsmax(error));
        log_amx("[KTP HLTV] Restart failed: code=%d error='%s'", _:code, error);
    } else {
        log_amx("[KTP HLTV] HLTV restart successful (port %d)", g_hltvPort);
    }

    // Notify the admin who requested the restart
    if (g_restartRequesterId > 0 && is_user_connected(g_restartRequesterId)) {
        if (success) {
            client_print(g_restartRequesterId, print_chat, "[KTP HLTV] HLTV on port %d restarted successfully.", g_hltvPort);
        } else {
            client_print(g_restartRequesterId, print_chat, "[KTP HLTV] HLTV restart failed! Check server logs.");
        }
    }

    g_restartRequesterId = 0;

    // Cleanup curl handle
    curl_easy_cleanup(curl);

    // Free headers
    if (g_curlHeaders != SList_Empty) {
        curl_slist_free_all(g_curlHeaders);
        g_curlHeaders = SList_Empty;
    }
}
