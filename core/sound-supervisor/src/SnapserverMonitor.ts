import * as http from 'http'
import * as net from 'net'
import AvahiAdvertiser from './AvahiAdvertiser'
import MasterBeacon, { BEACON_INTERVAL_MS, type BeaconMessage } from './MasterBeacon'
import { SnapcastBrowser, type SnapcastService } from './AvahiBrowser'
import { constants } from './constants'

const RPC_PORT = 1780
const SNAPCAST_TCP_PORT = 1704
const POLL_INTERVAL_MS = 5000
const REACHABILITY_CHECK_INTERVAL_MS = 10000
const GROUP_TTL_MS = 7 * 24 * 60 * 60 * 1000

export interface MonitorConfig {
  groupName: string | undefined
  deviceUuid: string
  localIp: string
  isMaster: boolean
  multiroomMaster?: string
  initialVolume?: number
}

export interface SeenGroup {
  name: string
  last_seen_epoch: number
}

interface TrackedMaster {
  svc: SnapcastService
  // mDNS says it exists; reachable says its snapserver port actually answers. A master that
  // is advertised but momentarily unreachable (e.g. snapserver restarting) is KEPT and just
  // excluded from selection — it is re-selected when it answers again, without needing a
  // fresh avahi 'up' event (which never comes while the advert stays published).
  reachable: boolean
  // Wall-clock ms of the last heartbeat beacon from this master; 0 if it has never sent one
  // (a master on an older release). A beaconing master that goes quiet is dropped.
  lastBeacon: number
}

// A beaconing master is considered gone after this long without a heartbeat (3 missed + slack).
const BEACON_TIMEOUT_MS = BEACON_INTERVAL_MS * 3 + 5000

/**
 * Owns mDNS discovery + advertisement and Snapcast JSON-RPC volume/latency for the group.
 *
 * Transient source-master model:
 *  - Browses ALWAYS (warm / sourcing / slave) so it always knows the current group
 *    masters, and so a sourcing device can detect a newer-epoch master and step down.
 *  - Advertises only while this device is the SOURCING master (advertise()/unadvertise()
 *    are driven by the orchestrator, not by snapserver coming up).
 *  - Never restarts containers. Master changes propagate through getMasterIp(), which the
 *    multiroom-client watchdog polls and applies in place.
 */
export default class SnapserverMonitor {
  private pollInterval: NodeJS.Timeout | null = null
  private advertiser = new AvahiAdvertiser()
  private beacon = new MasterBeacon((msg, ip) => this.onBeacon(msg, ip))
  private browser: SnapcastBrowser | null = null
  private ttlTimer: NodeJS.Timeout | null = null
  private serverWasUp = false
  private lastClientCount = 0
  private advertising = false
  private groupVolume: number

  // Remote group masters only (own advertisement is filtered out by UUID).
  private masters = new Map<string, TrackedMaster>()
  // Discovered group names on the LAN (name -> last_seen_epoch ms).
  private seenGroups = new Map<string, number>()

  private groupName: string | undefined
  private readonly deviceUuid: string
  private readonly localIp: string | undefined
  private readonly multiroomMaster: string | undefined
  private isMaster: boolean
  // Wall-clock ms when this device last became the SOURCING master. Advertised so peers can
  // apply "newest source wins": a device that started sourcing more recently owns the group.
  private sourcingEpoch = 0
  // Highest epoch seen in any remote master's advertisement. A new sourcing epoch is always
  // above it, so "newest source wins" still holds when this device's clock is behind (no RTC,
  // NTP not synced yet). Otherwise a promoting device with a slow clock advertises an older
  // epoch than the master it is replacing, neither side yields, and the group splits.
  private highestSeenEpoch = 0

  // Invoked when this device is SOURCING but a master with a newer epoch (or lower UUID on tie)
  // appears, i.e. we lost the tiebreak and must demote. The orchestrator decides SLAVE vs SOLO.
  private onSuperseded: ((svc: SnapcastService) => void) | null = null
  private onMasterChange: ((hasMaster: boolean) => void) | null = null

  constructor(cfg: MonitorConfig) {
    this.groupName = cfg.groupName
    this.deviceUuid = cfg.deviceUuid
    this.localIp = cfg.localIp === 'localhost' ? undefined : cfg.localIp
    this.multiroomMaster = cfg.multiroomMaster
    this.isMaster = cfg.isMaster
    this.groupVolume = Math.max(0, Math.min(100, Math.round(cfg.initialVolume ?? constants.volume)))
    if (this.groupName) {
      this.seenGroups.set(this.groupName, Date.now())
    }
  }

  // --- Public API ---

  setOnSuperseded(cb: (svc: SnapcastService) => void): void {
    this.onSuperseded = cb
  }

  setOnMasterChange(cb: (hasMaster: boolean) => void): void {
    this.onMasterChange = cb
  }

  // True if any advertised, reachable remote master exists. Used for SOLO recovery: when
  // this goes false, a SOLO device (still playing locally) can take the group.
  hasReachableMaster(): boolean {
    return this.selectedMaster() !== null
  }

  // True when this device is actively participating in Snapcast (either as sourcing master
  // or connected/targeting a reachable remote/explicit master).
  hasActiveMultiroomTarget(): boolean {
    return this.isMaster || Boolean(this.getDiscoveredMasterIp())
  }

  // Newest-epoch REACHABLE remote master service (lowest UUID breaks ties), or null.
  // Matches onMasterUp() tie-breaking so all devices agree on group authority.
  private selectedMaster(): SnapcastService | null {
    let best: SnapcastService | null = null
    for (const m of this.masters.values()) {
      if (!m.reachable) continue
      if (!best) {
        best = m.svc
        continue
      }
      const epoch = parseInt(m.svc.txt['epoch'] ?? '0', 10)
      const bestEpoch = parseInt(best.txt['epoch'] ?? '0', 10)
      const uuid = m.svc.txt['master_uuid'] ?? ''
      const bestUuid = best.txt['master_uuid'] ?? ''
      if (epoch > bestEpoch || (epoch === bestEpoch && uuid < bestUuid)) {
        best = m.svc
      }
    }
    return best
  }

  // Master IP for THIS device's snapclient to target.
  // Sourcing → our own snapserver (env override wins for manual setups).
  // Otherwise → explicit override, else the discovered remote master.
  getMasterIp(): string {
    if (this.isMaster) return this.multiroomMaster ?? this.localIp ?? 'localhost'
    return this.multiroomMaster ?? this.selectedMaster()?.ip ?? this.localIp ?? 'localhost'
  }

  // A usable remote/explicit master, or null. Used to decide whether a non-sourcing
  // device has anywhere to connect (client-ready). Must NOT fall back to own IP.
  getDiscoveredMasterIp(): string | null {
    return this.multiroomMaster ?? this.selectedMaster()?.ip ?? null
  }

  private activeMasterRpcHost(): string | null {
    return this.isMaster ? 'localhost' : this.getDiscoveredMasterIp()
  }

  // Update group name live without restarting sound-supervisor.
  setGroupName(name: string | undefined): void {
    const normalized = name || undefined
    if (this.groupName === normalized) return
    this.groupName = normalized
    if (normalized) {
      this.seenGroups.set(normalized, Date.now())
    }
    this.masters.clear()
    this.browser?.setGroupName(this.groupName)
    if (this.advertising) {
      this.unadvertise()
      this.advertise()
    }
    this.onMasterChange?.(this.hasActiveMultiroomTarget())
  }

  getSeenGroups(): SeenGroup[] {
    const cutoff = Date.now() - GROUP_TTL_MS
    const out: SeenGroup[] = []
    for (const [name, epoch] of this.seenGroups.entries()) {
      if (epoch >= cutoff) {
        out.push({ name, last_seen_epoch: epoch })
      } else {
        this.seenGroups.delete(name)
      }
    }
    return out
  }

  clearSeenGroups(): void {
    this.seenGroups.clear()
    if (this.groupName) {
      this.seenGroups.set(this.groupName, Date.now())
    }
  }

  getCachedVolume(): number {
    return this.groupVolume
  }

  setCachedVolume(percent: number): void {
    this.groupVolume = Math.max(0, Math.min(100, Math.round(percent)))
  }

  // Push this device's snapclient latency live via the snapserver JSON-RPC, so a latency
  // change needs no container restart. Targets the master's RPC (localhost when sourcing,
  // the remote master otherwise); the client id is this device's UUID (snapclient hostID).
  async setClientLatency(latencyMs: number): Promise<void> {
    const masterIp = this.activeMasterRpcHost()
    if (!masterIp) {
      console.log('[snapserver-monitor] setClientLatency: no master yet — value applies on next connect')
      return
    }
    try {
      await this.rpcCall(masterIp, 'Client.SetLatency', {
        id: this.deviceUuid,
        latency: Math.round(latencyMs)
      }, 4)
      console.log(`[snapserver-monitor] Client.SetLatency ${Math.round(latencyMs)}ms (${this.deviceUuid})`)
    } catch (err) {
      console.log(`[snapserver-monitor] setClientLatency failed: ${(err as Error).message}`)
    }
  }

  // Set volume for all snapcast clients in the active master's group(s) via JSON-RPC
  // Client.SetVolume. Works whether invoked on the sourcing master (localhost) or on a client.
  async setGroupVolume(percent: number): Promise<number> {
    const clamped = Math.max(0, Math.min(100, Math.round(percent)))
    this.groupVolume = clamped
    const host = this.activeMasterRpcHost()
    if (!host) return clamped

    try {
      const status = await this.fetchServerStatus(host)
      const groups: Array<{ id?: string; clients?: Array<{ id?: string }> }> = status?.server?.groups ?? []
      const clientIds = new Set<string>()
      for (const g of groups) {
        for (const c of g?.clients ?? []) {
          if (c?.id) clientIds.add(c.id)
        }
      }
      if (clientIds.size === 0 && this.deviceUuid) {
        clientIds.add(this.deviceUuid)
      }
      for (const id of clientIds) {
        await this.rpcCall(host, 'Client.SetVolume', {
          id,
          volume: { percent: clamped, muted: false }
        }, 3)
      }
      if (clientIds.size > 0) {
        console.log(`[snapserver-monitor] Group volume set to ${clamped}% across ${clientIds.size} client(s) on ${host}`)
      }
    } catch (err) {
      console.log(`[snapserver-monitor] Failed to set group volume on ${host}: ${(err as Error).message}`)
    }
    return clamped
  }

  // Query current group volume from the active master's Snapserver, falling back to cached groupVolume.
  async getGroupVolume(): Promise<number> {
    const host = this.activeMasterRpcHost()
    if (!host) return this.groupVolume
    try {
      const status = await this.fetchServerStatus(host)
      const groups: Array<{ clients?: Array<{ id?: string; config?: { volume?: { percent?: number } } }> }> =
        status?.server?.groups ?? []
      const allClients = groups.flatMap(g => g?.clients ?? [])
      const own = allClients.find(c => c?.id === this.deviceUuid)
      const target = own ?? allClients[0]
      const pct = target?.config?.volume?.percent
      if (typeof pct === 'number') {
        this.groupVolume = Math.max(0, Math.min(100, Math.round(pct)))
        return this.groupVolume
      }
    } catch {
      // Fall back to cached groupVolume
    }
    return this.groupVolume
  }

  start(): void {
    // Browse in every state so we always know the current group masters.
    this.startBrowsing()
    this.beacon.listen()
    if (this.isMaster) {
      this.sourcingEpoch = this.nextSourcingEpoch()
      this.startPolling()
      this.advertise()
    }
  }

  private nextSourcingEpoch(): number {
    return Math.max(Date.now(), this.highestSeenEpoch + 1)
  }

  stop(): void {
    this.stopPolling()
    this.stopBrowsing()
    this.unadvertise()
    this.beacon.close()
  }

  // Called by the orchestrator on a SOURCING enter/exit. Never restarts containers.
  setMaster(isMaster: boolean): void {
    if (this.isMaster === isMaster) return
    this.isMaster = isMaster
    console.log(`[snapserver-monitor] → ${isMaster ? 'SOURCING (master)' : 'not sourcing'}`)
    if (isMaster) {
      this.sourcingEpoch = this.nextSourcingEpoch()
      this.startPolling()
      this.advertise()
    } else {
      this.stopPolling()
      this.unadvertise()
      this.serverWasUp = false
      this.lastClientCount = 0
    }
    this.onMasterChange?.(this.hasActiveMultiroomTarget())
  }

  // --- Advertisement ---

  advertise(): void {
    if (this.advertising) return
    this.advertising = true
    const name = this.groupName ?? 'default'
    this.seenGroups.set(name, Date.now())
    this.advertiser.advertise(name, SNAPCAST_TCP_PORT, {
      group: name,
      role: 'host',
      version: '2.1',
      epoch: String(this.sourcingEpoch),
      master_uuid: this.deviceUuid,
    })
    // Heartbeat alongside mDNS: one broadcast every 10s while we are the master.
    this.beacon.start(() => ({
      group: this.groupName ?? 'default',
      uuid: this.deviceUuid,
      epoch: this.sourcingEpoch,
      port: SNAPCAST_TCP_PORT,
    }))
  }

  unadvertise(): void {
    if (!this.advertising) return
    this.advertising = false
    this.advertiser.unpublish()
    this.beacon.stop()
  }

  // --- Browsing ---

  private startBrowsing(): void {
    if (this.browser) return
    this.browser = new SnapcastBrowser(
      (svc) => this.onMasterUp(svc),
      (svc) => this.onMasterDown(svc),
      this.groupName,
      (group) => this.seenGroups.set(group, Date.now())
    )
    this.browser.start()
    this.ttlTimer = setInterval(() => this.checkReachability(), REACHABILITY_CHECK_INTERVAL_MS)
  }

  private stopBrowsing(): void {
    if (this.ttlTimer) { clearInterval(this.ttlTimer); this.ttlTimer = null }
    if (this.browser) { this.browser.stop(); this.browser = null }
    this.masters.clear()
  }

  // One entry per master device, whichever path (mDNS or beacon) reported it.
  private masterKey(svc: SnapcastService): string {
    return svc.txt['master_uuid'] || svc.name
  }

  // Heartbeat from a master (or its "bye"). Feeds the same table as mDNS.
  private onBeacon(msg: BeaconMessage, ip: string): void {
    if (msg.uuid === this.deviceUuid) return
    this.seenGroups.set(msg.group, Date.now())
    if (msg.group !== (this.groupName ?? 'default')) return

    if (msg.type === 'bye') {
      if (this.masters.delete(msg.uuid)) {
        console.log(`[snapserver-monitor] Master gone (beacon bye): ${ip}`)
        this.onMasterChange?.(this.hasActiveMultiroomTarget())
      }
      return
    }

    this.onMasterUp({
      name: msg.group,
      ip,
      port: msg.port,
      txt: { group: msg.group, role: 'host', epoch: String(msg.epoch), master_uuid: msg.uuid },
    }, true)
  }

  private onMasterUp(svc: SnapcastService, fromBeacon = false): void {
    // Filter our own advertisement — we discover it too once browsing is always-on.
    if ((svc.txt['master_uuid'] ?? '') === this.deviceUuid) return

    const seenEpoch = parseInt(svc.txt['epoch'] ?? '0', 10)
    if (Number.isFinite(seenEpoch) && seenEpoch > this.highestSeenEpoch) {
      this.highestSeenEpoch = seenEpoch
    }

    const hadTarget = this.hasActiveMultiroomTarget()
    const key = this.masterKey(svc)
    const existing = this.masters.get(key)
    const known = existing !== undefined
    this.masters.set(key, {
      svc,
      // Optimistic reachable for a new master or a fresh mDNS announcement;
      // checkReachability() corrects it within 10s. A routine heartbeat must not override
      // what the port probe found, or reachability would flap every beacon.
      reachable: fromBeacon && existing ? existing.reachable : true,
      lastBeacon: fromBeacon ? Date.now() : (existing?.lastBeacon ?? 0),
    })
    if (fromBeacon && existing && !existing.lastBeacon) {
      console.log(`[snapserver-monitor] Heartbeat established from master ${svc.ip}`)
    }
    if (!known) {
      console.log(`[snapserver-monitor] Master discovered${fromBeacon ? ' (beacon)' : ''}: ${svc.name} @ ${svc.ip} (uuid=${svc.txt['master_uuid'] ?? '?'} epoch=${svc.txt['epoch'] ?? '?'})`)
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
        return
      }
    }

    if (!hadTarget && this.hasActiveMultiroomTarget()) {
      this.onMasterChange?.(true)
    }
  }

  private onMasterDown(svc: SnapcastService): void {
    const key = this.masterKey(svc)
    const tracked = this.masters.get(key)
    // The heartbeat outranks an mDNS goodbye: if this master beaconed recently it is still
    // sourcing (the goodbye is an mDNS rename/flap). A real stop sends a beacon "bye" too.
    if (tracked && tracked.lastBeacon && Date.now() - tracked.lastBeacon < BEACON_INTERVAL_MS * 2) {
      return
    }
    if (this.masters.delete(key)) {
      console.log(`[snapserver-monitor] Master gone (goodbye): ${svc.name} @ ${svc.ip}`)
      this.onMasterChange?.(this.hasActiveMultiroomTarget())
    }
  }

  // Probe each known master's snapserver port and update reachability. We never delete here:
  // real disappearance arrives as an avahi 'down' event (onMasterDown). This only flips a
  // wedged/restarting master out of and back into selection as its port stops/starts
  // answering, so recovery needs no fresh mDNS announcement.
  private async checkReachability(): Promise<void> {
    let changed = false
    for (const [key, m] of [...this.masters.entries()]) {
      // A master that was sending heartbeats and stopped is gone, even if we never received
      // its goodbye and its snapserver port still answers (snapserver stays up when idle).
      if (m.lastBeacon && Date.now() - m.lastBeacon > BEACON_TIMEOUT_MS) {
        if (this.masters.delete(key)) {
          console.log(`[snapserver-monitor] Master gone (heartbeat lost): ${m.svc.ip}`)
          changed = true
        }
        continue
      }
      const alive = await this.probe(m.svc.ip, SNAPCAST_TCP_PORT)
      // Re-read after the await: a heartbeat may have replaced this entry while we probed.
      const current = this.masters.get(key)
      if (!current) continue
      if (alive !== current.reachable) {
        console.log(`[snapserver-monitor] Master ${current.svc.ip} ${alive ? 'reachable' : 'unreachable'}`)
        changed = true
      }
      current.reachable = alive
    }
    if (changed) {
      this.onMasterChange?.(this.hasActiveMultiroomTarget())
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

  // --- Polling (only while sourcing: syncs group volume on new clients) ---

  private startPolling(): void {
    if (this.pollInterval) return
    this.poll()
    this.pollInterval = setInterval(() => this.poll(), POLL_INTERVAL_MS)
  }

  private stopPolling(): void {
    if (this.pollInterval) { clearInterval(this.pollInterval); this.pollInterval = null }
    this.lastClientCount = 0
  }

  private async poll(): Promise<void> {
    try {
      const status = await this.fetchServerStatus('localhost')
      const groups: Array<{ id?: string; clients?: Array<{ connected?: boolean }> }> =
        status?.server?.groups ?? []
      const connectedCount = groups.reduce(
        (acc, g) => acc + (g?.clients?.filter(c => c?.connected !== false).length ?? 0),
        0
      )
      if (!this.serverWasUp || connectedCount > this.lastClientCount) {
        this.setGroupVolume(this.groupVolume).catch(() => {})
      }
      this.lastClientCount = connectedCount
      this.serverWasUp = true
    } catch {
      if (this.serverWasUp) {
        this.serverWasUp = false
        this.lastClientCount = 0
        console.log('[snapserver-monitor] Snapserver status unavailable')
      }
    }
  }

  private async fetchServerStatus(host = 'localhost'): Promise<any> {
    return this.rpcCall(host, 'Server.GetStatus', undefined, 1)
  }

  // Execute a single JSON-RPC 2.0 request against Snapserver (:1780/jsonrpc).
  // Uses a dedicated one-shot keep-alive agent per call because Snapserver 0.35's Beast HTTP
  // server triggers Node 24 llhttp "Data after Connection: close" when sent Connection: close,
  // and drops sequential pipelined requests on reused sockets.
  private rpcCall(host: string, method: string, params?: Record<string, unknown>, id = 1): Promise<any> {
    return new Promise((resolve, reject) => {
      const payload = JSON.stringify({ id, jsonrpc: '2.0', method, ...(params ? { params } : {}) })
      const agent = new http.Agent({ keepAlive: true })
      const req = http.request({
        host,
        port: RPC_PORT,
        path: '/jsonrpc',
        method: 'POST',
        agent,
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(payload),
          'Connection': 'keep-alive',
        },
        timeout: 3000,
      }, (res) => {
        let data = ''
        res.on('data', chunk => { data += chunk })
        res.on('end', () => {
          agent.destroy()
          try {
            const parsed = JSON.parse(data)
            if (parsed?.error) {
              reject(new Error(parsed.error.message ?? JSON.stringify(parsed.error)))
            } else {
              resolve(parsed?.result)
            }
          } catch (err) {
            reject(err)
          }
        })
      })
      req.on('error', (err) => { agent.destroy(); reject(err) })
      req.on('timeout', () => { req.destroy(); agent.destroy(); reject(new Error('Snapserver RPC timeout')) })
      req.write(payload)
      req.end()
    })
  }
}
