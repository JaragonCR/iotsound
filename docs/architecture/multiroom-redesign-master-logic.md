# Multiroom Master-Logic Redesign — transient source-master

Status: **design, not yet implemented.** Agreed 2026-06-07. Higher-risk rewrite; needs
hardware validation. Pairs with the sync fix in `multiroom-audit-2026-06.md` (Option C).

## Principle
**Master = whoever is currently playing a local source.** A device advertises
`_snapcast._tcp` only while it is sourcing; otherwise it sits warm and silent, ready to
promote in well under a second. No container restarts on any transition.

## States (role = auto)
| State | snapserver | pacat | advertises | snapclient | meaning |
|-------|-----------|-------|-----------|-----------|---------|
| **WARM** | running (FIFO held) | stopped | no | stopped | idle, master-ready |
| **SOURCING** | running | running | yes | →own server | playing a local source (the group master) |
| **SLAVE** | running (idle) | stopped | no | →remote master | playing another device's stream |
| **SOLO** | running (idle) | stopped | no | stopped; input→output direct | lost the UUID tiebreak but has a local source |

`host` = always SOURCING-equivalent. `join` = SLAVE only (never sources). `disabled` = standalone.

## Transitions (all in-place — no `restartBalenaService`)
- **WARM → SOURCING**: local play (`/internal/play`). Start `pacat`, publish advert.
  First run the conflict check (below).
- **SOURCING → WARM**: 30 s no local play. Stop `pacat`, unpublish advert. snapserver stays warm.
- **WARM → SLAVE**: a remote advert for my group appears. Spawn snapclient → that master
  (the client watchdog already does this in place).
- **SLAVE → WARM**: master goodbye/TTL with no replacement. Stop snapclient.
- **SLAVE → SOURCING**: local play while slave → run conflict check vs the current master.
- **any SOURCING/SOLO → WARM**: local source stops (30 s); then re-evaluate (may become SLAVE).

## Conflict resolution (two sources at once, same group)
Tiebreaker key: **`master_uuid`** (already in the TXT record; stable balena identity).
**Lowest UUID keeps the group.**
- On entering SOURCING, publish advert, then browse for other group masters.
- If another master has a **lower** UUID → I lose: go **SOLO** (play my own source locally
  via input→output direct, do not advertise, do not join). When my source stops → WARM, then
  join the surviving master as SLAVE.
- If every other master has a **higher** UUID → I keep the group; they will detect me and step
  down to SOLO/SLAVE themselves.
- Normal source-switching (previous source already stopped) is **not** a conflict — only
  simultaneous play triggers this.
- Toggle point: to switch to "newest source steals the group," invert the comparison (new
  source always wins, old master drops to SLAVE). Single-line change, kept as an option.

## File-level change map
- **`SnapserverMonitor.ts`**
  - Advertise on **promotion to SOURCING**, unpublish on demotion — not on every snapserver-up.
  - **Browse always** (warm/sourcing/slave), not only when client, so conflict + master discovery
    work in every state.
  - On discovering a lower-UUID master while SOURCING → demote (unpublish, signal pacat stop) and
    transition (SLAVE, or SOLO if a local source is still playing).
  - `restartClientForNewMaster()` → drop the container restart; just clear `discoveredMasterIp`
    and let the client watchdog respawn in place.
  - Add `setClientLatency(ms)` via JSON-RPC **`Client.SetLatency`** (mirrors the existing
    `Group.SetVolume` call).
- **`index.ts`**
  - `handlePlayDetect`: WARM/SLAVE → SOURCING with conflict check; signal pacat start + advert.
  - `handleStopDetect`: 30 s → SOURCING → WARM in place (stop pacat, unpublish). No restart.
  - Remove the 20 s direct-bypass fallback once Option C makes local-through-snapclient fast
    (interim: make it reversible — restore snapcast routing when a client appears).
- **`SoundConfig.ts`**
  - Replace `applyElectionResult`/`demoteToIdle` container-restart calls with state flags
    (`isSourcing`, `isSlave`, `isSolo`). Pre-warm (start both multiroom containers) stays.
- **`core/multiroom/server/start.sh`**
  - Already polls `/multiroom/active` and starts `pacat` when true. **Add: when it goes false,
    stop `pacat` (kill `PACAT_PID`) while keeping snapserver + `fd 3` alive.** This makes
    promote/demote an inner start/stop of pacat — the core of "no restart."
- **`core/multiroom/client/start.sh`**
  - Largely unchanged (watchdog already respawns in place). Latency changes come via supervisor
    `Client.SetLatency` RPC instead of a container restart.
- **`SoundAPI.ts`**
  - `POST /multiroom/latency` → `monitor.setClientLatency()` (RPC), not
    `restartBalenaService('multiroom-client')`.

## What this deletes
- Optimistic-promotion-without-conflict-check (B4 split brain) → replaced by advertise-on-source +
  UUID tiebreak.
- Container restarts as transitions (B3) → in-place pacat/snapclient control.
- Direct-bypass fallback (B5, B7) → unnecessary once local playback is fast (Option C).

## Sequence
1. Land **Option C** (snapclient → hw sink) and validate sync on a JOIN-only pair.
2. Implement in-place server demotion (pacat stop/start on the polled flag).
3. Implement advertise-on-source + always-browse + UUID conflict in the monitor.
4. Swap latency change to `Client.SetLatency`.
5. Delete the fallback; switch stream `codec` pcm→flac; retune buffers down.
Each step is independently testable on hardware.
