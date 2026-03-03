# IoTSound (JaragonCR Fork) — v4.1.0

> **Actively maintained community fork** of [iotsound/iotsound](https://github.com/iotsound/iotsound), originally developed by Balena as balenaSound.
> In October 2025 Balena issued a [call for maintainers](https://github.com/iotsound/iotsound/issues/689) but did not transfer the project to volunteers. This fork picks up that work.

[![deploy button](https://balena.io/deploy.svg)](https://dashboard.balena-cloud.com/deploy?repoUrl=https://github.com/JaragonCR/iotsound&defaultDeviceType=raspberry-pi)

---

## What's different in this fork

### ✅ Completed modernization (v4.0.0)

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

### ✨ New in v4.1.0

| Feature | Details |
|---|---|
| **WiFi Watchdog** | Automatic WiFi recovery service monitors connectivity every 30 seconds. If WiFi is down for 10+ minutes (and no audio is playing), it toggles WiFi off/on. Reboots device after 3 failed recovery attempts. Audio-aware to protect active playback. |

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
- **Extended DAC support**: HiFiBerry DAC+ and other supported DAC boards
- **PipeWire audio stack**: Modern, low-latency audio with full PulseAudio backward compatibility
- **WiFi Watchdog**: Automatic WiFi recovery — toggles connection if down for 10+ minutes, reboots after 3 failed attempts
- **balenaCloud managed**: Full OTA updates, fleet management and device monitoring via balenaCloud dashboard

## Hardware tested

| Device | Status |
|---|---|
| Raspberry Pi 4 + HiFiBerry DAC+ | ✅ Tested and working |
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
| `AUDIO_OUTPUT` | Audio output selection | `AUTO` |
| `SOUND_VOLUME` | Default volume 0-100 | `75` |
| `WIFI_CHECK_INTERVAL` | WiFi watchdog check interval (seconds) | `30` |
| `WIFI_OFFLINE_THRESHOLD` | WiFi offline timeout before recovery (seconds) | `600` (10 min) |
| `WIFI_RECOVERY_WAIT` | Wait time between recovery attempts (seconds) | `300` (5 min) |
| `MAX_RECOVERY_ATTEMPTS` | Max WiFi toggle attempts before reboot | `3` |

### WiFi Watchdog

The WiFi Watchdog service monitors your device's WiFi connection and automatically recovers from dropouts:

**Behavior:**
- Checks WiFi connectivity every 30 seconds
- If offline for 10+ minutes AND no audio is playing, attempts recovery
- Recovery: Toggles WiFi off (5s) → on, waits 5 minutes for reconnection
- Retries up to 3 times
- If all attempts fail, reboots the device
- Resets recovery counter when WiFi returns online

**Audio-aware:** Won't reboot or toggle WiFi while audio is actively playing (protects your music).

**Monitor watchdog status:**
```bash
balena logs <device-uuid> --follow | grep wifi-watchdog
```

**Customize behavior via fleet variables** (no rebuild needed):
```
WIFI_CHECK_INTERVAL=60          # Check every 60 seconds
WIFI_OFFLINE_THRESHOLD=900      # 15 minutes before recovery
WIFI_RECOVERY_WAIT=600          # 10 minutes between attempts
MAX_RECOVERY_ATTEMPTS=5         # 5 toggle attempts before reboot
```

### Web UI

Once deployed, access the control panel at `http://<device-ip>/` for volume control and device management.

## Branch workflow

This project uses [Versionist](https://github.com/product-os/versionist) for automated versioning.
All changes should go through feature branches and PRs — see [.versionbot/COMMIT_RULES.md](.versionbot/COMMIT_RULES.md) for commit message guidelines.

## Documentation

Head over to the [original docs](https://iotsound.github.io/) for detailed installation and usage instructions. Note some docs may reference older versions.

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
- WiFi Watchdog implementation by Claude (Anthropic)
- Modernization work by [@JaragonCR](https://github.com/JaragonCR) with assistance from Claude (Anthropic)