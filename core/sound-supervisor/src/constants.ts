import { MultiroomRole, SoundModes } from './types'

function checkInt(s: string | undefined): number | undefined {
  return s ? parseInt(s) : undefined
}

function resolveRole(): MultiroomRole {
  const roleEnv = process.env.SOUND_MULTIROOM_ROLE?.toLowerCase()
  if (roleEnv && Object.values(MultiroomRole).includes(roleEnv as MultiroomRole)) {
    return roleEnv as MultiroomRole
  }
  // Migrate from SOUND_MODE
  const modeEnv = process.env.SOUND_MODE
  if (modeEnv) {
    console.warn(`[DEPRECATED] SOUND_MODE=${modeEnv} — set SOUND_MULTIROOM_ROLE instead`)
    switch (modeEnv) {
      case SoundModes.MULTI_ROOM: return MultiroomRole.AUTO
      case SoundModes.MULTI_ROOM_CLIENT: return MultiroomRole.JOIN
      case SoundModes.STANDALONE: return MultiroomRole.DISABLED
    }
  }
  return MultiroomRole.AUTO
}

const deviceType: string = process.env.BALENA_DEVICE_TYPE ?? 'unknown'
const logLevel = (process.env.SOUND_SUPERVISOR_LOG_LEVEL ?? process.env.LOG_LEVEL ?? 'info').toLowerCase()

export const constants = {
  debug: logLevel === 'debug',
  logLevel,
  port: checkInt(process.env.SOUND_SUPERVISOR_PORT) ?? 80,
  role: resolveRole(),
  groupName: process.env.SOUND_GROUP_NAME,
  balenaDeviceType: deviceType,
  volume: checkInt(process.env.SOUND_VOLUME) ?? 75,
  inputSink: process.env.SOUND_INPUT_SINK ?? 'balena-sound.input',
  multiroomMaster: process.env.SOUND_MULTIROOM_MASTER,
  // Extra fixed offset added to snapclient. 0 by default: with Option C, snapclient plays
  // straight to the hardware sink and PipeWire reports the real device latency, which
  // snapclient compensates — so no manual per-device offset is needed. Advanced override only.
  multiroomClientLatency: checkInt(process.env.SOUND_MULTIROOM_LATENCY) ?? 0
}
