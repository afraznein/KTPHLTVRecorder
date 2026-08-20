---
name: plugin-dev
description: Use BEFORE writing or modifying any KTPHLTVRecorder Pawn code — the slot-reuse-across-async-callback rule (this repo's exemplar fix), the KTPMatchHandler forward dependency, and the compile/review/stage/verify workflow. Also use when planning a change, to know which invariants it touches.
---

# KTPHLTVRecorder Development

This plugin drives HLTV demo recording/renaming metadata on a production fleet
(24 instances). It is small and currently clean (2026-07 review: no findings) —
keep it that way by not reintroducing the pattern it was already fixed for.

## Hard safety rules
- **NEVER restart game servers** or issue LinuxGSM control commands without the
  operator's explicit permission in the current conversation.
- Deploys are staged as `KTPHLTVRecorder.amxx.new` in each instance's plugins dir
  and swap at the 03:00 ET nightly restart. Never hot-swap the live `.amxx`.
- Run the `ktp-code-review` agent on any nontrivial change BEFORE compiling for deploy.

## Architecture constraints
- **Extension mode**: KTPAMXX loads as a ReHLDS extension — there is NO Metamod
  and NO fakemeta. Never add a fakemeta/engine-module dependency.
- **This plugin does not control recording.** Since v1.7.0, HLTV instances
  record always-on (`record auto_<friendly>` baked into their own cfg). The
  plugin only: (1) logs `MATCH_WINDOW_OPEN`/`MATCH_WINDOW_CLOSE` lines that the
  data server's renamer parses to rename demo segments, and (2) makes async HTTP
  calls (curl → HLTV API on the data server, FIFO-pipe-fed into HLTV stdin) for
  `.hltvrestart` and a warn-only match-start health check. Do not add a
  synchronous `record`/`stoprecording` path — per-match record commands caused
  cross-match demo bleed (HLTV ties basenames to source-reconnect, not to
  commands) and that's why this architecture exists.
- The `MATCH_WINDOW_*` log line format is a parsing contract with the renamer
  (regexes, lowercase match-type prefixes). Changing the format without updating
  the renamer breaks demo naming fleet-wide silently — no error surfaces here.
- **The paired HLTV proxy is a connected client**, not an invisible observer. It
  occupies a player slot and its reconnect runs `client_putinserver`, so plugin
  forwards fire for it like any other join. Anything keyed on "a player connected"
  or on a player count has to account for it — and work started from that forward at
  restart time can find itself in flight when the engine quits.
- **Dependency on KTPMatchHandler**: recording/window triggers come from its
  `ktp_match_start`/`ktp_match_end` forwards. Recompile this plugin after ANY
  KTPMatchHandler change that moves, renames, or changes the signature of those
  forwards — a stale build won't error, it'll just stop firing silently.

## Async-boundary identity rule (this repo's exemplar fix, 1.7.2)
A player **slot index is not an identity**. Any slot captured before a curl
request or `set_task` window may point at a different person by the time the
callback fires — slots recycle on disconnect/map-change, and
`is_user_connected()` only proves the slot is occupied, not by whom.

`.hltvrestart` runs a ~30-second curl-callback window. The fix: capture the
requester's **authid alongside the slot** at request time, and re-verify both
at callback time before printing the confirmation to that slot.
- **Suppression is the safe direction** — if identity doesn't match at callback
  time, withhold the on-screen confirmation. Don't guess or fall back to the
  slot.
- **Log the outcome unconditionally either way** — the restart itself happened
  and must appear in the audit trail even when the confirmation is suppressed.

Apply this same pattern to any new admin command that captures a slot before an
async boundary (curl, `set_task`, menu). Don't reintroduce a bare
`is_user_connected(slot)` check across such a boundary.

## Pawn checklist (apply to every diff)
- `charsmax(buf)` for every format/copy; watch truncation on composed strings.
- Every `set_task` with an id: unique id range, `remove_task` on disconnect.
- Check return values of curl/file/localinfo natives that can fail.
- No synchronous file/network I/O reachable from the game thread — HLTV API
  calls go through the non-blocking curl module, never blocking sockets.
- Comments: short, explain *why*, no ticket/finding IDs, never delete a tripwire
  fact while editing near it.

## Never run a destructive simulation inside the working tree
Verifying a fix often means simulating the failure — writing a fake `build.sh`, a
fake artifact, a fake staging dir. Do it in a **verified** scratch dir, never in
the repo:

```bash
T="$(mktemp -d)" || exit 1
[ -n "$T" ] && [ -d "$T" ] || exit 1   # verify BEFORE you cd — this is the whole rule
cd "$T" || exit 1
```

`cd "$T"` with an empty `$T` **silently succeeds and leaves you where you were** —
in the repo. A simulation that then writes `build.sh` overwrites the real one. On
2026-07-16 exactly that truncated a tracked 60-line upstream file to 2 lines and
dropped a junk `.so` into `build/`, where a `find | head -1` could have staged it.
It was caught only because `git status` showed a modification nobody made.

So: verify the scratch dir before `cd`, and **run `git status` after any test that
touches the filesystem** — an unexpected change is the tell. Prefer copying inputs
out to the scratch dir over running tools "in place".

## Workflow
1. **Version bump** (every shipped change): `#define PLUGIN_VERSION` in the
   .sma, new `CHANGELOG.md` section, README header version, TODO.md if applicable.
2. **Compile**: `wsl bash -c "cd '/mnt/n/Nein_/KTP Git Projects/KTPHLTVRecorder' && bash compile.sh"`
   (outputs `compiled/`, bakes git SHA + build time into `build_info.inc` for
   `amx_ktp_versions`, auto-stages to the KTP DoD Server test tree).
3. **Review**: `ktp-code-review` agent before any fleet stage.
4. **Fleet stage**: deploy as `.new` via paramiko (see root CLAUDE.md § SSH);
   verify staged md5 on all 24 active instances.
5. **Post-activation verify** (after the nightly): 24/24 on the new md5, no
   leftover `.new`, and check `/tmp` for cores — `find /tmp -maxdepth 1 -name
   'core.*' -mtime -1` on every host. A game-tree core search proves nothing
   (matches only core.so/core.ini/core.wav).

## Config reference
`addons/ktpamx/configs/hltv_recorder.ini` per game server: `hltv_api_url`,
`hltv_api_key`, `hltv_port` (paired HLTV instance, logged for the renamer),
`hltv_friendly` (drives chat glob + portal URL). `hltv_stop_delay` is legacy,
ignored since v1.7.0 — don't wire new logic to it.
