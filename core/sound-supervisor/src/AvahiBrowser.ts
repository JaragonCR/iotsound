import { exec } from 'child_process'

export interface SnapcastService {
  name: string
  ip: string
  port: number
  txt: Record<string, string>
}

function parseTxt(raw: string): Record<string, string> {
  const result: Record<string, string> = {}
  for (const m of (raw.match(/"([^"]+)"/g) ?? [])) {
    const kv = m.slice(1, -1)
    const eq = kv.indexOf('=')
    if (eq > 0) result[kv.slice(0, eq)] = kv.slice(eq + 1)
  }
  return result
}

// Browse for _snapcast._tcp services on the local network.
// Uses --terminate so avahi-browse exits once the initial cache is populated (~1-3s).
// Returns resolved entries only (lines starting with '=').
export function browseSnapcast(timeoutMs = 8000): Promise<SnapcastService[]> {
  return new Promise((resolve) => {
    exec('avahi-browse -rpt _snapcast._tcp --terminate', { timeout: timeoutMs }, (err, stdout) => {
      if (err && !stdout) { resolve([]); return }
      const services: SnapcastService[] = []
      for (const line of stdout.split('\n')) {
        // Parseable resolved format: =;iface;proto;name;type;domain;host;addrproto;ip;port;txt
        const parts = line.split(';')
        if (parts[0] !== '=') continue
        const ip = parts[8]
        const port = parseInt(parts[9] ?? '0')
        const txt = parseTxt(parts[10] ?? '')
        const name = parts[3] ?? ''
        if (ip && port) services.push({ name, ip, port, txt })
      }
      console.log(`[avahi-browse] Found ${services.length} snapcast service(s)`)
      resolve(services)
    })
  })
}
