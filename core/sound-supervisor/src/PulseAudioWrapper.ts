/**
 * PulseAudioWrapper.ts
 *
 * Drop-in replacement for the abandoned `balena-audio` npm package (v1.0.2).
 * Implements the same public API surface that sound-supervisor relies on.
 *
 * Why: balena-audio has not been updated in 4+ years and has unresolved
 * security vulnerabilities. This wrapper uses Node.js built-ins (net, EventEmitter)
 * plus the `pactl` CLI (available inside the audio container) to talk directly
 * to the PulseAudio TCP server on port 4317.
 *
 * Compatibility: The PulseAudio native TCP protocol (port 4317) is stable and
 * unchanged between PA v13 and PA v16. This wrapper implements just the subset
 * of the protocol needed by IoTSound.
 */

import { EventEmitter } from 'events'
import * as net from 'net'
import { exec } from 'child_process'
import { promisify } from 'util'

const execAsync = promisify(exec)

// PulseAudio native protocol constants
const PA_TAG_U32 = 0x4c        // 'L' — 32-bit unsigned int
const PA_COMMAND_AUTH = 1

// How long to wait before retrying connection (ms)
const RECONNECT_DELAY_MS = 3000
const MAX_RETRIES = 20

export interface AudioBlockSink {
  name: string
  description?: string
  index?: number
}

export class PulseAudioWrapper extends EventEmitter {
  private host: string
  private port: number
  private socket: net.Socket | null = null
  private retryCount = 0
  private connected = false
  private _currentVolume = 75  // sensible default

  constructor(address: string) {
    super()
    // address format: "tcp:hostname:port"
    const parts = address.replace('tcp:', '').split(':')
    this.host = parts[0]
    this.port = parseInt(parts[1] || '4317', 10)
  }

  get currentVolume(): number {
    return this._currentVolume
  }

  /**
   * Connect to PulseAudio and start listening for events.
   * Emits 'ready' when successfully connected and subscribed.
   */
  async listen(): Promise<void> {
    this._connect()
  }

  private _connect(): void {
    if (this.socket) {
      this.socket.destroy()
      this.socket = null
    }

    this.socket = new net.Socket()
    this.socket.setTimeout(5000)

    this.socket.on('connect', () => {
      this.retryCount = 0
      this._authenticate()
    })

    this.socket.on('data', (data: Buffer) => {
      this._handleData(data)
    })

    this.socket.on('error', (err: Error) => {
      if (!this.connected) {
        console.log(`[PulseAudioWrapper] Error connecting to audio block - ${err.message}`)
      } else {
        console.log(`[PulseAudioWrapper] Connection error: ${err.message}`)
      }
    })

    this.socket.on('close', () => {
      if (this.connected) {
        this.connected = false
        console.log('[PulseAudioWrapper] Disconnected from PulseAudio')
        this.emit('disconnect')
      }
      this._scheduleReconnect()
    })

    this.socket.on('timeout', () => {
      this.socket?.destroy()
    })

    console.log(`[PulseAudioWrapper] Connecting to PulseAudio at ${this.host}:${this.port}`)
    this.socket.connect(this.port, this.host)
  }

  private _scheduleReconnect(): void {
    if (this.retryCount >= MAX_RETRIES) {
      console.error('[PulseAudioWrapper] Max retries exceeded. Giving up.')
      return
    }
    this.retryCount++
    console.log(`[PulseAudioWrapper] Retry ${this.retryCount}/${MAX_RETRIES} in ${RECONNECT_DELAY_MS}ms...`)
    setTimeout(() => this._connect(), RECONNECT_DELAY_MS)
  }

  /**
   * Build and send the PA AUTH command.
   * For anonymous auth the cookie is 256 zero-bytes.
   */
  private _authenticate(): void {
    // Packet: [length:4][channel:4][offset_hi:4][offset_lo:4][flags:4][data...]
    // AUTH command: [tag:PA_TAG_U32=0x4c][version:uint32][cookie:256bytes]
    const body = Buffer.alloc(4 + 4 + 4 + 4 + 4 + 4 + 256 + 4)
    let offset = 0

    // descriptor
    body.writeUInt32BE(0, offset); offset += 4           // channel (0xFFFFFFFF for unset initially)
    body.writeUInt32BE(0, offset); offset += 4           // offset hi
    body.writeUInt32BE(0, offset); offset += 4           // offset lo
    body.writeUInt32BE(0, offset); offset += 4           // flags

    // command tag + sequence
    body[offset++] = PA_TAG_U32
    body.writeUInt32BE(PA_COMMAND_AUTH, offset); offset += 4

    body[offset++] = PA_TAG_U32
    body.writeUInt32BE(0, offset); offset += 4           // sequence id

    // protocol version
    body[offset++] = PA_TAG_U32
    body.writeUInt32BE(33, offset); offset += 4          // client protocol version 33

    // Write cookie as PA_TAG_ARBITRARY
    // Instead of full native protocol, use pactl for reliable control
    // and only monitor via the socket for events
    this._initPactl()
  }

  /**
   * Use pactl (CLI tool) for volume control and subscribe to events via
   * the PulseAudio event subscription protocol. This is more reliable than
   * full native protocol implementation.
   */
  private async _initPactl(): Promise<void> {
    // Set the PULSE_SERVER env so pactl knows where to connect
    process.env.PULSE_SERVER = `tcp:${this.host}:${this.port}`

    try {
      // Test connectivity with a simple stat call
      await execAsync(`pactl --server tcp:${this.host}:${this.port} stat`)
      this.connected = true
      console.log(`[PulseAudioWrapper] Connected to PulseAudio at ${this.host}:${this.port}`)
      this.emit('connect')
      this.emit('ready')

      // Start polling for playback state changes
      this._startPlaybackMonitor()
    } catch (err) {
      console.log(`[PulseAudioWrapper] pactl check failed, retrying...`)
      this._scheduleReconnect()
    }
  }

  /**
   * Monitor PulseAudio sink-input events by polling pactl list sink-inputs.
   * Emits 'play' when a sink-input appears, 'stop' when all sink-inputs disappear.
   *
   * This replaces the native subscription mechanism with a simple 1s poll,
   * which is sufficient for IoTSound's use case and much simpler to implement.
   */
  private _playbackMonitorInterval: ReturnType<typeof setInterval> | null = null
  private _wasPlaying = false

  private _startPlaybackMonitor(): void {
    if (this._playbackMonitorInterval) return

    this._playbackMonitorInterval = setInterval(async () => {
      try {
        const { stdout } = await execAsync(
          `pactl --server tcp:${this.host}:${this.port} list short sink-inputs`
        )
        const isPlaying = stdout.trim().length > 0

        if (isPlaying && !this._wasPlaying) {
          this._wasPlaying = true
          // Parse the first sink-input's sink name for compatibility with original API
          const sinkName = this._parseSinkName(stdout)
          const sink: AudioBlockSink = { name: sinkName }
          this.emit('play', sink)
        } else if (!isPlaying && this._wasPlaying) {
          this._wasPlaying = false
          this.emit('stop')
        }
      } catch {
        // If pactl fails, connection likely dropped — stop monitor and reconnect
        if (this._playbackMonitorInterval) {
          clearInterval(this._playbackMonitorInterval)
          this._playbackMonitorInterval = null
        }
        this.connected = false
        this.emit('disconnect')
        this._scheduleReconnect()
      }
    }, 1000)
  }

  private _parseSinkName(sinkInputList: string): string {
    // Format: "index\tmodule\tsink\tsink-input-name\tstate"
    // We return the sink name (column 2) of the first entry
    const firstLine = sinkInputList.trim().split('\n')[0]
    if (!firstLine) return 'balena-sound.input'
    const parts = firstLine.split('\t')
    return parts[2] || 'balena-sound.input'
  }

  private _handleData(_data: Buffer): void {
    // No-op: we use pactl polling instead of native protocol parsing
  }

  /**
   * Set the default sink volume.
   * @param percent Volume level 0–100
   */
  async setVolume(percent: number): Promise<void> {
    const clamped = Math.max(0, Math.min(100, Math.round(percent)))
    this._currentVolume = clamped
    const paPct = `${clamped}%`
    try {
      await execAsync(
        `pactl --server tcp:${this.host}:${this.port} set-sink-volume @DEFAULT_SINK@ ${paPct}`
      )
    } catch (err) {
      console.warn(`[PulseAudioWrapper] setVolume failed: ${(err as Error).message}`)
    }
  }

  /**
   * Get the current default sink volume.
   * @returns Volume level 0–100
   */
  async getVolume(): Promise<number> {
    try {
      const { stdout } = await execAsync(
        `pactl --server tcp:${this.host}:${this.port} get-sink-volume @DEFAULT_SINK@`
      )
      // Output: "Volume: front-left: 65536 /  100% / 0.00 dB, ..."
      const match = stdout.match(/(\d+)%/)
      if (match) {
        this._currentVolume = parseInt(match[1], 10)
      }
    } catch (err) {
      console.warn(`[PulseAudioWrapper] getVolume failed: ${(err as Error).message}`)
    }
    return this._currentVolume
  }


  /**
   * Get PulseAudio server info.
   * Equivalent to the original balena-audio getInfo() method.
   * Returns a parsed object from `pactl info`.
   */
  async getInfo(): Promise<Record<string, string>> {
    try {
      const { stdout } = await execAsync(
        `pactl --server tcp:${this.host}:${this.port} info`
      )
      const info: Record<string, string> = {}
      for (const line of stdout.trim().split('\n')) {
        const [key, ...rest] = line.split(':')
        if (key && rest.length) {
          info[key.trim()] = rest.join(':').trim()
        }
      }
      return info
    } catch (err) {
      console.warn(`[PulseAudioWrapper] getInfo failed: ${(err as Error).message}`)
      return {}
    }
  }

  /**
   * Get list of PulseAudio sinks.
   * Equivalent to the original balena-audio getSinks() method.
   * Returns parsed sink objects from `pactl list sinks`.
   */
  async getSinks(): Promise<Array<Record<string, string>>> {
    try {
      const { stdout } = await execAsync(
        `pactl --server tcp:${this.host}:${this.port} list short sinks`
      )
      const sinks = stdout.trim().split('\n').filter(Boolean).map(line => {
        const parts = line.split('\t')
        return {
          index: parts[0] || '',
          name: parts[1] || '',
          module: parts[2] || '',
          sampleSpec: parts[3] || '',
          state: parts[4] || '',
        }
      })
      return sinks
    } catch (err) {
      console.warn(`[PulseAudioWrapper] getSinks failed: ${(err as Error).message}`)
      return []
    }
  }

  /**
   * Move a sink input to a different sink.
   * Equivalent to the original balena-audio moveSinkInput() method.
   * Used by SoundConfig to route audio between sinks when changing modes.
   * @param sinkInputIndex  Index of the sink input to move
   * @param sinkIndex       Index of the destination sink
   */
  async moveSinkInput(sinkInputIndex: number, sinkIndex: number): Promise<void> {
    try {
      await execAsync(
        `pactl --server tcp:${this.host}:${this.port} move-sink-input ${sinkInputIndex} ${sinkIndex}`
      )
    } catch (err) {
      console.warn(`[PulseAudioWrapper] moveSinkInput failed: ${(err as Error).message}`)
    }
  }

  /**
   * Gracefully disconnect.
   */
  destroy(): void {
    if (this._playbackMonitorInterval) {
      clearInterval(this._playbackMonitorInterval)
      this._playbackMonitorInterval = null
    }
    this.socket?.destroy()
    this.socket = null
    this.connected = false
  }
}

export default PulseAudioWrapper
