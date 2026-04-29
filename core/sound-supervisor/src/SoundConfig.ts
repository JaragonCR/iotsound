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
  private safeService(fn: (s: string) => Promise<unknown>, service: string): void {
    fn(service).catch((err: Error) => console.log(`Service call failed [${service}]: ${err.message}`))
  }

  private applyRoleServices(): void {
    switch (this.role) {
      case MultiroomRole.AUTO:
      case MultiroomRole.HOST:
        // All plugins run; Avahi + WirePlumber decide who becomes server
        this.safeService(startBalenaService, 'multiroom-server')
        this.safeService(startBalenaService, 'multiroom-client')
        this.safeService(startBalenaService, 'airplay')
        this.safeService(startBalenaService, 'librespot')
        this.safeService(startBalenaService, 'bluetooth')
        break
      case MultiroomRole.JOIN:
        // Invisible to streaming apps; only snapcast client runs
        this.safeService(stopBalenaService, 'multiroom-server')
        this.safeService(stopBalenaService, 'airplay')
        this.safeService(stopBalenaService, 'librespot')
        this.safeService(stopBalenaService, 'bluetooth')
        this.safeService(startBalenaService, 'multiroom-client')
        break
      case MultiroomRole.DISABLED:
        // Standalone only; no multiroom participation
        this.safeService(stopBalenaService, 'multiroom-server')
        this.safeService(stopBalenaService, 'multiroom-client')
        this.safeService(startBalenaService, 'airplay')
        this.safeService(startBalenaService, 'librespot')
        this.safeService(startBalenaService, 'bluetooth')
        break
    }
  }

  applyCurrentRole(): void {
    const group = this.groupName ? ` (group: ${this.groupName})` : ''
    console.log(`Applying role on startup: ${this.role}${group}`)
    this.applyRoleServices()
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
      deviceIp: this.device.ip,
      groupLatency: constants.groupLatency,
      hwLatency: constants.hwLatency
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
