import { browseSnapcast } from './AvahiBrowser'
import { MultiroomRole } from './types'

export type ElectedRole = 'master' | 'client'

const ELECTION_DEFAULT_GROUP = 'default'

// Deterministic jitter from UUID so the same device always races the same way.
// FNV-1a (32-bit): a plain XOR-of-char-codes collapses to <256 distinct values and
// collides constantly, so two devices booting together would often draw identical
// jitter and both promote to master (split brain). FNV-1a spreads UUIDs across the
// full range, making simultaneous-boot ties actually stagger.
function uuidJitterMs(uuid: string, maxMs: number): number {
  let hash = 0x811c9dc5
  for (let i = 0; i < uuid.length; i++) {
    hash ^= uuid.charCodeAt(i)
    hash = Math.imul(hash, 0x01000193)
  }
  return (hash >>> 0) % maxMs
}

function delay(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms))
}

/**
 * Run master election for AUTO role devices.
 *
 * HOST → always master (no contest).
 * JOIN / DISABLED → always client.
 * AUTO → browse mDNS for an existing server in the group.
 *   First browse (4s): immediate check.
 *   If no server: wait UUID-based jitter (0–2s), browse again (3s) to resolve simultaneous-boot races.
 *   If still no server: become master.
 */
export async function electMaster(
  role: MultiroomRole,
  groupName: string | undefined,
  deviceUuid: string
): Promise<ElectedRole> {
  if (role === MultiroomRole.HOST) {
    console.log('[election] role=host → master (unconditional)')
    return 'master'
  }

  if (role === MultiroomRole.JOIN || role === MultiroomRole.DISABLED) {
    console.log(`[election] role=${role} → client (no election)`)
    return 'client'
  }

  // AUTO: elect based on who already advertises for this group
  const group = groupName ?? ELECTION_DEFAULT_GROUP

  console.log(`[election] role=auto group="${group}" — browsing for existing server...`)
  const first = await browseSnapcast(group, 4000)
  if (first.length > 0) {
    console.log(`[election] Existing server at ${first[0].ip} → client`)
    return 'client'
  }

  // No server found — wait UUID-based jitter before confirming to break ties
  // when multiple devices boot simultaneously.
  const jitter = uuidJitterMs(deviceUuid, 2000)
  console.log(`[election] No server found. Waiting ${jitter}ms (UUID jitter)...`)
  await delay(jitter)

  const second = await browseSnapcast(group, 3000)
  if (second.length > 0) {
    console.log(`[election] After jitter: server at ${second[0].ip} appeared → client`)
    return 'client'
  }

  console.log('[election] No server in group — becoming master')
  return 'master'
}
