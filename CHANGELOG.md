# Changelog

All notable changes to KTPHLTVRecorder will be documented in this file.

## [Unreleased]

### Documentation

Installation step 1 said to copy the plugin to `addons/amxmodx/plugins/`. This
plugin consumes KTPMatchHandler forwards and KTPAMXX natives, so it only runs on
the KTP stack — the path is `addons/ktpamx/plugins/`. Step 1 also now builds via
`compile.sh` and deploys from `compiled/`, matching the rest of the stack.

Same class of error in step 3: the config template was named as bare
`hltv_recorder.ini.example` (it lives in `documents/`) destined for
`configs/hltv_recorder.ini`. The plugin resolves its config through
`get_configsdir()`, so anything outside `addons/ktpamx/configs/` is never read and
`.hltvrestart` silently stays unavailable. Both paths corrected.

Further corrections, all verified against source:

- **`.hltvrestart` never stated its permission level.** It is ADMIN_RCON
  (`ADMIN_HLTVRESTART`), enforced in the command handler; repo `CLAUDE.md` had it
  right and the README was the only doc missing it.
- **KTPMatchHandler minimum version disagreed** — README said v0.10.1+ while the
  source header and `CLAUDE.md` both say v0.10.4+. Aligned to 0.10.4+.
- **Documented the forward coupling as a runtime name contract.** These forwards
  are matched by name with no compile-time link, and the `MatchType` enum is a
  local mirror of KTPMatchHandler's. A rename, re-signature, or enum reorder
  upstream fails silently — demos stop being renamed or get mislabelled, with no
  build or load error. The rule lived only in the root project doc.
- **The health-check bullet oversold itself.** Two pre-flight paths skip the
  check and print the optimistic "recording" announcement anyway: incomplete
  config (which includes an unset `hltv_api_key`, since that leaves the header
  list empty) and `curl_easy_init()` failure. The behavior is deliberate; it just
  wasn't disclosed, so players could be told a match is recording with nothing
  verified.
- **`MATCH_WINDOW_OPEN`'s quoted format was missing its `enabled=` field** — and
  it sits two lines above "their format must stay stable", so a renamer-side
  parser written to the doc would have been written to the short form.
- Requirements now list `ktp_version_reporter.inc` / `amx_ktp_versions`; "AMX Mod
  X Curl module" corrected to the **KTP** AMXX Curl module.
- Config template's fleet map said "Chicago: CHI1..CHI4 (CHI5 disabled)". CHI5 was
  deleted 2026-07-13, not disabled; dropped the parenthetical.
- Repo `CLAUDE.md` listed one of the two CI workflows; added `config-tests.yml`
  and the `tests/` tree.

## [1.7.3] - 2026-07-18

### Changed
- **Demo-portal chat links repointed to `https://fastdl.ktpdod.com/demos`** (was `http://74.91.112.242/demos`), part of the ktpdod.com domain migration. Three sites: the two "Match recorded — find ... .dem at ..." lines and the `.hltvrestart` "portal: ..." line. These are human-clicked browser links (not a game `sv_downloadurl`), so the FastDL HTTP-only-client caveat does not apply — HTTPS is correct. Verified `https://fastdl.ktpdod.com/demos/` serves (HTTP 200). Cosmetic only; no logic change (the `MATCH_WINDOW_*` renamer contract is untouched).
- Swapped the dead `<:ktp:…>` Discord emoji token for the current `<:KTP:1002382703020212245>` in the `.hltvrestart` audit embed (the old one renders as raw text since 2026-07-17). Cosmetic; part of the fleet-wide emoji sweep.

## [1.7.2] - 2026-07-13

### Fixed
- **`.hltvrestart` confirmation could print to the wrong player** — the
  completion callback carried only the requester's slot index, and the
  restart request has a 30-second curl timeout. The curl module's per-frame
  poll keeps running across map changes (extension mode reloads plugins
  without unloading them), so if the requesting admin disconnected in that
  window and another player was recycled into the slot,
  `is_user_connected()` passed and the "restarted successfully" / "restart
  failed" chat line went to the new occupant. The request payload now also
  carries the requester's SteamID, and the callback re-resolves the slot and
  verifies the authid still matches before printing. Cosmetic impact only
  (a confusing chat line), but the slot-recycling pattern is the sharp edge
  of the async-callback class, so it's closed properly.

---

## [1.7.1] - 2026-07-08

Docs-truth release plus four small code fixes from the 2026-07-06 wave-2
assessment (HR-1 through HR-4). No behavior change to the match-window
logging contract; forward signatures untouched.

### Fixed
- **`say_team /hltvrestart` now registered** — the other three prefix/say
  combinations (`say .hltvrestart`, `say_team .hltvrestart`,
  `say /hltvrestart`) were registered but the fourth was missing, so the
  command silently did nothing when typed with `/` in team chat.
- **MatchType enum comment corrected** — listed mixed-case `ktpOT_`/`draftOT_`
  renamer prefixes, contradicting the lowercase mandate (and the actual
  lowercase output of `match_type_string`). Prefixes are `ktpot_`/`draftot_`.
- **Empty-api-key warning now states the consequence** — an unset
  `hltv_api_key` at boot means the curl header list is never built, so any
  API request that still fires goes out unauthenticated until a restart.
  The log line says so instead of just ".hltvrestart will fail".

### Removed
- **Dead `g_currentMatchId` global** — written on match start, cleared on
  match end, never read (log lines use the forward's `matchId` parameter
  directly). Leftover from the pre-1.7.0 control-flow state.

### Docs
- **README.md + CLAUDE.md rewritten to the 1.7.0 architecture** — both still
  described the retired record/stop design (plugin-issued `record` /
  `stoprecording` commands, `<type>_<matchid>_<half>.dem` naming by the
  plugin, delayed-stop lifecycle, `hltv_stop_delay`). They now describe the
  always-on model: HLTV records via its own cfg (`record auto_<friendly>`),
  the plugin logs MATCH_WINDOW_OPEN/CLOSE for the data-server renamer, the
  match-start health check warns only (never recovers), and `.hltvrestart`
  is the sole HTTP control path. Config docs gain `hltv_friendly` and mark
  `hltv_stop_delay` as ignored.

---

## [1.7.0] - 2026-04-29

Architectural rewrite. Recording responsibility moves from the plugin to HLTV
itself; the plugin becomes a match-window logger plus the `.hltvrestart`
admin command.

### Why
The 1.6.0 polling-before-record fix turned out to be unable to fully address
the bleed bug: HLTV processes `record` commands one per source-reconnect
cycle and holds a sticky basename for that connection's lifetime. Per-match
record commands therefore collide with the in-flight basename regardless of
how cleverly the plugin polls. Removing per-match commands eliminates the
class of bug entirely.

### Changed
- **Recording now driven by HLTV's own cfg** — each HLTV instance is configured
  with `record auto_<friendly>` (e.g., `record auto_ny2`) so HLTV is always
  recording and auto-rotates per source-reconnect with port-stamped
  filenames like `auto_ny2-2604291902-dod_anzio.dem`.
- **Plugin role narrowed** — no longer issues `record` / `stoprecording`
  commands. Emits structured `[KTP HLTV] MATCH_WINDOW_OPEN` / `MATCH_WINDOW_CLOSE`
  log lines instead. The new `hltv-demo-renamer` service (Phase 1c) reads
  these and renames the auto-* segments to the canonical
  `<type>_<matchid>_<half>_<map>.dem` format. The existing 4 AM
  `ktp-organize-hltv-demos.sh` then sorts them into per-friendly subfolders
  for the public demo portal.
- **Plugin shrinks from 1118 to ~290 lines.** Stripped: poll-idle state machine,
  verify-after-record, delayed-stop, bleed-detection alerts, all task IDs,
  and persistent localinfo coordination.

### Added
- **Verified match-start chat** — async `GET /hltv/<port>/state` on
  `ktp_match_start` confirms HLTV is alive and recording before the plugin
  promises players a specific demo name. Failure modes get explicit warnings
  ("HLTV API unreachable…", "HLTV %d is offline…", "HLTV %d is up but not
  recording…") instead of misleading promises.
- **Portal-aware match-start / match-end chat** — verified-success path
  prints the demo glob (`<type>_<matchid>-<friendly>_h<half>-*.dem`) plus the
  per-friendly portal URL (`http://74.91.112.242/demos/<friendly>/<type>/`).
  Match-end announcement points at the same portal directory and notes the
  4 AM ET sort cadence so players know when to expect availability.
- **`hltv_friendly` config field** — UPPERCASE fleet alias (e.g., `ATL1`).
  Required for accurate chat announcements; the demo glob and portal URL
  fall back to a generic form if unset (with a warning at config load).

### Removed
- All per-match HLTV control commands. The plugin no longer drives recording
  in any form — by design.
- `hltv_stop_delay` configuration field is now ignored (left in config files
  for back-compat during rollout; operators can remove on next config touch).

### Notes
- **Hard prerequisites for activation:**
  1. Phase 1a — every HLTV instance config must have `record auto_<friendly>`.
  2. Phase 1c — `hltv-demo-renamer` service deployed on the data server.
  Activating the plugin without these in place loses recordings (HLTV won't
  be recording auto-segments) and produces unprocessed `auto_*.dem` files.
- Activates at next nightly restart (~03:00 ET) per the standard `.new` swap.

---

## [1.6.0] - 2026-04-28

### Fixed
- **Match-id bleed across half/match boundaries** — HLTV silently ignored `record <new>` commands while already recording, keeping the original basename and bleeding subsequent matches into wrong demo files. Fleet-wide audit (1041 demos, 2026-04-28) found 60 misfiled match keys / 350 files / 59 missing-h1 cases across all regions. Worst case: CHI1 match `1776218309-CHI1` h1 had 70 files from a 23h scrim session all under the original basename. Root cause confirmed via journal: `Already recording to <X>.dem.` events at every map change with no `Stop recording` between matches.

### Added
- **`/state` polling before `record`** — plugin now queries the new `GET /hltv/<port>/state` endpoint before issuing `record`. Polls up to 10 times at 500ms intervals (5s budget) until HLTV reports it is not recording, then issues the record command. Best-effort fallback after timeout (issues record anyway with Discord alert) so a stuck HLTV never blocks the next match's recording.
- **Post-record verification** — 3 seconds after `record` HTTP 200, plugin polls `/state` and compares HLTV's reported basename against what we asked for. If mismatch (bleed) or `recording=false` (silent failure), broadcasts a chat alert to all players + posts a Discord audit embed naming both basenames. Players see "Demo bleed detected" instead of finding out a week later.
- **Post-deferred-stop verification** — after match-end stoprecording fires (75s after `MATCH_END`), polls `/state` to confirm HLTV actually stopped. Alerts on stuck recordings.
- **Process-down detection** — `/state` returns `process_running: false` when `hltv@<port>.service` is inactive. Plugin no longer fires `record` into the void; surfaces immediately as "HLTV is not running — recording disabled for this match."
- **Already-recording journal signal** — `/state` exposes `already_recording_warning: true` when HLTV's most recent journal event was the explicit "Already recording to ..." line (HLTV's silent-rejection signature). Plugin treats this as bleed and alerts.

### Changed
- Requires hltv-api.py v2.2+ (provides `GET /hltv/<port>/state`). Older API responds 400 to /state path; plugin falls back to best-effort behavior in that case.
- `start_recording` is now a thin entry point that hands off to the new `poll_idle_then_record` state machine. Existing health-check + recovery logic unchanged.
- `task_delayed_match_stop` schedules `task_verify_post_deferred_stop` 3s after issuing stoprecording.
- `hltv_record_callback` HTTP 200 path no longer prints "Recording: X" immediately — it schedules verification first, and prints either "Recording: X" (verified) or the bleed alert.

### Notes
- Activates at next nightly restart (~03:00 ET) per the standard `.new` swap. Requires hltv-api.py to be deployed BEFORE plugin activation, else plugin gets 400 on /state and falls back to best-effort. Deploy order matters.

---

## [1.5.7] - 2026-04-25

### Added
- **Adopted `ktp_version_reporter` shared include** — plugin now registers with the fleet-wide `amx_ktp_versions` rcon command (ADMIN_RCON). Output reports name, version, build SHA, and build time alongside other KTP plugins. See KTPMatchHandler 0.10.116 for the canary release introducing the include.
- **`compile.sh` build-info generation** — git short SHA + UTC build time written to `build_info.inc` and baked into the .amxx so the rcon command can report what's actually deployed.

## [1.5.6] - 2026-03-24

### Fixed
- **Delayed stop preserved + guarded against killing new recordings** — Previously, `remove_task(TASK_DELAYED_STOP)` cancelled the pending stoprecording when a new match started, which could leave the previous recording open indefinitely. Now the delayed stop task is preserved so the HLTV buffer drain completes naturally. Added `g_matchActive` guard in `task_delayed_match_stop` so the stop is skipped if a new match is already recording — prevents the edge case where the old delayed stop fires after a new recording has started.
- **`init_curl_headers` no longer frees/rebuilds** — The guard that freed and rebuilt the slist could trigger a use-after-free if called while async requests were in flight. Now returns immediately if already initialized. Also skips building headers when API key is not configured.
- **`g_hltvApiUrl` buffer increased from 128 to 256** — Matches downstream URL buffers, prevents silent truncation on long API URLs.
- **Dead `g_hltvPort <= 0` guard removed** — Port is validated to 1024-65535 in `load_config`, so this check was unreachable.

### Changed
- **Version display removed** — No longer sends plugin info to players on connect.
- **`server_print` removed from `plugin_init`** — Fires on every map change; `register_plugin` already records the plugin.
- **Dead code cleanup** — Removed `TASK_VERSION_BASE`, `fn_version_display`, `client_putinserver`, `client_disconnected` version task management.

---

## [1.5.5] - 2026-03-17

### Added
- **Recording verification with in-game chat feedback** — After sending the `record` command, the HLTV API now waits 2 seconds and checks if the `.dem` file was created on disk. The plugin reports the result to all players via chat: success shows the demo name, failure triggers a chat error + Discord alert. This would have caught the Practice Mode hostname bug (space in filename caused HLTV to reject the command silently).

### Changed
- Record command uses dedicated `hltv_record_callback` instead of the generic `hltv_api_callback`, enabling recording-specific chat notifications.
- Curl timeout for record commands increased from 5s to 8s to accommodate the API's 2s verification delay.
- HLTV API updated to v2.1: returns HTTP 200 (recording confirmed) or HTTP 422 (demo file not created) for record commands.

---

## [1.5.4] - 2026-03-13

### Fixed
- **Delayed recording task had no task ID** — Back-to-back matches could overwrite `g_pendingDemoName` before the delayed task fires, causing missed or duplicate recordings. Now uses `TASK_DELAYED_RECORD` (5501) with proper `remove_task` on new match start.
- **5-second recovery delay raced 30-second HLTV restart** — After health check failure, `send_hltv_restart()` had a 30s timeout but the recovery recording attempt fired after only 5s, hitting the still-restarting API. Increased to 35s.
- **`g_restartRequesterId` global corrupted by concurrent `.hltvrestart`** — Second admin overwrote the requester ID before the first async callback fired. Now passes requester ID through `curl_easy_perform` data parameter.
- **Version message task used raw player ID** — Could collide on reconnect within 5s. Now uses `id + TASK_VERSION_BASE` offset with cleanup on `client_disconnected`.

### Changed
- Version announcement restricted to admins only (was shown to all players).
- Port validation added: `hltv_port` clamped to 1024-65535 range.
- `configsDir` buffer increased from 128 to 256 bytes.
- Task ID namespace documented: KTPHLTVRecorder owns 5500-5534.

---

## [1.5.3] - 2026-03-06

### Fixed
- **Second half demo cutoff (~45-48 seconds lost)** - The v1.5.0 fix only resolved first half cutoff. At match end, `ktp_match_end` scheduled a 75-second delayed `stoprecording` to let the HLTV buffer drain, but the subsequent map change destroyed the task. `plugin_cfg()` on the new map detected `_ktp_hltv_pending_stop` and sent `stoprecording` immediately — before the ~60s delay buffer had drained. Now `plugin_cfg()` re-schedules the delayed stop task instead of sending `stoprecording` immediately.

---

## [1.5.2] - 2026-02-25

### Fixed
- **HTTP API errors silently treated as success** - All three callbacks (`hltv_health_callback`, `hltv_api_callback`, `hltv_restart_callback`) only checked `CURLcode` (transport-level result), never the HTTP response code. API errors (401, 404, 500) were invisible — a misconfigured API key or wrong port would silently produce no demos with no alerts. Now calls `curl_easy_getinfo(CURLINFO_RESPONSE_CODE)` and treats non-2xx as failure with Discord/chat alerts.
- **Health check missing auth headers** - `send_hltv_health_check()` didn't include `g_curlHeaders`, so the X-Auth-Key header was absent. Added for consistency with all other API requests.
- **Stale header comment** - VERSION in header block said 1.5.0, now matches actual version.

---

## [1.5.1] - 2026-02-18

### Fixed
- **Segfault on half 2 start** - v1.5.0's new `stoprecording` + health check + `record` sequence fired three overlapping async curl requests. The shared `g_curlHeaders` slist was freed and recreated between requests, causing use-after-free when earlier curl handles still referenced the freed memory.

### Changed
- **Curl headers now created once at init** - `init_curl_headers()` builds the slist once after config loads. All requests share the same persistent headers. No per-request free/create cycle.

---

## [1.5.0] - 2026-02-18

### Fixed
- **HLTV demo cutoff (~47 seconds lost per half)** - Root cause: `stoprecording` was sent during map changes (via `plugin_end()` and orphan cleanup in `plugin_cfg()`), which immediately killed the HLTV delay buffer (~60s of unwritten content). With ~13s of intermission before the map change, this produced the ~47-second cutoff.

### Changed
- **Removed `stoprecording` from `plugin_end()`** - HLTV now keeps recording through map changes, allowing the delay buffer to drain naturally
- **Removed orphan cleanup `stoprecording` from `plugin_cfg()`** - Replaced with localinfo-based pending stop check
- **Half transitions now stop previous recording** - `ktp_match_start(half > 1)` sends `stoprecording` before starting new recording (safe because buffer has drained during the 60-120+ second gap between halves)
- **Match end uses delayed `stoprecording`** - Waits `hltv_stop_delay` seconds (default 75) after match end to allow buffer to drain before closing the demo

### Added
- **`hltv_stop_delay` config option** - Configurable delay (10-300 seconds, default 75) before sending `stoprecording` after match end
- **`_ktp_hltv_pending_stop` localinfo** - Persists pending stop state across map changes as safety net
- **`g_matchActive` state tracking** - Tracks whether a match is in progress

### Removed
- **`g_isRecording` state variable** - No longer needed; recording lifecycle is managed by match start/end events and half transitions

### Trade-offs
- Half 1 demo will include ~60 seconds of half 2 warmup content at the end (between HLTV reconnect and `stoprecording` at half 2 start). This is acceptable — all actual match gameplay is captured completely.

---

## [1.4.0] - 2026-01-31

### Added
- **Pre-match HLTV health check** - Verifies HLTV API is responding before starting recording
  - GET request to `/health` endpoint with 3 second timeout
  - If health check fails, attempts automatic HLTV restart as recovery
  - Falls back to delayed recording attempt after recovery
- **Discord + chat alerts** - Notifies when HLTV recording may not work
  - Posts to audit Discord channels with server hostname and error details
  - In-game chat warning to all connected players
  - Uses red embed color for failure alerts
- **Callback failure detection** - Detects when recording commands fail
  - `hltv_api_callback` now alerts on curl errors
  - Marks recording as failed so state stays accurate

### Technical
- Added `g_hltvHealthy` state tracking
- Added `g_pendingMatchId`, `g_pendingDemoName`, `g_pendingHalf` for deferred recording
- Added `alert_hltv_failure()` for unified error notification
- Added `send_hltv_health_check()` and `hltv_health_callback()`
- Added `task_delayed_recording_start()` for post-recovery recording attempt

---

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
