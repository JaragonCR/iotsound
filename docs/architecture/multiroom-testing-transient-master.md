# Testing guide — transient source-master + Option C

Branch: `feat/multiroom-transient-master`. **Unvalidated on hardware** — this guide is the
validation plan. Deploy with `balena push g_jorge_aragon/sound`. Use `LOG_LEVEL=debug` on the
devices under test for verbose supervisor + container logs.

## What changed (in one breath)
- **Option C:** the multiroom client plays snapcast straight to the detected hardware sink
  (`PULSE_SINK=<hw>` from `GET /audio/output-sink`), not the `balena-sound.output` null sink, so
  PipeWire reports the real device latency to snapclient. This is the sync fix.
- **Transient source-master:** a device advertises `_snapcast._tcp` (becomes master) only while it
  plays a local source; 30 s after it stops, it demotes. Promotion/demotion are **in-place**
  (start/stop `pacat`, publish/unpublish advert) — no container restarts.
- **Tiebreak:** if two devices source at once, **lowest `master_uuid` keeps the group**; the other
  goes **SOLO** (plays its own source locally, doesn't advertise or join) until it stops.
- **No restarts on transitions:** latency changes apply via Snapcast `Client.SetLatency` (RPC);
  master changes/ demotions are handled in place by the server/client supervisor loops.
- **Codec:** stream codec is now `SOUND_MULTIROOM_CODEC` (default **flac**; was hardcoded pcm).

## Relevant env vars
| Var | Default | Effect |
|---|---|---|
| `SOUND_MULTIROOM_CODEC` | `flac` | stream codec: flac/pcm/opus/ogg. A/B flac vs pcm for skipping. |
| `SOUND_MULTIROOM_BUFFER_MS` | 400 | snapserver buffer. After Option C, try lowering toward 150–250. |
| `SOUND_MULTIROOM_CAPTURE_MS` | 50 | master pacat capture buffer. Raise if master-origin underruns. |
| `SOUND_MULTIROOM_PA_LATENCY_MS` | 200 | snapclient→PulseAudio buffer. |
| `SOUND_MULTIROOM_LATENCY` | 400 | snapclient `--latency`. After Option C this should be ~0 for matched HW. |
| `SOUND_MULTIROOM_POLL_S` | 2 | server pacat reconcile interval. |
| `SOUND_GROUP_NAME` | (unset→`default`) | group identity / mDNS filter. |

## Scenarios

### 1. Single AUTO device (sanity)
- Boot one `auto` device, no group peers. Expect: WARM (no advert, `pacat` stopped).
- Play Spotify → supervisor log `→ SOURCING (group master)`, server `Active … starting pacat`,
  client `Target acquired: <own IP>`, audio out. **Listen for the latency drop** vs old build.
- Stop for >30 s → `→ not sourcing`, server `Demoted — stopping pacat in place`. **No container
  restart** in `balena logs` (no "Starting multi-room server/client" reappearing).

### 2. Two AUTO devices, one source (the main sync test) ★
- Both `auto`, same `SOUND_GROUP_NAME`. Play on device A only.
- A → SOURCING + advertises; B → discovers A, `Target acquired: <A IP>`, plays in sync.
- **Walk between speakers — they should be tight.** With matched HW, `SOUND_MULTIROOM_LATENCY=0`
  should already be close. This is the pass/fail for Option C.
- Stop A; after 30 s A demotes; B loses target (`Target changed … <none>`) and idles. No restarts.

### 3. Heterogeneous HW sync (Pi4 + Pi3/HDMI)
- Same as #2 across different output paths. Measure skew. Expectation: dramatically smaller than
  before *without* manual per-device latency, because PipeWire now reports each device's real
  latency. Any residual is a single fixed `SOUND_MULTIROOM_LATENCY` per device, not a moving target.

### 4. Tiebreak / SOLO
- Both `auto`, same group. Start a source on BOTH within a second.
- Lower-UUID device keeps the group (stays SOURCING). Higher-UUID device logs
  `playing SOLO` / `Yielded group … → SOLO`, reroutes input→output direct, **does not join**.
- Stop the SOLO device's source → after 30 s it leaves SOLO (`restore … input → snapcast`) and, if
  the other is still playing, joins it as a client.

### 5. Latency tuning without restart
- While playing in a group, `POST /multiroom/latency {"latencyMs": 150}` (or the UI slider).
- Expect supervisor `Client.SetLatency 150ms (<uuid>)` and an **immediate** shift with **no**
  snapclient/container restart (no audio gap beyond the latency change itself).

### 6. JOIN / HOST / DISABLED unchanged
- `host`: always SOURCING (advertises from boot). `join`: only ever a client. `disabled`:
  standalone (input→output, no snapcast). Confirm each still behaves.

## What to watch in logs
- Supervisor state line: `[state] → SOURCING / not sourcing / SOLO`.
- `[snapserver-monitor] Master discovered … uuid=…` and `Lower-UUID master … superseded`.
- Server: `reconciling pacat against /multiroom/active`, `stopping pacat in place`.
- Client: `Starting → <ip> (… sink <hw_sink> …)` — confirm **sink is the hardware sink**, not
  `balena-sound.output`. If it shows `<default>`, the `/audio/output-sink` lookup returned empty
  (check the audio container detected a HW sink).

## Known risks to verify (I could not test these)
1. **`PULSE_SINK` honored by snapclient.** libpulse honors `PULSE_SINK` for a NULL playback device,
   which is how Option C targets the DAC. Confirm `pactl list sink-inputs` shows the snapclient
   stream on the **hardware** sink, not `balena-sound.output`. If not, set the device explicitly via
   `--player pulse:device=<hw>` instead of the env.
2. **Default-sink timing.** If `/audio/output-sink` is empty at first spawn, the client falls back to
   the PA default sink. Verify the audio container has run `set-default-sink <HW_SINK>` by then.
3. **Volume double-attenuation (pre-existing, watch closely).** `/audio/volume` sets the PA sink
   volume *and* snapcast group volume. With snapclient on the hardware sink, the master's local
   output may be attenuated twice (snapcast software volume × PA hw-sink volume). If volume feels
   "squared," we need to pick one authority (recommend: snapcast group volume for all clients, hw
   sinks at 100%). Flagged, not yet changed.
4. **SOLO reroute module match.** `rerouteInputDirect()` finds the input→snapcast loopback by its
   args. Confirm SOLO actually produces local audio and that leaving SOLO restores snapcast routing
   (no silent or doubled audio).
5. **Codec.** Default flipped to flac. A/B against `SOUND_MULTIROOM_CODEC=pcm` if you hear codec
   latency; flac should *reduce* WiFi skipping.

## Rollback
Revert is clean: the branch is isolated. To disable just Option C, set `PULSE_SINK=balena-sound.output`
as a device env (the client honors it). To disable flac, `SOUND_MULTIROOM_CODEC=pcm`.
