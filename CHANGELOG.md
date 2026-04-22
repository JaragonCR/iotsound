# Changelog

All notable changes to this project will be documented in this file.
This project adheres to [Semantic Versioning](https://semver.org/).
Releases are automated by [Versionist](https://github.com/product-os/versionist).

# v4.2.5
## (2026-04-22)

* fix(versionist): scan commit body for Change-type as footer fallback [JaragonCR]

# v4.2.4
## (2026-04-22)

* fix(sound-supervisor): replace hardcoded sink indexes in setMode() [JaragonCR]
* fix(sound-supervisor): add name-based sink lookup to PulseAudioWrapper [JaragonCR]
* fix(sound-supervisor): consolidate balena SDK into single BalenaClient [JaragonCR]
* fix(sound-supervisor): remove orphaned dependencies [JaragonCR]
* fix(balena): add raspberrypi5 to supportedDeviceTypes [JaragonCR]
* fix(audio): correct phase numbering in start.sh log sections [JaragonCR]
* fix(sound-supervisor): replace deprecated npm install --production [JaragonCR]
* fix(watchdog): switch to balenalib base image, drop unused packages [JaragonCR]
* fix(librespot): quote all string values in generated YAML config [JaragonCR]
* fix(airplay): vendor alsa-bridge script instead of curl | sh [JaragonCR]
* fix(librespot): pin alpine to 3.21 and vendor alsa-bridge script [JaragonCR]

# v4.2.3
## (2026-03-30)

* fix(ci): pass secrets to Flowzone with inherit [JaragonCR]

# v4.2.2
## (2026-03-30)

* fix(bluetooth): modernize agent entrypoint, fix re-pairing and restart loop [JaragonCR]

# v4.2.1
## (2026-03-03)

* fix: Add hardware audio device detection and microphone filtering [JaragonCR]

# v4.2.0
## (2026-03-03)

* feature: Hardware audio device detection with microphone filtering [JaragonCR]

# v4.1.0
## (2026-03-03)

* minor: Add WiFi watchdog service for automatic recovery [JaragonCR]

# v4.0.4
## (2026-03-03)

* patch: improve audio service initialization sequencing [JaragonCR]
* patch: improve audio service initialization sequencing [JaragonCR]
* patch: improve audio service initialization sequencing [JaragonCR]
* patch: improve audio service initialization sequencing [JaragonCR]
* patch: improve audio service initialization sequencing [JaragonCR]
* patch: improve audio service initialization sequencing [JaragonCR]

# v4.0.3
## (2026-03-03)

* patch: implement robust sink detection and fix variable expansion [JaragonCR]

# v4.0.2
## (2026-03-03)

* patch: ensure audio service starts on pipewire by checking for config files [JaragonCR]

# v4.0.1
## (2026-03-03)

* fix: validate PipeWire sink name before writing to pa config [JaragonCR]
* fix: pass FLOWZONE_TOKEN explicitly to flowzone reusable workflow [JaragonCR]
* docs: test Versionist integration [JaragonCR]
* docs: test Versionist integration [JaragonCR]
* feat: add versionist.conf.js to sync balena.yml and VERSION on release [JaragonCR]
* fix: add root package.json for Versionist version tracking [JaragonCR]

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
