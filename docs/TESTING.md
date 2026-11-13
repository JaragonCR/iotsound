# Testing

## v5.0 Validation Matrix

This document records what was manually validated for the v5.0 release and calls out known gaps where community help is needed.

### Hardware tested

| Device | Role | Notes |
|---|---|---|
| Raspberry Pi 4 (raspberrypi4-64) | Master + client (AUTO) | Primary test device — wispy-road |
| Raspberry Pi 3 B/B+ (raspberrypi3-64) | Remote client (AUTO) | Coolbeans — 2.4 GHz WiFi |

### Audio outputs tested

| Output | Device | Result |
|---|---|---|
| DAC HAT (I2S) | Raspberry Pi 4 | ✔ Confirmed working |
| 3.5mm headphone jack | Raspberry Pi 3 B/B+ | ✔ Confirmed working |
| HDMI | — | ✘ Not tested in this release |
| USB sound card / USB DAC | — | ✘ Not tested in this release |

### Audio sources tested

| Source | Result | Notes |
|---|---|---|
| Spotify Connect (librespot) | ✔ Confirmed working | Both devices visible and selectable |
| AirPlay | — | Service present, not validated in this sprint |
| Bluetooth | — | Service present, not validated in this sprint |

### Multi-room scenarios tested

| Scenario | Result | Notes |
|---|---|---|
| Pi 4 master + Pi 3 B/B+ client | ✔ Confirmed working | mDNS discovery, dynamic election, audio sync |
| Volume sync across devices | ✔ Confirmed working | |
| 30s demotion after stream stops | ✔ Confirmed working | |
| Per-device snapclient latency | Superseded | Since direct-to-hardware output, latency is compensated automatically; `SOUND_MULTIROOM_LATENCY` defaults to `0`. |
| 2+ clients simultaneously | ✘ Not tested | Only 1 client available during validation |
| Pi 3 B/B+ as master | ✘ Not tested | Known BT/WiFi interference risk; Pi 4 preferred for master |
| Multiple groups on the same network | ✘ Not tested | |
| Cross-VLAN with `SOUND_MULTIROOM_MASTER` override | ✘ Not tested | Code path exists, not validated |

### Network conditions tested

| Condition | Result | Notes |
|---|---|---|
| 2.4 GHz + WiFi 6 on same subnet | ✔ Confirmed working | mDNS inter-band confirmed after WPA2 config |
| Ethernet | ✘ Not tested | |
| WPA3 / PMF disabled for Pi 3 | ✔ Recommended workaround confirmed needed | See [support docs](./07-support.md#avoid-wpa3--pmf-on-24-ghz) |

### Karaoke plugin

Karaoke is included in v5.0 but hardware validation is incomplete — see open items in `docs/archive/KARAOKE_WORKING_PROMPT.md`. Treat it as **beta** for this release.

---

## v5.2 validation (November 2026)

Same two devices: Raspberry Pi 4 with a DAC HAT, Raspberry Pi 3 on the 3.5mm jack, both on Wi‑Fi.

| Area | Result | Notes |
|---|---|---|
| Spotify Connect, go-librespot | ✔ Confirmed by ear | Both speakers, master moves when you switch device |
| Spotify Connect, Soloist (lossless) | ✔ Confirmed by ear | `codec: flac` in the logs, multiroom follows it, auto-update installed a new build |
| Soloist takeover from a second account | ✘ Not tested | |
| Master heartbeat and quiet-master check | ✔ Confirmed on devices | Speakers join within 10 s; no false "Master gone" on lossy Wi‑Fi |
| Routing recovery after `audio` starts before the supervisor | ✔ Forced 6 times | Route restored, Spotify restarted |
| `pcm` stream codec on the Pi 3 | ✔ Confirmed on devices | Stops the once-a-minute snapclient crash seen with `flac` |
| Mid-song dropouts on all speakers | ✔ Fixed and re-tested under forced SD card load | snapserver state moved to RAM |
| Soloist cache in RAM (Pi 4) | ✔ Confirmed on device | Disk cache removed, tmpfs in use |
| Alpine 3.24 / PipeWire 1.6.8 / WirePlumber 0.5.15 | ✔ Spotify by ear; other sources not yet | |
| AirPlay (shairport-sync 5.6.3) | ✘ Not re-tested after the bump | Worked on 5.2.2.2 with both speakers selected |
| Bluetooth (BlueZ 5.86) | ✘ Not re-tested after the bump | |
| Karaoke playback (new SQLite driver) | ✘ Web UI loads; playback not re-tested | |

---

## Help wanted

We only have two devices available for testing. If you can validate IoTSound on any of the untested hardware or scenarios above, please comment on [this issue](https://github.com/JaragonCR/iotsound/issues) with your findings.

We are specifically looking for validation on:

- Raspberry Pi 5
- Raspberry Pi 1 / Zero / Zero W (client role)
- Raspberry Pi 2
- Intel NUC
- USB sound cards and USB DACs
- HDMI audio output on Pi 4 and Pi 5
- AirPlay and Bluetooth source validation in v5.0
- Multi-client multi-room (3+ devices)
- Ethernet-only setups
- Multiple groups on the same network

If you are willing to send hardware for validation, please reach out via a GitHub issue — we will test, document, and return it.
