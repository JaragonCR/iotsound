# Usage

After your device finishes downloading the app, you should be ready to go!

Before starting, make sure to connect the audio output of your device to your Hi-Fi or speaker system. Remember that we support multiple [audio interfaces](audio-interfaces). This is helpful if you're interested in improving the audio quality of your setup -- be sure to check it out!

To connect to your IoTSound device:

- If using Bluetooth: search for your device on your phone or laptop and pair.
- If using Airplay: select the IoTSound device from your audio output options.
- If using Spotify Connect: open Spotify and choose the IoTSound device as an alternate output.

The `iotsound` name is used by default. Set `SOUND_DEVICE_NAME` to customize the name broadcast by Bluetooth, AirPlay, and Spotify Connect.

Let the music play!

## Roles

IoTSound uses a role system to control how each device participates in multi-room audio. Set `SOUND_MULTIROOM_ROLE`, or change it live from the web UI at `http://<device-ip>/`.

| Role | Streaming plugins | Joins multi-room | Becomes master |
|---|---|---|---|
| `auto` (default) | ✅ Bluetooth, AirPlay, Spotify | ✅ | ✅ On first play |
| `host` | ✅ | ✅ | ✅ Always |
| `join` | ❌ Stopped | ✅ | ❌ Never |
| `disabled` | ✅ | ❌ | ❌ Never |

### auto (default)

The device starts idle at boot. The moment you stream to it (via Bluetooth, AirPlay, or Spotify), it promotes itself to multi-room master, starts Snapcast server, and advertises via mDNS. All other devices in the same group discover it automatically and sync up within seconds. When you stop playing for 30 seconds it releases the master role and returns to idle.

### host

Always runs as the Snapcast server, regardless of whether audio is playing. Use for a dedicated device with a reliable wired connection that you always want as the group audio source.

### join

Passive receiver only. No Bluetooth, AirPlay, or Spotify — the device is invisible to streaming apps. It only plays audio received from the current group master. Best for secondary speakers in a room that should only ever receive synchronized audio.

### disabled (standalone)

The device plays completely independently. All streaming plugins remain active, but Snapcast is not started — the device does not participate in multi-room synchronization. Use when a room should always play independently, or when you only have one device.

## Plugin system

IoTSound has been re-designed to easily allow integration with audio streaming sources. These are the sources we currently support and the projects that make it possible:

| Plugin          | Library/Project                                                                                                                                                                                                                                                                                 |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Spotify Connect | [go-librespot](https://github.com/devgianlu/go-librespot) — Spotify Connect only works with Spotify Premium accounts. Zeroconf authentication via your phone/device Spotify client is supported as well as providing user and password, see [customization](customization#plugins) section for details. |
| AirPlay2        | [shairport-sync](https://github.com/mikebrady/shairport-sync/)                                                                                                                                                                                                                                  |
| Bluetooth       | Custom bluetooth-agent (vendored) with BlueALSA for audio routing                                                                                                                                                                                                                              |
| Soundcard input | Experimental — enable via `AUDIO_INPUT_LOOPBACK=true`. See [customization](customization#plugins) section.                                                                                                                                                                                      |

If your desired audio source is not supported feel free to [reach out](support#contact-us) and leave us a comment. We've also considerably simplified the process of adding new plugins, so [PR's are welcome](https://github.com/iotsound/iotsound/blob/master/CONTRIBUTING.md) too (be be sure to check out our IoTSound [architecture](https://github.com/iotsound/iotsound/blob/master/docs/ARCHITECTURE.md) guide)!

## Audio interfaces

IoTSound supports all audio interfaces present on our [supported devices](device-support) be it 3.5mm audio jack, HDMI, I2C DAC's or USB soundcards. The `audio` service handles device detection and routing automatically.

Some audio interfaces require special configuration, you can read more about this in the [audio interfaces](audio-interfaces) configuration section.
