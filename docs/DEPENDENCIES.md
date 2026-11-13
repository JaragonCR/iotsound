# Dependencies

Generated from `dependencies.json` by `python3 scripts/check-deps.py --write`. Do not edit by hand.

Every external piece of software IoTSound builds on, the version we pin, and every file that pins it.
Run `python3 scripts/check-deps.py` to compare the pins with upstream; every PR does this (see `AGENTS.md`).

| Dependency | Kind | Pinned | Where used | Notes |
| --- | --- | --- | --- | --- |
| Alpine Linux | base image | 3.24 | `core/audio/Dockerfile.template`<br>`core/hostname/Dockerfile.template`<br>`plugins/bluetooth/Dockerfile.template` | Carries PipeWire, WirePlumber, BlueZ and bluez-alsa (apk, unpinned: they move with the Alpine release). A bump changes the audio stack: full audio regression on both device types. |
| Debian | base image | trixie | `core/multiroom/server/Dockerfile.template`<br>`core/multiroom/client/Dockerfile.template`<br>`plugins/karaoke/app/Dockerfile.template`<br>`plugins/upnp/Dockerfile.template`<br>`plugins/librespot/Dockerfile.template` | Named release (trixie = 13). Soloist needs glibc 2.38 or newer. ffmpeg, libpulse and the Snapcast runtime libraries come from apt, unpinned. Node and Go image tags carry the same release name: move them together. |
| Node.js | base image | 26 | `core/sound-supervisor/Dockerfile.template` | Use even (LTS) majors only. Keep @types/node on the same major. |
| npm | build tool | 12.2.2 | `core/sound-supervisor/Dockerfile.template` | Build stage only. |
| Python | base image | 3.15 | `core/watchdog/Dockerfile.template` | wifi-watchdog only, standard library. |
| Go toolchain | base image | 1.27 | `plugins/karaoke/app/Dockerfile.template`<br>`plugins/librespot/Dockerfile.template` | Builds the karaoke app and go-librespot. go-librespot's go.mod sets the minimum. |
| Snapcast | built from source | 0.35.0 | `core/multiroom/server/Dockerfile.template`<br>`core/multiroom/client/Dockerfile.template` | Server and client must be the same version. Multiroom regression on both devices. |
| shairport-sync | base image | 5.6.3 | `plugins/airplay/Dockerfile.template` | AirPlay 2. Bundles NQPTP. Test AirPlay from an Apple device, single speaker and multiroom. |
| go-librespot | built from source | 2026-11-11 | `plugins/librespot/Dockerfile.template` | Floating on purpose: built from upstream master because Spotify changes its protocol. The pin is only a cache-bust date; bump it to pull a new build. |
| Spotify Soloist | downloaded at runtime | floating | `plugins/librespot/soloist-engine.sh` | Never in the image. Self-updates from Spotify's CDN every 6 hours while idle; builds expire after 90 days. |
| yt-dlp | pip, unpinned | floating | `plugins/karaoke/app/Dockerfile.template` | Floating on purpose: latest at build time, and the container self-updates every 24 hours. |
| modernc.org/sqlite | Go module | 1.62.0 | `plugins/karaoke/app/go.mod` | Karaoke queue database. Update with go get and go mod tidy, then test the queue survives a restart. |
| axios | npm | 1.21.1 | `core/sound-supervisor/package-lock.json`<br>`core/sound-supervisor/package.json` | Pinned column is the locked version; package.json holds the range. |
| balena-sdk | npm | 23.2.24 | `core/sound-supervisor/package-lock.json`<br>`core/sound-supervisor/package.json` | Pulls most of the transitive tree; the 'overrides' block in package.json exists because of it. Re-check each override on every bump and drop the ones no longer needed. Pinned column is the locked version; package.json holds the range. |
| express | npm | 5.3.0 | `core/sound-supervisor/package-lock.json`<br>`core/sound-supervisor/package.json` | Pinned column is the locked version; package.json holds the range. |
| TypeScript | npm (dev) | 7.0.2 | `core/sound-supervisor/package-lock.json`<br>`core/sound-supervisor/package.json` | Build only. A new major can need tsconfig or source changes. Pinned column is the locked version; package.json holds the range. |
| support-toolkit | image, unpinned | floating | `docker-compose.yml` | Debug container, only runs with LOG_LEVEL=debug. Third-party image on the latest tag. |
| Flowzone | CI workflow | floating | `.github/workflows/flowzone.yml` | Tracks @master, so it updates itself. |
| balenaOS and Supervisor | host | floating | balenaCloud fleet, not in the repo | Updated per device from the dashboard. Check for a host OS update when a PR touches audio devices, WiFi or boot config. |

OS packages installed with `apk` or `apt` are not pinned: they follow the base image release in the first rows.
Transitive npm packages are locked in `core/sound-supervisor/package-lock.json`.
