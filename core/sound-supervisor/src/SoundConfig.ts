import { getIPAddress } from './utils'
import { MultiroomRole, SoundModes } from './types'
import { constants } from './constants'
import { startBalenaService, stopBalenaService } from './utils'

interface DeviceConfig {
  ip: string
  type: string
}

export default class SoundConfig {
  public role: MultiroomRole = constants.role
  public groupName: string | undefined = constants.groupName
  public device: DeviceConfig = {
    ip: getIPAddress() ?? 'localhost',
    type: constants.balenaDeviceType
  }
  // Transient source-master state (role=auto). HOST is always sourcing; JOIN/DISABLED never.
  // sourcing → we are the group master (advertising, pacat running).
  // solo     → we lost the UUID tiebreak but have a local source, so we play locally
  //            (input→output direct) without advertising or joining anyone.
  // Both transitions are in-place: the multiroom containers stay running and react to the
  // /multiroom/active + /multiroom/master endpoints. Nothing here restarts a container.
  private sourcing = false
  private solo = false
  private readonly sourcePlugins = ['airplay', 'librespot', 'bluetooth', 'karaoke', 'karaoke-fetcher']

  private safeService(fn: (s: string) => Promise<unknown>, service: string, attempt = 1): void {
    fn(service).catch((err: unknown) => {
      const status = (err as { response?: { status?: number } })?.response?.status
      if (status === 423 && attempt <= 3) {
        const delay = attempt * 2000
        console.log(`Service call locked [${service}] (423), retrying in ${delay}ms (attempt ${attempt}/3)`)
        setTimeout(() => this.safeService(fn, service, attempt + 1), delay)
      } else {
        console.log(`Service call failed [${service}]: ${(err as Error).message}`)
      }
    })
  }

  private startSourcePlugins(): void {
    this.sourcePlugins.forEach((service) => this.safeService(startBalenaService, service))
  }

  private stopSourcePlugins(): void {
    this.sourcePlugins.forEach((service) => this.safeService(stopBalenaService, service))
  }

  private applyRoleServices(): void {
    switch (this.role) {
      case MultiroomRole.HOST:
        // HOST is always master — start everything including server immediately.
        this.safeService(startBalenaService, 'multiroom-server')
        this.safeService(startBalenaService, 'multiroom-client')
        this.startSourcePlugins()
        break
      case MultiroomRole.AUTO:
        // Pre-warm both multiroom containers so they're ready when play fires.
        // Each polls GET /multiroom/active and only starts its main process
        // (pacat / snapclient) once that endpoint returns true.
        this.safeService(startBalenaService, 'multiroom-server')
        this.safeService(startBalenaService, 'multiroom-client')
        this.startSourcePlugins()
        break
      case MultiroomRole.JOIN:
        // Invisible to streaming apps; only snapcast client runs.
        this.safeService(stopBalenaService, 'multiroom-server')
        this.stopSourcePlugins()
        this.safeService(startBalenaService, 'multiroom-client')
        break
      case MultiroomRole.DISABLED:
        // Standalone only; no multiroom participation.
        this.safeService(stopBalenaService, 'multiroom-server')
        this.safeService(stopBalenaService, 'multiroom-client')
        this.startSourcePlugins()
        break
    }
  }

  applyCurrentRole(): void {
    const group = this.groupName ? ` (group: ${this.groupName})` : ''
    console.log(`Applying role on startup: ${this.role}${group}`)
    this.applyRoleServices()
  }

  // --- Transient source-master transitions (all in-place, no container restarts) ---

  // We started a local source AND won (or are unopposed): become the group master.
  // The pre-warmed multiroom-server starts pacat once /multiroom/active flips true;
  // the multiroom-client watchdog retargets snapclient to our own snapserver in place.
  promoteToSourcing(): void {
    this.sourcing = true
    this.solo = false
    console.log('[state] → SOURCING (group master)')
  }

  // Stop sourcing (30s idle, or superseded by a lower-UUID master with no local source).
  // /multiroom/active flips false → server stops pacat in place, advertisement is pulled.
  demoteFromSourcing(): void {
    this.sourcing = false
    console.log('[state] → not sourcing')
  }

  // We have a local source but lost the UUID tiebreak: play locally, do not advertise,
  // do not join. The orchestrator reroutes input→output direct for this state.
  enterSolo(): void {
    this.sourcing = false
    this.solo = true
    console.log('[state] → SOLO (local source, lost tiebreak)')
  }

  exitSolo(): void {
    this.solo = false
    console.log('[state] → leaving SOLO')
  }

  isSolo(): boolean {
    return this.solo
  }

  // Drives /multiroom/active (server pacat + advertisement). SOLO is NOT master.
  isElectedMaster(): boolean {
    if (this.role === MultiroomRole.HOST) return true
    if (this.role === MultiroomRole.AUTO) return this.sourcing
    return false
  }

  setRole(role: MultiroomRole): boolean {
    if (!Object.values(MultiroomRole).includes(role)) {
      console.log(`Invalid role: ${role}`)
      return false
    }
    const changed = role !== this.role
    this.role = role
    if (changed) {
      this.applyRoleServices()
    }
    return changed
  }

  setGroupName(name: string): void {
    this.groupName = name || undefined
  }

  getMultiroomStatus() {
    return {
      role: this.role,
      groupName: this.groupName ?? null,
      deviceIp: this.device.ip
    }
  }

  /** @deprecated Use setRole(). Kept for /mode backward-compat. */
  setMode(mode: SoundModes): boolean {
    console.warn(`[DEPRECATED] POST /mode — use POST /multiroom/role instead`)
    const modeToRole: Record<string, MultiroomRole> = {
      [SoundModes.MULTI_ROOM]: MultiroomRole.AUTO,
      [SoundModes.MULTI_ROOM_CLIENT]: MultiroomRole.JOIN,
      [SoundModes.STANDALONE]: MultiroomRole.DISABLED,
    }
    const role = modeToRole[mode]
    if (!role) {
      console.log(`Unknown mode: ${mode}`)
      return false
    }
    return this.setRole(role)
  }
}
