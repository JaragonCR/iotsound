import * as path from 'path'
import * as express from 'express'
import { Application } from 'express'
import SoundConfig from './SoundConfig'
import PulseAudioWrapper from './PulseAudioWrapper'
import { constants } from './constants'
import { restartDevice, rebootDevice, shutdownDevice } from './utils'
import { BalenaSDK } from 'balena-sdk'
import sdk from './BalenaClient'
import * as fs from 'fs'

const VERSION = fs.existsSync('VERSION') 
  ? fs.readFileSync('VERSION', 'utf8').trim() 
  : '3.11.0'; // last version before removal of VERSION```

export default class SoundAPI {
  private api: Application
  private sdk: BalenaSDK

  constructor(public config: SoundConfig, public audioBlock: PulseAudioWrapper) {
    this.sdk = sdk
    this.api = express()
    this.api.use(express.json())

    // Healthcheck endpoint
    this.api.get('/ping', (_req, res) => res.send('OK'))

    // Configuration
    this.api.get('/config', (_req, res) => res.json(this.config))

    // Config variables -- one by one
    for (const [key, value] of Object.entries(this.config)) {
      this.api.get(`/${key}`, (_req, res) => res.send(this.config[key]))
      if (typeof value === 'object') {
        for (const [subKey] of Object.entries(<any>value)) {
          this.api.get(`/${key}/${subKey}`, (_req, res) => res.send(this.config[key][subKey]))
        }
      }
    }

    // balenaSound version
    this.api.get('/version', (_req, res) => res.send(VERSION) )

    // Config variables -- update mode
    this.api.post('/mode', async (req, res) => {
      const updated: boolean = this.config.setMode(req.body.mode)
      if (updated) {
        try {
          await this.sdk.models.device.envVar.set(process.env.BALENA_DEVICE_UUID!, 'SOUND_MODE', req.body.mode)
          console.log(`SOUND_MODE persisted: ${req.body.mode}`)
        } catch (err) {
          console.log(`Failed to persist SOUND_MODE: ${(err as Error).message}`)
        }
      }
      res.json({ mode: this.config.mode, updated })
    })

    // Audio block
    this.api.get('/audio', async (_req, res) => res.json(await this.audioBlock.getInfo()))
    this.api.get('/audio/volume', async (_req, res) => res.json(await this.audioBlock.getVolume()))
    this.api.post('/audio/volume', async (req, res) => res.json(await this.audioBlock.setVolume(req.body.volume)))
    this.api.get('/audio/sinks', async (_req, res) => res.json(stringify(await this.audioBlock.getSinks())))

    // Device management
    this.api.post('/device/restart', async (_req, res) => res.json(await restartDevice()))
    this.api.post('/device/reboot', async (_req, res) => res.json(await rebootDevice()))
    this.api.post('/device/shutdown', async (_req, res) => res.json(await shutdownDevice()))
    this.api.post('/device/dtoverlay', async (req, res) => {
      const { dtoverlay } = req.body
      try {
        console.log(`Applying BALENA_HOST_CONFIG_dtoverlay=${dtoverlay}...`)
        await this.sdk.models.device.configVar.set(process.env.BALENA_DEVICE_UUID!, 'BALENA_HOST_CONFIG_dtoverlay', dtoverlay) // BALENA_DEVICE_UUID is always present in balenaOS
        res.json({ status: 'OK' })
      } catch (error) {
        console.log(error)
        res.json({ error: error })
      }
    })

    // Support endpoint -- Gathers information for troubleshooting
    this.api.get('/support', async (_req, res) => {
      res.json({
        version: VERSION,
        config: this.config,
        audio: await this.audioBlock.getInfo(),
        sinks: stringify(await this.audioBlock.getSinks()),
        volume: await this.audioBlock.getVolume(),
        constants: constants
      })
    })

    // Local UI
    this.api.use('/', express.static(path.join(__dirname, 'ui')))

    // Error catchall
    this.api.use((err: Error, _req, res, _next) => {
      res.status(500).json({ error: err.message })
    })
  }

  public async listen(port: number): Promise<void> {
    return new Promise((resolve) => {
      this.api.listen(port, () => {
        console.log(`Sound supervisor listening on port ${port}`)
        return resolve()
      })
    })
  }

}

// Required to avoid: "TypeError: Do not know how to serialize a BigInt"
function stringify(value) {
  return JSON.parse(JSON.stringify(value, (_, v) => typeof v === 'bigint' ? `${v}n` : v))
}
