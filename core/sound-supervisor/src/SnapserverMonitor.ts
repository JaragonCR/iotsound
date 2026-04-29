import axios from 'axios'
import { restartBalenaService } from './utils'

const SNAPSERVER_URL = 'http://localhost:1780/jsonrpc'
const STANDALONE_BUFFER_MS = 50
const POLL_INTERVAL_MS = 5000
const RESTART_COOLDOWN_MS = 20000

export interface SnapserverBufferStatus {
  configured: number
  effective: number
  mode: 'standalone' | 'multiroom'
}

export default class SnapserverMonitor {
  private configuredBufferMs: number
  private effectiveBufferMs: number = STANDALONE_BUFFER_MS
  private previousRemoteCount: number = 0
  private cooldownUntil: number = 0
  private interval: NodeJS.Timeout | null = null

  constructor(configuredBufferMs: number) {
    this.configuredBufferMs = configuredBufferMs
  }

  getStatus(): SnapserverBufferStatus {
    return {
      configured: this.configuredBufferMs,
      effective: this.effectiveBufferMs,
      mode: this.effectiveBufferMs === STANDALONE_BUFFER_MS ? 'standalone' : 'multiroom',
    }
  }

  setConfiguredBuffer(ms: number): void {
    this.configuredBufferMs = Math.max(50, Math.min(ms, 2000))
    // If already in multi-room mode, apply the new buffer immediately
    if (this.previousRemoteCount > 0) {
      this.effectiveBufferMs = this.configuredBufferMs
      this.triggerRestart('multiroom')
    }
  }

  start(): void {
    this.interval = setInterval(() => this.poll(), POLL_INTERVAL_MS)
  }

  stop(): void {
    if (this.interval) {
      clearInterval(this.interval)
      this.interval = null
    }
  }

  private async poll(): Promise<void> {
    if (Date.now() < this.cooldownUntil) return

    try {
      const status = await this.fetchServerStatus()
      const allClients: any[] = status.server.groups.flatMap((g: any) => g.clients)
      const connectedCount = allClients.filter((c: any) => c.connected).length
      // One local snapclient is always connected; everything beyond that is remote
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
      // snapserver not reachable yet — normal at startup or after restart
    }
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
    // After the restart, local snapclient reconnects first. Set previousRemoteCount
    // to the expected post-restart value so the first poll after cooldown doesn't
    // fire a spurious transition.
    this.previousRemoteCount = targetMode === 'multiroom' ? 1 : 0
    this.cooldownUntil = Date.now() + RESTART_COOLDOWN_MS
    restartBalenaService('multiroom-server').catch((err: Error) =>
      console.log(`[snapserver-monitor] Failed to restart multiroom-server: ${err.message}`)
    )
  }
}
