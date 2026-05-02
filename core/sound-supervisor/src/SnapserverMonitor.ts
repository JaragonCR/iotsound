import axios from 'axios'
import { restartBalenaService } from './utils'
import AvahiAdvertiser from './AvahiAdvertiser'
import { browseSnapcast } from './AvahiBrowser'

const SNAPSERVER_URL = 'http://localhost:1780/jsonrpc'
const STANDALONE_BUFFER_MS = 50
const POLL_INTERVAL_MS = 5000
const DISCOVERY_INTERVAL_MS = 15000
const RESTART_COOLDOWN_MS = 20000

export interface SnapserverBufferStatus {
  configured: number
  effective: number
  mode: 'standalone' | 'multiroom'
}

export interface MonitorConfig {
  bufferMs: number
  groupName: string | undefined
  deviceUuid: string
  groupLatency: number
  hwLatency: number
  localIp: string
  isMaster: boolean
}

export default class SnapserverMonitor {
  private configuredBufferMs: number
  private effectiveBufferMs: number = STANDALONE_BUFFER_MS
  private previousRemoteCount: number = 0
  private cooldownUntil: number = 0
  private pollInterval: NodeJS.Timeout | null = null
  private discoveryInterval: NodeJS.Timeout | null = null

  private advertiser = new AvahiAdvertiser()
  private serverWasUp = false
  private cachedGroupId: string | null = null
  private discoveredMasterIp: string | null = null
  private discovering = false

  private readonly groupName: string | undefined
  private readonly deviceUuid: string
  private readonly groupLatency: number
  private readonly hwLatency: number
  private readonly localIp: string
  private isMaster: boolean

  constructor(cfg: MonitorConfig) {
    this.configuredBufferMs = cfg.bufferMs
    this.groupName = cfg.groupName
    this.deviceUuid = cfg.deviceUuid
    this.groupLatency = cfg.groupLatency
    this.hwLatency = cfg.hwLatency
    this.localIp = cfg.localIp
    this.isMaster = cfg.isMaster
  }

  // --- Public API ---

  getStatus(): SnapserverBufferStatus {
    return {
      configured: this.configuredBufferMs,
      effective: this.effectiveBufferMs,
      mode: this.effectiveBufferMs === STANDALONE_BUFFER_MS ? 'standalone' : 'multiroom',
    }
  }

  setConfiguredBuffer(ms: number): void {
    this.configuredBufferMs = Math.max(50, Math.min(ms, 2000))
    if (this.previousRemoteCount > 0) {
      this.effectiveBufferMs = this.configuredBufferMs
      this.triggerRestart('multiroom')
    }
  }

  // Returns the discovered snapcast server IP, or this device's own IP as fallback.
  getMasterIp(): string {
    return this.discoveredMasterIp ?? this.localIp
  }

  // Propagate volume to all snapcast clients in the group via JSON-RPC.
  async setGroupVolume(percent: number): Promise<void> {
    if (!this.cachedGroupId) return
    try {
      await axios.post(SNAPSERVER_URL, {
        id: 3, jsonrpc: '2.0', method: 'Group.SetVolume',
        params: { id: this.cachedGroupId, volume: { percent: Math.round(percent), muted: false } }
      }, { timeout: 3000 })
      console.log(`[snapserver-monitor] Group volume set to ${Math.round(percent)}%`)
    } catch (err) {
      console.log(`[snapserver-monitor] Failed to set group volume: ${(err as Error).message}`)
    }
  }

  start(): void {
    // Poll snapserver HTTP API only if this device is the elected master.
    // Client devices run discovery only so they can find the master IP.
    if (this.isMaster) {
      this.pollInterval = setInterval(() => this.poll(), POLL_INTERVAL_MS)
    }
    this.discoveryInterval = setInterval(() => this.discover(), DISCOVERY_INTERVAL_MS)
    this.discover().catch(() => {})
  }

  stop(): void {
    if (this.pollInterval) { clearInterval(this.pollInterval); this.pollInterval = null }
    if (this.discoveryInterval) { clearInterval(this.discoveryInterval); this.discoveryInterval = null }
    this.advertiser.unpublish()
  }

  // Called when election result changes at runtime (e.g. play-detect promotes client → master).
  setMaster(isMaster: boolean): void {
    if (this.isMaster === isMaster) return
    this.isMaster = isMaster
    console.log(`[snapserver-monitor] Role transition → ${isMaster ? 'master' : 'client'}`)
    if (isMaster && !this.pollInterval) {
      this.pollInterval = setInterval(() => this.poll(), POLL_INTERVAL_MS)
    } else if (!isMaster && this.pollInterval) {
      clearInterval(this.pollInterval)
      this.pollInterval = null
      this.advertiser.unpublish()
      this.serverWasUp = false
    }
  }

  // --- Private ---

  private async poll(): Promise<void> {
    if (Date.now() < this.cooldownUntil) return

    try {
      const status = await this.fetchServerStatus()

      // Cache group ID for volume control
      this.cachedGroupId = status.server.groups[0]?.id ?? null

      // Advertise as soon as the server first comes up
      if (!this.serverWasUp) {
        this.serverWasUp = true
        this.startAdvertising()
      }

      const allClients: any[] = status.server.groups.flatMap((g: any) => g.clients)
      const connectedCount = allClients.filter((c: any) => c.connected).length
      const remoteCount = Math.max(0, connectedCount - 1)

      if (this.previousRemoteCount === 0 && remoteCount > 0) {
        console.log(`[snapserver-monitor] Remote client joined (connected=${connectedCount}). Buffer: standalone → ${this.configuredBufferMs}ms`)
        this.effectiveBufferMs = this.configuredBufferMs
        this.triggerRestart('multiroom')
      } else if (this.previousRemoteCount > 0 && remoteCount === 0) {
        console.log(`[snapserver-monitor] Last remote client left. Buffer: ${this.effectiveBufferMs}ms → standalone (${STANDALONE_BUFFER_MS}ms)`)
        this.effectiveBufferMs = STANDALONE_BUFFER_MS
        this.triggerRestart('standalone')
      }

      this.previousRemoteCount = remoteCount
    } catch {
      // Server not reachable — normal at startup or after restart
      if (this.serverWasUp) {
        this.serverWasUp = false
        this.cachedGroupId = null
        this.advertiser.unpublish()
        console.log('[snapserver-monitor] Snapserver went down, advertisement unpublished')
      }
    }
  }

  private async discover(): Promise<void> {
    if (this.discovering) return
    this.discovering = true
    try {
      const services = await browseSnapcast(this.groupName)
      const newIp = services[0]?.ip ?? null
      if (newIp !== this.discoveredMasterIp) {
        console.log(`[snapserver-monitor] Master IP: ${this.discoveredMasterIp ?? '(none)'} → ${newIp ?? '(none)'}`)
        this.discoveredMasterIp = newIp
      }
    } finally {
      this.discovering = false
    }
  }

  private startAdvertising(): void {
    const name = this.groupName ?? 'default'
    this.advertiser.advertise(name, 1704, {
      group: this.groupName ?? 'default',
      group_latency: String(this.groupLatency),
      hw_latency: String(this.hwLatency),
      role: 'host',
      version: '2.0',
      master_uuid: this.deviceUuid,
    })
  }

  private async fetchServerStatus(): Promise<any> {
    const resp = await axios.post(
      SNAPSERVER_URL,
      { id: 1, jsonrpc: '2.0', method: 'Server.GetStatus' },
      { timeout: 3000 }
    )
    return resp.data.result
  }

  private triggerRestart(targetMode: 'standalone' | 'multiroom'): void {
    this.previousRemoteCount = targetMode === 'multiroom' ? 1 : 0
    this.cooldownUntil = Date.now() + RESTART_COOLDOWN_MS
    restartBalenaService('multiroom-server').catch((err: Error) =>
      console.log(`[snapserver-monitor] Failed to restart multiroom-server: ${err.message}`)
    )
  }
}
