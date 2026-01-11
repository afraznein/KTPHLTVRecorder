# KTPHLTVRecorder

Automatic HLTV demo recording for KTP competitive matches.

## Overview

KTPHLTVRecorder hooks into [KTPMatchHandler](https://github.com/afraznein/KTPMatchHandler) match events and automatically controls HLTV demo recording via HTTP API. When a match starts, recording begins. When it ends, recording stops.

## Features

- Automatic recording for all match types (`.ktp`, `.scrim`, `.draft`, `.12man`, `.ktpOT`, `.draftOT`)
- 1:1 game server to HLTV pairing
- Descriptive demo naming: `<type>_<matchid>.dem` (matchId includes map)
- HTTP API communication with HLTV control service

## Requirements

- [KTPMatchHandler](https://github.com/afraznein/KTPMatchHandler) v0.10.4+
- AMX Mod X Curl module
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
hltv_api_key = KTPVPS2026
hltv_port = 27020
```

Each game server needs its own config with its paired HLTV port:

| Game Server | Port  | HLTV Port |
|-------------|-------|-----------|
| Atlanta 1   | 27015 | 27020     |
| Atlanta 2   | 27016 | 27021     |
| Atlanta 3   | 27017 | 27022     |

## Demo Naming

Format: `<matchtype>_<matchid>.dem`

The matchId already contains the map name (e.g., `KTP-1735052400-dod_anzio`), so it's not duplicated.

| Match Type | Example Demo Name |
|------------|-------------------|
| `.ktp`     | `ktp_KTP-1735052400-dod_anzio.dem` |
| `.scrim`   | `scrim_KTP-1735052400-dod_flash.dem` |
| `.draft`   | `draft_KTP-1735052400-dod_avalanche.dem` |
| `.12man`   | `12man_KTP-1735052400-dod_caen.dem` |
| `.ktpOT`   | `ktpOT_KTP-1735052400-dod_anzio.dem` |
| `.draftOT` | `draftOT_KTP-1735052400-dod_avalanche.dem` |

## How It Works

1. Plugin registers handlers for `ktp_match_start` and `ktp_match_end` forwards
2. On match start: sends HTTP POST to HLTV API with `record <demoname>` command
3. API writes command to FIFO pipe, which feeds HLTV stdin
4. On match end: sends `stoprecording` via same flow
5. HLTV saves the demo to its configured demo directory

## Architecture

```
Game Server Plugin --HTTP POST--> HLTV API (8087) --FIFO--> HLTV Instance
```

## Building

Requires WSL with KTPAMXX compiler:

```bash
./compile.sh
```

## License

GPL-3.0 - See [LICENSE](LICENSE)

## Author

**Nein_** ([@afraznein](https://github.com/afraznein))

Part of the [KTP Competitive Infrastructure](https://github.com/afraznein).
