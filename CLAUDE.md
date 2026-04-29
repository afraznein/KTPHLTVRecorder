# KTPHLTVRecorder - Claude Code Context

## Compile Command
To compile this plugin, use:
```bash
wsl bash -c "cd '/mnt/n/Nein_/KTP Git Projects/KTPHLTVRecorder' && bash compile.sh"
```

This will:
1. Compile `KTPHLTVRecorder.sma` using KTPAMXX compiler
2. Output to `compiled/KTPHLTVRecorder.amxx`
3. Auto-stage to `N:\Nein_\KTP Git Projects\KTP DoD Server\serverfiles\dod\addons\ktpamx\plugins\`

## Project Structure
- `KTPHLTVRecorder.sma` - Main plugin source
- `compile.sh` - WSL compile script (also generates `build_info.inc` with git SHA + UTC build time)
- `compiled/` - Compiled .amxx output
- `documents/hltv_recorder.ini.example` - Config template
- `CHANGELOG.md` - Version history
- `README.md` - Documentation
- `.github/workflows/smoke.yml` - Tier 1 build-time smoke (calls KTPInfrastructure's reusable workflow)

## Purpose
Hooks `ktp_match_start` / `ktp_match_end` from KTPMatchHandler and drives HLTV demo recording via the data server's HLTV control HTTP API. One game server pairs 1:1 with one HLTV proxy instance; the plugin POSTs `record` / `stoprecording` commands keyed on the configured `hltv_port`.

## Dependencies
- **KTPMatchHandler v0.10.4+** — provides `ktp_match_start` and `ktp_match_end` forwards
- **KTP AMXX Curl module** — non-blocking HTTP POST to the HLTV API
- **`ktp_version_reporter` shared include** — registers with fleet-wide `amx_ktp_versions` rcon command

## Configuration
Per-server config at `addons/ktpamx/configs/hltv_recorder.ini`:
```ini
hltv_enabled = 1
hltv_api_url = http://<data-server>:8087
hltv_api_key = <your-api-key>
hltv_port = <paired-hltv-port>
```

Each game server needs its own config with its paired HLTV port. The HLTV port mapping is documented in `KTP Git Projects/CLAUDE.md` under "Current Servers" (game ports 27015-27019, HLTV ports 27020-27044 across the fleet).

## HLTV Control Architecture
```
Game Server Plugin --HTTP POST--> HLTV API (data server :8087) --FIFO pipe--> HLTV Instance
```

The HLTV API service, FIFO pipes, and HLTV wrapper script all live on the data server. See `KTPInfrastructure/docs/TECHNICAL_GUIDE.md` for the implementation-side details (paths, systemd units, auth setup).

## Recording Lifecycle (v1.5.0+)
HLTV has a ~60s delay buffer. Naive `stoprecording` on map change kills the buffer mid-flight and loses ~47s of gameplay. The current flow avoids that:

1. **Half 1 start** (`ktp_match_start`, half=1) → `record <type>_<matchid>_h1`
2. **Half 1 end (map change)** → no-op; HLTV keeps recording, buffer drains naturally
3. **Half 2 start** (`ktp_match_start`, half=2) → `stoprecording` (safe; buffer drained), then `record <type>_<matchid>_h2`
4. **Match end** (`ktp_match_end`) → schedules delayed `stoprecording` after `hltv_stop_delay` seconds (default 75)
5. **Edge: map changes before delayed stop fires** → `plugin_cfg()` detects `_ktp_hltv_pending_stop` localinfo and sends `stoprecording`

**Trade-off:** half-1 demo includes ~60s of half-2 warmup at the end. All actual match gameplay is captured fully.

## v1.6.0 — record-while-recording bleed fix
HLTV silently ignored `record` if already recording. Result: half-2 commands could land on a still-active half-1 stream and bleed across matches. v1.6.0 polls the HLTV API's `/state` endpoint to confirm idle before issuing `record`. See `CHANGELOG.md` for the full audit + fix.

## Demo Naming
Format: `<matchtype>_<matchid>_<half>.dem` (matchId already contains map name).
Examples: `ktp_KTP-1735052400-dod_anzio_h1.dem`, `scrim_KTP-1735052400-dod_flash_h2.dem`, `ktpOT_KTP-1735052400-dod_anzio_ot1.dem`.

## Admin Commands
- **`.hltvrestart`** — restart paired HLTV instance via the API (ADMIN_RCON, sends Discord audit notification). Useful when HLTV disconnects or gets stuck.

## Server Deployment
Deploy compiled plugin to production servers using Python/Paramiko (preferred over shell SSH).

**Remote Path:** `~/dod-{port}/serverfiles/dod/addons/ktpamx/plugins/KTPHLTVRecorder.amxx`

See `N:\Nein_\KTP Git Projects\CLAUDE.md` for full paramiko SSH documentation, server credentials, and working deployment scripts. Plugin takes effect on next `plugin_init` (map change or full restart in extension mode — see project-root CLAUDE.md "Deployment Flow").

## Related Projects
- `N:\Nein_\KTP Git Projects\KTPMatchHandler` - Source of `ktp_match_start` / `ktp_match_end` forwards
- `N:\Nein_\KTP Git Projects\KTPInfrastructure` - HLTV API service + FIFO pipe + wrapper scripts (data server)
- `N:\Nein_\KTP Git Projects\KTPAMXX` - Custom AMX Mod X fork (compiler + curl module + shared include)
- `N:\Nein_\KTP Git Projects\KTP DoD Server` - Test server with staged plugins
- `N:\Nein_\KTP Git Projects\TODO.md` - Development TODO list

## Key Files to Update on Version Bump
1. `KTPHLTVRecorder.sma` - `#define PLUGIN_VERSION`
2. `CHANGELOG.md` - Add new version section
3. `README.md` - Update version in header
4. `N:\Nein_\KTP Git Projects\TODO.md` - Update completed/pending items
