/**
 * PulseAudioWrapper.ts
 *
 * Drop-in replacement for the abandoned `balena-audio` npm package (v1.0.2).
 * Implements the same public API surface that sound-supervisor relies on.
 *
 * Design: Uses pactl CLI exclusively via child_process. No persistent TCP
 * socket — pactl is stateless and opens/closes its own connection per command.
 * Connectivity is checked via a poll interval; events are emitted based on
 * changes in sink-input state.
 */

import { EventEmitter } from 'events'
import { exec } from 'child_process'
import { promisify } from 'util'

const execAsync = (cmd: string) => promisify(exec)(cmd, { timeout: 5000 })

const RECONNECT_DELAY_MS = 3000
const MAX_RETRIES = 20
const POLL_INTERVAL_MS = 1000

export interface AudioBlockSink {
  name: string
  description?: string
  index?: number
}

export class PulseAudioWrapper extends EventEmitter {
  private host: string
  private port: number
  private server: string
  private retryCount = 0
  private connected = false
  private _currentVolume = 75
  private _wasPlaying = false
  private _pollInterval: ReturnType<typeof setInterval> | null = null
  private _connectInterval: ReturnType<typeof setInterval> | null = null

  constructor(address: string) {
    super()
    // address format: "tcp:hostname:port"
    const parts = address.replace('tcp:', '').split(':')
    this.host = parts[0]
    this.port = parseInt(parts[1] || '4317', 10)
    this.server = `tcp:${this.host}:${this.port}`
  }

  get currentVolume(): number {
    return this._currentVolume
  }

  /**
   * Start connecting to PulseAudio and emit 'ready' when connected.
   */
  async listen(): Promise<void> {
    return new Promise((resolve) => {
      this.once('ready', resolve)
      this._scheduleConnect()
    })
  }

  // -------------------------------------------------------------------------
  // Connection management
  // -------------------------------------------------------------------------

  private _scheduleConnect(): void {
    // Poll until PulseAudio is up, then start monitoring
    this._connectInterval = setInterval(async () => {
      if (this.connected) return

      try {
        await execAsync(`pactl --server ${this.server} stat`)
        // Connected!
        if (this._connectInterval) {
          clearInterval(this._connectInterval)
          this._connectInterval = null
        }
        this.retryCount = 0
        this.connected = true
        console.log(`[PulseAudioWrapper] Connected to PulseAudio at ${this.host}:${this.port}`)
        this.emit('connect')
        this.emit('ready')
        this._startPollMonitor()
      } catch {
        this.retryCount++
        if (this.retryCount <= MAX_RETRIES) {
          console.log(`[PulseAudioWrapper] pactl check failed, retrying... (${this.retryCount}/${MAX_RETRIES})`)
        } else {
          console.error(`[PulseAudioWrapper] Max retries exceeded. Giving up.`)
          if (this._connectInterval) {
            clearInterval(this._connectInterval)
            this._connectInterval = null
          }
        }
      }
    }, RECONNECT_DELAY_MS)
  }

  private _startPollMonitor(): void {
    if (this._pollInterval) return

    this._pollInterval = setInterval(async () => {
      try {
        // Check connectivity first via a lightweight stat call
        await execAsync(`pactl --server ${this.server} stat`)

        // Check playback state
        const { stdout } = await execAsync(
          `pactl --server ${this.server} list short sink-inputs`
        )
        const isPlaying = stdout.trim().length > 0

        if (isPlaying && !this._wasPlaying) {
          this._wasPlaying = true
          const sinkName = this._parseSinkName(stdout)
          this.emit('play', { name: sinkName } as AudioBlockSink)
        } else if (!isPlaying && this._wasPlaying) {
          this._wasPlaying = false
          this.emit('stop')
        }
      } catch {
        // PulseAudio went away — mark disconnected and start reconnect loop
        if (this._pollInterval) {
          clearInterval(this._pollInterval)
          this._pollInterval = null
        }
        if (this.connected) {
          this.connected = false
          this._wasPlaying = false
          console.log('[PulseAudioWrapper] Disconnected from PulseAudio')
          this.emit('disconnect')
        }
        this.retryCount = 0
        this._scheduleConnect()
      }
    }, POLL_INTERVAL_MS)
  }

  private _parseSinkName(sinkInputList: string): string {
    const firstLine = sinkInputList.trim().split('\n')[0]
    if (!firstLine) return 'balena-sound.input'
    const parts = firstLine.split('\t')
    return parts[2] || 'balena-sound.input'
  }

  // -------------------------------------------------------------------------
  // Volume control
  // -------------------------------------------------------------------------

  private _quote(value: string): string {
    return `'${value.replace(/'/g, `'\\''`)}'`
  }

  private async _getVolumeTargetSinks(): Promise<string[]> {
    const sinks = await this.getSinks()
    const names = sinks.map((sink) => sink.name).filter(Boolean)
    const hardware = names.filter((name) =>
      name.startsWith('alsa_output.') && !name.includes('balena-sound') && name !== 'snapcast'
    )
    const targets = [
      ...hardware,
      ...names.filter((name) => name === 'balena-sound.output'),
    ]
    return targets.length > 0 ? targets : ['@DEFAULT_SINK@']
  }

  async setVolume(percent: number): Promise<void> {
    const clamped = Math.max(0, Math.min(100, Math.round(percent)))
    this._currentVolume = clamped
    const targets = await this._getVolumeTargetSinks()
    let applied = false

    for (const sink of targets) {
      const sinkRef = sink === '@DEFAULT_SINK@' ? sink : this._quote(sink)
      try {
        await execAsync(
          `pactl --server ${this.server} set-sink-volume ${sinkRef} ${clamped}%`
        )
        applied = true
      } catch (err) {
        console.warn(`[PulseAudioWrapper] setVolume failed for ${sink}: ${(err as Error).message}`)
      }
    }

    if (applied) return

    try {
      await execAsync(
        `pactl --server ${this.server} set-sink-volume @DEFAULT_SINK@ ${clamped}%`
      )
    } catch (err) {
      console.warn(`[PulseAudioWrapper] setVolume failed: ${(err as Error).message}`)
    }
  }

  async getVolume(): Promise<number> {
    const targets = await this._getVolumeTargetSinks()

    for (const sink of targets) {
      const sinkRef = sink === '@DEFAULT_SINK@' ? sink : this._quote(sink)
      try {
        const { stdout } = await execAsync(
          `pactl --server ${this.server} get-sink-volume ${sinkRef}`
        )
        const match = stdout.match(/(\d+)%/)
        if (match) {
          this._currentVolume = parseInt(match[1], 10)
          return this._currentVolume
        }
      } catch (err) {
        console.warn(`[PulseAudioWrapper] getVolume failed for ${sink}: ${(err as Error).message}`)
      }
    }

    try {
      const { stdout } = await execAsync(
        `pactl --server ${this.server} get-sink-volume @DEFAULT_SINK@`
      )
      const match = stdout.match(/(\d+)%/)
      if (match) {
        this._currentVolume = parseInt(match[1], 10)
      }
    } catch (err) {
      console.warn(`[PulseAudioWrapper] getVolume failed: ${(err as Error).message}`)
    }
    return this._currentVolume
  }

  // -------------------------------------------------------------------------
  // Sink info
  // -------------------------------------------------------------------------

  async getInfo(): Promise<Record<string, string>> {
    try {
      const { stdout } = await execAsync(
        `pactl --server ${this.server} info`
      )
      const info: Record<string, string> = {}
      for (const line of stdout.trim().split('\n')) {
        const colonIndex = line.indexOf(':')
        if (colonIndex > -1) {
          const key = line.substring(0, colonIndex).trim()
          const value = line.substring(colonIndex + 1).trim()
          info[key] = value
        }
      }
      return info
    } catch (err) {
      console.warn(`[PulseAudioWrapper] getInfo failed: ${(err as Error).message}`)
      return {}
    }
  }

  async getSinks(): Promise<Array<Record<string, string>>> {
    try {
      const { stdout } = await execAsync(
        `pactl --server ${this.server} list short sinks`
      )
      return stdout.trim().split('\n').filter(Boolean).map(line => {
        const parts = line.split('\t')
        return {
          index: parts[0] || '',
          name: parts[1] || '',
          module: parts[2] || '',
          sampleSpec: parts[3] || '',
          state: parts[4] || '',
        }
      })
    } catch (err) {
      console.warn(`[PulseAudioWrapper] getSinks failed: ${(err as Error).message}`)
      return []
    }
  }

  async moveSinkInput(sinkInputIndex: number, sinkIndex: number): Promise<void> {
    try {
      await execAsync(
        `pactl --server ${this.server} move-sink-input ${sinkInputIndex} ${sinkIndex}`
      )
    } catch (err) {
      console.warn(`[PulseAudioWrapper] moveSinkInput failed: ${(err as Error).message}`)
    }
  }

  async getSinkIndexByName(name: string): Promise<number | null> {
    const sinks = await this.getSinks()
    const found = sinks.find(s => s.name === name)
    return found ? parseInt(found.index, 10) : null
  }

  async getSinkInputIndexBySource(sourceName: string): Promise<number | null> {
    try {
      const { stdout } = await execAsync(`pactl --server ${this.server} list sink-inputs`)
      let currentIndex: number | null = null
      for (const line of stdout.split('\n')) {
        const indexMatch = line.match(/^Sink Input #(\d+)/)
        if (indexMatch) {
          currentIndex = parseInt(indexMatch[1], 10)
        }
        if (currentIndex !== null && line.includes(`Loopback from ${sourceName}`)) {
          return currentIndex
        }
      }
      console.warn(`[PulseAudioWrapper] getSinkInputIndexBySource: no sink-input found for source '${sourceName}'`)
      return null
    } catch (err) {
      console.warn(`[PulseAudioWrapper] getSinkInputIndexBySource failed: ${(err as Error).message}`)
      return null
    }
  }

  async moveSinkInputByName(sinkInputSourceName: string, targetSinkName: string): Promise<void> {
    const [sinkInputIndex, sinkIndex] = await Promise.all([
      this.getSinkInputIndexBySource(sinkInputSourceName),
      this.getSinkIndexByName(targetSinkName)
    ])
    if (sinkInputIndex === null) {
      console.warn(`[PulseAudioWrapper] moveSinkInputByName: sink-input for source '${sinkInputSourceName}' not found`)
      return
    }
    if (sinkIndex === null) {
      console.warn(`[PulseAudioWrapper] moveSinkInputByName: sink '${targetSinkName}' not found`)
      return
    }
    await this.moveSinkInput(sinkInputIndex, sinkIndex)
  }

  // -------------------------------------------------------------------------
  // Cleanup
  // -------------------------------------------------------------------------

  destroy(): void {
    if (this._pollInterval) {
      clearInterval(this._pollInterval)
      this._pollInterval = null
    }
    if (this._connectInterval) {
      clearInterval(this._connectInterval)
      this._connectInterval = null
    }
    this.connected = false
  }
}

export default PulseAudioWrapper
