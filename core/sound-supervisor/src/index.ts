import PulseAudioWrapper from './PulseAudioWrapper'
import SoundAPI from './SoundAPI'
import SoundConfig from './SoundConfig'
import SnapserverMonitor from './SnapserverMonitor'
import { electMaster } from './ElectionManager'
import { MultiroomRole } from './types'
import { constants } from './constants'
import sdk from './BalenaClient'

const deviceUuid = process.env.BALENA_DEVICE_UUID ?? ''
const config: SoundConfig = new SoundConfig()
const audioBlock: PulseAudioWrapper = new PulseAudioWrapper(`tcp:${config.device.ip}:4317`)
const soundAPI: SoundAPI = new SoundAPI(config, audioBlock)

let monitor: SnapserverMonitor
let stopTimer: NodeJS.Timeout | null = null
let fallbackTimer: NodeJS.Timeout | null = null
let inMultiroomFallback = false
const STOP_DEMOTION_MS = 30_000
const MULTIROOM_FALLBACK_MS = 20_000

init()
async function init() {
  await soundAPI.listen(constants.port)

  // Register play/stop handlers and start monitor before waiting for Pulse.
  // WirePlumber fires /internal/play as soon as audio starts — handlers must
  // be wired before that can happen, regardless of how long Pulse takes to init.
  config.applyCurrentRole()

  // HOST is always master — elect immediately.
  // AUTO stays unelected at boot; it promotes to master on first play via handlePlayDetect.
  // JOIN / DISABLED are always clients — applyCurrentRole already handles service state.
  if (config.role === MultiroomRole.HOST) {
    const elected = await electMaster(config.role, config.groupName, deviceUuid)
    config.applyElectionResult(elected)
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
  soundAPI.setMonitor(monitor)
  monitor.start()

  // Connect to PulseAudio in the background. PulseWrapper retries indefinitely,
  // so startup is never blocked by a slow audio container.
  audioBlock.listen().then(() => audioBlock.setVolume(constants.volume)).catch(() => {})
}

// Play detection: the `pactl subscribe` watcher at the end of core/audio/start.sh
// POSTs /internal/play when a sink-input appears on balena-sound.input. (The
// WirePlumber Lua balena-play-detect.lua is a no-op stub — null-sink links are not
// exposed to the WirePlumber session manager in this environment.)
audioBlock.on('play', async (sink: any) => {
  // PipeWire emits a synthetic stream with name '-' during graph init — skip it.
  if (!sink?.name || sink.name === '-') return
  if (constants.debug) {
    console.log('[event] Audio block: play', sink)
  }
  try {
    await sdk.models.device.tags.set(deviceUuid, 'metrics:play', '')
  } catch (error) {
    console.log((error as Error).message)
  }
})

// Called by SoundAPI when /internal/play fires.
// Cancels any pending demotion timer, then optimistically promotes to master.
// Collisions are rare; existing snapcast conflict resolution handles them.
export async function handlePlayDetect(): Promise<void> {
  if (!monitor) return
  if (config.role !== MultiroomRole.AUTO) return

  if (stopTimer) {
    clearTimeout(stopTimer)
    stopTimer = null
    console.log('[play-detect] Demotion timer cancelled — still playing')
  }

  if (config.isElectedMaster()) return

  console.log('[play-detect] AUTO device — optimistically promoting to master')
  config.applyElectionResult('master', Boolean(monitor.getDiscoveredMasterIp()))
  monitor.setMaster(true)

  // Start a fallback timer. If no snapclient connects within MULTIROOM_FALLBACK_MS,
  // bypass Snapcast and route input directly to output so audio is never silent.
  if (fallbackTimer) clearTimeout(fallbackTimer)
  fallbackTimer = setTimeout(async () => {
    fallbackTimer = null
    if (!config.isElectedMaster() || inMultiroomFallback) return
    const hasClients = await snapserverHasClients()
    if (!hasClients) {
      console.log(`[multiroom-fallback] No snapclient — bypassing Snapcast`)
      inMultiroomFallback = true
      audioBlock.rerouteInputDirect().catch(err =>
        console.log(`[multiroom-fallback] reroute error: ${(err as Error).message}`)
      )
    }
  }, MULTIROOM_FALLBACK_MS)
}

// Called by SoundAPI when /internal/stop fires.
// Starts a 30s timer; if no play arrives before it fires, tears down multiroom stack.
export function handleStopDetect(): void {
  if (!monitor) return
  if (config.role !== MultiroomRole.AUTO || !config.isElectedMaster()) return

  if (fallbackTimer) { clearTimeout(fallbackTimer); fallbackTimer = null }
  if (stopTimer) clearTimeout(stopTimer)
  console.log(`[stop-detect] Stream stopped — demoting in ${STOP_DEMOTION_MS / 1000}s if no replay`)
  stopTimer = setTimeout(async () => {
    stopTimer = null
    if (inMultiroomFallback) {
      inMultiroomFallback = false
      await audioBlock.restoreSnapcastRouting().catch(err =>
        console.log(`[multiroom-fallback] restore error: ${(err as Error).message}`)
      )
    }
    console.log('[stop-detect] No replay — demoting to idle')
    config.demoteToIdle()
    monitor.setMaster(false)
  }, STOP_DEMOTION_MS)
}

async function snapserverHasClients(): Promise<boolean> {
  try {
    const res = await fetch('http://localhost:1780/jsonrpc', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id: 1, jsonrpc: '2.0', method: 'Server.GetStatus' }),
      signal: AbortSignal.timeout(3000),
    })
    const data = await res.json() as any
    const groups: any[] = data?.result?.server?.groups ?? []
    return groups.some((g: any) => (g.clients ?? []).some((c: any) => c.connected))
  } catch {
    return false
  }
}

