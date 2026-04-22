# IoTSound (JaragonCR Fork) — v4.2.3

> **Actively maintained community fork** of [iotsound/iotsound](https://github.com/iotsound/iotsound), originally developed by Balena as balenaSound.
> In October 2025 Balena issued a [call for maintainers](https://github.com/iotsound/iotsound/issues/689) but did not transfer the project to volunteers. This fork picks up that work.

[![deploy button](https://balena.io/deploy.svg)](https://dashboard.balena-cloud.com/deploy?repoUrl=https://github.com/JaragonCR/iotsound&defaultDeviceType=raspberry-pi)

---

## What's different in this fork

### ✅ Completed modernization (v4.0.0 → v4.1.0)

| Change | Details |
|---|---|
| **PulseAudio → PipeWire** | Replaced PulseAudio 15 with PipeWire + WirePlumber on Alpine 3.21. `pipewire-pulse` maintains full TCP 4317 backward compatibility with all audio clients. |
| **Audio block wrapper** | Replaced the abandoned `balena-audio` npm package (4+ years unmaintained) with `PulseAudioWrapper` — a drop-in replacement using `pactl` and Node.js built-ins. Zero new dependencies. |
| **librespot → go-librespot** | Replaced the aging librespot Rust implementation with [go-librespot](https://github.com/devgianlu/go-librespot) for better Spotify Connect stability and zeroconf support. |
| **Node.js 14 → 20 LTS** | Upgraded sound-supervisor from EOL Node 14 to Node 20 LTS. |
| **TypeScript 3.9 → 5.4.5** | Modernized TypeScript compiler and updated tsconfig target to ES2022. |
| **13 CVEs fixed** | Addressed all Dependabot security alerts: `axios`, `express`, `async`, `lodash`, `js-yaml`, `braces`, `socket.io-parser` and more. |
| **Hostname fix** | Fixed Day 1 issue where `${SOUND_DEVICE_NAME}` was never resolved due to balena not supporting docker-compose variable substitution syntax. Replaced with self-contained supervisor API script. |
| **Bluetooth modernization** | Removed fragile `git clone at build time` pattern. Vendored custom `bluetooth-agent` directly into the plugin. Upgraded Python 3.8 → 3.12. Custom changes: wipe paired devices on startup, fix `RECONNECT_MAX_RETRIES` type cast bug. |
| **Logging cleanup** | Removed outdated kernel version comments and verbose debug noise across all containers. |
| **Versionist integration** | Automated changelog generation and semantic versioning via Flowzone. |
| **Hardware audio detection** | Auto-detect output devices (DAC > USB > HDMI > Built-in) and input devices (USB > Built-in) with manual override support. |
| **Microphone filtering** | Configurable PipeWire biquad filters (highpass/lowpass) for voice quality optimization. Perfect for karaoke. |

### 🔧 Pending / In Progress

| Item | Notes |
|---|---|
| **Karaoke support** | Integrating [pitube-karaoke](https://github.com/JaragonCR/pitube-karaoke) — Go-based karaoke with HDMI video output and 3.5mm audio input |
| **Airplay plugin update** | shairport-sync version bump and base image update |
| **Multiroom modernization** | Snapcast server/client — consider switching from build-from-source to official Docker images |
| **UPnP plugin update** | gmrender-resurrect base image update |

---

## Highlights

- **Audio source plugins**: Stream audio from Bluetooth, Airplay2, Spotify Connect, UPnP and more
- **Multi-room synchronous playing**: Perfectly synchronized audio across multiple devices
- **Extended DAC support**: HiFiBerry DAC+, USB audio devices, and other supported DAC boards
- **Hardware auto-detection**: Automatically detects and prioritizes audio output and input devices
- **Microphone filtering**: Configurable highpass/lowpass filters for microphone input (ideal for karaoke)
- **PipeWire audio stack**: Modern, low-latency audio with full PulseAudio backward compatibility
- **balenaCloud managed**: Full OTA updates, fleet management and device monitoring via balenaCloud dashboard

## Hardware tested

| Device | Status |
|---|---|
| Raspberry Pi 4 + HiFiBerry DAC+ | ✅ Tested and working |
| Raspberry Pi 4 + C-Media USB Audio Dongle | ✅ Tested and working |
| Raspberry Pi 5 | Not yet tested |
| Raspberry Pi Zero W | Should work, not tested |

## Setup and configuration

Deploy to a balenaCloud fleet with one click:

[![deploy button](https://balena.io/deploy.svg)](https://dashboard.balena-cloud.com/deploy?repoUrl=https://github.com/JaragonCR/iotsound&defaultDeviceType=raspberry-pi)

### Fleet variables

Set these in your balenaCloud fleet or device variables:

| Variable | Description | Default |
|---|---|---|
| `SOUND_DEVICE_NAME` | Device hostname and Bluetooth/Spotify name | `iotsound` |
| `SOUND_DISABLE_BLUETOOTH` | Set to `1` to disable Bluetooth | unset |
| `SOUND_VOLUME` | Default volume 0-100 | `75` |
| `AUDIO_OUTPUT` | Audio output selection (`AUTO`, device name, or device number) | `AUTO` |
| `AUDIO_INPUT` | Audio input selection (`AUTO`, device name, or device number) | `AUTO` |
| `AUDIO_INPUT_HIGHPASS` | Microphone highpass filter frequency in Hz (0 = disabled) | `120` |
| `AUDIO_INPUT_LOWPASS` | Microphone lowpass filter frequency in Hz (0 = disabled) | `12000` |
| `AUDIO_MIC_INPUT_VOLUME` | Microphone input volume percentage (0-100) | `40` |
| `AUDIO_INPUT_LOOPBACK` | Enable microphone loopback to speakers for testing (`true`/`false`) | `false` |

**For detailed audio configuration documentation**, see [AUDIO_CONFIGURATION.md](docs/AUDIO_CONFIGURATION.md) which includes:
- Device detection and priority ordering
- Output device selection (DAC prioritization)
- Input device selection (microphone detection)
- Microphone filter settings (highpass/lowpass for voice quality)
- Microphone volume and loopback configuration
- Latency settings for different use cases
- Troubleshooting guide

### Web UI

Once deployed, access the control panel at `http://<device-ip>/` for volume control and device management.

## Audio Devices

### Automatic Detection

The audio service automatically detects available audio devices on startup and logs them:

```
[STEP] Available Hardware Output Sinks:
  1        alsa_output.usb-0d8c_C-Media_USB_Audio_Device-00.analog-stereo
  2        alsa_output.platform-soc_sound.stereo-fallback
  (Set AUDIO_OUTPUT=<n> to force a specific device)

[STEP] Available Hardware Input Sources:
  1        alsa_input.usb-0d8c_C-Media_USB_Audio_Device-00.mono-fallback
  (Set AUDIO_INPUT=<n> to force a specific device)
```

### Output Priority

By default, devices are selected in this order:
1. HiFiBerry DAC+ (best audio quality)
2. USB Audio devices
3. HDMI audio
4. Built-in 3.5mm jack (fallback)

Use `AUDIO_OUTPUT` to override: `AUDIO_OUTPUT=1` to force device #1, or `AUDIO_OUTPUT=USB` to force USB.

### Input Priority

By default, microphone devices are selected in this order:
1. USB Audio devices (USB microphones, audio dongles)
2. Built-in microphone

Use `AUDIO_INPUT` to override: `AUDIO_INPUT=1` to force device #1, or `AUDIO_INPUT=USB` to force USB.

## Microphone Input & Filtering

The audio service includes configurable audio filters for microphone input to improve voice quality and remove unwanted noise. This is especially useful for karaoke and voice applications.

### Default Configuration (Optimized for Karaoke)

```
AUDIO_INPUT_HIGHPASS = 120    # Removes rumble and low-frequency noise
AUDIO_INPUT_LOWPASS = 12000   # Removes high-frequency harshness
AUDIO_MIC_INPUT_VOLUME = 40   # Input level (prevents amplification noise)
AUDIO_INPUT_LOOPBACK = false  # Disable mic monitoring by default
```

### Common Configurations

**Studio/Professional Vocals:**
```
AUDIO_INPUT_HIGHPASS = 80
AUDIO_INPUT_LOWPASS = 15000
AUDIO_MIC_INPUT_VOLUME = 50
```

**Karaoke (Default - Recommended):**
```
AUDIO_INPUT_HIGHPASS = 120
AUDIO_INPUT_LOWPASS = 12000
AUDIO_MIC_INPUT_VOLUME = 40
```

**No Filtering (Full Spectrum):**
```
AUDIO_INPUT_HIGHPASS = 0
AUDIO_INPUT_LOWPASS = 0
AUDIO_MIC_INPUT_VOLUME = 40
```

For detailed filter descriptions and more configuration examples, see [AUDIO_CONFIGURATION.md](docs/AUDIO_CONFIGURATION.md).

## Branch workflow

This project uses [Versionist](https://github.com/product-os/versionist) for automated versioning.
All changes should go through feature branches and PRs — see [.versionbot/COMMIT_RULES.md](.versionbot/COMMIT_RULES.md) for commit message guidelines.

## Documentation

Head over to the [original docs](https://iotsound.github.io/) for detailed installation and usage instructions. Note some docs may reference older versions.

For audio configuration details: see [AUDIO_CONFIGURATION.md](docs/AUDIO_CONFIGURATION.md)

## Motivation

![concept](https://raw.githubusercontent.com/iotsound/iotsound/master/docs/images/sound.png)

There are many commercial solutions out there that provide functionality similar to IoTSound — Sonos, WiiM, and others. Most come with a premium price tag, vendor lock-in, and privacy concerns.

IoTSound is an open source project that lets you build your own DIY audio streaming platform without compromises. Bring your old speakers back to life, on your own terms.

## Alternatives

If you need a more established solution:

- [moOde Audio](https://moodeaudio.org/) — free, open source audiophile streamer with multiroom support
- [Volumio](https://volumio.com/) — free and premium options
- [piCorePlayer](https://www.picoreplayer.org/) — lightweight, supports local and streaming services

## Contributing

This is a community-maintained fork. PRs welcome. If you find a bug or want to help with any of the pending items above, please [raise an issue](https://github.com/JaragonCR/iotsound/issues/new).

See [.versionbot/COMMIT_RULES.md](.versionbot/COMMIT_RULES.md) for commit message guidelines.

## Getting Help

If you're having any problem, please [raise an issue](https://github.com/JaragonCR/iotsound/issues/new) on GitHub.

## Credits

- Original project by [Balena](https://www.balena.io/)
- go-librespot by [devgianlu](https://github.com/devgianlu/go-librespot)
- PipeWire migration assistance by Google Gemini
- Audio hardware detection and microphone filtering by Claude (Anthropic)
- Modernization work by [@JaragonCR](https://github.com/JaragonCR)