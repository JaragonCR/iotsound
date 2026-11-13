# AI Architecture Index

This folder is the fast path for AI-assisted debugging and feature work. Prefer these docs before scanning the whole repository.

## Read order

1. [`system-map.md`](system-map.md) — containers, ports, networks, volumes, and service responsibilities.
2. [`runtime-states.md`](runtime-states.md) — role/state transitions and the exact audio paths for standalone, master, client, and fallback.
3. [`audio-flow.md`](audio-flow.md) — detailed signal path and latency/buffer ownership.
4. [`ownership-map.md`](ownership-map.md) — where to edit for each concern.
5. [`mdns.md`](mdns.md) — mDNS/Snapcast discovery design and IPv4-only constraints.
6. [`ai-prompt.md`](ai-prompt.md) — copy/paste prompt for efficient AI debugging or feature design.

## High-value invariants

- `audio` owns PipeWire, WirePlumber, the PulseAudio-compatible server on TCP `4317` (published on host loopback only: host-network services use `127.0.0.1:4317`, bridge services use `audio:4317`), the `pactl subscribe` play/stop detector (Phase 10 of `core/audio/start.sh`), and the virtual sinks.
- `sound-supervisor` owns orchestration, live role/group changes, service start/stop calls, web/API endpoints, mDNS advertisement/discovery state, and single-authority volume control.
- Plugins are source producers. They send audio to `balena-sound.input` and do not pick hardware devices directly.
- `balena-sound.input` is the source mix point. `balena-sound.output` is used for `disabled` standalone and `SOLO` fallback only.
- In `SOUND_MULTIROOM_ROLE=disabled` (and `SOLO`), audio goes from `balena-sound.input` to `balena-sound.output` to the hardware sink.
- **Direct-to-Hardware Multiroom Output (Option C):** Both local and remote `snapclient` instances query `GET /audio/output-sink` and output **directly to the hardware sink** (`PULSE_SINK=<HW_SINK>`), bypassing `balena-sound.output` so PipeWire reports true DAC latency to Snapcast.
- **Single Volume Authority (Option B):** When multiroom is active (`snapclient`/`snapserver` active), local hardware sinks are locked at `100%` (unity gain) and `GET`/`POST /audio/volume` controls Snapcast `Client.SetVolume` on the active master (`localhost` or `discoveredMasterIp`). When multiroom is off/idle/SOLO, `GET`/`POST /audio/volume` controls the local PipeWire sink directly.
- **Transient Source-Master (`WARM` / `SOURCING` / `SLAVE` / `SOLO`):** All transitions happen **in place** without restarting containers. Conflict resolution uses **newest-`epoch` wins** (`master_uuid` lowest breaks ties).
- `SOUND_MULTIROOM_LATENCY` is a snapclient compensation offset (default `0`), not the snapserver stream buffer (`SOUND_MULTIROOM_BUFFER_MS`, default `600` ms, codec `flac`).
- mDNS discovery resolves usable IPv4 LAN addresses only. Loopback, link-local, Docker bridge, veth, and IPv6 targets are rejected.
- `join` devices stop source plugins and are not visible as Spotify/AirPlay/Bluetooth targets.
- `disabled` devices keep source plugins active and do not participate in Snapcast.
- **Master heartbeat:** the sourcing master broadcasts a UDP beacon every 10 s on port `1706` (`MasterBeacon.ts`). Beacons and mDNS feed one master table. A master that goes quiet for ~35 s is checked over unicast (`GET /multiroom/active`) before it is dropped.
- **Routing follows the role:** `core/audio/start.sh` picks the input route once at boot (falling back to standalone if `sound-supervisor` does not answer in 60 s). `sound-supervisor` re-applies the route for its current state every time it (re)connects to PulseAudio, then restarts the `librespot` and `airplay` services if PulseAudio was replaced underneath them.
- **Spotify engine:** the `librespot` service runs go-librespot or Spotify Soloist (`SOUND_SPOTIFY_ENGINE`, `plugins/librespot/soloist-engine.sh`). Soloist is downloaded at runtime, never shipped, and falls back to go-librespot after 3 failed starts.
- **Nothing in the audio path may write to the SD card.** snapserver keeps its state in `/dev/shm`, and the supervisor only sends `Client.SetVolume` to clients that are off target. A blocked card write stalls snapserver and silences every speaker.
- `karaoke` is a single Go container (`plugins/karaoke/app`) with built-in `ffmpeg` and `yt-dlp`.

## Minimal debugging context

When asking an AI for help, include:

- The user's symptom and the role of each device: `auto`, `host`, `join`, or `disabled`.
- Whether the failing device is supposed to be source/master, local speaker, or remote client.
- Relevant logs from `sound-supervisor`, `audio`, `multiroom-server`, `multiroom-client`, and the source plugin.
- Current values of `SOUND_MULTIROOM_ROLE`, `SOUND_GROUP_NAME`, `SOUND_MULTIROOM_MASTER`, `SOUND_MULTIROOM_BUFFER_MS`, `SOUND_MULTIROOM_CAPTURE_MS`, `SOUND_MULTIROOM_LATENCY`, and `SOUND_MULTIROOM_PA_LATENCY_MS`.
- Whether `balena-sound.input`, `snapcast`, and `balena-sound.output` exist in `pactl list short sinks`.
- Whether `snapcast.monitor` exists in `pactl list short sources`.
- Whether `/multiroom`, `/multiroom/active`, `/multiroom/client-ready`, and `/multiroom/master` return expected values from `sound-supervisor`.
