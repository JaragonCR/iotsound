import * as net from 'net'
import axios from 'axios'
import { restartBalenaService } from './utils'
import AvahiAdvertiser from './AvahiAdvertiser'
import { SnapcastBrowser, type SnapcastService } from './AvahiBrowser'

const SNAPSERVER_URL = 'http://localhost:1780/jsonrpc'
const POLL_INTERVAL_MS = 5000
// 3× the 30s demotion timer — safety net for masters that crash without sending a goodbye
const MASTER_TTL_MS = 90000
// Probe every 30s: 3 consecutive failures → TTL fires at 90s.
const TTL_CHECK_INTERVAL_MS = 30000

export interface MonitorConfig {
  groupName: string | undefined
  deviceUuid: string
  groupLatency: number
  hwLatency: number
  localIp: string
  isMaster: boolean
  multiroomMaster?: string
}

export default class SnapserverMonitor {
  private pollInterval: NodeJS.Timeout | null = null

  private advertiser = new AvahiAdvertiser()
  private browser: SnapcastBrowser | null = null
  private ttlTimer: NodeJS.Timeout | null = null
  private serverWasUp = false
  private cachedGroupId: string | null = null
  private discoveredMasterIp: string | null = null
  private discoveredMasterLastSeen: number = 0

  private readonly groupName: string | undefined
  private readonly deviceUuid: string
  private readonly groupLatency: number
  private readonly hwLatency: number
  private readonly localIp: string | undefined
  private readonly multiroomMaster: string | undefined
  private isMaster: boolean

  constructor(cfg: MonitorConfig) {
    this.groupName = cfg.groupName
    this.deviceUuid = cfg.deviceUuid
    this.groupLatency = cfg.groupLatency
    this.hwLatency = cfg.hwLatency
    this.localIp = cfg.localIp === 'localhost' ? undefined : cfg.localIp
    this.multiroomMaster = cfg.multiroomMaster
    this.isMaster = cfg.isMaster
  }

  // --- Public API ---

  // Returns master IP: env override → mDNS discovered → own IP fallback.
  getMasterIp(): string {
    return this.multiroomMaster ?? this.discoveredMasterIp ?? this.localIp ?? 'localhost'
  }

  // Returns only a usable remote/explicit master for client join decisions.
  // AUTO clients must not fall back to their own IP while idle, otherwise they
  // never join an already-advertised room.
  getDiscoveredMasterIp(): string | null {
    return this.multiroomMaster ?? this.discoveredMasterIp
  }

  // Propagate volume to all snapcast clients in the group via JSON-RPC.
  async setGroupVolume(percent: number): Promise<void> {
    if (!this.cachedGroupId) return
    try {
      const resp = await axios.post(SNAPSERVER_URL, {
        id: 3, jsonrpc: '2.0', method: 'Group.SetVolume',
        params: { id: this.cachedGroupId, volume: { percent: Math.round(percent), muted: false } }
      }, { timeout: 3000 })
      if (resp.data?.error) {
        throw new Error(resp.data.error.message ?? JSON.stringify(resp.data.error))
      }
      console.log(`[snapserver-monitor] Group volume set to ${Math.round(percent)}%`)
    } catch (err) {
      console.log(`[snapserver-monitor] Failed to set group volume: ${(err as Error).message}`)
    }
  }

  start(): void {
    if (this.isMaster) {
      this.pollInterval = setInterval(() => this.poll(), POLL_INTERVAL_MS)
    } else {
      this.startBrowsing()
    }
  }

  stop(): void {
    if (this.pollInterval) { clearInterval(this.pollInterval); this.pollInterval = null }
    this.stopBrowsing()
    this.advertiser.unpublish()
  }

  // Called when election result changes at runtime.
  setMaster(isMaster: boolean): void {
    if (this.isMaster === isMaster) return
    this.isMaster = isMaster
    console.log(`[snapserver-monitor] Role transition → ${isMaster ? 'master' : 'client'}`)
    if (isMaster) {
      this.stopBrowsing()
      // Clear stale remote IP so getMasterIp() falls through to localIp.
      // Without this, the watchdog sees no IP change and stays connected to
      // the previous master instead of joining the now-local snapserver.
      this.discoveredMasterIp = null
      this.discoveredMasterLastSeen = 0
      if (!this.pollInterval) {
        this.pollInterval = setInterval(() => this.poll(), POLL_INTERVAL_MS)
      }
    } else {
      if (this.pollInterval) {
        clearInterval(this.pollInterval)
        this.pollInterval = null
        this.advertiser.unpublish()
        this.serverWasUp = false
      }
      this.startBrowsing()
    }
  }

  // --- Private ---

  private startBrowsing(): void {
    if (this.browser) return
    this.browser = new SnapcastBrowser(
      (svc) => this.onMasterUp(svc),
      (svc) => this.onMasterDown(svc),
      this.groupName
    )
    this.browser.start()
    this.ttlTimer = setInterval(() => this.checkMasterTtl(), TTL_CHECK_INTERVAL_MS)
  }

  private stopBrowsing(): void {
    if (this.ttlTimer) { clearInterval(this.ttlTimer); this.ttlTimer = null }
    if (this.browser) { this.browser.stop(); this.browser = null }
  }

  private onMasterUp(svc: SnapcastService): void {
    if (svc.ip !== this.discoveredMasterIp) {
      console.log(`[snapserver-monitor] Master UP: ${this.discoveredMasterIp ?? '(none)'} → ${svc.ip}`)
      this.discoveredMasterIp = svc.ip
    }
    this.discoveredMasterLastSeen = Date.now()
  }

  private onMasterDown(svc: SnapcastService): void {
    if (svc.ip === this.discoveredMasterIp) {
      console.log(`[snapserver-monitor] Master DOWN (goodbye): clearing ${this.discoveredMasterIp}`)
      this.discoveredMasterIp = null
      this.discoveredMasterLastSeen = 0
      this.restartClientForNewMaster('goodbye')
    }
  }

  private async checkMasterTtl(): Promise<void> {
    if (!this.discoveredMasterIp) return

    // Probe port 1704 every 30s. If the master is alive, refresh lastSeen so
    // the TTL never fires during an active session. Three consecutive failures
    // (30 + 60 + 90s) are required before the restart triggers at 90s.
    const alive = await this.probeMasterSnapserver()
    if (alive) {
      this.discoveredMasterLastSeen = Date.now()
      return
    }

    if (Date.now() - this.discoveredMasterLastSeen <= MASTER_TTL_MS) return

    console.log(`[snapserver-monitor] Master TTL expired (${MASTER_TTL_MS}ms) — clearing ${this.discoveredMasterIp}`)
    this.discoveredMasterIp = null
    this.discoveredMasterLastSeen = 0
    this.restartClientForNewMaster('ttl')
  }

  private probeMasterSnapserver(): Promise<boolean> {
    const ip = this.discoveredMasterIp!
    return new Promise((resolve) => {
      const sock = new net.Socket()
      const timer = setTimeout(() => { sock.destroy(); resolve(false) }, 2000)
      sock.connect(1704, ip, () => { clearTimeout(timer); sock.destroy(); resolve(true) })
      sock.on('error', () => { clearTimeout(timer); resolve(false) })
    })
  }

  // Restart multiroom-client so it stops retrying a dead server and re-enters
  // the client-ready wait loop. Skipped if this device is already master.
  private restartClientForNewMaster(reason: 'goodbye' | 'ttl'): void {
    if (this.isMaster) return
    console.log(`[snapserver-monitor] Master gone (${reason}) — restarting multiroom-client`)
    restartBalenaService('multiroom-client').catch((err: Error) =>
      console.log(`[snapserver-monitor] Failed to restart multiroom-client: ${err.message}`)
    )
  }

  private async poll(): Promise<void> {
    try {
      const status = await this.fetchServerStatus()
      // Guard every hop: a malformed-but-responding RPC (e.g. an {error:...} shape
      // during snapserver startup) must not throw here. A throw lands in the catch
      // below and unpublishes the mDNS advertisement, which makes every client see
      // "master DOWN" and restart. Only a real outage (axios reject) should do that.
      this.cachedGroupId = status?.server?.groups?.[0]?.id ?? null

      if (!this.serverWasUp) {
        this.serverWasUp = true
        this.startAdvertising()
      }
    } catch {
      if (this.serverWasUp) {
        this.serverWasUp = false
        this.cachedGroupId = null
        this.advertiser.unpublish()
        console.log('[snapserver-monitor] Snapserver went down, advertisement unpublished')
      }
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


}
