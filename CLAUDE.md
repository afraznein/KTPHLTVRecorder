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
Hooks `ktp_match_start` / `ktp_match_end` from KTPMatchHandler and emits structured `MATCH_WINDOW_OPEN` / `MATCH_WINDOW_CLOSE` log lines that the data server's `hltv-demo-renamer` service uses to name demos post-match. Since v1.7.0 the plugin does **not** drive recording — HLTV instances record always-on via `record auto_<friendly>` in their own config. One game server pairs 1:1 with one HLTV proxy instance; the HTTP API is used only for the `.hltvrestart` admin command and the match-start `/state` health check (warn-only — the plugin never restarts or recovers HLTV on its own).

## Dependencies
- **KTPMatchHandler v0.10.4+** — provides `ktp_match_start` and `ktp_match_end` forwards
- **KTP AMXX Curl module** — non-blocking HTTP POST to the HLTV API
- **`ktp_version_reporter` shared include** — registers with fleet-wide `amx_ktp_versions` rcon command

## Configuration
Per-server config at `addons/ktpamx/configs/hltv_recorder.ini`:
```ini
hltv_enabled = 1                  ; gates chat announcements + health check; log lines emit regardless
hltv_api_url = http://<data-server>:8087
hltv_api_key = <your-api-key>
hltv_port = <paired-hltv-port>    ; logged for the renamer
hltv_friendly = <UPPER-alias>     ; e.g. ATL1 — drives chat demo glob + portal URL
```
`hltv_stop_delay` is a legacy field, ignored since v1.7.0.

Each game server needs its own config with its paired HLTV port. The HLTV port mapping is documented in `KTP Git Projects/CLAUDE.md` under "Current Servers" (game ports 27015-27019, HLTV ports 27020-27044 across the fleet).

## Recording Architecture (v1.7.0+)
```
HLTV cfg (record auto_<friendly>) ------> HLTV Instance (always recording, auto-rotates per source-reconnect)
Game Server Plugin --amxx log lines--> hltv-demo-renamer (data server) --rename--> demo portal
Game Server Plugin --HTTP POST------> HLTV API (data server :8087) --FIFO pipe--> HLTV Instance  (.hltvrestart + /state health check only)
```

Recording is always-on: each HLTV instance's cfg carries `record auto_<friendly>` at boot, so HLTV records continuously and rotates segments on source-reconnect. The plugin never sends `record`/`stoprecording` — per the 2026-04-29 investigation, HLTV processes record commands one-per-source-reconnect with a sticky basename, so per-match commands caused cross-match bleed no matter how the plugin polled (see CHANGELOG 1.6.0/1.7.0).

The plugin's job per match:
1. `ktp_match_start` → log `[KTP HLTV] MATCH_WINDOW_OPEN match_id=... half=... match_type=... map=... hltv_port=... wall_time=...`
2. If `hltv_enabled`: async `GET /hltv/<port>/state` health check, then chat — either the expected demo glob + portal URL, or an explicit warning (API unreachable / HLTV offline / not recording). **Warn-only**: the health check never restarts or recovers anything.
3. `ktp_match_end` → log `MATCH_WINDOW_CLOSE` with score; chat points players at the portal.

The `MATCH_WINDOW_*` lines are the renamer's input contract — emitted regardless of `hltv_enabled`, format must stay stable (renamer parses with regexes; matchtype regex is lowercase-only).

The HLTV API service, FIFO pipes, HLTV wrapper script, and renamer all live on the data server. See `KTPInfrastructure/docs/TECHNICAL_GUIDE.md` for the implementation-side details (paths, systemd units, auth setup).

## Demo Naming (renamer output)
HLTV writes `auto_<friendly>-<hltv_ts>-<map>.dem` segments; the renamer matches them to logged match windows and renames to:
`<matchtype>_<match_id>-<UPPER_FRIENDLY>_<half>-<hltv_ts>-<map>.dem`
Example: `ktp_1777070040-ATL1_h1-2604241856-dod_lennon5_b1.dem`. Match-type prefixes are lowercase (`ktp_`, `scrim_`, `12man_`, `draft_`, `ktpot_`, `draftot_`); halves `h1`/`h2`, OT rounds `ot1`+. The 4 AM ET organizer then sorts renamed demos into per-friendly portal directories.

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
