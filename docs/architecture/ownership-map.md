# Ownership Map

Use this when deciding where a bug or feature belongs. The goal is to avoid broad repo scans and accidental cross-layer changes.

## By concern

| Concern | Primary owner | Supporting files | Do not edit first |
|---|---|---|---|
| PipeWire/PulseAudio startup | `core/audio/start.sh` | `core/audio/balena-sound.pa`, `core/audio/pulseaudio/` | Plugin start scripts |
| Virtual sink creation | `core/audio/balena-sound.pa` | `core/audio/start.sh` | `sound-supervisor` unless runtime reroute is needed |
| Hardware output selection | `core/audio/start.sh` | `docs/05-audio-interfaces.md`, `docs/Audio_Configuration.md` | Snapcast services |
| Hardware input/mic selection | `core/audio/start.sh` | `plugins/karaoke/app/main.go` for karaoke-owned loopback | Source plugins unrelated to mic |
| Role defaults/env parsing | `core/sound-supervisor/src/constants.ts` | `core/sound-supervisor/src/types.ts` | Shell scripts |
| Role service lifecycle | `core/sound-supervisor/src/SoundConfig.ts` | `core/sound-supervisor/src/utils.ts` | Docker restart policies |
| Play/stop promotion flow | `core/sound-supervisor/src/index.ts` | `core/audio/wireplumber/balena-play-detect.lua`, `SoundAPI.ts` | Plugin code |
| Supervisor API/UI | `core/sound-supervisor/src/SoundAPI.ts` | `core/sound-supervisor/src/ui/` | Audio service |
| mDNS advertise/browse | `core/sound-supervisor/src/SnapserverMonitor.ts` | `AvahiAdvertiser.ts`, `AvahiBrowser.ts`, `docs/architecture/mdns.md` | `multiroom-client` unless connection target is wrong |
| Master election | `core/sound-supervisor/src/ElectionManager.ts` | `SnapserverMonitor.ts`, `SoundConfig.ts` | Snapserver config |
| Snapserver capture/buffer | `core/multiroom/server/start.sh` | `core/multiroom/server/snapserver.conf`, `docs/architecture/audio-flow.md` | `snapclient` unless only one client stutters |
| Snapclient output/latency | `core/multiroom/client/start.sh` | `core/sound-supervisor/src/SoundAPI.ts` latency endpoint | `snapserver` unless every client stutters |
| Direct fallback routing | `core/sound-supervisor/src/index.ts` | `PulseAudioWrapper.ts` | `core/audio/balena-sound.pa` |
| Volume control | `core/sound-supervisor/src/PulseAudioWrapper.ts` | `SnapserverMonitor.ts`, `SoundAPI.ts` | Hardware selection code |
| Spotify Connect source | `plugins/librespot/start.sh` | shared D-Bus volume in `docker-compose.yml` | Audio routing unless no source reaches input |
| AirPlay source | `plugins/airplay/start.sh` | shared D-Bus volume in `docker-compose.yml` | Multiroom services |
| Bluetooth source | `plugins/bluetooth/` | `bluetooth-agent`, `entry.sh` | Snapcast services |
| UPnP source | `plugins/upnp/` | `docker-compose.yml` if enabling it | Core audio unless routing fails |
| Karaoke queue/UI | `plugins/karaoke/app/main.go` | `plugins/karaoke/app/static/`, `plugins/karaoke/fetcher/` | `sound-supervisor` except its public API |
| Karaoke local audio injection | `plugins/karaoke/app/main.go` | `SOUND_SUPERVISOR_URL`, `PULSE_SERVER` env in compose | Global source plugins |
| WiFi recovery | `core/watchdog/` | `WIFI_*` env vars | Audio services |
| Hostname | `core/hostname/` | `SOUND_DEVICE_NAME` | mDNS discovery code unless advertised names are wrong |

## By symptom

| Symptom | Start here | Then check |
|---|---|---|
| No sources visible in Spotify/AirPlay | `librespot` or `airplay` logs | mDNS/Avahi state, shared D-Bus volume, network interface readiness |
| Source visible but no audio anywhere | `audio` logs and `pactl list short sinks` | Source plugin PulseAudio backend and `balena-sound.input` sink-inputs |
| Disabled standalone has no output | `core/audio/start.sh` role routing | `balena-sound.output` -> hardware loopback |
| Master plays locally only after delay or not at all | `sound-supervisor` play detection and `multiroom-client` logs | `/multiroom/active`, `/multiroom/client-ready`, local `snapclient` target |
| Remote clients do not join | `SnapserverMonitor` discovery logs | Avahi browse output, `SOUND_GROUP_NAME`, TCP `1704` reachability |
| All multiroom clients stutter | `multiroom-server` buffer/capture | `SOUND_MULTIROOM_BUFFER_MS`, `SOUND_MULTIROOM_CAPTURE_MS`, master CPU/network |
| One client stutters | `multiroom-client` latency/output | `SOUND_MULTIROOM_PA_LATENCY_MS`, DAC/hardware, client CPU/network |
| One client is consistently late | `SOUND_MULTIROOM_LATENCY` on that device or on the earlier device | Lower the late device's value, or raise the earlier device's value. |
| Speakers drift or all clients stutter | Snapcast/Pulse buffering | `SOUND_MULTIROOM_BUFFER_MS`, `SOUND_MULTIROOM_PA_LATENCY_MS`, network and CPU |
| Volume changes only local speaker | `SoundAPI.ts` `/audio/volume` and `SnapserverMonitor.setGroupVolume()` | Cached Snapcast group id and JSON-RPC `1780` |
| AUTO source starts but no promotion | WirePlumber play-detect and `/internal/play` | `sound-supervisor` startup order and `PulseAudioWrapper.listen()` |
| AUTO device never demotes | `/internal/stop` flow | sink-inputs stuck on `balena-sound.input` |
| Karaoke plays in browser but not speakers | `plugins/karaoke/app/main.go` audio mode | `PULSE_SERVER`, ffmpeg command, `/internal/play` notification |
| Karaoke mic leaks when idle | karaoke mic loopback cleanup | modules containing `sink=balena-sound.input` |

## Environment variable ownership

| Variable | Owner | Effect |
|---|---|---|
| `SOUND_MULTIROOM_ROLE` | `constants.ts`, `SoundConfig.ts`, `core/audio/start.sh` | Role and initial input routing. |
| `SOUND_GROUP_NAME` | `SnapserverMonitor.ts`, `AvahiBrowser.ts` | mDNS group filtering and advertisement TXT. |
| `SOUND_MULTIROOM_MASTER` | `SnapserverMonitor.ts` | Explicit Snapcast master IP, bypasses discovery. |
| `SOUND_MULTIROOM_CODEC` | `core/multiroom/server/start.sh` | Snapcast stream codec (default `flac`). |
| `SOUND_MULTIROOM_BUFFER_MS` | `core/multiroom/server/start.sh` | Snapserver stream buffer. |
| `SOUND_MULTIROOM_CAPTURE_MS` | `core/multiroom/server/start.sh` | `pacat` capture latency. |
| `SOUND_MULTIROOM_LATENCY` | `core/multiroom/client/start.sh` | `snapclient --latency`. |
| `SOUND_MULTIROOM_PA_LATENCY_MS` | `core/multiroom/client/start.sh` | PulseAudio sink-input buffer for snapclient. |
| `SOUND_VOLUME` | `constants.ts`, `PulseAudioWrapper.ts` | Startup and API volume. |
| `AUDIO_OUTPUT` | `core/audio/start.sh` | Hardware sink selection. |
| `AUDIO_INPUT` and mic EQ vars | `core/audio/start.sh` | Hardware input selection/filtering. |
| `SOUND_DISABLE_*` plugin vars | plugin start scripts and `SoundConfig.ts` service lifecycle | Source visibility and startup. |
| `KARAOKE_*` | `plugins/karaoke/` | Karaoke quality, queue limits, sync, mic gain, logging. |

## Change boundaries

- Routing topology changes belong in docs first, then in `core/audio/` and `sound-supervisor` together.
- Service lifecycle changes belong in `SoundConfig.ts`; avoid hiding lifecycle decisions in service shell scripts.
- Snapcast target selection belongs in supervisor APIs/monitoring; `multiroom-client` should consume `/multiroom/master`.
- Source plugins should not know about multiroom roles. They output to PulseAudio and let the core route.
- Karaoke is allowed to behave as a source plugin, but it must not change global output device selection, base audio topology, or multiroom role.
