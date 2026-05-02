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
const STOP_DEMOTION_MS = 30_000

init()
async function init() {
  await soundAPI.listen(constants.port)
  console.log('Giving the audio block 10 seconds to initialize PulseAudio...')
  await timeout(10000)
  await audioBlock.listen()
  await audioBlock.setVolume(constants.volume)

  // Ensure balena service state matches the configured role on every startup.
  // balenaOS persists stopped-via-API state across reboots, so we must
  // explicitly start/stop services to recover from any prior crash or partial
  // role switch.
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
    bufferMs: constants.multiroomBufferMs,
    groupName: constants.groupName,
    deviceUuid,
    groupLatency: constants.groupLatency,
    hwLatency: constants.hwLatency,
    localIp: config.device.ip,
    isMaster: config.isElectedMaster(),
  })
  soundAPI.setMonitor(monitor)
  monitor.start()
}

// WirePlumber Lua fires POST /internal/play when a stream links to balena-sound.input.
audioBlock.on('play', async (sink: any) => {
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
  config.applyElectionResult('master')
  monitor.setMaster(true)
}

// Called by SoundAPI when /internal/stop fires.
// Starts a 30s timer; if no play arrives before it fires, tears down multiroom stack.
export function handleStopDetect(): void {
  if (!monitor) return
  if (config.role !== MultiroomRole.AUTO || !config.isElectedMaster()) return

  if (stopTimer) clearTimeout(stopTimer)
  console.log(`[stop-detect] Stream stopped — demoting in ${STOP_DEMOTION_MS / 1000}s if no replay`)
  stopTimer = setTimeout(() => {
    stopTimer = null
    console.log('[stop-detect] No replay — demoting to idle')
    config.demoteToIdle()
    monitor.setMaster(false)
  }, STOP_DEMOTION_MS)
}

async function timeout(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
}
