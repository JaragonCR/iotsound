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

### Karaoke

Karaoke is shipped as a plugin under `plugins/karaoke` with two services:

- `karaoke`: Go audience/singer UI and local playback controller on port 8080.
- `karaoke-fetcher`: Python/Waitress sidecar on port 8081 that runs `yt-dlp` downloads into the shared `karaoke-media` volume.

Set `SOUND_DISABLE_KARAOKE` to disable both services. In local speaker mode, karaoke sends audio and mic loopback into `balena-sound.input` only while a song is actively playing; in stream mode, the browser decodes the MP4 directly.

## Development checklist

When adding or renaming a plugin service, keep the service name consistent across:

- `docker-compose.yml`
- the plugin's `SOUND_DISABLE_<PLUGIN>` handling
- `core/sound-supervisor/src/SoundConfig.ts`
- the configuration tables in `README.md` and `docs/03-customization.md`

Source plugins that can create audio must be listed in `SoundConfig.ts` so role switching can start them in `auto`, `host`, and `disabled`, and stop them in `join`. A `join` device should act as a passive Snapcast receiver; leaving a source plugin running there can expose a local UI or stream endpoint that injects audio outside the elected master path.

Plugins with sidecar services should include every sidecar that needs to follow the same role visibility. For karaoke, both `karaoke` and `karaoke-fetcher` are managed together because the UI and downloader should disappear together on passive client devices, and `SOUND_DISABLE_KARAOKE` disables both containers.

## Installable

The following plugins are available to be added to your IoTSound installation:

- UPnP: Universal Plug and Play
- (Work in progress) Tidal Connect: See [PR #399](https://github.com/iotsound/iotsound/pull/399)
- (Work in progress) Roon Bridge: See [PR #388](https://github.com/iotsound/iotsound/pull/388)

Installing these plugins is a more involved process than just deploying the off the shelf version of IoTSound. You'll need to edit the contents of the `docker-compose.yml` file before deploying the app. This means that you won't be able to deploy using the "Deploy with balena" button; you either need to use the [CLI to deploy](https://iotsound.github.io/iotsound/getting-started#cli-deploy) or use "Deploy with balena" with your own forked version of the project. If you don't feel comfortable performing these steps or need some help along the way hit us up at our [forums](https://forums.balena.io) and we'll gladly help you out.

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
