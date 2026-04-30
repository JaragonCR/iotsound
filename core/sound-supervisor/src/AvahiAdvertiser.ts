import Bonjour from 'bonjour-service'
import type { Service } from 'bonjour-service'

export default class AvahiAdvertiser {
  private bonjour: Bonjour | null = null
  private service: Service | null = null

  advertise(name: string, port: number, txt: Record<string, string>): void {
    this.unpublish()
    console.log(`[mdns-advert] Advertising "${name}" _snapcast._tcp port=${port}`)
    this.bonjour = new Bonjour()
    this.service = this.bonjour.publish({ name, type: 'snapcast', port, txt })
  }

  unpublish(): void {
    if (this.service) {
      this.service.stop?.()
      this.service = null
    }
    if (this.bonjour) {
      this.bonjour.destroy()
      this.bonjour = null
      console.log('[mdns-advert] Advertisement unpublished')
    }
  }

  isAdvertising(): boolean {
    return this.service !== null
  }
}
