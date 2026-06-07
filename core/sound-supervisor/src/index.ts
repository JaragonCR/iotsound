import PulseAudioWrapper from './PulseAudioWrapper'
import SoundAPI from './SoundAPI'
import SoundConfig from './SoundConfig'
import SnapserverMonitor from './SnapserverMonitor'
import type { SnapcastService } from './AvahiBrowser'
import { MultiroomRole } from './types'
import { constants } from './constants'
import sdk from './BalenaClient'

const deviceUuid = process.env.BALENA_DEVICE_UUID ?? ''
const config: SoundConfig = new SoundConfig()
const audioBlock: PulseAudioWrapper = new PulseAudioWrapper(`tcp:${config.device.ip}:4317`)
const soundAPI: SoundAPI = new SoundAPI(config, audioBlock)

let monitor: SnapserverMonitor
let stopTimer: NodeJS.Timeout | null = null
// True between a local /internal/play and /internal/stop — the *immediate* source state,
// independent of the 30s demotion grace. Drives the SOURCING-vs-SOLO decision.
let localSourceActive = false
const STOP_DEMOTION_MS = 30_000

init()
async function init() {
  await soundAPI.listen(constants.port)

  // Register play/stop handlers and start the monitor before waiting for Pulse: the
  // audio container's pactl watcher can POST /internal/play the moment audio starts.
  config.applyCurrentRole()

  // HOST is unconditionally the group master.
  if (config.role === MultiroomRole.HOST) {
    config.promoteToSourcing()
  }

  soundAPI.setPlayHandler(handlePlayDetect)
  soundAPI.setStopHandler(handleStopDetect)

  monitor = new SnapserverMonitor({
    groupName: constants.groupName,
    deviceUuid,
    groupLatency: constants.groupLatency,
    hwLatency: constants.hwLatency,
    localIp: config.device.ip,
    isMaster: config.isElectedMaster(),
    multiroomMaster: constants.multiroomMaster,
  })
  // Lower-UUID master appeared while we were sourcing → step down (in place).
  monitor.setOnSuperseded(handleSuperseded)
  soundAPI.setMonitor(monitor)
  monitor.start()

  // Connect to PulseAudio in the background; the wrapper retries indefinitely so a slow
  // audio container never blocks startup or handler registration.
  audioBlock.listen().then(() => audioBlock.setVolume(constants.volume)).catch(() => {})
}

// Metrics tag on first play (best-effort).
audioBlock.on('play', async (sink: any) => {
  if (!sink?.name || sink.name === '-') return
  if (constants.debug) console.log('[event] Audio block: play', sink)
  try {
    await sdk.models.device.tags.set(deviceUuid, 'metrics:play', '')
  } catch (error) {
    console.log((error as Error).message)
  }
})

// POST /internal/play — a local source started.
// AUTO: become the group master, unless a lower-UUID master already owns the group, in
// which case play locally (SOLO) without disturbing it. Promotion is in-place and optimistic;
// if a lower-UUID master appears slightly later, handleSuperseded() steps us down.
export async function handlePlayDetect(): Promise<void> {
  if (!monitor) return
  localSourceActive = true

  if (config.role !== MultiroomRole.AUTO) return

  if (stopTimer) {
    clearTimeout(stopTimer)
    stopTimer = null
    console.log('[play-detect] Demotion timer cancelled — still playing')
  }

  if (config.isElectedMaster() || config.isSolo()) return

  const competitor = monitor.getSelectedMaster()
  if (competitor && (competitor.txt['master_uuid'] ?? '') < deviceUuid) {
    console.log(`[play-detect] Lower-UUID master ${competitor.ip} owns the group — playing SOLO`)
    config.enterSolo()
    await audioBlock.rerouteInputDirect().catch(err =>
      console.log(`[solo] reroute error: ${(err as Error).message}`))
    return
  }

  console.log('[play-detect] Becoming group master (SOURCING)')
  config.promoteToSourcing()
  monitor.setMaster(true)
}

// POST /internal/stop — local source stopped. Arms a 30s grace; if no replay, demote in place.
export function handleStopDetect(): void {
  if (!monitor) return
  localSourceActive = false
  if (config.role !== MultiroomRole.AUTO) return
  if (!config.isElectedMaster() && !config.isSolo()) return

  if (stopTimer) clearTimeout(stopTimer)
  console.log(`[stop-detect] Source stopped — demoting in ${STOP_DEMOTION_MS / 1000}s if no replay`)
  stopTimer = setTimeout(async () => {
    stopTimer = null
    if (config.isSolo()) {
      config.exitSolo()
      await audioBlock.restoreSnapcastRouting().catch(err =>
        console.log(`[solo] restore error: ${(err as Error).message}`))
    }
    if (config.isElectedMaster()) {
      config.demoteFromSourcing()
      monitor.setMaster(false)
    }
    console.log('[stop-detect] Demoted — warm (will join a remote master if one appears)')
  }, STOP_DEMOTION_MS)
}

// Monitor callback: we are SOURCING but a lower-UUID master exists, so we yield the group.
// If we still have a local source, fall back to SOLO (play it locally); otherwise go warm.
function handleSuperseded(_svc: SnapcastService): void {
  if (!config.isElectedMaster()) return
  config.demoteFromSourcing()
  monitor.setMaster(false)
  if (localSourceActive) {
    console.log('[supersede] Yielded group but still sourcing locally → SOLO')
    config.enterSolo()
    audioBlock.rerouteInputDirect().catch(err =>
      console.log(`[solo] reroute error: ${(err as Error).message}`))
  } else {
    console.log('[supersede] Yielded group → warm')
  }
}
