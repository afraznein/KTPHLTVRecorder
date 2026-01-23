# Changelog

All notable changes to KTPHLTVRecorder will be documented in this file.

## [1.3.0] - 2026-01-22

### Fixed
- **Second half recording** - Each half now gets its own separate demo file
  - Previously, second half wouldn't record due to "already recording" skip logic
  - Plugin state is lost during map changes, so each half starts fresh

### Added
- **Half suffix in demo names** - `_h1`, `_h2`, `_ot1`, `_ot2`, etc.
  - Example: `ktp_KTP-1735052400-dod_anzio_h1.dem` (first half)
  - Example: `ktp_KTP-1735052400-dod_anzio_h2.dem` (second half)
  - Example: `ktp_KTP-1735052400-dod_anzio_ot1.dem` (overtime round 1)

### Removed
- **"Already recording" skip logic** - No longer tries to continue recording across halves

---

## [1.2.2] - 2026-01-13

### Fixed
- **Orphaned recording bug** - Sends `stoprecording` on plugin startup and shutdown
  - Prevents orphaned recordings when server restarts mid-match
  - Cleans up any in-progress recording on plugin load

---

## [1.2.1] - 2026-01-13

### Added
- **Discord audit notifications** for `.hltvrestart` command
  - Posts to all configured audit channels (KTP Discord and 1.3 Discord)
  - Shows admin name, SteamID, and HLTV port being restarted
  - Uses `:ktp:` emoji in embed title

### Technical
- Added `ktp_discord.inc` integration for Discord embeds
- Added `plugin_cfg()` to load shared Discord configuration

## [1.2.0] - 2026-01-13

### Added
- **`.hltvrestart` admin command** - Restart paired HLTV instance from game server
  - Requires ADMIN_RCON access level
  - Sends HTTP POST to `/hltv/<port>/restart` endpoint
  - Notifies admin of success/failure via chat

### Technical
- Updated HLTV API (hltv-api.py) with `/hltv/<port>/restart` endpoint
- Restart uses `systemctl restart hltv@<port>` on data server

## [1.1.1] - 2026-01-10

### Added
- Support for new explicit overtime match types (`MATCH_TYPE_KTP_OT`, `MATCH_TYPE_DRAFT_OT`)
- Demo naming: `ktpOT_<matchid>.dem` and `draftOT_<matchid>.dem`

### Changed
- Updated MatchType enum to match KTPMatchHandler v0.10.43

## [1.1.0] - 2026-01-10

### Changed
- **Breaking**: Switched from UDP RCON to HTTP API communication
- Replaced Sockets module dependency with Curl module
- Commands now sent via HTTP POST to data server API (port 8087)
- API injects commands to HLTV via FIFO pipes

### Why
- GoldSrc HLTV doesn't support standard UDP RCON protocol
- FIFO pipe injection provides reliable command delivery
- HTTP API allows centralized HLTV control from any game server

### Config Changes
- Removed: `hltv_ip`, `hltv_rcon`
- Added: `hltv_api_url`, `hltv_api_key`
- Kept: `hltv_enabled`, `hltv_port`

## [1.0.7] - 2026-01-09

### Changed
- Rewrote RCON to try simple RCON first (works with most HLTV versions)
- Falls back to challenge-response if server requires it
- Assumes success if no response (HLTV often doesn't ack successful commands)
- Added extensive AMX logging for debugging RCON issues
- Fixed packet building to manually set 0xFF header bytes

## [1.0.6] - 2026-01-09

### Changed
- Implemented challenge-response RCON protocol
- HLTV was rejecting simple RCON with "Invalid rcon challenge"
- Now requests challenge first, parses response, then sends command with challenge

## [1.0.5] - 2026-01-09

### Changed
- Updated to handle new `ktp_match_start(matchId, map, type, half)` signature
- Idempotent recording - continues existing recording through map changes
- Added half parameter logging (1=first half, 2=second half, 101+=OT rounds)

## [1.0.4] - 2026-01

### Changed
- Version bump for live server deployment
- Tested with KTPMatchHandler v0.10.30

## [1.0.1] - 2025-12-29

### Changed
- Demo naming simplified from `<type>_<matchid>_<map>.dem` to `<type>_<matchid>.dem`
- Removed redundant map suffix since matchId already contains map name

## [1.0.0] - 2025-12-24

### Added
- Initial release
- Hooks `ktp_match_start` and `ktp_match_end` forwards from KTPMatchHandler
- Automatic demo recording for all match types (`.ktp`, `.scrim`, `.draft`, `.12man`)
- UDP RCON communication with paired HLTV instance
- Configurable HLTV IP, port, and RCON password via `hltv_recorder.ini`
- Demo naming format: `<matchtype>_<matchid>_<map>.dem`
- Console and AMX logging for recording start/stop events
