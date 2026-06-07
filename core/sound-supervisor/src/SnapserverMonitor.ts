import * as net from 'net'
import axios from 'axios'
import AvahiAdvertiser from './AvahiAdvertiser'
import { SnapcastBrowser, type SnapcastService } from './AvahiBrowser'

const RPC_PORT = 1780
const SNAPCAST_TCP_PORT = 1704
const POLL_INTERVAL_MS = 5000
const REACHABILITY_CHECK_INTERVAL_MS = 10000

export interface MonitorConfig {
  groupName: string | undefined
  deviceUuid: string
  groupLatency: number
  hwLatency: number
  localIp: string
  isMaster: boolean
  multiroomMaster?: string
}

interface TrackedMaster {
  svc: SnapcastService
  // mDNS says it exists; reachable says its snapserver port actually answers. A master that
  // is advertised but momentarily unreachable (e.g. snapserver restarting) is KEPT and just
  // excluded from selection — it is re-selected when it answers again, without needing a
  // fresh avahi 'up' event (which never comes while the advert stays published).
  reachable: boolean
}

/**
 * Owns mDNS discovery + advertisement for the multiroom group.
 *
 * Transient source-master model:
 *  - Browses ALWAYS (warm / sourcing / slave) so it always knows the current group
 *    masters, and so a sourcing device can detect a lower-UUID master and step down.
 *  - Advertises only while this device is the SOURCING master (advertise()/unadvertise()
 *    are driven by the orchestrator, not by snapserver coming up).
 *  - Never restarts containers. Master changes propagate through getMasterIp(), which the
 *    multiroom-client watchdog polls and applies in place.
 */
export default class SnapserverMonitor {
  private pollInterval: NodeJS.Timeout | null = null
  private advertiser = new AvahiAdvertiser()
  private browser: SnapcastBrowser | null = null
  private ttlTimer: NodeJS.Timeout | null = null
  private serverWasUp = false
  private cachedGroupId: string | null = null
  private advertising = false

  // Remote group masters only (own advertisement is filtered out by UUID).
  private masters = new Map<string, TrackedMaster>()

  private readonly groupName: string | undefined
  private readonly deviceUuid: string
  private readonly groupLatency: number
  private readonly hwLatency: number
  private readonly localIp: string | undefined
  private readonly multiroomMaster: string | undefined
  private isMaster: boolean
  // Wall-clock ms when this device last became the SOURCING master. Advertised so peers can
  // apply "newest source wins": a device that started sourcing more recently owns the group.
  private sourcingEpoch = 0

  // Invoked when this device is SOURCING but a master with a lower UUID appears,
  // i.e. we lost the tiebreak and must demote. The orchestrator decides SLAVE vs SOLO.
  private onSuperseded: ((svc: SnapcastService) => void) | null = null

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

  setOnSuperseded(cb: (svc: SnapcastService) => void): void {
    this.onSuperseded = cb
  }

  // Public: the deterministic group authority (lowest-UUID remote master), or null.
  getSelectedMaster(): SnapcastService | null {
    return this.selectedMaster()
  }

  // True if any advertised, reachable remote master exists. Used for SOLO recovery: when
  // this goes false, a SOLO device (still playing locally) can take the group.
  hasReachableMaster(): boolean {
    return this.selectedMaster() !== null
  }

  // Lowest-UUID REACHABLE remote master service, or null. Deterministic group authority.
  private selectedMaster(): SnapcastService | null {
    let best: SnapcastService | null = null
    for (const m of this.masters.values()) {
      if (!m.reachable) continue
      const uuid = m.svc.txt['master_uuid'] ?? ''
      if (!best || uuid < (best.txt['master_uuid'] ?? '')) best = m.svc
    }
    return best
  }

  // Master IP for THIS device's snapclient to target.
  // Sourcing → our own snapserver (env override wins for manual setups).
  // Otherwise → explicit override, else the discovered lowest-UUID remote master.
  getMasterIp(): string {
    if (this.isMaster) return this.multiroomMaster ?? this.localIp ?? 'localhost'
    return this.multiroomMaster ?? this.selectedMaster()?.ip ?? this.localIp ?? 'localhost'
  }

  // A usable remote/explicit master, or null. Used to decide whether a non-sourcing
  // device has anywhere to connect (client-ready). Must NOT fall back to own IP.
  getDiscoveredMasterIp(): string | null {
    return this.multiroomMaster ?? this.selectedMaster()?.ip ?? null
  }

  // Push this device's snapclient latency live via the snapserver JSON-RPC, so a latency
  // change needs no container restart. Targets the master's RPC (localhost when sourcing,
  // the remote master otherwise); the client id is this device's UUID (snapclient hostID).
  async setClientLatency(latencyMs: number): Promise<void> {
    const masterIp = this.isMaster ? 'localhost' : this.getDiscoveredMasterIp()
    if (!masterIp) {
      console.log('[snapserver-monitor] setClientLatency: no master yet — value applies on next connect')
      return
    }
    try {
      const resp = await axios.post(this.rpcUrl(masterIp), {
        id: 4, jsonrpc: '2.0', method: 'Client.SetLatency',
        params: { id: this.deviceUuid, latency: Math.round(latencyMs) }
      }, { timeout: 3000 })
      if (resp.data?.error) throw new Error(resp.data.error.message ?? JSON.stringify(resp.data.error))
      console.log(`[snapserver-monitor] Client.SetLatency ${Math.round(latencyMs)}ms (${this.deviceUuid})`)
    } catch (err) {
      console.log(`[snapserver-monitor] setClientLatency failed: ${(err as Error).message}`)
    }
  }

  // Propagate volume to all snapcast clients in the group via JSON-RPC.
  async setGroupVolume(percent: number): Promise<void> {
    if (!this.cachedGroupId) return
    try {
      const resp = await axios.post(this.rpcUrl('localhost'), {
        id: 3, jsonrpc: '2.0', method: 'Group.SetVolume',
        params: { id: this.cachedGroupId, volume: { percent: Math.round(percent), muted: false } }
      }, { timeout: 3000 })
      if (resp.data?.error) throw new Error(resp.data.error.message ?? JSON.stringify(resp.data.error))
      console.log(`[snapserver-monitor] Group volume set to ${Math.round(percent)}%`)
    } catch (err) {
      console.log(`[snapserver-monitor] Failed to set group volume: ${(err as Error).message}`)
    }
  }

  start(): void {
    // Browse in every state so we always know the current group masters.
    this.startBrowsing()
    if (this.isMaster) {
      this.sourcingEpoch = Date.now()
      this.startPolling()
      this.advertise()
    }
  }

  stop(): void {
    this.stopPolling()
    this.stopBrowsing()
    this.unadvertise()
  }

  // Called by the orchestrator on a SOURCING enter/exit. Never restarts containers.
  setMaster(isMaster: boolean): void {
    if (this.isMaster === isMaster) return
    this.isMaster = isMaster
    console.log(`[snapserver-monitor] → ${isMaster ? 'SOURCING (master)' : 'not sourcing'}`)
    if (isMaster) {
      this.sourcingEpoch = Date.now()
      this.startPolling()
      this.advertise()
    } else {
      this.stopPolling()
      this.unadvertise()
      this.serverWasUp = false
    }
  }

  // --- Advertisement ---

  advertise(): void {
    if (this.advertising) return
    this.advertising = true
    const name = this.groupName ?? 'default'
    this.advertiser.advertise(name, SNAPCAST_TCP_PORT, {
      group: name,
      group_latency: String(this.groupLatency),
      hw_latency: String(this.hwLatency),
      role: 'host',
      version: '2.1',
      epoch: String(this.sourcingEpoch),
      master_uuid: this.deviceUuid,
    })
  }

  unadvertise(): void {
    if (!this.advertising) return
    this.advertising = false
    this.advertiser.unpublish()
  }

  // --- Browsing ---

  private startBrowsing(): void {
    if (this.browser) return
    this.browser = new SnapcastBrowser(
      (svc) => this.onMasterUp(svc),
      (svc) => this.onMasterDown(svc),
      this.groupName
    )
    this.browser.start()
    this.ttlTimer = setInterval(() => this.checkReachability(), REACHABILITY_CHECK_INTERVAL_MS)
  }

  private stopBrowsing(): void {
    if (this.ttlTimer) { clearInterval(this.ttlTimer); this.ttlTimer = null }
    if (this.browser) { this.browser.stop(); this.browser = null }
    this.masters.clear()
  }

  private onMasterUp(svc: SnapcastService): void {
    // Filter our own advertisement — we discover it too once browsing is always-on.
    if ((svc.txt['master_uuid'] ?? '') === this.deviceUuid) return

    const known = this.masters.has(svc.name)
    // Optimistic reachable: it just announced. checkReachability() corrects it within 10s.
    this.masters.set(svc.name, { svc, reachable: true })
    if (!known) {
      console.log(`[snapserver-monitor] Master discovered: ${svc.name} @ ${svc.ip} (uuid=${svc.txt['master_uuid'] ?? '?'} epoch=${svc.txt['epoch'] ?? '?'})`)
    }

    // Newest source wins: if we are sourcing and another master started MORE RECENTLY
    // (higher epoch; UUID breaks an exact tie), step down. This lets a freshly-played device
    // take the group from one whose source already stopped and is just in its demotion grace.
    if (this.isMaster) {
      const otherEpoch = parseInt(svc.txt['epoch'] ?? '0', 10)
      const otherUuid = svc.txt['master_uuid'] ?? ''
      const otherIsNewer = otherEpoch > this.sourcingEpoch ||
        (otherEpoch === this.sourcingEpoch && otherUuid < this.deviceUuid)
      if (otherIsNewer) {
        console.log(`[snapserver-monitor] Newer master ${svc.ip} (epoch ${otherEpoch} > ${this.sourcingEpoch}) — superseded`)
        this.onSuperseded?.(svc)
      }
    }
  }

  private onMasterDown(svc: SnapcastService): void {
    if (this.masters.delete(svc.name)) {
      console.log(`[snapserver-monitor] Master gone (goodbye): ${svc.name} @ ${svc.ip}`)
    }
  }

  // Probe each known master's snapserver port and update reachability. We never delete here:
  // real disappearance arrives as an avahi 'down' event (onMasterDown). This only flips a
  // wedged/restarting master out of and back into selection as its port stops/starts
  // answering, so recovery needs no fresh mDNS announcement.
  private async checkReachability(): Promise<void> {
    for (const m of this.masters.values()) {
      const alive = await this.probe(m.svc.ip, SNAPCAST_TCP_PORT)
      if (alive !== m.reachable) {
        console.log(`[snapserver-monitor] Master ${m.svc.ip} ${alive ? 'reachable' : 'unreachable'}`)
      }
      m.reachable = alive
    }
  }

  private probe(ip: string, port: number): Promise<boolean> {
    return new Promise((resolve) => {
      const sock = new net.Socket()
      const timer = setTimeout(() => { sock.destroy(); resolve(false) }, 2000)
      sock.connect(port, ip, () => { clearTimeout(timer); sock.destroy(); resolve(true) })
      sock.on('error', () => { clearTimeout(timer); resolve(false) })
    })
  }

  // --- Polling (only while sourcing: caches group id for volume) ---

  private startPolling(): void {
    if (this.pollInterval) return
    this.pollInterval = setInterval(() => this.poll(), POLL_INTERVAL_MS)
  }

  private stopPolling(): void {
    if (this.pollInterval) { clearInterval(this.pollInterval); this.pollInterval = null }
    this.cachedGroupId = null
  }

  private async poll(): Promise<void> {
    try {
      const status = await this.fetchServerStatus()
      // Guard every hop: a malformed-but-responding reply must not throw into the catch.
      this.cachedGroupId = status?.server?.groups?.[0]?.id ?? null
      this.serverWasUp = true
    } catch {
      if (this.serverWasUp) {
        this.serverWasUp = false
        this.cachedGroupId = null
        console.log('[snapserver-monitor] Snapserver status unavailable')
      }
    }
  }

  private async fetchServerStatus(): Promise<any> {
    const resp = await axios.post(
      this.rpcUrl('localhost'),
      { id: 1, jsonrpc: '2.0', method: 'Server.GetStatus' },
      { timeout: 3000 }
    )
    return resp.data.result
  }

  private rpcUrl(ip: string): string {
    return `http://${ip}:${RPC_PORT}/jsonrpc`
  }
}
