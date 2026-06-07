# Audio Flow

End-to-end signal paths for standalone and multiroom playback. Each multiroom stage lists the buffer it introduces, which file owns it, and the env var to change it (if any).

---

## Standalone path

Used when `SOUND_MULTIROOM_ROLE=disabled`.

```
[Plugin source: librespot / airplay / bluetooth / karaoke / upnp]
        │  PCM audio written to balena-sound.input
        ▼
balena-sound.input                              (PipeWire null sink, audio container)
        │  loopback rule
        ▼
balena-sound.output                             (PipeWire null sink, audio container)
        │  loopback rule
        ▼
Hardware DAC / ALSA sink
        │
        ▼
Speakers
```

No `snapserver` or `snapclient` is used in this mode.

---

## Multiroom master path

Used when a device is `host` or when an `auto` device promotes to master. The master normally plays local audio through its own local `snapclient`.

```
[Plugin source: librespot / airplay / bluetooth]
        │  PCM audio written to balena-sound.input (PipeWire null sink)
        ▼
balena-sound.input                              (PipeWire null sink, audio container)
        │  WirePlumber loopback rule
        ▼
snapcast                                        (PipeWire null sink, audio container)
        │  pacat --record --device=snapcast.monitor
        │  Buffer: 50 ms default
        │  Env var: SOUND_MULTIROOM_CAPTURE_MS
        ▼
FIFO pipe  /tmp/snapserver-audio               (kernel pipe buffer, ~64 KB)
        │
        ▼
snapserver  (multiroom-server container)
        │  Stream buffer: 400 ms default
        │  Env var: SOUND_MULTIROOM_BUFFER_MS   (set per-fleet or per-device)
        │
        ├── local loopback ─────────────────────────────────────────
        │
        ▼
snapclient  (multiroom-client container on the master device)
        │  --latency offset: 0 ms default (SOUND_MULTIROOM_LATENCY, advanced)
        │  PulseAudio sink-input buffer: 200 ms (SOUND_MULTIROOM_PA_LATENCY_MS)
        │  Plays DIRECTLY to the hardware sink (PULSE_SINK = detected HW sink).
        │  PipeWire reports the real device latency → snapclient compensates it.
        ▼
Hardware DAC / ALSA sink
        │
        ▼
Speakers
```

Remote clients receive the same Snapcast stream:

```
snapserver  (master device)
        │
        ▼  ── network ──────────────────────────────────────────────
        │
snapclient  (multiroom-client container, each speaker device)
        │  --latency offset: 0 ms default (SOUND_MULTIROOM_LATENCY, advanced)
        │  PulseAudio sink-input buffer: 200 ms (SOUND_MULTIROOM_PA_LATENCY_MS)
        │  Plays DIRECTLY to that device's hardware sink — no balena-sound.output
        │  null sink / loopback in the path, so each device's real output latency
        │  is visible to Snapcast and compensated automatically.
        ▼
Hardware DAC / ALSA sink
        │  DAC hardware buffer — device-specific (HiFiBerry PCM5122: ~5 ms)
        ▼
Speakers
```

> **Why direct-to-sink (Option C):** routing snapclient through the `balena-sound.output`
> null sink + a WirePlumber loopback hid a per-device, variable output delay that Snapcast
> could not see, which made heterogeneous hardware impossible to sync. Playing straight to the
> hardware sink lets PipeWire report the true latency, so Snapcast keeps devices in sync with
> no per-device tuning. The `balena-sound.output` sink is still used for the standalone
> (`disabled`) path and as the SOLO fallback.

---

## SOLO (simultaneous-source) fallback

If two devices in the same group are *both* playing a local source at once, the newest one owns
the synced group; the other plays its own audio locally (it cannot merge two different sources):

```
[Plugin source on the losing device]
        │
        ▼
balena-sound.input
        │  input → output direct loopback (loaded by sound-supervisor)
        ▼
balena-sound.output → Hardware DAC / speakers
```

When that device's source stops, or the other master goes away, it leaves SOLO and rejoins/takes
the group. This only happens on genuinely simultaneous play — normal source-switching hands the
group straight to the newest device.

---

## Buffer reference table

| Stage | Default | Owner file | Env var |
|---|---|---|---|
| pacat capture | 50 ms | `core/multiroom/server/start.sh` | `SOUND_MULTIROOM_CAPTURE_MS` |
| Kernel FIFO pipe | ~64 KB | OS | — not applicable — |
| snapserver stream buffer | 400 ms | `core/multiroom/server/start.sh` | `SOUND_MULTIROOM_BUFFER_MS` |
| PulseAudio sink-input (snapclient → PA) | 200 ms | `core/multiroom/client/start.sh` | `SOUND_MULTIROOM_PA_LATENCY_MS` |
| snapclient `--latency` offset (advanced) | 0 ms | `core/multiroom/client/start.sh` | `SOUND_MULTIROOM_LATENCY` |
| Hardware DAC | device-specific | n/a | — not configurable — |

---

## Latency compensation (automatic)

There is **no manual per-device latency tuning** in normal use. Because snapclient plays directly
to the hardware sink, PipeWire reports that sink's real latency to snapclient, and Snapcast
schedules playback so every device hits the same wall-clock moment — identical and mixed hardware
alike. `SOUND_MULTIROOM_LATENCY` (snapclient `--latency`, default `0`) is an advanced escape hatch
for a device with a known fixed output delay Snapcast cannot otherwise observe; leave it at `0`
unless you have measured a reason not to. If you hear dropouts, raise a **buffer**
(`SOUND_MULTIROOM_BUFFER_MS` / `SOUND_MULTIROOM_CAPTURE_MS` / `SOUND_MULTIROOM_PA_LATENCY_MS`),
not the latency offset.


## Key PipeWire null sinks

| Sink | Purpose |
|---|---|
| `balena-sound.input` | Plugin capture point — all sources write here |
| `snapcast` | Multiroom capture — WirePlumber loopback feeds from balena-sound.input:monitor |
| `balena-sound.output` | Playback mixing point — all consumers read from here |

WirePlumber loopback rules live in `core/audio/` and wire these sinks together automatically.
