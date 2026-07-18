# KTPHLTVRecorder

**Version 1.7.3** - Match-window logger for the always-on HLTV recording pipeline.

## Overview

Since v1.7.0, HLTV instances record **always-on** via their own config (`record auto_<friendly>` at HLTV boot) — this plugin does not start or stop recording. Instead it hooks [KTPMatchHandler](https://github.com/afraznein/KTPMatchHandler) match events and emits structured `MATCH_WINDOW_OPEN` / `MATCH_WINDOW_CLOSE` log lines. The `hltv-demo-renamer` service on the data server reads those windows and renames HLTV's `auto_*` demo segments to canonical match filenames post-match.

## Features

- Match-window logging for all match types (`.ktp`, `.scrim`, `.draft`, `.12man`, `.ktpOT`, `.draftOT`) — the renamer's input contract
- 1:1 game server to HLTV pairing
- **Match-start health check** - Async `GET /hltv/<port>/state`; warns in chat if HLTV is unreachable, offline, or not recording. Warn-only: it never restarts or recovers anything on its own
- **Recording announcements** - Verified match-start chat with the expected demo glob + portal URL; match-end chat pointing at the portal
- **Admin HLTV restart command** - `.hltvrestart` or `/hltvrestart` to restart the paired HLTV instance (HTTP POST with X-Auth-Key, Discord audit)

## Requirements

- [KTPMatchHandler](https://github.com/afraznein/KTPMatchHandler) v0.10.1+ (provides `ktp_match_start`/`ktp_match_end` forwards)
- AMX Mod X Curl module
- [ktp_discord.inc](https://github.com/afraznein/KTPMatchHandler) - Shared Discord library (for audit notifications)
- HLTV API service running on data server
- Paired HLTV instance per game server, with `record auto_<friendly>` in its config (the actual recording trigger)
- `hltv-demo-renamer` service on the data server (produces the canonical filenames)

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
hltv_friendly = ATL1
```

| Key | Default | Description |
|-----|---------|-------------|
| `hltv_enabled` | `0` | Gates chat announcements + the match-start health check (1/0). Match-window log lines are emitted regardless |
| `hltv_api_url` | | HLTV API base URL (used by `.hltvrestart` + health check) |
| `hltv_api_key` | | API authentication key (X-Auth-Key header) |
| `hltv_port` | `27020` | Paired HLTV instance port (logged for the renamer) |
| `hltv_friendly` | | UPPERCASE fleet alias (e.g. `ATL1`) — drives the demo glob and portal URL in chat. Generic fallback if unset |

`hltv_stop_delay` is a legacy field — ignored since v1.7.0, safe to remove from existing configs.

Each game server needs its own config with its paired HLTV port:

| Game Server | Port  | HLTV Port |
|-------------|-------|-----------|
| Atlanta 1   | 27015 | 27020     |
| Atlanta 2   | 27016 | 27021     |
| Atlanta 3   | 27017 | 27022     |

## Demo Naming

HLTV records `auto_<friendly>-<hltv_ts>-<map>.dem` segments continuously (one per source-reconnect). The renamer matches segments to match windows and produces:

`<matchtype>_<match_id>-<UPPER_FRIENDLY>_<half>-<hltv_ts>-<map>.dem`

e.g. `ktp_1777070040-ATL1_h1-2604241856-dod_lennon5_b1.dem`. Halves are `h1`/`h2`, overtime rounds `ot1`/`ot2`/... Match types are lowercase prefixes: `ktp_`, `scrim_`, `12man_`, `draft_`, `ktpot_`, `draftot_`.

The plugin can't predict `<hltv_ts>` at match start, so chat announces a glob keyed on the known parts (`<type>_<matchid>-<FRIENDLY>_<half>-*.dem`) plus the portal URL. The 4 AM ET organizer sorts renamed demos into per-friendly portal directories.

## How It Works

1. HLTV instances are always recording — `record auto_<friendly>` in each HLTV config at boot. The plugin never sends record/stop commands
2. On `ktp_match_start`: plugin logs `[KTP HLTV] MATCH_WINDOW_OPEN match_id=... half=... match_type=... map=... hltv_port=... wall_time=...`
3. Still at match start (if `hltv_enabled`): async `/state` health check — success announces the expected demo glob + portal URL in chat; failure prints an explicit warning (API unreachable / HLTV offline / not recording). Warn-only — no recovery is attempted
4. On `ktp_match_end`: plugin logs `MATCH_WINDOW_CLOSE` with the final score and announces the portal location in chat
5. The `hltv-demo-renamer` service tails the amxx logs, associates `auto_*` segments with match windows, and renames them to canonical filenames within ~30s of match end

Both `MATCH_WINDOW_*` lines are emitted regardless of `hltv_enabled` — they are the renamer's input contract and their format must stay stable.

## Architecture

```
HLTV cfg (record auto_*) ---------> HLTV Instance (always recording)
Game Server Plugin --amxx log--> hltv-demo-renamer (data server) --rename--> portal
Game Server Plugin --HTTP POST--> HLTV API (8087) --FIFO--> HLTV Instance   (.hltvrestart + /state only)
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
