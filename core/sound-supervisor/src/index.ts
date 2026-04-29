import PulseAudioWrapper from './PulseAudioWrapper'
import SoundAPI from './SoundAPI'
import SoundConfig from './SoundConfig'
import SnapserverMonitor from './SnapserverMonitor'
import { constants } from './constants'
import sdk from './BalenaClient'

const config: SoundConfig = new SoundConfig()
const audioBlock: PulseAudioWrapper = new PulseAudioWrapper(`tcp:${config.device.ip}:4317`)
const soundAPI: SoundAPI = new SoundAPI(config, audioBlock)

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

  // Start monitoring snapserver client connections to dynamically adjust buffer.
  // Polls localhost:1780 every 5s; transitions standalone ↔ multi-room on client join/leave.
  const monitor = new SnapserverMonitor(constants.multiroomBufferMs)
  soundAPI.setMonitor(monitor)
  monitor.start()
}

// TODO(multiroom-2 spike-1): Replace this with WirePlumber Lua stream-linked event.
// WirePlumber fires when a stream links to balena-sound.input; sound-supervisor
// receives it and triggers master election (auto/host) or stays silent (join/disabled).
audioBlock.on('play', async (sink: any) => {
  if (constants.debug) {
    console.log(`[event] Audio block: play`)
    console.log(sink)
  }

  // Usage tracking for balenaHub metrics
  try {
    await sdk.models.device.tags.set(process.env.BALENA_DEVICE_UUID!, 'metrics:play', '')
  } catch (error) {
    console.log((error as Error).message)
  }
})

async function timeout(delay: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, delay))
}
