# IoTSound (JaragonCR Fork) — v4.7.0

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
| **Node.js 14 → 24 LTS** | Upgraded sound-supervisor from EOL Node 14 to Node 24 LTS. |
| **TypeScript 3.9 → 5.4.5** | Modernized TypeScript compiler and updated tsconfig target to ES2022. |
| **13 CVEs fixed** | Addressed all Dependabot security alerts: `axios`, `express`, `async`, `lodash`, `js-yaml`, `braces`, `socket.io-parser` and more. |
| **Hostname fix** | Fixed Day 1 issue where `${SOUND_DEVICE_NAME}` was never resolved due to balena not supporting docker-compose variable substitution syntax. Replaced with self-contained supervisor API script. |
| **Bluetooth modernization** | Removed fragile `git clone at build time` pattern. Vendored custom `bluetooth-agent` directly into the plugin. Upgraded Python 3.8 → 3.12. Custom changes: wipe paired devices on startup, fix `RECONNECT_MAX_RETRIES` type cast bug. |
| **Logging cleanup** | Removed outdated kernel version comments and verbose debug noise across all containers. |
| **Versionist integration** | Automated changelog generation and semantic versioning via Flowzone. |
| **Hardware audio detection** | Auto-detect output devices (DAC > USB > HDMI > Built-in) and input devices (USB > Built-in) with manual override support. |
| **Microphone filtering** | Configurable PipeWire biquad filters (highpass/lowpass) for voice quality optimization. Perfect for karaoke. |

### ✅ Completed modernization (v4.5.0 → v4.6.0)

| Change | Details |
|---|---|
| **Multiroom 2.0** | Replaced cote UDP pub/sub election with mDNS auto-discovery. Play-triggered master promotion — the device you stream to becomes master instantly. Role system (`auto` / `host` / `join` / `disabled`) replaces the old three-mode system. No manual IP pinning needed. Group names let multiple independent groups coexist on the same network. |

### 🔧 Pending / In Progress

| Item | Notes |
|---|---|
| **Karaoke support** | Integrating [pitube-karaoke](https://github.com/JaragonCR/pitube-karaoke) — Go-based karaoke with HDMI video output and 3.5mm audio input |
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

#### Device identity

| Variable | Description | Default |
|---|---|---|
| `SOUND_DEVICE_NAME` | Hostname and broadcast name for Bluetooth, AirPlay, Spotify Connect, and UPnP | `iotsound` |

#### Audio output

| Variable | Description | Default |
|---|---|---|
| `SOUND_VOLUME` | Default volume (0–100) | `75` |
| `AUDIO_OUTPUT` | Output device — `AUTO`, device name substring, or device number | `AUTO` |
| `AUDIO_LOG_LEVEL` | Audio log verbosity: `ERROR`, `WARN`, `NOTICE`, `INFO`, `DEBUG` | `NOTICE` |

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
| `SOUND_MULTIROOM_ROLE` | `auto` (play-triggered master), `host` (always master), `join` (always client), `disabled` (standalone) | `auto` |
| `SOUND_GROUP_NAME` | Multiroom group — devices with the same name sync together | `default` |
| `SOUND_GROUP_LATENCY` | Group-wide Snapcast buffer in ms — increase if clients stutter | `400` |
| `SOUND_STANDALONE_BUFFER_MS` | Local Snapcast buffer used by `auto`/`host` devices before remote clients join | `150` |
| `SOUND_MULTIROOM_BUFFER_MS` | Snapcast buffer used when remote clients are connected | `400` |
| `SOUND_MULTIROOM_LATENCY` | Per-device latency fine-tuning in ms | unset |
| `SOUND_MULTIROOM_MASTER` | Override master IP — skips mDNS discovery (for networks where mDNS is blocked) | unset |

#### Multiroom roles

| Role | Streaming plugins | Joins multiroom | Becomes master |
|---|---|---|---|
| `auto` | ✅ Bluetooth, AirPlay, Spotify | ✅ | ✅ On first play |
| `host` | ✅ | ✅ | ✅ Always |
| `join` | ❌ Stopped (device invisible to streaming apps) | ✅ | ❌ Never |
| `disabled` | ✅ | ❌ Standalone only | ❌ Never |

**Standalone mode** — set `SOUND_MULTIROOM_ROLE=disabled` for devices that should play independently. All streaming plugins (Bluetooth, AirPlay, Spotify) remain active; Snapcast is simply not started.

**Groups** — devices with the same `SOUND_GROUP_NAME` sync together. Different group names form independent groups that can play different audio simultaneously on the same network.

You can change role and group name live from the web UI at `http://<device-ip>/` without restarting services.

#### Spotify Connect (librespot)

| Variable | Description | Default |
|---|---|---|
| `SOUND_SPOTIFY_BITRATE` | Streaming bitrate in kbps: `96`, `160`, or `320` | `160` |
| `SOUND_SPOTIFY_INITIAL_VOLUME` | Volume level when Spotify connects (0–100) | `50` |
| `SOUND_SPOTIFY_USERNAME` | Spotify username for credential auth (use with `SOUND_SPOTIFY_PASSWORD`) | unset |
| `SOUND_SPOTIFY_PASSWORD` | Spotify access token for credential auth | unset |
| `SOUND_SPOTIFY_DISABLE_NORMALISATION` | Disable loudness normalization (set to `1`) | unset |
| `LOG_LEVEL` | go-librespot log level: `debug`, `info`, `warning`, `error` | `info` |

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

#### WiFi watchdog

| Variable | Description | Default |
|---|---|---|
| `WIFI_CHECK_INTERVAL` | Connectivity check interval in seconds | `30` |
| `WIFI_OFFLINE_THRESHOLD` | Seconds offline before recovery starts | `600` |
| `WIFI_RECOVERY_WAIT` | Seconds between recovery attempts | `300` |
| `MAX_RECOVERY_ATTEMPTS` | Recovery attempts before forcing a device reboot | `3` |

**For detailed audio configuration documentation**, see [AUDIO_CONFIGURATION.md](docs/AUDIO_CONFIGURATION.md) which includes:
- Device detection and priority ordering
- Output device selection (DAC prioritization)
- Input device selection (microphone detection)
- Microphone filter settings (highpass/lowpass for voice quality)
- Microphone volume and loopback configuration
- Latency settings for different use cases
- Troubleshooting guide

### Web UI

Once deployed, access the control panel at `http://<device-ip>/` for:
- **Volume control** — device output volume slider
- **Multiroom** — role selector (auto/host/join/disabled), group name dropdown with discovered groups, live master IP
- **Multi-room buffer** — Snapcast latency slider
- **DAC overlay** — set a custom device tree overlay for DAC boards
- **Device management** — restart services, reboot, shutdown

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

### Forcing a specific output or input device

Check the startup logs (or the Support logs page at `http://<device-ip>/support`) to see the numbered device list:

```
[STEP] Available Hardware Output Sinks:
  1        alsa_output.usb-0d8c_C-Media_USB_Audio_Device-00.analog-stereo
  2        alsa_output.platform-soc_sound.stereo-fallback
  (Set AUDIO_OUTPUT=<n> to force a specific device)
```

Then set the fleet or device variable:

| Goal | Variable |
|---|---|
| Force output device #1 | `AUDIO_OUTPUT=1` |
| Force USB audio output | `AUDIO_OUTPUT=USB` |
| Force HiFiBerry DAC | `AUDIO_OUTPUT=HiFiBerry` |
| Force output device by full name | `AUDIO_OUTPUT=C-Media` (substring match) |
| Force input device #1 | `AUDIO_INPUT=1` |
| Force USB microphone | `AUDIO_INPUT=USB` |

The match is case-insensitive substring — you don't need the full device name. `AUTO` (the default) uses the priority order above.

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
