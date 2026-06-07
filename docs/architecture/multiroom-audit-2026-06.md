# Multiroom Audit & Sync Redesign — 2026-06-07

Audit of the Multiroom 2.0 stack as shipped in v5.0.1. Focus: **why heterogeneous
hardware will not stay in sync**, plus a ranked bug inventory and a design proposal.

Scope of this pass: code/docs review only (no device deploys). Audio-timing changes
are proposed, not applied, because they require hardware validation.

---

## TL;DR

1. **The sync ceiling is architectural, not a tuning problem.** Snapclient plays into a
   PipeWire *null sink* (`balena-sound.output`) and a `module-loopback` carries the audio
   to the real DAC. That loopback's latency (100 ms default, 500 ms for HDMI) is **downstream
   of snapclient's sync point, differs per device, and drifts at runtime** (adaptive
   resampling). Snapcast can only sync up to where it hands off the sample — everything after
   the null sink is invisible to it. No static `SOUND_MULTIROOM_LATENCY` offset can compensate
   a *drifting* delay. This is the root cause of "async HW is impossible to sync."
2. **The automatic latency reconciliation that was designed was never built.** The server
   advertises `group_latency`/`hw_latency` in its mDNS TXT record, but no client reads them.
   Sync is 100% manual per-device `SOUND_MULTIROOM_LATENCY` tuning.
3. **Most "crashes" are container-restart churn.** State transitions (demote, master-change,
   latency change) are implemented by restarting the multiroom containers. Each restart is an
   audible gap and a chance to wedge.
4. **No authoritative master election** → split-brain when two `auto` devices originate audio.

---

## Signal path (as built)

### Client / remote speaker
```
snapserver (master) ──network──> snapclient  --player pulse  (PULSE_SINK=balena-sound.output)
                                      │   ← snapcast sync point is HERE
                                      ▼
                              balena-sound.output  (PipeWire NULL sink)
                                      │  module-loopback  latency_msec = 100 (I2S/USB) | 500 (HDMI)
                                      │  ← adaptive resampling, runtime-variable, per-device
                                      ▼
                              hardware DAC ── speakers
```

### Master local playback
```
plugin → balena-sound.input → loopback → snapcast (null sink) → pacat --record snapcast.monitor
       → FIFO /tmp/snapserver-audio → snapserver (pipe source, 400 ms buf) → local snapclient → (same output path as above)
```

The decisive fact: **Snapcast's guarantee ends at the snapclient output backend.** Here the
backend is a null sink, and the real DAC is one or two variable PipeWire hops further on.

---

## Bug & risk inventory (ranked)

### P0 — Defeats audio sync (the headline problem)

**B1. Snapclient outputs to a PipeWire null sink, not the DAC.**
`core/multiroom/client/start.sh` runs `snapclient --player pulse` into `balena-sound.output`;
`core/audio/balena-sound.pa` then `module-loopback`s that to the hardware sink with
`latency_msec = %OUTPUT_LATENCY%` (`core/audio/start.sh:614-622`: 100 ms normally, 500 ms for
mailbox/HDMI). That post-snapclient latency is (a) different on every device and (b) not
constant (PulseAudio adaptive resampling). Snapcast cannot see or compensate it, so devices with
different output paths cannot be sample-synced, and identical devices drift.
→ Fix = remove the variable hop from the sync path (see **Design, Option A**).

**B2. Designed auto hw-latency reconciliation is unimplemented.**
`SnapserverMonitor.startAdvertising()` publishes `group_latency`/`hw_latency` TXT records, but
no code consumes them. `multiroom/client/start.sh` derives `--latency` only from
`SOUND_MULTIROOM_LATENCY` (env or `GET /multiroom/latency`, default 400). The
"server computes group max, clients adopt it" mechanism from `multiroom-2-architecture.md`
does not exist. Sync is entirely manual.

### P1 — Reliability / crashes

**B3. State changes via container restart (restart storm).**
- `SoundConfig.demoteToIdle()` → `restartBalenaService('multiroom-server')` **and**
  `'multiroom-client')` on every stop that lasts >30 s.
- `SnapserverMonitor.restartClientForNewMaster()` restarts the client on every master
  goodbye/TTL.
- `POST /multiroom/latency` restarts the client on every UI tweak.
Each restart drops audio for seconds and can wedge in the PA-wait / client-ready loops. The
client watchdog already swaps targets in-place (re-fetches master IP every 5 s) — the same
pattern should cover all transitions, eliminating the restarts.

**B4. No authoritative election → split brain.**
`handlePlayDetect()` (index.ts) optimistically promotes any `auto` device to master on first
play with **no mDNS conflict check** ("Collisions are rare; existing snapcast conflict
resolution handles them" — but there is none at this path). Two `auto` devices that both
originate audio in the same group both become master → two `_snapcast._tcp` advertisements →
clients flip between them → snapclient respawn thrash.
`ElectionManager.uuidJitterMs()` (the only tiebreaker) is a weak XOR-of-char-codes hash with
heavy collisions, so the "UUID jitter breaks simultaneous-boot ties" rarely does. The
lexicographic-lowest-UUID tiebreaker described in the design memory was never implemented.

**B5. AUTO-direct fallback can permanently mute remote clients.**
`handlePlayDetect()` arms a 20 s timer; if `snapserverHasClients()` is false it calls
`PulseAudioWrapper.rerouteInputDirect()`, which **unloads the input→snapcast loopback** and
routes input→output locally. If a remote speaker connects *after* that window (slow boot, or a
device that joins the group later), the snapcast sink is no longer fed → that speaker plays
silence until the next stop→restore (30 s demotion) or a container restart. The fallback never
re-checks for clients to undo itself mid-session.

**B6. Transient malformed JSON-RPC unpublishes the master advertisement.**
`SnapserverMonitor.poll()` does `status.server.groups[0]` with no guarding. If snapserver
answers with a non-`result` shape (startup, momentary error), the property access throws, the
catch treats the server as *down*, and the mDNS advertisement is unpublished — every client then
sees "master DOWN" and restarts. A real outage already produces an axios error (correctly handled);
only the malformed-but-responding case needs the guard.

### P2 — Latency cost / correctness

**B7. Master local playback carries full multiroom latency.**
A master plays its own audio through input-loopback (100) + pacat capture (50) + snapserver
buffer (400) + snapclient + PA buffer (200) + output-loopback (100) ≈ **850 ms+**. Correct for
group sync, but standalone-feeling use on a lone `auto` device is needlessly laggy. The
20 s direct-fallback (B5) is the only mitigation and it's fragile.

**B8. Pipe-source clock assumption.**
snapserver's `pipe://` source assumes the writer delivers exactly 48 kHz on the *server* clock;
`pacat` is driven by the *PipeWire* clock. Same host = same oscillator, so drift is negligible
**today** — noted only so it isn't reintroduced as a cross-host hop later.

**B9. Dead/misleading config.** `core/multiroom/server/snapserver.conf` is `COPY`d to
`/etc/snapserver.conf` but unused — `start.sh` generates and runs `/tmp/snapserver.conf`. The
static file has no `[stream]` and will mislead anyone debugging.

**B10. Stale comments.** `index.ts` and `SoundAPI.ts` say "WirePlumber Lua fires
`POST /internal/play`." The Lua (`balena-play-detect.lua`) is a **no-op stub**; detection is the
`pactl subscribe` watcher at the end of `core/audio/start.sh`. The comments point future
debugging at the wrong file.

**B11. Doc drift.** `multiroom-2-architecture.md` says discovery uses `bonjour-service` (pure
Node, no daemon); the shipped code spawns `avahi-browse`/`avahi-publish` CLIs. `audio-flow.md`
implies automatic latency handling that B2 shows is absent.

---

## Design proposal — make sync actually work

### Root principle
Snapcast can only synchronize **up to the snapclient output backend**. Therefore the backend
must be the real device (or a path with a fixed, known latency). Today it's a null sink with a
variable loopback behind it. Fix that and sync becomes tractable.

### Option A — snapclient writes directly to ALSA  ★ recommended
Run `snapclient --player alsa -s <hw:CARD>` straight to the DAC, bypassing the PipeWire output
graph on the playback side. Snapcast then owns the whole buffer to the DAC and can query/compensate
the ALSA device's real latency — removing B1's variable hop, the single biggest skew source.

Trade-offs / work:
- **Pure speaker (JOIN):** clean — PipeWire isn't needed on the output side.
- **AUTO/HOST master:** it plays locally through its own snapclient too, so the same direct path
  applies; ensure WirePlumber does **not** also grab the hardware sink (release it / mark it
  unavailable on multiroom devices).
- **Volume:** move off `pactl set-sink-volume balena-sound.output` to Snapcast's own
  per-client/group volume (JSON-RPC `Group.SetVolume` is already wired) or the ALSA mixer.
- **Device name:** the audio container already detects `HW_SINK`; expose it (via the supervisor)
  to the client container instead of routing through PipeWire.
- **Source mixing (karaoke/mic):** happens at `balena-sound.input` (capture side) — unaffected.

Expected result: identical devices sample-synced out of the box; heterogeneous devices need only
a *single fixed* `--latency` for the genuinely-fixed DAC delta, not a drifting chase.

### Option B — keep PipeWire output, but make the post-snapclient latency fixed & auto-fed
Pin the output loopback to a fixed latency (rate-matched bridge / disable adaptive resampling) and
have the supervisor compute `OUTPUT_LATENCY + DAC` and feed it into snapclient `--latency`
automatically (client reads it; no manual tuning). Less invasive, but fights PulseAudio's adaptive
loopback and the DAC period is still device-specific → *approximate* sync, not sample-accurate.
This is essentially automating today's manual tuning (also subsumes B2). Good interim if A is too
big a lift.

### Option C — implement the designed TXT reconciliation (B2)
Only worth it layered on A or B; on its own it still rides the broken output path.

### Complexity reduction (addresses "added complexity" + most crashes)
- **Stop using container restarts as state transitions** (B3). Extend the in-place client
  watchdog to handle demote/master-change/latency without restarts.
- **Pick a simpler product model for election** (B4). Strongest simplification: require one
  explicit `host` (the "source") per group and make everyone else `join`. That deletes the entire
  optimistic-promotion / fallback / demotion / election subsystem (B4, B5, B7 disappear). Most
  real setups have an obvious main device; auto-election generates most of the bug surface for
  little practical gain. If auto-election is kept, it needs an authoritative tiebreaker
  (candidacy advertisement + lowest-UUID), not optimistic promotion.

### Recommended sequence
1. **Option A** on a JOIN-only test pair (lowest risk, biggest sync win) — validate on hardware.
2. Fold master local playback onto the same direct-ALSA path.
3. Replace restart-based transitions with in-place reconfig (B3).
4. Decide election model (B4); simplify or make authoritative.
5. Retire manual latency tuning; keep one fixed per-device `--latency` for DAC delta only.

---

## Low-risk fixes applied now (no hardware needed)
See PR `fix/multiroom-audit-safe-fixes`:
- **B4 (partial):** replace the weak XOR jitter hash with FNV-1a so simultaneous-boot ties
  actually stagger. (Does not add the authoritative tiebreaker — that's design work.)
- **B6:** guard `SnapserverMonitor.poll()` so a malformed RPC response can't spuriously
  unpublish the advertisement.
- **B10:** correct the play-detection comments to point at the `pactl` watcher.

Deferred (need device validation): B1/B2/B3/B5 and the redesign options.
