#!/usr/bin/env bash
# =============================================================================
# IoTSound - Versionist setup, README update, and major version squash
# =============================================================================

set -e

echo ""
echo "============================================="
echo " IoTSound - Versionist + v4.0.0 Setup"
echo "============================================="
echo ""

# --- Sanity check ---
if [ ! -f "balena.yml" ]; then
  echo "ERROR: Run from the root of the iotsound repo."
  exit 1
fi

# =============================================================================
# STEP 1: Create .github/workflows/flowzone.yml
# =============================================================================
echo ">> Setting up Flowzone / Versionist workflow..."

mkdir -p .github/workflows

cat > .github/workflows/flowzone.yml << 'EOF'
name: Flowzone
on:
  pull_request:
    types: [opened, synchronize, closed]
    branches:
      - "main"
      - "master"
jobs:
  flowzone:
    name: Flowzone
    uses: product-os/flowzone/.github/workflows/flowzone.yml@master
    secrets: inherit
EOF

echo "   ✓ .github/workflows/flowzone.yml created"

# =============================================================================
# STEP 2: Create .versionbot/COMMIT_RULES.md
# =============================================================================
echo ">> Setting up Versionbot commit rules..."

mkdir -p .versionbot

cat > .versionbot/COMMIT_RULES.md << 'EOF'
# Commit Message Guidelines

This project uses [Versionist](https://github.com/product-os/versionist) to automatically
generate changelogs and bump versions based on commit messages.

## Format

Every commit that should trigger a version bump must include a `Change-type` footer:

```
<type>: <short description>

<optional longer description>

Change-type: patch | minor | major
```

## Change types

| Type | When to use | Version bump |
|---|---|---|
| `patch` | Bug fixes, dependency updates, documentation | 4.0.0 → 4.0.1 |
| `minor` | New features, backward-compatible improvements | 4.0.0 → 4.1.0 |
| `major` | Breaking changes, major rewrites | 4.0.0 → 5.0.0 |

## Examples

```
fix: correct PulseAudio sink name for HiFiBerry DAC

Change-type: patch
```

```
feat: add karaoke support via pitube-karaoke

Change-type: minor
```

## Branches

- All work should be done on feature branches
- PRs merged to master trigger Versionist
- Versionist opens a version bump PR automatically
- Merge the version bump PR to create a tagged release
EOF

echo "   ✓ .versionbot/COMMIT_RULES.md created"

# =============================================================================
# STEP 3: Update balena.yml to v4.0.0
# =============================================================================
echo ">> Updating balena.yml to v4.0.0..."

cat > balena.yml << 'EOF'
name: IoTSound
type: sw.application
description: >-
  Build a single or multi-room streamer for an existing audio device using a
  Raspberry Pi! Supports Bluetooth, Airplay2 and Spotify Connect
fleetcta: Sounds good
post-provisioning: >-
  ## Usage instructions
assets:
  repository:
    type: blob.asset
    data:
      url: 'https://github.com/JaragonCR/iotsound'
  logo:
    type: blob.asset
    data:
      url: >-
        https://raw.githubusercontent.com/iotsound/iotsound/master/logo.png
data:
  applicationEnvironmentVariables:
    - SOUND_VOLUME: 75
    - AUDIO_OUTPUT: AUTO
  defaultDeviceType: raspberry-pi
  supportedDeviceTypes:
    - raspberry-pi
    - raspberry-pi2
    - raspberrypi3
    - raspberrypi3-64
    - raspberrypi4-64
    - fincm3
    - intel-nuc
version: 4.0.0
EOF

echo "   ✓ balena.yml updated to v4.0.0"

# =============================================================================
# STEP 4: Write VERSION file
# =============================================================================
echo ">> Writing VERSION file..."
echo "4.0.0" > VERSION
echo "   ✓ VERSION file created"

# =============================================================================
# STEP 5: Write updated README.md
# =============================================================================
echo ">> Writing updated README.md..."

cat > README.md << 'EOF'
# IoTSound (JaragonCR Fork) — v4.0.0

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
- Modernization work by [@JaragonCR](https://github.com/JaragonCR) with assistance from Claude (Anthropic)
EOF

echo "   ✓ README.md updated"

# =============================================================================
# STEP 6: Write CHANGELOG.md
# =============================================================================
echo ">> Writing CHANGELOG.md..."

cat > CHANGELOG.md << 'EOF'
# Changelog

All notable changes to this project will be documented in this file.
This project adheres to [Semantic Versioning](https://semver.org/).
Releases are automated by [Versionist](https://github.com/product-os/versionist).

## 4.0.0 - 2026-03-02

### Major modernization of IoTSound fork

* Replace PulseAudio 15 with PipeWire + WirePlumber on Alpine 3.21
* Replace abandoned balena-audio npm package with PulseAudioWrapper
* Replace librespot with go-librespot for Spotify Connect
* Upgrade Node.js 14 → 20 LTS
* Upgrade TypeScript 3.9.7 → 5.4.5, tsconfig target ES2022
* Fix 13 CVEs via Dependabot (axios, express, async, lodash, js-yaml, braces, socket.io-parser and more)
* Fix hostname variable resolution (Day 1 issue)
* Modernize bluetooth plugin: vendor bluetooth-agent, upgrade Python 3.8 → 3.12
* Remove git clone at build time pattern from bluetooth container
* Add Versionist / Flowzone integration for automated versioning
* Add COMMIT_RULES.md for contribution guidelines
EOF

echo "   ✓ CHANGELOG.md written"

# =============================================================================
# STEP 7: Squash all commits and create v4.0.0
# =============================================================================
echo ""
echo ">> Squashing all commits into v4.0.0..."

git fetch upstream 2>/dev/null || true

# Soft reset to upstream
git reset --soft upstream/master

# Stage everything
git add -A

git commit -m "feat: IoTSound fork v4.0.0 - major modernization

Complete modernization of the IoTSound fork from the upstream v3.30.0 base.

Audio stack:
- Replace PulseAudio 15 with PipeWire + WirePlumber on Alpine 3.21
- pipewire-pulse provides drop-in TCP 4317 backward compatibility
- Replace abandoned balena-audio npm with PulseAudioWrapper (pure pactl)

Streaming:
- Replace librespot with go-librespot for better Spotify Connect stability

Sound supervisor:
- Node.js 14 → 20 LTS
- TypeScript 3.9.7 → 5.4.5, tsconfig target ES2022
- Fix 13 CVEs (axios, express, async, lodash, js-yaml, braces, socket.io-parser)

Bluetooth:
- Vendor bluetooth-agent directly, remove git clone at build time
- Python 3.8 → 3.12
- Wipe paired devices on startup for fresh connections
- Fix RECONNECT_MAX_RETRIES int() cast bug

Infrastructure:
- Fix hostname variable resolution (Day 1 balena docker-compose issue)
- Add Flowzone / Versionist for automated semantic versioning
- Add COMMIT_RULES.md for contribution guidelines
- Clean up logging across all containers

Change-type: major"

echo "   ✓ Squashed into single v4.0.0 commit"

# =============================================================================
# STEP 8: Force push
# =============================================================================
echo ""
echo ">> Force pushing to origin..."
git push origin master --force-with-lease

echo ""
echo "============================================="
echo " ✅ Done! IoTSound v4.0.0 is live."
echo "============================================="
echo ""
echo " Next steps:"
echo "   1. Go to GitHub → create a Release tagged v4.0.0"
echo "   2. All future work → feature branches + PRs"
echo "   3. Versionist will auto-bump versions on merge"
echo ""