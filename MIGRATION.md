# Modernization Migration Notes

## Branch: modernize/audio-wrapper

### What changed

#### Replaced `balena-audio` npm package with `PulseAudioWrapper`

**File added:** `core/sound-supervisor/src/PulseAudioWrapper.ts`

The `balena-audio` package (v1.0.2) has not been updated in 4+ years and contains
unpatched security vulnerabilities. It was used solely to connect to the PulseAudio
TCP server on port 4317.

`PulseAudioWrapper` is a drop-in replacement that:
- Implements the same event-based API (`play`, `stop`, `connect`, `disconnect`, `ready`)
- Implements the same `setVolume(percent)` / `getVolume()` methods
- Uses `pactl` (already present in the audio container) and Node.js built-ins only
- Has zero new npm dependencies

**No changes to balenaCloud integration** — all `io.balena.features.*` labels,
the balena SDK, supervisor API, and cote fleet communication are untouched.

#### Node.js upgraded to 20 LTS

`core/sound-supervisor/Dockerfile.template` now targets Node 20, which is the
current LTS (supported until April 2026). Node 14 reached EOL in April 2023.

### How to test

1. Deploy to a test fleet in balenaCloud as normal (`git push balena master` or via the dashboard)
2. Check the `sound-supervisor` logs for:
   ```
   [PulseAudioWrapper] Connected to PulseAudio at <ip>:4317
   ```
3. Connect a Bluetooth/Airplay/Spotify source and verify playback events appear in logs
4. Test volume control via the sound supervisor API endpoint

### Rollback

If anything breaks, simply delete this branch and re-deploy from master.
The audio container and all plugins are completely unchanged.

### Next steps (future PRs)

- Fix remaining npm audit CVEs in sound-supervisor
- Update shairport-sync to latest version in airplay plugin
- Update librespot in spotify plugin
