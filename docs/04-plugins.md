# Plugins

Plugins are the sources from where you can stream audio to your device. IoTSound comes with a set of plugins installed by default and the possibility of adding some extra ones with a bit of tinkering. We are always on the lookout for adding new plugins so keep an eye out!

**Why not include all plugins by default?**
We want to avoid deploying all installable plugins by default because of (a) increased build time, (b) increased deploy time, (c) impact on device performance. Given that most users typically don't use more than one or two plugins it seems reasonable to limit defaults to the most popular ones to prevent users paying the cost of having many plugins that will never be used.

## Default

The following plugins ship with IoTSound out of the box:

- Spotify Connect
- Bluetooth
- AirPlay2
- Karaoke
- Soundcard input (Requires setting `SOUND_ENABLE_SOUNDCARD_INPUT`, see [details](customization#plugins))

Default plugins can be disabled at runtime via variables. For more details see [here](customization#plugins).

### Spotify

Spotify Connect requires a premium account. There is two methods of authentication:

- zeroconf: most Spotify clients on smartphones, computers and smart tvs will automatically connect to balenaSound and pass on credentials without the need for manual authentication.
- manual: providing user and password via variables, see [customization](customization#plugins) section for details.

Manual authentication will let you stream audio over the internet from a client that is on a different network than the balenaSound device. This is useful if your IoTSound device is on a separate WiFi network that's harder to reach (e.g. a backyard network).

#### Lossless with Spotify Soloist (optional)

By default Spotify Connect is provided by go-librespot, which streams at up to 320 kbps. You
can switch to [Spotify Soloist](https://github.com/spotify/soloist), Spotify's own headless
Connect client, which supports lossless on Premium accounts.

1. Create an API key on the Spotify for Developers dashboard (see Spotify's
   [getting started guide](https://developer.spotify.com/documentation/soloist/tutorials/getting-started)).
   A Premium account is needed to create it. The key is yours: do not share it.
2. Set two device variables: `SOUND_SPOTIFY_ENGINE=soloist` and `SOLOIST_API_KEY=<your key>`.
3. In the Spotify app, open the device's settings in the Connect menu and choose Lossless.

How IoTSound handles it:

- Spotify does not allow Soloist to be redistributed, so it is not part of the IoTSound
  image. The device downloads it from Spotify's CDN the first time the engine is enabled
  with a key present. Without a key nothing is downloaded and go-librespot runs.
- Soloist builds expire 90 days after their build date. The device checks for a new build
  every 6 hours and installs it while nothing is playing; an expired build is replaced
  on the spot.
- If Soloist fails to start 3 times within 5 minutes, go-librespot takes over under the same
  speaker name. Soloist is tried again after `SOUND_SPOTIFY_SOLOIST_RETRY_MIN` minutes
  (default 30) once nothing is playing.
- Both engines run in the same container, so only one advertises the speaker at a time.
- `SOUND_SPOTIFY_BITRATE`, `SOUND_SPOTIFY_DISABLE_NORMALISATION`, `SOUND_SPOTIFY_USERNAME` and
  `SOUND_SPOTIFY_PASSWORD` apply to go-librespot only. With Soloist, quality and normalization
  follow the Spotify app.
- Soloist answers Spotify Connect discovery with its own mDNS responder on UDP 5353, next to
  the shared avahi-daemon; it has no option to use Avahi. If the speaker stops showing up in
  Spotify while Soloist is the engine, switch back to `librespot` to compare.
- Soloist caches every track it plays. On devices with 1.5 GB of memory or more the cache
  lives in RAM (100 MB limit) so lossless playback does not wear the SD card; smaller devices
  cache on disk. Force either with `SOUND_SPOTIFY_SOLOIST_CACHE=ram` or `disk`.
- A speaker that is not the active Spotify Connect device must be silent. Soloist has been
  seen to keep playing after the app disconnected, so IoTSound checks its state every few
  seconds and pauses it when it is playing without being the active device.
- Soloist receives the key as a command-line argument, so it is visible in the process
  list on the device.

### Karaoke

Karaoke is shipped as a plugin under `plugins/karaoke/app`:

- `karaoke`: Go audience/singer UI, `yt-dlp` downloader, and local playback controller on port 8080.

Set `SOUND_DISABLE_KARAOKE` to disable the service. In local speaker mode, karaoke sends audio and mic loopback into `balena-sound.input` only while a song is actively playing; in stream mode, the browser decodes the MP4 directly.

## Development checklist

When adding or renaming a plugin service, keep the service name consistent across:

- `docker-compose.yml`
- the plugin's `SOUND_DISABLE_<PLUGIN>` handling
- `core/sound-supervisor/src/SoundConfig.ts`
- the configuration tables in `README.md` and `docs/03-customization.md`

Source plugins that can create audio must be listed in `SoundConfig.ts` so role switching can start them in `auto`, `host`, and `disabled`, and stop them in `join`. A `join` device should act as a passive Snapcast receiver; leaving a source plugin running there can expose a local UI or stream endpoint that injects audio outside the elected master path.

## Installable

The following plugins are available to be added to your IoTSound installation:

- UPnP: Universal Plug and Play
- (Work in progress) Tidal Connect: See [PR #399](https://github.com/iotsound/iotsound/pull/399)
- (Work in progress) Roon Bridge: See [PR #388](https://github.com/iotsound/iotsound/pull/388)

Installing these plugins is a more involved process than just deploying the off the shelf version of IoTSound. You'll need to edit the contents of the `docker-compose.yml` file before deploying the app. This means that you won't be able to deploy using the "Deploy with balena" button; you either need to use the [CLI to deploy](01-getting-started.md#cli-deploy) or use "Deploy with balena" with your own forked version of the project. If you don't feel comfortable performing these steps or need some help along the way hit us up at our [forums](https://forums.balena.io) and we'll gladly help you out.

### UPnP

To install UPnP plugin add the following to the `services` section on your `docker-compose.yml` file:

```
  upnp:
    build: ./plugins/upnp
    restart: on-failure
    network_mode: host
    ports:
      - 49494:49494
```
