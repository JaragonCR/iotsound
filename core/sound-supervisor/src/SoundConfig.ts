import { getIPAddress } from './utils'
import { SoundModes } from "./types"
import { constants } from './constants'
import { startBalenaService, stopBalenaService, restartBalenaService } from './utils'
import PulseAudioWrapper from './PulseAudioWrapper'

interface MultiRoomConfig {
  master: string,
  forced: boolean
}

interface DeviceConfig {
  ip: string,
  type: string
}

export default class SoundConfig {
  public mode: SoundModes = constants.mode
  public device: DeviceConfig = {
    ip: getIPAddress() ?? 'localhost',
    type: constants.balenaDeviceType
  }
  public multiroom: MultiRoomConfig = {
    master: constants.multiroom.master ?? this.device.ip,
    forced: constants.multiroom.forced
  }
  private audioBlock: PulseAudioWrapper

  bindAudioBlock(audioBlock: PulseAudioWrapper) {
    this.audioBlock = audioBlock
  }

  setMultiRoomMaster(master: string) {
    this.multiroom.master = master
    this.safeService(restartBalenaService, 'multiroom-client')
  }

  private safeService(fn: (s: string) => Promise<void>, service: string): void {
    fn(service).catch((err: Error) => console.log(`Service call failed [${service}]: ${err.message}`))
  }

  setMode(mode: SoundModes): boolean {
    let oldMode: SoundModes = this.mode
    let modeUpdated: boolean = mode !== oldMode

    if (mode && Object.values(SoundModes).includes(mode)) {
      this.mode = SoundModes[mode]

      if (modeUpdated) {
        switch (this.mode) {
          case SoundModes.MULTI_ROOM:
            this.safeService(startBalenaService, 'multiroom-server')
            this.safeService(startBalenaService, 'multiroom-client')
            this.safeService(startBalenaService, 'airplay')
            this.safeService(startBalenaService, 'spotify')
            this.safeService(startBalenaService, 'upnp')
            this.safeService(startBalenaService, 'bluetooth')
            this.audioBlock.moveSinkInputByName('balena-sound.input', 'snapcast')
            break
          case SoundModes.MULTI_ROOM_CLIENT:
            this.safeService(stopBalenaService, 'multiroom-server')
            this.safeService(stopBalenaService, 'airplay')
            this.safeService(stopBalenaService, 'spotify')
            this.safeService(stopBalenaService, 'upnp')
            this.safeService(stopBalenaService, 'bluetooth')
            this.safeService(startBalenaService, 'multiroom-client')
            break
          case SoundModes.STANDALONE:
            this.safeService(stopBalenaService, 'multiroom-server')
            this.safeService(stopBalenaService, 'multiroom-client')
            this.safeService(startBalenaService, 'airplay')
            this.safeService(startBalenaService, 'spotify')
            this.safeService(startBalenaService, 'upnp')
            this.safeService(startBalenaService, 'bluetooth')
            this.audioBlock.moveSinkInputByName('balena-sound.input', 'balena-sound.output')
            break
          default:
            break
        }
      }
    } else {
      console.log(`Error setting mode, invalid mode: ${mode}`)
    }

    return modeUpdated
  }

  isMultiRoomEnabled(): boolean {
    let mrModes: SoundModes[] = [SoundModes.MULTI_ROOM, SoundModes.MULTI_ROOM_CLIENT]
    return mrModes.includes(this.mode)
  }

  isMultiRoomServer(): boolean {
    let mrModes: SoundModes[] = [SoundModes.MULTI_ROOM]
    return mrModes.includes(this.mode)
  }

  isMultiRoomMaster(): boolean {
    return this.isMultiRoomServer() && this.device.ip === this.multiroom.master
  }

  isNewMultiRoomMaster(master: string): boolean {
    return this.isMultiRoomEnabled() && this.multiroom.master !== master
  }

}