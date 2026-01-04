# KTPHLTVRecorder

Automatic HLTV demo recording for KTP competitive matches.

## Overview

KTPHLTVRecorder hooks into [KTPMatchHandler](https://github.com/afraznein/KTPMatchHandler) match events and automatically controls HLTV demo recording via RCON. When a match starts, recording begins. When it ends, recording stops.

## Features

- Automatic recording for all match types (`.ktp`, `.scrim`, `.draft`, `.12man`)
- 1:1 game server to HLTV pairing
- Descriptive demo naming: `<type>_<matchid>.dem` (matchId includes map)
- UDP RCON communication with HLTV

## Requirements

- [KTPMatchHandler](https://github.com/afraznein/KTPMatchHandler) v0.10.4+
- AMX Mod X Sockets module
- Paired HLTV instance per game server

## Installation

1. Copy `KTPHLTVRecorder.amxx` to `addons/amxmodx/plugins/`
2. Add to `plugins.ini`: `KTPHLTVRecorder.amxx`
3. Copy `hltv_recorder.ini.example` to `configs/hltv_recorder.ini`
4. Configure your paired HLTV settings

## Configuration

```ini
hltv_enabled = 1
hltv_ip = 74.91.112.242
hltv_port = 27020
hltv_rcon = ktpadmin
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

## How It Works

1. Plugin registers handlers for `ktp_match_start` and `ktp_match_end` forwards
2. On match start (1st half LIVE): sends `record <demoname>` via UDP RCON to paired HLTV
3. On match end (regulation or OT): sends `stoprecording` via UDP RCON
4. HLTV saves the demo to its configured demo directory

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
