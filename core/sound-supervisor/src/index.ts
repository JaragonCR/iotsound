import PulseAudioWrapper from './PulseAudioWrapper'
import SoundAPI from './SoundAPI'
import SoundConfig from './SoundConfig'
import SnapserverMonitor from './SnapserverMonitor'
import type { SnapcastService } from './AvahiBrowser'
import { MultiroomRole } from './types'
import { constants } from './constants'
import sdk from './BalenaClient'
import axios from 'axios'
import { restartBalenaService } from './utils'

const deviceUuid = process.env.BALENA_DEVICE_UUID ?? ''
const config: SoundConfig = new SoundConfig()
// Loopback, not the LAN address: sound-supervisor is on the host network and the audio
// container publishes 4317 there. The LAN IP was read once at startup, so a DHCP change
// (or starting before WiFi had an address) left every pactl call pointing at a dead IP.
const audioBlock: PulseAudioWrapper = new PulseAudioWrapper('tcp:127.0.0.1:4317')
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
    localIp: config.device.ip,
    isMaster: config.isElectedMaster(),
    multiroomMaster: constants.multiroomMaster,
    initialVolume: constants.volume,
  })
  // Newer-epoch (or lower-UUID on tie) master appeared while we were sourcing → step down in place.
  monitor.setOnSuperseded(handleSuperseded)
  // Keep local PipeWire sink at 100% unity gain whenever Snapcast is active so Snapcast
  // Client.SetVolume is the sole volume authority (no double-attenuation); restore local sink
  // volume when multiroom is inactive.
  monitor.setOnMasterChange(() => { reconcileVolumeMode() })
  soundAPI.setMonitor(monitor)
  monitor.start()

  // SOLO recovery: a device that lost a simultaneous-play race plays locally (SOLO) without
  // advertising. Poll so that once the master that beat it is gone, it takes over the group
  // instead of staying stuck playing alone forever.
  setInterval(reconcileSolo, 3000)

  // Connect to PulseAudio in the background; the wrapper retries indefinitely so a slow
  // audio container never blocks startup or handler registration.
  audioBlock.listen().then(() => reconcileVolumeMode()).catch(() => {})
  // Re-check routing every time PulseAudio (re)appears, including audio container restarts.
  audioBlock.on('connect', () => scheduleRoutingReconcile())
}

// Routing authority.
//
// core/audio/start.sh picks the input route once, at boot, from GET /role. If this service is
// not answering within its 60s wait (seen on device during a release update: the audio
// container came up about a minute before sound-supervisor), it falls back to standalone
// routing: balena-sound.input → balena-sound.output. Nothing corrected that afterwards, so an
// `auto` device played its own sources locally while its snapserver stayed silent and no
// other speaker could hear it, even though every state transition looked right.
//
// So once PulseAudio is up and the audio container has finished applying its own rules
// (default sink is the input sink), make the loopback match the state this service holds.
// Both helpers are idempotent and only act (and log) when the routing is wrong.
const ROUTING_POLL_MS = 3000
const ROUTING_POLL_MAX = 60
const ROUTING_SETTLE_MS = 5000
let routingTimer: NodeJS.Timeout | null = null

function scheduleRoutingReconcile(attempt = 1): void {
  if (routingTimer) clearTimeout(routingTimer)
  routingTimer = setTimeout(async () => {
    routingTimer = null
    const info = await audioBlock.getInfo().catch(() => ({} as Record<string, string>))
    if (info['Default Sink'] !== constants.inputSink) {
      // Audio container still starting (or gone again): keep waiting, up to ~3 minutes.
      if (attempt < ROUTING_POLL_MAX) scheduleRoutingReconcile(attempt + 1)
      return
    }
    // The default sink is set just before start.sh loads its loopbacks; let it finish so we
    // never race it into loading a second input loopback.
    routingTimer = setTimeout(() => {
      routingTimer = null
      reconcileRouting().catch(err => console.log(`[routing] reconcile error: ${(err as Error).message}`))
    }, ROUTING_SETTLE_MS)
  }, attempt === 1 ? 0 : ROUTING_POLL_MS)
}

async function reconcileRouting(): Promise<void> {
  const wantDirect = config.role === MultiroomRole.DISABLED || config.isSolo()
  if (wantDirect) {
    await audioBlock.rerouteInputDirect()
  } else {
    await audioBlock.restoreSnapcastRouting()
  }
  reconcileVolumeMode()
  await restartSourcesIfStale().catch(err =>
    console.log(`[source-restart] check failed: ${(err as Error).message}`))
}

// Restart source plugins when PulseAudio has been replaced underneath them.
//
// go-librespot and Shairport Sync keep their PulseAudio connection for as long as their
// output exists and do not notice when the server goes away: they carry on "playing" into a
// dead connection (seen on device: go-librespot `failed to set volume error=EOF`; Shairport
// `Delay error -5 when checking running latency`, no sink-input, no sound, no play event) until
// the service is restarted. The audio container can be restarted or replaced on its own (a
// crash, a release that only changes the audio image), so someone has to restart them.
//
// Two cases, both checked once PulseAudio is up and routed:
//  - We were running across the restart: the PipeWire instance cookie in `pactl info`
//    changed. A supervisor-side pactl timeout does not change the cookie, so a blip never
//    restarts a source mid-song.
//  - We started after it (release update replaced audio and these services together): the
//    audio container is newer than the source's container.
const PULSE_SOURCE_SERVICES = ['librespot', 'airplay']
let lastPulseCookie: string | null = null

async function restartSourcesIfStale(): Promise<void> {
  // JOIN keeps source plugins stopped; a restart call would start them.
  if (config.role === MultiroomRole.JOIN) return

  const cookie = (await audioBlock.getInfo())['Cookie'] ?? ''
  const previous = lastPulseCookie
  if (cookie) lastPulseCookie = cookie

  let stale: Array<{ service: string; reason: string }> = []
  if (previous === null) {
    stale = await sourcesOlderThanAudio()
  } else if (cookie && cookie !== previous) {
    stale = PULSE_SOURCE_SERVICES.map(service => ({ service, reason: 'PulseAudio restarted' }))
  }
  for (const { service, reason } of stale) {
    console.log(`[source-restart] ${reason}: restarting ${service} so it reconnects to PulseAudio`)
    await restartBalenaService(service).catch(err =>
      console.log(`[source-restart] restarting ${service} failed: ${(err as Error).message}`))
  }
}

// Running source services whose container was created before the audio container.
async function sourcesOlderThanAudio(): Promise<Array<{ service: string; reason: string }>> {
  const url = `${process.env.BALENA_SUPERVISOR_ADDRESS}/v2/state/status?apikey=${process.env.BALENA_SUPERVISOR_API_KEY}`
  const res = await axios.get(url, { timeout: 5000 })
  const containers: Array<{ serviceName?: string; createdAt?: string; status?: string }> = res.data?.containers ?? []
  const created = (name: string): number => {
    const c = containers.find(x => x.serviceName === name)
    return c?.createdAt ? Date.parse(c.createdAt) : NaN
  }
  const audioAt = created('audio')
  if (!Number.isFinite(audioAt)) return []
  const out: Array<{ service: string; reason: string }> = []
  for (const service of PULSE_SOURCE_SERVICES) {
    const c = containers.find(x => x.serviceName === service)
    if (!c || c.status !== 'Running') continue
    const at = created(service)
    if (Number.isFinite(at) && audioAt > at + 5000) {
      out.push({ service, reason: `audio container is newer than the ${service} container` })
    }
  }
  return out
}

function reconcileVolumeMode(): void {
  if (!monitor) return
  const snapcastActive =
    config.role !== MultiroomRole.DISABLED &&
    !config.isSolo() &&
    monitor.hasActiveMultiroomTarget()

  if (snapcastActive) {
    audioBlock.setHardwareUnityGain().catch(() => {})
  } else {
    audioBlock.setVolume(monitor.getCachedVolume()).catch(() => {})
  }
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
// AUTO: become the group master ("newest source wins"). Promotion is in-place and optimistic;
// if another device starts sourcing even more recently, handleSuperseded() steps us down.
export async function handlePlayDetect(): Promise<void> {
  if (!monitor) return
  // The audio container resends the current state every few seconds (resync), so a play
  // that is not a stop→play edge must be a no-op. Without this a SOLO device, which keeps
  // a local source active on purpose, would re-take the group on every resync tick.
  const wasActive = localSourceActive
  localSourceActive = true

  if (config.role !== MultiroomRole.AUTO) return

  if (stopTimer) {
    clearTimeout(stopTimer)
    stopTimer = null
    console.log('[play-detect] Demotion timer cancelled — still playing')
  }

  if (wasActive) return
  if (config.isElectedMaster()) return

  // Newest source wins: promote unconditionally. If another device is actively sourcing,
  // its monitor sees our newer epoch and yields. If we were SOLO (lost an earlier race),
  // restore snapcast routing before taking the group.
  if (config.isSolo()) {
    config.exitSolo()
    await audioBlock.restoreSnapcastRouting().catch(err =>
      console.log(`[solo] restore error: ${(err as Error).message}`))
  }

  console.log('[play-detect] Becoming group master (SOURCING)')
  config.promoteToSourcing()
  monitor.setMaster(true)
  reconcileVolumeMode()
}

// POST /internal/stop — local source stopped. Arms a 30s grace; if no replay, demote in place.
export function handleStopDetect(): void {
  if (!monitor) return
  localSourceActive = false
  if (config.role !== MultiroomRole.AUTO) return
  if (!config.isElectedMaster() && !config.isSolo()) return

  // Repeated stop (resync tick): the grace period is already counting down, keep it.
  if (stopTimer) return
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
    reconcileVolumeMode()
    console.log('[stop-detect] Demoted — warm (will join a remote master if one appears)')
  }, STOP_DEMOTION_MS)
}

// SOLO recovery loop. A SOLO device is still playing a local source but yielded the group
// to a peer that started sourcing more recently. When that peer is gone (no reachable
// master left), promote: restore snapcast routing and take the group so other devices can
// join. If our own source has stopped, stop-detect handles the exit instead.
function reconcileSolo(): void {
  if (!monitor) return
  if (config.role !== MultiroomRole.AUTO) return
  if (!config.isSolo()) return
  if (!localSourceActive) return
  if (monitor.hasReachableMaster()) return
  console.log('[solo] No reachable master left — promoting SOLO → SOURCING')
  config.exitSolo()
  audioBlock.restoreSnapcastRouting().catch(err =>
    console.log(`[solo] restore error: ${(err as Error).message}`))
  config.promoteToSourcing()
  monitor.setMaster(true)
  reconcileVolumeMode()
}

// Monitor callback: we are SOURCING but a newer-epoch (or lower-UUID on tie) master exists,
// so we yield the group. If we still have a local source, fall back to SOLO (play it locally);
// otherwise go warm.
function handleSuperseded(_svc: SnapcastService): void {
  if (config.role !== MultiroomRole.AUTO) return // HOST never yields
  if (!config.isElectedMaster()) return
  if (stopTimer) { clearTimeout(stopTimer); stopTimer = null }
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
  reconcileVolumeMode()
}
