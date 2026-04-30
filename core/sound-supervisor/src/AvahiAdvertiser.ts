import { spawn, ChildProcess } from 'child_process'

export default class AvahiAdvertiser {
  private proc: ChildProcess | null = null

  advertise(name: string, port: number, txt: Record<string, string>): void {
    this.unpublish()
    const txtArgs = Object.entries(txt).map(([k, v]) => `${k}=${v}`)
    console.log(`[avahi-advert] Advertising "${name}" _snapcast._tcp port=${port}`)
    this.proc = spawn('avahi-publish-service', [name, '_snapcast._tcp', String(port), ...txtArgs], {
      stdio: ['ignore', 'pipe', 'pipe']
    })
    this.proc.stdout?.on('data', (d: Buffer) => console.log(`[avahi-advert] ${d.toString().trim()}`))
    this.proc.stderr?.on('data', (d: Buffer) => console.log(`[avahi-advert] ${d.toString().trim()}`))
    this.proc.on('exit', (code: number | null) => {
      if (code !== null && code !== 0) {
        console.log(`[avahi-advert] process exited with code ${code}`)
      }
      this.proc = null
    })
  }

  unpublish(): void {
    if (this.proc) {
      this.proc.kill('SIGTERM')
      this.proc = null
      console.log('[avahi-advert] Advertisement unpublished')
    }
  }

  isAdvertising(): boolean {
    return this.proc !== null
  }
}
