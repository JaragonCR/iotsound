# Changelog

All notable changes to this project will be documented in this file.
This project adheres to [Semantic Versioning](https://semver.org/).
Releases are automated by [Versionist](https://github.com/product-os/versionist).

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
