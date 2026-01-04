# Changelog

All notable changes to KTPHLTVRecorder will be documented in this file.

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
