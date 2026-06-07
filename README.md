# IoTSound — v5.0.1

> **Actively maintained community fork** of [iotsound/iotsound](https://github.com/iotsound/iotsound), originally developed by Balena as balenaSound.
> In October 2025 Balena issued a [call for maintainers](https://github.com/iotsound/iotsound/issues/689) but did not transfer the project to volunteers. This fork picks up that work.

[![deploy button](https://balena.io/deploy.svg)](https://dashboard.balena-cloud.com/deploy?repoUrl=https://github.com/JaragonCR/iotsound&defaultDeviceType=raspberry-pi)

---

## Features

- **Multi-source streaming** — Bluetooth, AirPlay 2, Spotify Connect, UPnP
- **Synchronized multi-room audio** — mDNS auto-discovery, play-triggered election, no IP pinning required
- **Karaoke** — YouTube search, singer/audience UI, queue, mic loopback with configurable EQ filters
- **Modern audio stack** — PipeWire + WirePlumber, full PulseAudio backward compatibility on TCP 4317
- **Hardware auto-detection** — DAC > USB > HDMI > built-in priority, manual override supported
- **balenaCloud managed** — OTA updates, fleet management, device monitoring

---

## Hardware tested

| Device | Status |
|---|---|
| Raspberry Pi 4 + HiFiBerry DAC HAT | ✅ Master + Spotify Connect + multiroom |
| Raspberry Pi 3 B/B+ + 3.5mm jack | ✅ Remote client + Spotify Connect + multiroom |
| Raspberry Pi 4 + C-Media USB Audio Dongle | ✅ Working |
| Raspberry Pi 5 | Not yet tested |
| Raspberry Pi Zero W | Not yet tested |

We only have two devices. If you can test on Pi 5, Pi Zero, USB DAC, HDMI, AirPlay, Bluetooth, or a 3+ device setup, please comment on [issue #39](https://github.com/JaragonCR/iotsound/issues/39). Hardware loans welcome.

---

## Setup and configuration

Deploy to a balenaCloud fleet with one click:

[![deploy button](https://balena.io/deploy.svg)](https://dashboard.balena-cloud.com/deploy?repoUrl=https://github.com/JaragonCR/iotsound&defaultDeviceType=raspberry-pi)

### Fleet variables

Set these in your balenaCloud fleet or device variables:

#### Device identity

| Variable | Description | Default |
|---|---|---|
| `SOUND_DEVICE_NAME` | Hostname and broadcast name for Bluetooth, AirPlay, Spotify Connect, and UPnP | `iotsound` |

#### Logging

| Variable | Description | Default |
|---|---|---|
| `LOG_LEVEL` | Universal debug switch — `debug` enables verbose output in all services and keeps the `support-toolkit` container running | `info` |

#### Audio output

| Variable | Description | Default |
|---|---|---|
| `SOUND_VOLUME` | Default volume (0–100) | `75` |
| `AUDIO_OUTPUT` | Output device — `AUTO`, device name substring, or device number | `AUTO` |
| `AUDIO_LOG_LEVEL` | Override audio log verbosity: `ERROR`, `WARN`, `NOTICE`, `INFO`, `DEBUG` | `LOG_LEVEL` or `NOTICE` |

#### Microphone input & filtering

| Variable | Description | Default |
|---|---|---|
| `AUDIO_INPUT` | Input device — `AUTO`, device name substring, or device number | `AUTO` |
| `AUDIO_INPUT_LOOPBACK` | Monitor mic through speakers (`true`/`false`) | `false` |
| `AUDIO_MIC_INPUT_VOLUME` | Mic input level 0–100 (only used when loopback is active) | `35` |
| `AUDIO_INPUT_EQ_DISABLED` | Disable all mic EQ filters (`true`/`false`) | `true` |
| `AUDIO_INPUT_HIGHPASS` | Highpass filter cutoff Hz — removes rumble (0 = off) | `130` |
| `AUDIO_INPUT_LOWPASS` | Lowpass filter cutoff Hz — removes harshness (0 = off) | `15000` |
| `AUDIO_INPUT_HIGHPASS_Q` | Highpass filter Q factor (bandwidth) | `1.0` |
| `AUDIO_INPUT_LOWPASS_Q` | Lowpass filter Q factor (bandwidth) | `1.0` |
| `AUDIO_INPUT_BOXY_CUT` | Peaking gain at 500 Hz (dB) to reduce boxy sound | `-2` |
| `AUDIO_INPUT_PROXIMITY_CUT` | Peaking gain at 250 Hz (dB) to reduce proximity effect | `-2` |
| `SOUND_ENABLE_SOUNDCARD_INPUT` | Route soundcard mic into the audio mix (set to any value to enable) | unset |
| `SOUND_INPUT_LATENCY` | Input loopback latency in ms | `200` |
| `SOUND_OUTPUT_LATENCY` | Output loopback latency in ms | `200` |

#### Multiroom (Snapcast)

See [docs/MULTIROOM.md](docs/MULTIROOM.md) for a full explanation of roles, group names, and election behaviour.

| Variable | Description | Default |
|---|---|---|
| `SOUND_MULTIROOM_ROLE` | `auto` (the device you play to becomes the group master), `host` (always master), `join` (always client), `disabled` (standalone) | `auto` |
| `SOUND_GROUP_NAME` | Multiroom group — devices with the same name sync together | `default` |
| `SOUND_MULTIROOM_CODEC` | Snapcast stream codec: `flac` (lossless, Wi‑Fi‑friendly), `pcm`, `opus`, `ogg` | `flac` |
| `SOUND_MULTIROOM_BUFFER_MS` | Snapserver stream buffer in ms — increase if all Snapcast clients stutter | `400` |
| `SOUND_MULTIROOM_CAPTURE_MS` | Master-side pacat capture latency in ms | `50` |
| `SOUND_MULTIROOM_PA_LATENCY_MS` | PulseAudio sink-input buffer for snapclient output in ms | `200` |
| `SOUND_MULTIROOM_LATENCY` | **Advanced.** Extra fixed snapclient `--latency` offset in ms. Leave at `0` — snapclient plays direct to the hardware sink and Snapcast compensates the real device latency automatically, so no per-device tuning is needed. | `0` |
| `SOUND_MULTIROOM_MASTER` | Override master IP — skips mDNS discovery (for networks where mDNS is blocked) | unset |

#### Multiroom roles

| Role | Streaming plugins | Joins multiroom | Becomes master |
|---|---|---|---|
| `auto` | ✅ Bluetooth, AirPlay, Spotify | ✅ | ✅ On first play |
| `host` | ✅ | ✅ | ✅ Always |
| `join` | ❌ Stopped (device invisible to streaming apps) | ✅ | ❌ Never |
| `disabled` | ✅ | ❌ Standalone only | ❌ Never |

**Standalone mode** — set `SOUND_MULTIROOM_ROLE=disabled` for devices that should play independently. Disabled devices route `balena-sound.input` directly to `balena-sound.output` and do not use Snapcast.

**Groups** — devices with the same `SOUND_GROUP_NAME` sync together. Different group names form independent groups that can play different audio simultaneously on the same network.

Role and group name can be changed live from the web UI at `http://<device-ip>/` without restarting services.

#### Spotify Connect (librespot)

| Variable | Description | Default |
|---|---|---|
| `SOUND_DISABLE_SPOTIFY` | Disable Spotify Connect entirely (set to any value) | unset |
| `SOUND_SPOTIFY_BITRATE` | Streaming bitrate in kbps: `96`, `160`, or `320` | `160` |
| `SOUND_SPOTIFY_INITIAL_VOLUME` | Volume level when Spotify connects (0–100) | `50` |
| `SOUND_SPOTIFY_USERNAME` | Spotify username for credential auth (use with `SOUND_SPOTIFY_PASSWORD`) | unset |
| `SOUND_SPOTIFY_PASSWORD` | Spotify access token for credential auth | unset |
| `SOUND_SPOTIFY_DISABLE_NORMALISATION` | Disable loudness normalization (set to `1`) | unset |

#### Bluetooth

| Variable | Description | Default |
|---|---|---|
| `SOUND_DISABLE_BLUETOOTH` | Disable Bluetooth entirely (set to any value) | unset |
| `BLUETOOTH_DEVICE_NAME` | Bluetooth broadcast name | `balenaOS <first 4 of UUID>` |
| `BLUETOOTH_HCI_INTERFACE` | Bluetooth adapter to use (e.g. `hci0`, `hci1`) | `hci0` |
| `BLUETOOTH_PAIRING_MODE` | `SSP` (Secure Simple Pairing) or `LEGACY` (PIN required) | `SSP` |

#### AirPlay

| Variable | Description | Default |
|---|---|---|
| `SOUND_DISABLE_AIRPLAY` | Disable AirPlay entirely (set to any value) | unset |

#### Karaoke

| Variable | Description | Default |
|---|---|---|
| `SOUND_DISABLE_KARAOKE` | Disable Karaoke entirely, including the player and fetcher containers (set to any value) | unset |
| `KARAOKE_QUALITY` | Maximum downloaded video height | `720` |
| `KARAOKE_MAX_QUEUE_PER_SINGER` | Maximum queued songs per singer | `3` |
| `KARAOKE_SYNC_OFFSET_MS` | Default local speaker A/V sync offset in ms, from `-2000` to `2000` | `0` |
| `KARAOKE_MIC_GAIN` | Default karaoke mic gain 0–100 | `AUDIO_MIC_INPUT_VOLUME` or `35` |
| `KARAOKE_LOG_LEVEL` | Override karaoke app and fetcher verbosity | `LOG_LEVEL` or `info` |

#### WiFi watchdog

| Variable | Description | Default |
|---|---|---|
| `WIFI_CHECK_INTERVAL` | Connectivity check interval in seconds | `30` |
| `WIFI_OFFLINE_THRESHOLD` | Seconds offline before recovery starts | `600` |
| `WIFI_RECOVERY_WAIT` | Seconds between recovery attempts | `300` |
| `MAX_RECOVERY_ATTEMPTS` | Recovery attempts before forcing a device reboot | `3` |

---

### Web UI

Access the control panel at `http://<device-ip>/` for:
- **Volume control** — device output volume slider
- **Multiroom** — role selector, group name dropdown with discovered groups, live master IP, client latency display
- **Multi-room buffer** — Snapcast latency slider
- **DAC overlay** — set a custom device tree overlay for DAC boards
- **Device management** — restart services, reboot, shutdown

---

## Audio Devices

### Output priority (AUTO)

1. HiFiBerry DAC (best quality)
2. USB audio devices
3. HDMI audio
4. Built-in 3.5mm jack (fallback)

### Input priority (AUTO)

1. USB audio devices / USB microphones
2. Built-in microphone

Check the startup logs to see detected devices:

```
[STEP] Available Hardware Output Sinks:
  1        alsa_output.usb-0d8c_C-Media_USB_Audio_Device-00.analog-stereo
  2        alsa_output.platform-soc_sound.stereo-fallback
  (Set AUDIO_OUTPUT=<n> to force a specific device)
```

Use `AUDIO_OUTPUT=1` to force by number, `AUDIO_OUTPUT=USB` to force by substring (case-insensitive). Same pattern for `AUDIO_INPUT`.

---

## Microphone Input & Filtering

The audio service includes configurable biquad filters for microphone input. Default configuration is optimised for karaoke:

```
AUDIO_INPUT_HIGHPASS = 130    # Removes rumble
AUDIO_INPUT_LOWPASS = 15000   # Removes harshness
AUDIO_MIC_INPUT_VOLUME = 35
AUDIO_INPUT_LOOPBACK = false
```

For detailed filter descriptions see [docs/Audio_Configuration.md](docs/Audio_Configuration.md).

---

## Documentation

- [Getting started](docs/01-getting-started.md)
- [Usage and roles](docs/02-usage.md)
- [Customization](docs/03-customization.md)
- [Multiroom](docs/MULTIROOM.md)
- [Audio configuration](docs/Audio_Configuration.md)
- [Device support](docs/06-device-support.md)
- [Troubleshooting](docs/07-support.md)
- [Testing matrix](docs/TESTING.md)

---

## Motivation

There are many commercial solutions that provide functionality similar to IoTSound — Sonos, WiiM, and others. Most come with a premium price tag, vendor lock-in, and privacy concerns.

IoTSound is an open source project that lets you build your own DIY audio streaming platform without compromises. Bring your old speakers back to life, on your own terms.

## Alternatives

- [moOde Audio](https://moodeaudio.org/) — free, open source audiophile streamer with multiroom support
- [Volumio](https://volumio.com/) — free and premium options
- [piCorePlayer](https://www.picoreplayer.org/) — lightweight, supports local and streaming services

## Contributing

This is a community-maintained fork. PRs welcome. Please [raise an issue](https://github.com/JaragonCR/iotsound/issues/new) for bugs or feature requests.

See [.versionbot/COMMIT_RULES.md](.versionbot/COMMIT_RULES.md) for commit message guidelines.

## Getting Help

If you're having any problem, please [raise an issue](https://github.com/JaragonCR/iotsound/issues/new) on GitHub or check [docs/07-support.md](docs/07-support.md).

## Credits

- Original project by [Balena](https://www.balena.io/)
- go-librespot by [devgianlu](https://github.com/devgianlu/go-librespot)
- Maintained by [@JaragonCR](https://github.com/JaragonCR)
