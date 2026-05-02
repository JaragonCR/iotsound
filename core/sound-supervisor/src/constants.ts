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

export const constants = {
  debug: process.env.SOUND_SUPERVISOR_DEBUG ? true : false,
  port: checkInt(process.env.SOUND_SUPERVISOR_PORT) ?? 80,
  role: resolveRole(),
  groupName: process.env.SOUND_GROUP_NAME,
  groupLatency: Math.min(checkInt(process.env.SOUND_GROUP_LATENCY) ?? 750, 1000),
  hwLatency: Math.min(checkInt(process.env.SOUND_DEVICE_HW_LATENCY) ?? 0, 200),
  balenaDeviceType: deviceType,
  volume: checkInt(process.env.SOUND_VOLUME) ?? 75,
  inputSink: process.env.SOUND_INPUT_SINK ?? 'balena-sound.input',
  multiroomBufferMs: Math.max(50, Math.min(checkInt(process.env.SOUND_MULTIROOM_BUFFER_MS) ?? 400, 2000)),
  multiroomMaster: process.env.SOUND_MULTIROOM_MASTER
}
