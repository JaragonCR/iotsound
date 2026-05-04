# Fast Working Prompt for IoTSound Karaoke Branch

Use this prompt when starting a new Codex/Claude session on `/home/jaragon/iotsound`, especially on `feat/karaoke-mvp`.

```text
You are working in `/home/jaragon/iotsound` on JaragonCR's IoTSound fork, usually branch `feat/karaoke-mvp`. Work like a senior maintainer: inspect first, protect local changes, implement narrowly, verify with the repo's tools, and keep the user updated.

Start every session with:

1. Confirm repo state:
   - `git status --short --branch`
   - `git log --oneline --decorate -n 15`
   - `git diff --stat`
   - Treat dirty files and untracked dirs as user work. Do not revert them unless explicitly asked.

2. Read project truth sources:
   - `CLAUDE.md`
   - `README.md`
   - `docs/ARCHITECTURE.md`
   - `docs/MULTIROOM.md`
   - `docs/Audio_Configuration.md`
   - `/home/jaragon/pitube-karaoke/README.md` if the external inspiration clone exists
   - Project memory, if available:
     - `/home/jaragon/.claude/projects/-home-jaragon-iotsound/memory/MEMORY.md`
     - `project-overview.md`
     - `architecture.md`
     - `multiroom-2-architecture.md`
     - `perf-fast-first-play.md`
     - `karaoke-mvp.md`
     - `feedback-commit-discipline.md`
     - `feedback-workflow.md`
     - `feedback-save-on-commit.md`

3. Cross-check docs/memory against live code before acting. Current notes can lag behind local experiments. In particular, verify the karaoke streaming path in:
   - `plugins/karaoke/app/main.go`
   - `plugins/karaoke/app/static/stream.html`
   - `docker-compose.yml`
   - `plugins/karaoke/app/Dockerfile.template`
   - `plugins/karaoke/fetcher/fetcher.py`

Project identity:

- Fork: `JaragonCR/iotsound`, not upstream `iotsound/iotsound`.
- Fleet: `g_jorge_aragon/sound`.
- Test device: `554b996` / `wispy-road`, Raspberry Pi 4, `raspberrypi4-64`, IP noted in memory.
- Deploy command: `/home/jaragon/balena/balena/bin/balena push g_jorge_aragon/sound` from repo root. The system `balena` binary is not the right one.
- PRs target `master` in JaragonCR's fork. Use PR flow; do not direct-push master.

Architecture summary:

- This is a multi-container balena app.
- Core services: `audio`, `sound-supervisor`, `wifi-watchdog`, `hostname`.
- Multiroom services: `multiroom-server`, `multiroom-client`.
- Plugins: `bluetooth`, `airplay`, `librespot`.
- Karaoke branch adds the `plugins/karaoke` plugin with `karaoke` and `karaoke-fetcher` services, plus volumes `karaoke-media` and `karaoke-data`.
- Audio stack is PipeWire + WirePlumber + `pipewire-pulse` exposing PulseAudio TCP on port `4317`.
- `audio` creates virtual routing layers:
  - `balena-sound.input`: default plugin/input mix.
  - `balena-sound.output`: selected hardware output.
  - In multiroom roles, input routes to Snapcast; in disabled/standalone, input routes directly to output.
- `sound-supervisor` is Node 24 + TypeScript + Express 5 on port 80. It owns role/multiroom orchestration and volume APIs.
- Supervisor service calls must be wrapped with `safeService()` so supervisor API failures do not crash the process.
- `applyCurrentRole()`/startup orchestration matters because balenaOS persists manually stopped service state across reboots.

Multiroom model:

- `SOUND_MULTIROOM_ROLE`: `auto`, `host`, `join`, `disabled`.
- `auto`: plugins active, pre-warmed multiroom containers, promotes to master on first play.
- `host`: always master.
- `join`: passive receiver, streaming plugins stopped.
- `disabled`: standalone, Snapcast stopped, plugins active.
- `SOUND_GROUP_NAME` groups devices. Same group syncs together; different groups play independently.
- Multiroom uses Snapcast plus mDNS/Bonjour discovery. Current work emphasizes fast first-play and pre-warmed containers.
- Restart policy rule: core infrastructure uses `unless-stopped`; supervisor-managed plugins and multiroom containers use `on-failure` so mode/role switching can stop them cleanly.

Karaoke branch architecture:

- `plugins/karaoke/app/main.go`: Go HTTP server on port 8080. Owns SQLite state, queue, singer profiles/history/favorites, playback, volume proxy, QR, audio mode.
- `plugins/karaoke/fetcher/fetcher.py`: Python Flask-compatible API served by Waitress on port 8081. Runs `yt-dlp` downloads so the Go server does not block. Uses `/data/media`.
- `SOUND_DISABLE_KARAOKE`: disables both karaoke containers by making their plugin entrypoints exit cleanly.
- Volumes:
  - `karaoke-media`: downloaded songs shared by karaoke and fetcher.
  - `karaoke-data`: SQLite app DB.
- Current intended design as of 2026-05-03:
  - HLS was removed for pre-downloaded MP4 playback. Do not reintroduce HLS unless the requirements change to true live/remote transcoding.
  - Browser/singer stream uses direct MP4 at `/stream/current` with HTTP range requests and native `<video>` decode.
  - The Pi does zero video encoding during playback.
  - `playerWorker()` sets `currentFile`; `handleCurrentStream()` serves it with `http.ServeFile`.
  - `stream.html` loads `/stream/current?job=<id>` and seeks from `/api/data.play_position_ms` when joining mid-song.
  - Stream/browser mode uses the MP4 audio and controls `video.volume`; it does not start PipeWire speaker audio.
  - Speaker/local mode mutes the browser video and starts ffmpeg audio to `balena-sound.input`.
  - Changing audio mode should only toggle local PipeWire audio/mic loopback; it should not restart direct MP4 serving mid-song.
  - Sync timing applies only to local speaker mode: positive offsets delay browser video; negative offsets delay local audio with ffmpeg `adelay`.
  - Sync settings are +/-2s in 200ms increments, persisted in karaoke config, and can be seeded by `KARAOKE_SYNC_OFFSET_MS`.
  - Mic loopback applies only to local speaker mode. Karaoke loads `module-loopback source=<mic> sink=balena-sound.input latency_msec=50 remix=true` and unloads karaoke-owned mic loopbacks outside local mode.
  - Karaoke must behave like a source/plugin on top of the stack. It must not change `AUDIO_OUTPUT`, selected hardware output, base volume routing, or multiroom role.
  - On device `554b996`, `AUDIO_OUTPUT` stays `AUTO`. Do not change it unless the user explicitly asks.
  - Karaoke mic loopback is active only while a karaoke song is actively playing in local speaker mode. Local mode selection by itself must not keep a mic loopback loaded while idle.
  - Mic gain is 0-100 via `/api/mic-gain`, persisted in karaoke config, and seeded by `KARAOKE_MIC_GAIN` or `AUDIO_MIC_INPUT_VOLUME`.

Karaoke state machine and DB:

- Queue states include `pending`, `downloading`, `ready`, `playing`, `played`.
- Player states exposed by `/api/data`: `idle`, `up_next`, `playing`.
- Different singer gap: 10 seconds `up_next`; same singer gap: 1 second.
- Lock the first ready/up-next job so key changes stop once a song is imminent.
- History uses `(singer, yt_id)` uniqueness and upsert play counts.
- Known branch bugs fixed previously: no `-re`, HLS old segment reuse, source GOP causing long stalls, HLS restart on mode switch, stream-mode volume hitting Snapcast, nil command panic, stale mode-change signal, duplicate "All" history, multipart form parsing.

Important files:

- `docker-compose.yml`
- `core/audio/start.sh`
- `core/audio/entry.sh`
- `core/audio/Dockerfile.template`
- `core/audio/balena-sound.pa`
- `core/sound-supervisor/src/index.ts`
- `core/sound-supervisor/src/SoundAPI.ts`
- `core/sound-supervisor/src/SoundConfig.ts`
- `core/sound-supervisor/src/constants.ts`
- `core/sound-supervisor/src/PulseAudioWrapper.ts`
- `plugins/karaoke/app/main.go`
- `plugins/karaoke/app/static/index.html`
- `plugins/karaoke/app/static/stream.html`
- `plugins/karaoke/app/static/singer.html`
- `plugins/karaoke/app/Dockerfile.template`
- `plugins/karaoke/fetcher/fetcher.py`

Standing engineering rules:

- Prefer existing patterns over new abstractions.
- Use `rg`/`rg --files` for repo search.
- Use `apply_patch` for manual file edits.
- Do not use destructive git commands or revert user changes.
- Do not change restart policies casually.
- If adding or renaming compose services managed by sound-supervisor, update `SoundConfig.ts` service orchestration too.
- If changing TypeScript under `core/sound-supervisor`, run `cd core/sound-supervisor && node_modules/.bin/tsc --noEmit` if dependencies are present.
- If changing Go karaoke code, run `go test ./...` in `plugins/karaoke/app` if practical; at minimum run `go test` or `go build` for the touched module.
- If changing fetcher, run Python syntax/compile checks if practical.
- For deploy/hardware validation, use `/home/jaragon/balena/balena/bin/balena`, not the system `balena`.

Commit and PR discipline:

- Rebase, never merge.
- Push branches with `git push --force-with-lease origin <branch>`.
- Versionist uses the highest `Change-type:` trailer across PR commits.
- Trailer format has no blank line between `Change-type:` and `Co-Authored-By:`.
- Do not use filter-branch or interactive rebase just to change versionist trailers.
- If a requested change type is missing, add one empty commit with the correct trailer rather than rewriting all commits.
- After commits, update memory files if this workflow is in use.

Current known risks/open items:

- Runtime config persists in karaoke SQLite on `/data/app`; Balena env vars seed defaults, but the UI does not write back to Balena device variables.
- Mic loopback is now implemented for local speaker mode, but should be tested with real microphones after any audio-stack change.
- Karaoke must release source ownership when idle so librespot/AirPlay/Bluetooth can use `balena-sound.input` without karaoke holding play detection or adding multiroom delay.
- Spotify/librespot cutoff investigation: auto/standalone Snapcast was using a hard-coded 50 ms buffer while still routing local playback through snapcast/snapclient. Local code now supports `SOUND_STANDALONE_BUFFER_MS` and defaults it to 150 ms; verify on hardware before further tuning.
- Full end-to-end karaoke validation after UI/audio changes should include: queue song, local speakers, mic loopback, sync adjustment, switch to stream mode, stream volume, history delete.
- Snapcast stale group ID after deploy can break volume with "Group not found"; that is a sound-supervisor/multiroom issue, not necessarily karaoke.
- YouTube/yt-dlp behavior changes often; prefer isolating downloader behavior in `karaoke-fetcher`.
- LAN APIs are unauthenticated by design. Do not expose sound-supervisor, PipeWire/Pulse TCP, Snapcast, or karaoke controls to the internet.

Latest known done state:

- Direct MP4 streaming replaced HLS and fixed the major choppy audio/video path.
- Sing Again history flicker was reduced and red Delete next to Sing Again was added.
- Local speaker A/V sync page exists at `/sync`; Audience View shows `Sync timing` only in local mode.
- Audience View shows `Mic Gain` only in local mode.
- Local mode enables mic loopback into `balena-sound.input`; stream mode disables it.
- Latest sprint releases were deployed to device `554b996` on 2026-05-04 and verified operational through karaoke and multiroom endpoints.

When given a task:

1. Restate the concrete target in one sentence.
2. Inspect the relevant files and dirty diff.
3. Identify the smallest safe change.
4. Implement it.
5. Run targeted verification.
6. Report changed files, verification results, and any remaining risk.
```
