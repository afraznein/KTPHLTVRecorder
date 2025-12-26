/* KTP HLTV Recorder v1.0.0
 * Automatic HLTV demo recording triggered by KTPMatchHandler
 *
 * AUTHOR: Nein_
 * VERSION: 1.0.0
 * DATE: 2025-12-24
 *
 * DESCRIPTION:
 * This plugin hooks into KTPMatchHandler's match start/end forwards
 * and sends RCON commands to a paired HLTV server to start/stop recording.
 *
 * REQUIREMENTS:
 * - KTPMatchHandler v0.10.1+ (for ktp_match_start/ktp_match_end forwards)
 * - Sockets module (for UDP RCON to HLTV)
 *
 * CONFIGURATION (hltv_recorder.ini):
 *   hltv_enabled = 1
 *   hltv_ip = 74.91.112.242
 *   hltv_port = 27020
 *   hltv_rcon = ktpadmin
 *
 * DEMO NAMING:
 *   Format: <matchtype>_<matchid>_<map>.dem
 *   Example: ktp_KTP-1735052400-dod_anzio_dod_anzio.dem
 */

#include <amxmodx>
#include <amxmisc>
#include <sockets>

#define PLUGIN_NAME    "KTP HLTV Recorder"
#define PLUGIN_VERSION "1.0.0"
#define PLUGIN_AUTHOR  "Nein_"

// Match types (must match KTPMatchHandler enum)
enum MatchType {
    MATCH_TYPE_COMPETITIVE = 0,
    MATCH_TYPE_SCRIM = 1,
    MATCH_TYPE_12MAN = 2,
    MATCH_TYPE_DRAFT = 3
};

// Configuration
new g_hltvEnabled = 0;
new g_hltvIp[64];
new g_hltvPort = 27020;
new g_hltvRcon[64];

// State
new bool:g_isRecording = false;
new g_currentMatchId[64];

public plugin_init() {
    register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);

    // Load configuration
    load_config();

    server_print("[KTP HLTV] %s v%s loaded - HLTV: %s:%d (enabled=%d)",
        PLUGIN_NAME, PLUGIN_VERSION, g_hltvIp, g_hltvPort, g_hltvEnabled);
}

// Forward from KTPMatchHandler - match started
public ktp_match_start(const matchId[], const map[], MatchType:matchType) {
    if (!g_hltvEnabled) return;

    // Build demo name based on match type
    new demoName[128];
    new typeStr[16];

    switch (matchType) {
        case MATCH_TYPE_COMPETITIVE: copy(typeStr, charsmax(typeStr), "ktp");
        case MATCH_TYPE_SCRIM:       copy(typeStr, charsmax(typeStr), "scrim");
        case MATCH_TYPE_12MAN:       copy(typeStr, charsmax(typeStr), "12man");
        case MATCH_TYPE_DRAFT:       copy(typeStr, charsmax(typeStr), "draft");
        default:                     copy(typeStr, charsmax(typeStr), "match");
    }

    // Demo name format: type_matchid_map
    formatex(demoName, charsmax(demoName), "%s_%s_%s", typeStr, matchId, map);

    // Store match ID for logging
    copy(g_currentMatchId, charsmax(g_currentMatchId), matchId);

    // Send record command to HLTV
    if (send_hltv_rcon("record %s", demoName)) {
        g_isRecording = true;
        server_print("[KTP HLTV] Started recording: %s.dem", demoName);
        log_amx("[KTP HLTV] Recording started: %s.dem (match_id=%s)", demoName, matchId);
    } else {
        server_print("[KTP HLTV] Failed to start recording!");
        log_amx("[KTP HLTV] ERROR: Failed to start recording (match_id=%s)", matchId);
    }
}

// Forward from KTPMatchHandler - match ended
public ktp_match_end(const matchId[], const map[], MatchType:matchType, team1Score, team2Score) {
    if (!g_hltvEnabled || !g_isRecording) return;

    // Send stoprecording command to HLTV
    if (send_hltv_rcon("stoprecording")) {
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

        // Parse key = value
        if (parse(line, key, charsmax(key), value, charsmax(value)) < 2)
            continue;

        // Remove = from key if present
        replace(key, charsmax(key), "=", "");
        trim(key);
        trim(value);

        if (equali(key, "hltv_enabled")) {
            g_hltvEnabled = str_to_num(value);
        } else if (equali(key, "hltv_ip")) {
            copy(g_hltvIp, charsmax(g_hltvIp), value);
        } else if (equali(key, "hltv_port")) {
            g_hltvPort = str_to_num(value);
        } else if (equali(key, "hltv_rcon")) {
            copy(g_hltvRcon, charsmax(g_hltvRcon), value);
        }
    }

    fclose(file);
    server_print("[KTP HLTV] Config loaded: %s:%d enabled=%d", g_hltvIp, g_hltvPort, g_hltvEnabled);
}

// Send RCON command to HLTV server via UDP
stock bool:send_hltv_rcon(const fmt[], any:...) {
    new command[256];
    vformat(command, charsmax(command), fmt, 2);

    // Build RCON packet: \xff\xff\xff\xffrcon <password> <command>
    new packet[512];
    formatex(packet, charsmax(packet), "%c%c%c%crcon %s %s",
        0xFF, 0xFF, 0xFF, 0xFF, g_hltvRcon, command);

    // Create UDP socket
    new sockError;
    new sock = socket_open(g_hltvIp, g_hltvPort, SOCKET_UDP, sockError);
    if (sock < 0) {
        server_print("[KTP HLTV] Socket error %d: could not connect to %s:%d", sockError, g_hltvIp, g_hltvPort);
        return false;
    }

    // Send packet
    new packetLen = strlen(packet);
    new sent = socket_send(sock, packet, packetLen);
    socket_close(sock);

    if (sent != packetLen) {
        server_print("[KTP HLTV] Socket error: sent %d of %d bytes", sent, packetLen);
        return false;
    }

    server_print("[KTP HLTV] RCON sent to %s:%d -> %s", g_hltvIp, g_hltvPort, command);
    return true;
}
