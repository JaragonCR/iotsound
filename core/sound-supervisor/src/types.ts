/** @deprecated Use MultiroomRole. Kept for SOUND_MODE migration mapping. */
export enum SoundModes {
  MULTI_ROOM = 'MULTI_ROOM',
  MULTI_ROOM_CLIENT = 'MULTI_ROOM_CLIENT',
  STANDALONE = 'STANDALONE'
}

export enum MultiroomRole {
  AUTO = 'auto',
  HOST = 'host',
  JOIN = 'join',
  DISABLED = 'disabled'
}