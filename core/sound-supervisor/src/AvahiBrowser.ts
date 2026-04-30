import Bonjour from 'bonjour-service'
import type { Service } from 'bonjour-service'

export interface SnapcastService {
  name: string
  ip: string
  port: number
  txt: Record<string, string>
}

export function browseSnapcast(timeoutMs = 8000): Promise<SnapcastService[]> {
  return new Promise((resolve) => {
    const bonjour = new Bonjour()
    const found: SnapcastService[] = []

    const browser = bonjour.find({ type: 'snapcast' }, (service: Service) => {
      const ip = service.addresses?.[0] ?? service.referer?.address
      if (!ip) return
      const txt: Record<string, string> = {}
      if (service.txt && typeof service.txt === 'object') {
        for (const [k, v] of Object.entries(service.txt as Record<string, unknown>)) {
          txt[k] = String(v)
        }
      }
      found.push({ name: service.name, ip, port: service.port, txt })
    })

    setTimeout(() => {
      browser.stop()
      bonjour.destroy()
      console.log(`[mdns-browse] Found ${found.length} snapcast service(s)`)
      resolve(found)
    }, timeoutMs)
  })
}
