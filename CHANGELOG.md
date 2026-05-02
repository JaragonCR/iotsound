# Changelog

All notable changes to this project will be documented in this file.
This project adheres to [Semantic Versioning](https://semver.org/).
Releases are automated by [Versionist](https://github.com/product-os/versionist).

# v4.7.0
## (2026-05-02)

* docs: add SECURITY.md with vulnerability reporting policy [JaragonCR]
* perf(multiroom): pre-warm containers for <500ms first-play latency [JaragonCR]

# v4.6.1
## (2026-05-02)

* fix(audit): post-Multiroom-2.0 cleanup — docs, stale vars, master override [JaragonCR]
* chore: delete root package-lock.json — no dependencies, pure noise [JaragonCR]
* chore: delete package-lock.json — npm install doesn't require it [JaragonCR]
* docs: remove airplay from pending — already on shairport-sync 5.0.4 [JaragonCR]

# v4.6.0
## (2026-05-02)

* chore: trigger versionist for Multiroom 2.0 commits [JaragonCR]
* docs: update README and MULTIROOM.md for v4.6.0 Multiroom 2.0 [JaragonCR]
* feat(ui): group selector with pinned default + known groups dropdown [JaragonCR]
* chore: rename default group from 'iotsound-default' to 'default' [JaragonCR]
* feat(ui): replace mode buttons with role selector + group name input [JaragonCR]
* chore(deps): remove cote — replaced by Avahi mDNS in Multiroom 2.0 [JaragonCR]
* feat(multiroom): optimistic master promotion + fix client backoff [JaragonCR]
* fix(audio): replace WirePlumber play-detect with pactl subscribe watcher [JaragonCR]
* debug(audio): log all WirePlumber links to identify node names [JaragonCR]
* fix(audio): switch play-detect to link-based WirePlumber events [JaragonCR]
* feat(multiroom-2): lazy AUTO election + 30s stop demotion [JaragonCR]
* fix(sound-supervisor): guard Object.entries against null config values [JaragonCR]
* feat(multiroom-2): Spike-4 master election + role-gated snapserver [JaragonCR]
* fix(startup): add pulseaudio-utils and reduce PA wait noise in multiroom-client [JaragonCR]
* fix(startup): replace /dev/tcp check with pactl info in multiroom-client [JaragonCR]
* fix(logs): remove noisy mdns-browse poll log [JaragonCR]
* fix(latency): reduce audio pipeline delay from ~3s to ~650ms [JaragonCR]
* fix(resilience): add PA readiness wait and restart guards to librespot and multiroom-server [JaragonCR]
* revert(multiroom-client): remove PULSE_LATENCY_MSEC=50 from snapclient [JaragonCR]
* fix(audio): remove PipeWire quantum cap — breaks plugin controls [JaragonCR]
* fix(audio): cap PipeWire quantum and snapclient output buffer at runtime [JaragonCR]
* revert(audio): restore loopback latencies and remove quantum cap [JaragonCR]
* fix(audio): cap PipeWire quantum and reduce loopback latency [JaragonCR]
* fix(multiroom-client): use /dev/tcp PA readiness check (pactl not installed) [JaragonCR]
* fix(multiroom): wait for PulseAudio ready + pacat watchdog [JaragonCR]
* fix(multiroom): replace avahi CLI with bonjour-service pure-Node mDNS [JaragonCR]
* feat(multiroom): Avahi advertisement + mDNS discovery + group volume sync (Spike-2+3) [JaragonCR]
* fix(multiroom): set pacat capture latency to 50ms [JaragonCR]
* feat(multiroom): dynamic snapcast buffer based on connected clients [JaragonCR]
* fix(multiroom): reduce snapcast latency to 400ms with PCM codec [JaragonCR]
* fix(multiroom-client): use --player pulse to bypass ALSA entirely [JaragonCR]
* fix(multiroom-server): capture via pacat FIFO instead of ALSA-Pulse [JaragonCR]
* fix(multiroom): use explicit PCM definitions with server/device in asound.conf [JaragonCR]
* fix(multiroom): match snapserver sample rate to PipeWire default (48000Hz) [JaragonCR]
* fix(multiroom): configure ALSA pulse PCM so snapcast uses PulseAudio [JaragonCR]
* fix(multiroom): override PULSE_SERVER to gateway IP at runtime [JaragonCR]
* fix(sound-supervisor): restore GET /mode and GET /multiroom/master [JaragonCR]
* debug(audio): watch Stream/Output/Audio nodes for play detection [JaragonCR]
* debug(audio): log all WirePlumber node names to find balena-sound.input [JaragonCR]
* fix(audio): move play-detect script to WirePlumber data dir [JaragonCR]
* fix(audio): port WirePlumber play-detect to 0.5 conf+script format [JaragonCR]
* chore(audio): use print() in play-detect lua and quiet wireplumber [JaragonCR]
* chore(audio): lower wireplumber debug level and log config dirs [JaragonCR]
* chore(audio): log wireplumber version and enable debug output [JaragonCR]
* chore(audio): pipe wireplumber logs to container stdout [JaragonCR]
* chore(audio): bust docker cache to force start.sh rebuild [JaragonCR]
* fix(librespot): add missing flac runtime library [JaragonCR]
* feat(multiroom-2): role system + WirePlumber play-detect spike [JaragonCR]
* chore: ignore CLAUDE.md and .claude/ session files [JaragonCR]
* fix(librespot): add missing runtime libs and drop ALSA bridge [JaragonCR]

# v4.5.0
## (2026-04-28)

* fix(audio): add eudev and start udevd for WirePlumber ALSA discovery [JaragonCR]
* feat(deps): Wave 4 — drop balenalib from audio block [JaragonCR]
* fix(compose): align restart policies with service ownership model [JaragonCR]
* fix: correct service names in mode switch (spotify→librespot, drop upnp) [JaragonCR]
* fix: apply current mode on startup to recover stopped services [JaragonCR]
* fix(ts): widen safeService type to Promise<unknown> [JaragonCR]
* fix: harden bluetooth and airplay autostart after reboot [JaragonCR]
* fix: setMode crash, mode persistence, and librespot YAML injection [JaragonCR]
* fix(airplay): fix backend name pa→pulseaudio for shairport-sync 5.x [JaragonCR]
* feat(deps): bump airplay to shairport-sync 5.0.4, drop ALSA bridge [JaragonCR]
* fix(bluetooth): add bash and remove balenalib entrypoint call [JaragonCR]
* feat(config): default SOUND_MODE to STANDALONE for all devices [JaragonCR]
* fix(deps): add libboost-dev and libexpat1-dev to snapcast builder [JaragonCR]
* fix(deps): add ca-certificates to snapcast builder stage [JaragonCR]
* feat(deps): Wave 3B — build snapcast from source at pinned tag [JaragonCR]
* feat(deps): Wave 3A — drop balenalib from watchdog and bluetooth [JaragonCR]
* feat(ui): add multiroom on/off toggle to sound-supervisor web UI [JaragonCR]
* docs(multiroom): clarify whole-house broadcast behavior and zone control [JaragonCR]
* docs: add MULTIROOM.md — architecture, usage, and future direction [JaragonCR]
* fix(deps): add iproute2 to multiroom images for ip route lookup [JaragonCR]
* feat(deps): Wave 2 — replace private multiroom registry with Debian packages [JaragonCR]
* feat(deps): Wave 1 — drop Buster EOL and pin hostname base image [JaragonCR]

# v4.4.0
## (2026-04-25)

* docs: expand fleet variables reference to full 40+ var coverage [JaragonCR]
* feat(deps): migrate sound-supervisor to node:24-bookworm-slim [JaragonCR]

# v4.3.0
## (2026-04-24)

* feat(deps): upgrade balena-sdk 15→23, fix uuid vuln, fix PA hang [JaragonCR]

# v4.2.9
## (2026-04-22)

* chore(deps): annotate dependency bump as patch [github-actions[bot]]
* fix(ci): fix YAML/shellcheck error in annotate-dependabot workflow [JaragonCR]
* feat(ci): add workflow to annotate Dependabot PRs with Change-type: patch [JaragonCR]

# v4.2.8
## (2026-04-22)

* fix(ci): make Dependabot patch detection robust against versionist field names [JaragonCR]

# v4.2.7
## (2026-04-22)

* fix(ci): restore clean flowzone.yml — remove pull_request_target [JaragonCR]

# v4.2.6
## (2026-04-22)

* fix(ci): use branch prefix instead of actor to detect Dependabot [JaragonCR]
* fix(ci): use pull_request_target for Dependabot to access secrets [JaragonCR]

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
