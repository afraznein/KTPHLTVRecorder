# KTPHLTVRecorder

**Version 1.5.4** - Automatic HLTV demo recording for KTP competitive matches.

## Overview

KTPHLTVRecorder hooks into [KTPMatchHandler](https://github.com/afraznein/KTPMatchHandler) match events and automatically controls HLTV demo recording via HTTP API. When a match starts, recording begins. When it ends, recording stops.

## Features

- Automatic recording for all match types (`.ktp`, `.scrim`, `.draft`, `.12man`, `.ktpOT`, `.draftOT`)
- 1:1 game server to HLTV pairing
- Descriptive demo naming: `<type>_<matchid>_<half>.dem` (matchId includes map)
- HTTP API communication with HLTV control service
- **Pre-match HLTV health check** - Verifies HLTV API before recording, auto-recovery on failure
- **Discord + chat alerts** - Notifies admins when HLTV recording fails
- **Admin HLTV restart command** - `.hltvrestart` or `/hltvrestart` to restart paired HLTV instance
- **Admin version display** - Shows plugin version to admins on connect (5 second delay)

## Requirements

- [KTPMatchHandler](https://github.com/afraznein/KTPMatchHandler) v0.10.1+ (provides `ktp_match_start`/`ktp_match_end` forwards)
- AMX Mod X Curl module
- [ktp_discord.inc](https://github.com/afraznein/KTPMatchHandler) - Shared Discord library (for audit notifications)
- HLTV API service running on data server
- Paired HLTV instance per game server

## Installation

1. Copy `KTPHLTVRecorder.amxx` to `addons/amxmodx/plugins/`
2. Add to `plugins.ini`: `KTPHLTVRecorder.amxx`
3. Copy `hltv_recorder.ini.example` to `configs/hltv_recorder.ini`
4. Configure your HLTV API settings

## Configuration

```ini
hltv_enabled = 1
hltv_api_url = http://74.91.112.242:8087
hltv_api_key = your-api-key-here
hltv_port = 27020
hltv_stop_delay = 75
```

| Key | Default | Description |
|-----|---------|-------------|
| `hltv_enabled` | `0` | Enable/disable recording (1/0) |
| `hltv_api_url` | | HLTV API base URL |
| `hltv_api_key` | | API authentication key |
| `hltv_port` | `27020` | Paired HLTV instance port |
| `hltv_stop_delay` | `75` | Seconds to wait after match end before sending stoprecording (10-300). Must exceed HLTV delay setting. |

Each game server needs its own config with its paired HLTV port:

| Game Server | Port  | HLTV Port |
|-------------|-------|-----------|
| Atlanta 1   | 27015 | 27020     |
| Atlanta 2   | 27016 | 27021     |
| Atlanta 3   | 27017 | 27022     |

## Demo Naming

Format: `<matchtype>_<matchid>_<half>.dem`

Each half gets its own demo file. The matchId already contains the map name (e.g., `KTP-1735052400-dod_anzio`).

| Match Type | Half | Example Demo Name |
|------------|------|-------------------|
| `.ktp`     | 1st  | `ktp_KTP-1735052400-dod_anzio_h1.dem` |
| `.ktp`     | 2nd  | `ktp_KTP-1735052400-dod_anzio_h2.dem` |
| `.scrim`   | 1st  | `scrim_KTP-1735052400-dod_flash_h1.dem` |
| `.draft`   | 1st  | `draft_KTP-1735052400-dod_avalanche_h1.dem` |
| `.12man`   | 1st  | `12man_KTP-1735052400-dod_caen_h1.dem` |
| `.ktpOT`   | OT1  | `ktpOT_KTP-1735052400-dod_anzio_ot1.dem` |
| `.ktpOT`   | OT2  | `ktpOT_KTP-1735052400-dod_anzio_ot2.dem` |

## How It Works

1. Plugin registers handlers for `ktp_match_start` and `ktp_match_end` forwards
2. On half 1 start: sends `record <demoname>` via HTTP POST to HLTV API
3. On map change (half transition): does **nothing** — HLTV keeps recording, delay buffer drains naturally
4. On half 2+ start: sends `stoprecording` (buffer drained, safe), then `record <new_demoname>`
5. On match end: schedules delayed `stoprecording` (default 75s) to let buffer drain
6. HLTV saves each half as a separate demo file

**Why delayed stop?** HLTV has a ~60 second delay buffer. Sending `stoprecording` immediately discards unwritten buffer content, losing ~47 seconds of gameplay. The delayed approach ensures all content is written before the demo is closed.

## Architecture

```
Game Server Plugin --HTTP POST--> HLTV API (8087) --FIFO--> HLTV Instance
```

## Building

Requires WSL with KTPAMXX compiler:

```bash
./compile.sh
```

See [CHANGELOG.md](CHANGELOG.md) for version history.

## License

GPL-3.0 - See [LICENSE](LICENSE)

## Author

**Nein_** ([@afraznein](https://github.com/afraznein))

Part of the [KTP Competitive Infrastructure](https://github.com/afraznein).
