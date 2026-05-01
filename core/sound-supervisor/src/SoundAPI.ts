import * as path from 'path'
import * as express from 'express'
import { Application } from 'express'
import SoundConfig from './SoundConfig'
import PulseAudioWrapper from './PulseAudioWrapper'
import SnapserverMonitor from './SnapserverMonitor'
import { constants } from './constants'
import { restartDevice, rebootDevice, shutdownDevice } from './utils'
import { MultiroomRole, SoundModes } from './types'
import { BalenaSDK } from 'balena-sdk'
import sdk from './BalenaClient'
import * as fs from 'fs'

const VERSION = fs.existsSync('VERSION')
  ? fs.readFileSync('VERSION', 'utf8').trim()
  : '3.11.0'

interface KnownGroup {
  name: string
  last_seen_epoch: number
}

export default class SoundAPI {
  private api: Application
  private sdk: BalenaSDK
  private monitor: SnapserverMonitor | null = null
  private playHandler: (() => Promise<void>) | null = null

  setMonitor(monitor: SnapserverMonitor): void {
    this.monitor = monitor
  }

  setPlayHandler(fn: () => Promise<void>): void {
    this.playHandler = fn
  }

  constructor(public config: SoundConfig, public audioBlock: PulseAudioWrapper) {
    this.sdk = sdk
    this.api = express()
    this.api.use(express.json())

    // Healthcheck endpoint
    this.api.get('/ping', (_req, res) => res.send('OK'))

    // Configuration
    this.api.get('/config', (_req, res) => res.json(this.config))

    // Config variables -- one by one (auto-generated from public SoundConfig properties)
    for (const [key, value] of Object.entries(this.config)) {
      this.api.get(`/${key}`, (_req, res) => res.send(this.config[key]))
      if (typeof value === 'object') {
        for (const [subKey] of Object.entries(<any>value)) {
          this.api.get(`/${key}/${subKey}`, (_req, res) => res.send(this.config[key][subKey]))
        }
      }
    }

    // balenaSound version
    this.api.get('/version', (_req, res) => res.send(VERSION))

    // --- Multiroom 2.0 API ---

    // GET /multiroom — role, group, device IP, latency config
    this.api.get('/multiroom', (_req, res) => {
      res.json(this.config.getMultiroomStatus())
    })

    // GET /multiroom/master — returns the snapcast server IP for multiroom-client to connect to.
    // Returns mDNS-discovered master IP when available, falls back to this device's own IP.
    this.api.get('/multiroom/master', (_req, res) => {
      const masterIp = this.monitor?.getMasterIp() ?? this.config.getMultiroomStatus().deviceIp
      res.send(masterIp)
    })

    // POST /multiroom/role — change role, persist to device env var
    this.api.post('/multiroom/role', async (req, res) => {
      const { role } = req.body
      if (!role || !Object.values(MultiroomRole).includes(role)) {
        res.status(400).json({ error: `Invalid role. Must be one of: ${Object.values(MultiroomRole).join(', ')}` })
        return
      }
      const changed = this.config.setRole(role as MultiroomRole)
      if (changed) {
        try {
          await this.sdk.models.device.envVar.set(process.env.BALENA_DEVICE_UUID!, 'SOUND_MULTIROOM_ROLE', role)
          console.log(`SOUND_MULTIROOM_ROLE persisted: ${role}`)
        } catch (err) {
          console.log(`Failed to persist SOUND_MULTIROOM_ROLE: ${(err as Error).message}`)
        }
      }
      res.json({ role: this.config.role, changed })
    })

    // POST /multiroom/group — change group name, persist to device env var
    this.api.post('/multiroom/group', async (req, res) => {
      const { groupName } = req.body
      if (typeof groupName !== 'string') {
        res.status(400).json({ error: 'groupName must be a string' })
        return
      }
      this.config.setGroupName(groupName)
      try {
        if (groupName) {
          await this.sdk.models.device.envVar.set(process.env.BALENA_DEVICE_UUID!, 'SOUND_GROUP_NAME', groupName)
        } else {
          await this.sdk.models.device.envVar.remove(process.env.BALENA_DEVICE_UUID!, 'SOUND_GROUP_NAME')
        }
        console.log(`SOUND_GROUP_NAME persisted: ${groupName || '(cleared)'}`)
      } catch (err) {
        console.log(`Failed to persist SOUND_GROUP_NAME: ${(err as Error).message}`)
      }
      res.json({ groupName: this.config.groupName ?? null })
    })

    // GET /multiroom/groups — return fleet-level known groups list
    this.api.get('/multiroom/groups', async (_req, res) => {
      const groups = await this.getKnownGroups()
      res.json(groups)
    })

    // DELETE /multiroom/groups — clear known groups fleet var
    this.api.delete('/multiroom/groups', async (_req, res) => {
      try {
        await this.sdk.models.application.envVar.remove(process.env.BALENA_APP_ID!, 'SOUND_KNOWN_GROUPS')
        console.log('SOUND_KNOWN_GROUPS fleet var cleared')
        res.json({ cleared: true })
      } catch (err) {
        console.log(`Failed to clear SOUND_KNOWN_GROUPS: ${(err as Error).message}`)
        res.status(500).json({ error: (err as Error).message })
      }
    })

    // GET /multiroom/buffer — returns { configured, effective, mode }
    // multiroom-server/start.sh reads this on every (re)start to know which bufferMs to use.
    this.api.get('/multiroom/buffer', (_req, res) => {
      const status = this.monitor
        ? this.monitor.getStatus()
        : { configured: constants.multiroomBufferMs, effective: 50, mode: 'standalone' as const }
      res.json(status)
    })

    // POST /multiroom/buffer — update the configured multi-room buffer (50–2000ms).
    // If currently in multi-room mode, triggers a snapserver restart with the new value.
    this.api.post('/multiroom/buffer', async (req, res) => {
      const { bufferMs } = req.body
      if (typeof bufferMs !== 'number' || bufferMs < 50 || bufferMs > 2000) {
        res.status(400).json({ error: 'bufferMs must be a number between 50 and 2000' })
        return
      }
      this.monitor?.setConfiguredBuffer(bufferMs)
      try {
        await this.sdk.models.device.envVar.set(process.env.BALENA_DEVICE_UUID!, 'SOUND_MULTIROOM_BUFFER_MS', String(bufferMs))
        console.log(`SOUND_MULTIROOM_BUFFER_MS persisted: ${bufferMs}`)
      } catch (err) {
        console.log(`Failed to persist SOUND_MULTIROOM_BUFFER_MS: ${(err as Error).message}`)
      }
      const status = this.monitor?.getStatus() ?? { configured: bufferMs, effective: 50, mode: 'standalone' as const }
      res.json(status)
    })

    // --- Internal (WirePlumber → supervisor events) ---

    // POST /internal/play — fired by WirePlumber Lua (99-balena-play-detect.lua) when a
    // stream links to balena-sound.input. For AUTO devices not yet master, delegates to
    // handlePlayDetect() (wired via setPlayHandler() in index.ts) to trigger re-election.
    this.api.post('/internal/play', (_req, res) => {
      this.playHandler?.().catch((err: Error) => console.log(`[play-detect] handler error: ${err.message}`))
      res.json({ received: true })
    })

    // --- Audio block ---
    this.api.get('/audio', async (_req, res) => res.json(await this.audioBlock.getInfo()))
    this.api.get('/audio/volume', async (_req, res) => res.json(await this.audioBlock.getVolume()))
    this.api.post('/audio/volume', async (req, res) => {
      const result = await this.audioBlock.setVolume(req.body.volume)
      // Propagate to all snapcast clients so remote speakers change volume too
      this.monitor?.setGroupVolume(req.body.volume).catch(() => {})
      res.json(result)
    })
    this.api.get('/audio/sinks', async (_req, res) => res.json(stringify(await this.audioBlock.getSinks())))

    // --- Device management ---
    this.api.post('/device/restart', async (_req, res) => res.json(await restartDevice()))
    this.api.post('/device/reboot', async (_req, res) => res.json(await rebootDevice()))
    this.api.post('/device/shutdown', async (_req, res) => res.json(await shutdownDevice()))
    this.api.post('/device/dtoverlay', async (req, res) => {
      const { dtoverlay } = req.body
      try {
        console.log(`Applying BALENA_HOST_CONFIG_dtoverlay=${dtoverlay}...`)
        await this.sdk.models.device.configVar.set(process.env.BALENA_DEVICE_UUID!, 'BALENA_HOST_CONFIG_dtoverlay', dtoverlay)
        res.json({ status: 'OK' })
      } catch (error) {
        console.log(error)
        res.json({ error: error })
      }
    })

    // --- Deprecated ---

    // GET /mode — backward compat for multiroom-server/client start.sh scripts that check
    // for MULTI_ROOM / MULTI_ROOM_CLIENT / STANDALONE before deciding whether to start.
    this.api.get('/mode', (_req, res) => {
      const mode = roleToLegacyMode(this.config.role)
      console.warn(`[DEPRECATED] GET /mode → ${mode} (role=${this.config.role})`)
      res.send(mode)
    })

    // POST /mode — kept for backward compat; use POST /multiroom/role instead
    this.api.post('/mode', async (req, res) => {
      console.warn('[DEPRECATED] POST /mode — use POST /multiroom/role')
      const updated: boolean = this.config.setMode(req.body.mode as SoundModes)
      if (updated) {
        try {
          await this.sdk.models.device.envVar.set(process.env.BALENA_DEVICE_UUID!, 'SOUND_MULTIROOM_ROLE', this.config.role)
          console.log(`SOUND_MULTIROOM_ROLE persisted via deprecated /mode: ${this.config.role}`)
        } catch (err) {
          console.log(`Failed to persist role via /mode: ${(err as Error).message}`)
        }
      }
      res.json({ mode: req.body.mode, role: this.config.role, updated })
    })

    // Support endpoint
    this.api.get('/support', async (_req, res) => {
      res.json({
        version: VERSION,
        config: this.config,
        audio: await this.audioBlock.getInfo(),
        sinks: stringify(await this.audioBlock.getSinks()),
        volume: await this.audioBlock.getVolume(),
        constants: constants
      })
    })

    // Local UI
    this.api.use('/', express.static(path.join(__dirname, 'ui')))

    // Error catchall
    this.api.use((err: Error, _req, res, _next) => {
      res.status(500).json({ error: err.message })
    })
  }

  public async listen(port: number): Promise<void> {
    return new Promise((resolve) => {
      this.api.listen(port, () => {
        console.log(`Sound supervisor listening on port ${port}`)
        return resolve()
      })
    })
  }

  private async getKnownGroups(): Promise<KnownGroup[]> {
    try {
      const raw = await this.sdk.models.application.envVar.get(process.env.BALENA_APP_ID!, 'SOUND_KNOWN_GROUPS')
      if (!raw) return []
      return JSON.parse(raw) as KnownGroup[]
    } catch {
      return []
    }
  }
}

function roleToLegacyMode(role: MultiroomRole): string {
  switch (role) {
    case MultiroomRole.HOST: return SoundModes.MULTI_ROOM
    case MultiroomRole.JOIN: return SoundModes.MULTI_ROOM_CLIENT
    case MultiroomRole.DISABLED: return SoundModes.STANDALONE
    case MultiroomRole.AUTO:
    default: return SoundModes.MULTI_ROOM
  }
}

function stringify(value) {
  return JSON.parse(JSON.stringify(value, (_, v) => typeof v === 'bigint' ? `${v}n` : v))
}
