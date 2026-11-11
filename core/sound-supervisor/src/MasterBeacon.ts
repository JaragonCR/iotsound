import * as dgram from 'dgram'

// Master heartbeat ("push" side of discovery).
//
// mDNS only announces a new service with a short burst of unsolicited packets, then waits to
// be asked; a long-running browser asks less and less often. A speaker that drops that burst
// (WiFi multicast is lossy) may not learn about the master for minutes, and one that drops
// the goodbye keeps a stale master. Avahi cannot re-announce without withdrawing the record
// first, which would make every listener see the master disappear.
//
// So the sourcing master also broadcasts one small UDP datagram every BEACON_INTERVAL_MS, and
// a "bye" when it stops. Cost is one packet per interval regardless of how many speakers are
// idle. Listeners feed beacons into the same master table mDNS feeds, so either path is
// enough on its own.
export const BEACON_PORT = parseInt(process.env.SOUND_MULTIROOM_BEACON_PORT ?? '1706', 10)
export const BEACON_INTERVAL_MS = 10_000
const BROADCAST_ADDR = '255.255.255.255'

export interface BeaconMessage {
  v: 1
  type: 'master' | 'bye'
  group: string
  uuid: string
  epoch: number
  port: number
}

export default class MasterBeacon {
  private socket: dgram.Socket | null = null
  private timer: NodeJS.Timeout | null = null
  private build: (() => Omit<BeaconMessage, 'v' | 'type'>) | null = null
  private closed = false

  constructor(private readonly onMessage: (msg: BeaconMessage, ip: string) => void) {}

  // Bind the shared port and start receiving. Safe to call more than once.
  listen(): void {
    if (this.socket || this.closed) return
    const sock = dgram.createSocket({ type: 'udp4', reuseAddr: true })
    this.socket = sock
    sock.on('error', (err) => {
      console.log(`[beacon] socket error: ${err.message} — retrying in 5s`)
      try { sock.close() } catch { /* already closed */ }
      if (this.socket === sock) this.socket = null
      setTimeout(() => this.listen(), 5000)
    })
    sock.on('message', (buf, rinfo) => {
      if (rinfo.family !== 'IPv4' || buf.length > 1024) return
      let msg: BeaconMessage
      try {
        msg = JSON.parse(buf.toString('utf8'))
      } catch {
        return
      }
      if (
        msg?.v !== 1 ||
        (msg.type !== 'master' && msg.type !== 'bye') ||
        typeof msg.group !== 'string' ||
        typeof msg.uuid !== 'string' || msg.uuid === '' ||
        typeof msg.epoch !== 'number' || !Number.isFinite(msg.epoch) ||
        typeof msg.port !== 'number'
      ) return
      this.onMessage(msg, rinfo.address)
    })
    sock.bind(BEACON_PORT, () => {
      try { sock.setBroadcast(true) } catch { /* not fatal: we can still receive */ }
      console.log(`[beacon] Listening for master heartbeats on udp/${BEACON_PORT}`)
    })
  }

  // Begin broadcasting as master. `build` is called per beacon so the content is never stale.
  start(build: () => Omit<BeaconMessage, 'v' | 'type'>): void {
    this.stopTimer()
    this.build = build
    this.send('master')
    this.timer = setInterval(() => this.send('master'), BEACON_INTERVAL_MS)
  }

  // Stop broadcasting and tell listeners right away (sent twice: UDP is lossy).
  stop(): void {
    this.stopTimer()
    if (!this.build) return
    const build = this.build
    this.build = null
    this.send('bye', build)
    setTimeout(() => this.send('bye', build), 300)
  }

  close(): void {
    this.closed = true
    this.stopTimer()
    this.build = null
    if (this.socket) {
      try { this.socket.close() } catch { /* already closed */ }
      this.socket = null
    }
  }

  private stopTimer(): void {
    if (this.timer) { clearInterval(this.timer); this.timer = null }
  }

  private send(type: BeaconMessage['type'], build = this.build): void {
    if (!this.socket || !build) return
    const payload = Buffer.from(JSON.stringify({ v: 1, type, ...build() }))
    this.socket.send(payload, BEACON_PORT, BROADCAST_ADDR, (err) => {
      if (err) console.log(`[beacon] send failed: ${err.message}`)
    })
  }
}
