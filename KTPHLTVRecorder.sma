/* KTP HLTV Recorder v1.7.0
 * Match window logger (Phase F+A architecture)
 *
 * AUTHOR: Nein_
 * VERSION: 1.7.0
 * DATE: 2026-04-29
 *
 * DESCRIPTION:
 * In v1.7.0 the recording-control responsibility moves from this plugin to
 * HLTV itself: each HLTV instance is configured with a port-stamped
 * `record auto_<friendly>` directive in its cfg, so HLTV is always recording
 * and auto-rotates per source-reconnect with file names like
 * `auto_ny2-2604291902-dod_anzio.dem`. This plugin no longer issues
 * `record` / `stoprecording` commands.
 *
 * What this plugin does in v1.7.0:
 *   - Emits structured MATCH_WINDOW_OPEN / MATCH_WINDOW_CLOSE log lines on
 *     ktp_match_start / ktp_match_end. The hltv-demo-renamer service reads
 *     these to associate HLTV's auto-* demo segments with match_ids and
 *     rename them to the canonical `<type>_<matchid>_h<half>_<map>.dem`
 *     format post-match.
 *   - Provides the `.hltvrestart` admin command (unchanged from v1.6.0).
 *
 * What this plugin no longer does (intentional):
 *   - Issuing `record` / `stoprecording` HTTP commands. Per the 2026-04-29
 *     architectural investigation, HLTV processes record commands one-per-
 *     source-reconnect and auto-rotates with a sticky basename; per-match
 *     commands cause the bleed bug regardless of plugin-side polling
 *     cleverness. Removing them eliminates the bug at the architectural
 *     level.
 *   - /state polling, idle confirmation, verify-after-record, delayed stop.
 *     None of these are meaningful when the plugin doesn't drive recording.
 *   - Bleed-detection alerts. There's nothing to bleed since the plugin
 *     doesn't issue per-match record commands.
 *
 * REQUIREMENTS:
 * - KTPMatchHandler v0.10.1+ (for ktp_match_start / ktp_match_end forwards)
 * - Curl module (for the `.hltvrestart` admin command)
 * - Each HLTV instance's cfg must have `record auto_<friendly>` (Phase 1a)
 *
 * CONFIGURATION (hltv_recorder.ini):
 *   hltv_enabled  = 1               ; gates the plugin entirely (legacy flag)
 *   hltv_api_url  = http://...:8087  ; used by .hltvrestart + match-start /state
 *   hltv_api_key  = <key>            ; used by .hltvrestart + match-start /state
 *   hltv_port     = 27020            ; paired HLTV port (logged for renamer)
 *   hltv_friendly = ATL1             ; UPPER fleet alias (NEW v1.7.0) — drives
 *                                    ; the portal-URL hint in match-start chat
 *                                    ; and the demo glob the renamer produces
 *
 * (hltv_stop_delay is ignored in v1.7.0; left in config for back-compat
 * during rollout — operator can remove the line at next config touch.)
 *
 * LOG OUTPUT FORMAT (the renamer's input contract):
 *   [KTP HLTV] MATCH_WINDOW_OPEN  match_id=<id> half=<n> match_type=<t> map=<m> hltv_port=<p> wall_time=<unix>
 *   [KTP HLTV] MATCH_WINDOW_CLOSE match_id=<id>           match_type=<t>           hltv_port=<p> wall_time=<unix> score=<a>-<b>
 *
 * Both lines are emitted regardless of `hltv_enabled` value. The renamer
 * reads these from each game server's amxx log via paramiko-tail.
 *
 * CHANGELOG (most recent first; full history in CHANGELOG.md):
 *   v1.7.0 (2026-04-29):
 *     - Removed all record / stoprecording / poll / verify logic.
 *     - HLTV cfg `record auto_<friendly>` is now the recording trigger.
 *     - Added MATCH_WINDOW_OPEN / MATCH_WINDOW_CLOSE structured log lines
 *       for the hltv-demo-renamer service (Phase 1c).
 *     - Plugin drops from 1118 lines to ~280 lines.
 *   v1.6.0 (2026-04-28): poll-before-record bleed fix (superseded by v1.7.0)
 *   v1.5.0 (2026-01-30): preserve-buffer-across-map-change recording lifecycle
 *   v1.2.1 (2026-01-13): admin .hltvrestart command (preserved in v1.7.0)
 */

#include <amxmodx>
#include <amxmisc>
#include <curl>
#include <ktp_discord>
#include <ktp_version_reporter>

#define PLUGIN_NAME    "KTP HLTV Recorder"
#define PLUGIN_VERSION "1.7.0"
#define PLUGIN_AUTHOR  "Nein_"

// Admin flag for HLTV restart command
#define ADMIN_HLTVRESTART ADMIN_RCON

// Match types — mirrors KTPMatchHandler enum (verified against v0.10.121).
// Used only for the match_type=<str> field in log lines; the renamer maps
// these to file-prefix conventions (ktp_, scrim_, 12man_, draft_, ktpOT_,
// draftOT_) when renaming auto-* segments.
enum MatchType {
    MATCH_TYPE_COMPETITIVE = 0,
    MATCH_TYPE_SCRIM = 1,
    MATCH_TYPE_12MAN = 2,
    MATCH_TYPE_DRAFT = 3,
    MATCH_TYPE_KTP_OT = 4,
    MATCH_TYPE_DRAFT_OT = 5
};

// Configuration (loaded from hltv_recorder.ini)
new g_hltvEnabled = 0;
new g_hltvApiUrl[256];
new g_hltvApiKey[64];
new g_hltvPort = 27020;
new g_hltvFriendly[16];   // UPPER fleet alias (e.g., "ATL1") — see config docs above

// State (kept minimal in v1.7.0 — only for log-line context, not control)
new g_currentMatchId[64];

// Pending context for the async match-start health-check callback. Set in
// ktp_match_start, read in hltv_health_check_callback. One match in flight at
// a time on a given server, so a single global set is fine.
new g_pendingExpectedDemo[160];
new g_pendingHalfStr[16];
new g_pendingPortalPath[64];

// Curl headers — created once at init, reused by .hltvrestart and the
// match-start /state health check.
// IMPORTANT: never free/recreate while requests are in flight (use-after-free).
new curl_slist:g_curlHeaders = SList_Empty;

public plugin_init() {
    register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);
    KTP_RegisterVersion(PLUGIN_NAME, PLUGIN_VERSION);

    load_config();
    init_curl_headers();

    // Admin command for HLTV restart (kept from v1.6.0 — useful for
    // operator-initiated proxy resets when HLTV gets stuck).
    register_clcmd("say .hltvrestart", "cmd_hltv_restart");
    register_clcmd("say_team .hltvrestart", "cmd_hltv_restart");
    register_clcmd("say /hltvrestart", "cmd_hltv_restart");
}

public plugin_cfg() {
    // Load shared Discord configuration for .hltvrestart audit alerts.
    ktp_discord_load_config();
}

public plugin_end() {
    // No cleanup needed — HLTV recording is independent of plugin lifecycle
    // in v1.7.0. The HLTV process keeps recording across plugin reloads /
    // map changes / restarts; renamer associates demos to matches via the
    // logged window timestamps, not via plugin state.
}

// Build the persistent curl header list. Called ONCE after config load.
// Headers are reused across all requests; never rebuilt mid-flight.
stock init_curl_headers() {
    if (g_curlHeaders != SList_Empty)
        return;

    if (!g_hltvApiKey[0]) {
        log_amx("[KTP HLTV] WARNING: hltv_api_key not configured — .hltvrestart will fail");
        return;
    }

    g_curlHeaders = curl_slist_append(SList_Empty, "Content-Type: application/json");

    new authHeader[128];
    formatex(authHeader, charsmax(authHeader), "X-Auth-Key: %s", g_hltvApiKey);
    g_curlHeaders = curl_slist_append(g_curlHeaders, authHeader);
}

// ============================================================================
// Match Window Logging
// ============================================================================
// MATCH_WINDOW_OPEN / MATCH_WINDOW_CLOSE log lines are the contract this
// plugin exposes to the hltv-demo-renamer service. Format MUST stay stable
// across versions; the renamer parses with `match_id=([^ ]+) ...` regexes.

// IMPORTANT: ktp-organize-hltv-demos.sh's matchtype regex is `[a-z0-9]+`
// (lowercase only). Mixed-case `ktpOT`/`draftOT` would NOT match and OT
// demos would never auto-organize. All match types must stay lowercase.
stock match_type_string(MatchType:matchType, output[], maxlen) {
    switch (matchType) {
        case MATCH_TYPE_COMPETITIVE: copy(output, maxlen, "ktp");
        case MATCH_TYPE_SCRIM:       copy(output, maxlen, "scrim");
        case MATCH_TYPE_12MAN:       copy(output, maxlen, "12man");
        case MATCH_TYPE_DRAFT:       copy(output, maxlen, "draft");
        case MATCH_TYPE_KTP_OT:      copy(output, maxlen, "ktpot");
        case MATCH_TYPE_DRAFT_OT:    copy(output, maxlen, "draftot");
        default:                     copy(output, maxlen, "match");
    }
}

stock half_string(half, output[], maxlen) {
    if (half <= 2) {
        formatex(output, maxlen, "h%d", half);
    } else {
        formatex(output, maxlen, "ot%d", half - 100);
    }
}

// Build the search-glob for a given match window. The renamer produces files
// of the form:
//   <matchtype>_<match_id>-<UPPER_FRIENDLY>(_h<n>)?-<hltv_ts>-<map>.dem
// e.g., ktp_1777070040-ATL1_h1-2604241856-dod_lennon5_b1.dem
// We can't predict <hltv_ts> at match_start (HLTV picks it on source-rotate),
// so we hand players a glob keyed on the parts we DO know — match_id and
// UPPER_FRIENDLY. They can grep their filename listing or hit the portal.
stock build_expected_demo_glob(const matchId[], MatchType:matchType, half, output[], maxlen) {
    new typeStr[16], halfStr[16];
    match_type_string(matchType, typeStr, charsmax(typeStr));
    half_string(half, halfStr, charsmax(halfStr));
    if (g_hltvFriendly[0]) {
        formatex(output, maxlen, "%s_%s-%s_%s-*.dem", typeStr, matchId, g_hltvFriendly, halfStr);
    } else {
        // Friendly not configured — best-effort glob without it.
        formatex(output, maxlen, "%s_%s-*_%s-*.dem", typeStr, matchId, halfStr);
    }
}

// Build the per-friendly portal URL fragment players can copy-paste.
// Returns just the path segment (caller can prepend portal base if desired).
stock build_portal_path(MatchType:matchType, output[], maxlen) {
    new typeStr[16];
    match_type_string(matchType, typeStr, charsmax(typeStr));
    if (g_hltvFriendly[0]) {
        formatex(output, maxlen, "/demos/%s/%s/", g_hltvFriendly, typeStr);
    } else {
        formatex(output, maxlen, "/demos/");
    }
}

// Forward from KTPMatchHandler — match/half started.
// half: 1=1st half, 2=2nd half, 101+=OT round (101, 102, 103...)
public ktp_match_start(const matchId[], const map[], MatchType:matchType, half) {
    new typeStr[16], halfStr[16];
    match_type_string(matchType, typeStr, charsmax(typeStr));
    half_string(half, halfStr, charsmax(halfStr));

    // Structured log line — primary contract with hltv-demo-renamer service.
    log_amx(
        "[KTP HLTV] MATCH_WINDOW_OPEN match_id=%s half=%s match_type=%s map=%s hltv_port=%d wall_time=%d enabled=%d",
        matchId, halfStr, typeStr, map, g_hltvPort, get_systime(), g_hltvEnabled
    );

    copy(g_currentMatchId, charsmax(g_currentMatchId), matchId);

    // Player-facing chat — announce the expected post-rename demo glob AFTER
    // verifying HLTV is alive and recording. Stash context for the async
    // /state callback; chat fires from hltv_health_check_callback.
    if (g_hltvEnabled) {
        build_expected_demo_glob(matchId, matchType, half,
            g_pendingExpectedDemo, charsmax(g_pendingExpectedDemo));
        build_portal_path(matchType, g_pendingPortalPath, charsmax(g_pendingPortalPath));
        copy(g_pendingHalfStr, charsmax(g_pendingHalfStr), halfStr);
        request_hltv_health_check();
    }
}

// Forward from KTPMatchHandler — match ended (whole match, both halves done).
public ktp_match_end(const matchId[], const map[], MatchType:matchType, team1Score, team2Score) {
    new typeStr[16];
    match_type_string(matchType, typeStr, charsmax(typeStr));

    // Structured log line — primary contract with hltv-demo-renamer service.
    log_amx(
        "[KTP HLTV] MATCH_WINDOW_CLOSE match_id=%s match_type=%s map=%s hltv_port=%d wall_time=%d score=%d-%d",
        matchId, typeStr, map, g_hltvPort, get_systime(), team1Score, team2Score
    );

    // Player-facing chat — confirm match is recorded. Renamer (Phase 1c)
    // produces the canonical filenames within ~30s of this log line; the
    // 4 AM organizer then sorts them into the per-friendly portal directory.
    if (g_hltvEnabled) {
        if (g_hltvFriendly[0]) {
            client_print(0, print_chat,
                "[KTP] Match recorded — find %s_%s-%s_*.dem at http://74.91.112.242/demos/%s/%s/ after the next 4 AM ET sort",
                typeStr, matchId, g_hltvFriendly, g_hltvFriendly, typeStr);
        } else {
            client_print(0, print_chat,
                "[KTP] Match recorded — find %s_%s-*.dem at http://74.91.112.242/demos/ after the next 4 AM ET sort",
                typeStr, matchId);
        }
    }

    g_currentMatchId[0] = EOS;
}

// ============================================================================
// HLTV Health Check (match_start)
// ============================================================================
// Async GET /hltv/<port>/state on match start. Verifies the paired HLTV is
// up and actively recording before we promise players a specific demo name.
// On failure modes (API unreachable, process down, recording=false) we post
// a warning instead of the optimistic announcement.
//
// Context (g_pendingExpectedDemo / g_pendingHalfStr) is stashed by
// ktp_match_start before we kick this off — passing it through curl
// userdata would mean re-encoding strings as cell arrays, and we never have
// more than one match-start in flight on a given server.

stock request_hltv_health_check() {
    if (!g_hltvApiUrl[0] || g_curlHeaders == SList_Empty) {
        // Config incomplete — fall back to optimistic announcement so players
        // still see a predicted demo name. Operator will see config warnings
        // in plugin_init logs.
        client_print(0, print_chat, "[KTP] HLTV %s recording: %s",
            g_pendingHalfStr, g_pendingExpectedDemo);
        return;
    }

    new url[256];
    formatex(url, charsmax(url), "%s/hltv/%d/state", g_hltvApiUrl, g_hltvPort);

    new CURL:curl = curl_easy_init();
    if (!curl) {
        log_amx("[KTP HLTV] ERROR: curl_easy_init() failed for /state");
        client_print(0, print_chat, "[KTP] HLTV %s recording: %s",
            g_pendingHalfStr, g_pendingExpectedDemo);
        return;
    }

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, g_curlHeaders);
    curl_easy_setopt(curl, CURLOPT_HTTPGET, 1);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 5);

    curl_easy_perform(curl, "hltv_health_check_callback");
}

public hltv_health_check_callback(CURL:curl, CURLcode:code) {
    new bool:reachable = false;
    new bool:processRunning = false;
    new bool:recording = false;
    new body[512];
    body[0] = EOS;

    if (code == CURLE_OK) {
        new httpCode;
        curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, httpCode);

        if (httpCode >= 200 && httpCode < 300) {
            curl_get_response_body(curl, body, charsmax(body));
            reachable = true;

            // Naive substring parse — JSON is small and well-formed (see
            // hltv-api.py _parse_state). Match both space and no-space JSON
            // serializations to be defensive across module versions.
            // "already_recording_warning" doesn't false-match "recording":
            // the chars between "recording" and ":" differ.
            if (contain(body, "^"process_running^": true") != -1 ||
                contain(body, "^"process_running^":true") != -1) {
                processRunning = true;
            }
            if (contain(body, "^"recording^": true") != -1 ||
                contain(body, "^"recording^":true") != -1) {
                recording = true;
            }
        }
    }

    curl_easy_cleanup(curl);

    if (!reachable) {
        client_print(0, print_chat,
            "[KTP] WARNING: HLTV API unreachable — recording status unknown for this match.");
        log_amx("[KTP HLTV] /state unreachable at match start (port %d, code=%d)",
                g_hltvPort, _:code);
    } else if (!processRunning) {
        client_print(0, print_chat,
            "[KTP] WARNING: HLTV %d is offline — this match may NOT be recorded.",
            g_hltvPort);
        log_amx("[KTP HLTV] HLTV process not running at match start (port %d)", g_hltvPort);
    } else if (!recording) {
        client_print(0, print_chat,
            "[KTP] WARNING: HLTV %d is up but not recording — match may be missing.",
            g_hltvPort);
        log_amx("[KTP HLTV] HLTV up but not recording at match start (port %d)", g_hltvPort);
    } else {
        client_print(0, print_chat,
            "[KTP] HLTV %s recording: %s  (portal: http://74.91.112.242%s)",
            g_pendingHalfStr, g_pendingExpectedDemo, g_pendingPortalPath);
    }
}

// ============================================================================
// Configuration
// ============================================================================

// Load configuration from hltv_recorder.ini.
// Tolerates the legacy hltv_stop_delay line (silently ignored in v1.7.0).
stock load_config() {
    new configsDir[256], configPath[320];
    get_configsdir(configsDir, charsmax(configsDir));
    formatex(configPath, charsmax(configPath), "%s/hltv_recorder.ini", configsDir);

    if (!file_exists(configPath)) {
        server_print("[KTP HLTV] Config not found: %s — .hltvrestart unavailable", configPath);
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
        if (!line[0] || line[0] == ';' || line[0] == '#')
            continue;

        new eqPos = contain(line, "=");
        if (eqPos < 1) continue;

        copy(key, min(eqPos, charsmax(key)), line);
        trim(key);

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
        } else if (equali(key, "hltv_friendly")) {
            copy(g_hltvFriendly, charsmax(g_hltvFriendly), value);
        }
        // hltv_stop_delay intentionally ignored in v1.7.0 (legacy field).
    }

    fclose(file);

    if (!g_hltvFriendly[0]) {
        server_print("[KTP HLTV] WARNING: hltv_friendly not configured — chat announcements will fall back to a generic glob");
    }

    server_print("[KTP HLTV] Config loaded: api=%s port=%d friendly=%s enabled=%d (v1.7.0 — recording driven by HLTV cfg)",
                 g_hltvApiUrl, g_hltvPort, g_hltvFriendly[0] ? g_hltvFriendly : "<unset>", g_hltvEnabled);
}

// ============================================================================
// Admin Commands — .hltvrestart
// ============================================================================

public cmd_hltv_restart(id) {
    if (!(get_user_flags(id) & ADMIN_HLTVRESTART)) {
        client_print(id, print_chat, "[KTP HLTV] You don't have permission to restart HLTV.");
        return PLUGIN_HANDLED;
    }

    if (!g_hltvApiUrl[0]) {
        client_print(id, print_chat, "[KTP HLTV] HLTV not configured for this server.");
        return PLUGIN_HANDLED;
    }

    new adminName[32], adminAuth[35];
    get_user_name(id, adminName, charsmax(adminName));
    get_user_authid(id, adminAuth, charsmax(adminAuth));

    log_amx("[KTP HLTV] Admin %s <%s> requested HLTV restart (port %d)", adminName, adminAuth, g_hltvPort);

    new description[256];
    formatex(description, charsmax(description),
        "**Admin:** %s (`%s`)^n**HLTV Port:** %d",
        adminName, adminAuth, g_hltvPort);
    ktp_discord_send_embed_audit("<:ktp:1105490705188659272> HLTV Restart", description, KTP_DISCORD_COLOR_ORANGE);

    client_print(id, print_chat, "[KTP HLTV] Restarting HLTV on port %d...", g_hltvPort);
    send_hltv_restart(id);

    return PLUGIN_HANDLED;
}

stock send_hltv_restart(requesterId = 0) {
    if (!g_hltvApiUrl[0]) {
        log_amx("[KTP HLTV] ERROR: hltv_api_url not configured");
        return;
    }

    new url[256];
    formatex(url, charsmax(url), "%s/hltv/%d/restart", g_hltvApiUrl, g_hltvPort);

    new CURL:curl = curl_easy_init();
    if (!curl) {
        log_amx("[KTP HLTV] ERROR: curl_easy_init() failed for restart");
        return;
    }

    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, g_curlHeaders);
    curl_easy_setopt(curl, CURLOPT_POST, 1);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, 0);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 30);

    log_amx("[KTP HLTV] Sending restart request to %s", url);

    new data[1];
    data[0] = requesterId;
    curl_easy_perform(curl, "hltv_restart_callback", data, sizeof(data));
}

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

    if (requesterId > 0 && requesterId <= MAX_PLAYERS && is_user_connected(requesterId)) {
        if (success) {
            client_print(requesterId, print_chat, "[KTP HLTV] HLTV on port %d restarted successfully.", g_hltvPort);
        } else {
            client_print(requesterId, print_chat, "[KTP HLTV] HLTV restart failed! Check server logs.");
        }
    }
}
