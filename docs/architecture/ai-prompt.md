# AI Debugging / Feature Prompt

Copy this prompt when asking an AI to debug IoTSound or design a feature. Fill in the bracketed sections and include only the logs that match the suspected layer.

```text
You are helping with IoTSound, a balena multi-container audio system. Be token-efficient and architecture-aware.

First read these docs in order before scanning broadly:
1. docs/architecture/ai-index.md
2. docs/architecture/system-map.md
3. docs/architecture/runtime-states.md
4. docs/architecture/audio-flow.md
5. docs/architecture/ownership-map.md
6. docs/architecture/mdns.md only if discovery, Spotify visibility, or Snapcast master selection is involved.

Important invariants:
- audio owns PipeWire/WirePlumber, pipewire-pulse TCP 4317, virtual sinks, hardware selection, and the pactl subscribe play/stop detector.
- sound-supervisor owns live role/group lifecycle, web/API, play/stop promotion, mDNS state, SOLO routing, and single-authority volume control.
- Source plugins send audio to balena-sound.input and must not choose hardware directly.
- balena-sound.input is the source mix point. balena-sound.output is used only for disabled standalone and SOLO fallback.
- disabled standalone path: source -> balena-sound.input -> balena-sound.output -> hardware.
- multiroom master path (Option C): source -> balena-sound.input -> snapcast sink -> snapserver -> local snapclient -> hardware sink directly (via GET /audio/output-sink).
- remote client path (Option C): remote snapserver -> local snapclient -> hardware sink directly (via GET /audio/output-sink).
- Single volume authority (Option B): when multiroom is active, local hardware sinks are locked at 100% unity gain and /audio/volume controls Snapcast Group.SetVolume on the active master; when multiroom is off/idle/SOLO, /audio/volume controls the local PipeWire sink directly.
- SOUND_MULTIROOM_LATENCY is snapclient compensation, not snapserver buffering (SOUND_MULTIROOM_BUFFER_MS default 600ms, codec flac).
- mDNS/Snapcast targets must be usable IPv4 LAN addresses. Do not remove IPv6/Docker/loopback filtering casually.
- join devices stop source plugins; disabled devices keep source plugins active but do not use Snapcast.

Task:
[debug this symptom / design this feature]

Current runtime state:
- Device A role/state: [auto-idle | auto-master-snapcast | auto-master-direct-fallback | auto-remote-client | host-master | join-remote-client | disabled-standalone]
- Device B role/state: [...]
- Expected audio path: [...]
- Actual behavior: [...]

Environment:
- SOUND_MULTIROOM_ROLE=[...]
- SOUND_GROUP_NAME=[...]
- SOUND_MULTIROOM_MASTER=[... or unset]
- SOUND_MULTIROOM_BUFFER_MS=[... or default]
- SOUND_MULTIROOM_CAPTURE_MS=[... or default]
- SOUND_MULTIROOM_LATENCY=[... or default]
- SOUND_MULTIROOM_PA_LATENCY_MS=[... or default]
- AUDIO_OUTPUT=[...]
- Source plugin: [Spotify/AirPlay/Bluetooth/UPnP/Karaoke]

Observed facts:
- /multiroom returns: [...]
- /multiroom/active returns: [...]
- /multiroom/client-ready returns: [...]
- /multiroom/master returns: [...]
- pactl list short sinks: [...]
- pactl list short sources: [...]
- snapserver JSON-RPC status if relevant: [...]

Logs:
sound-supervisor:
[paste only relevant lines]

audio:
[paste only relevant lines]

multiroom-server:
[paste only relevant lines]

multiroom-client:
[paste only relevant lines]

source plugin:
[paste only relevant lines]

Instructions:
- Start with the smallest likely owner from docs/architecture/ownership-map.md.
- Separate control-plane failures from audio-plane failures.
- Do not propose broad rewrites unless the invariant being changed is named explicitly.
- If code changes are needed, list exact files and why.
- If more data is needed, ask for the minimum command/log needed next.
- For debugging, produce: likely cause, evidence, next verification, minimal fix.
- For features, produce: architecture impact, owner files, state transitions, invariants preserved, and tests/manual verification.
```

## Minimal command bundle for future debugging

Use this when collecting context from a device:

```sh
curl -s http://localhost/ping
curl -s http://localhost/multiroom
curl -s http://localhost/multiroom/active
curl -s http://localhost/multiroom/client-ready
curl -s http://localhost/multiroom/master
PULSE_SERVER=tcp:localhost:4317 pactl list short sinks
PULSE_SERVER=tcp:localhost:4317 pactl list short sources
PULSE_SERVER=tcp:localhost:4317 pactl list short sink-inputs
```

For Snapcast master status:

```sh
curl -s http://localhost:1780/jsonrpc \
  -H 'Content-Type: application/json' \
  -d '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}'
```
