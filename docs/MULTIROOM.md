# Multi-Room Audio

IoTSound turns multiple Raspberry Pis into a perfectly-synchronized whole-home audio system — similar to Sonos, but open source and self-hosted.

---

## How it works

Every device runs two Snapcast services:
- **snapserver** — receives audio from the audio block and broadcasts it over the local network
- **snapclient** — receives the audio stream from the active master and plays it through the local speaker

The key property of Snapcast is **sample-accurate synchronisation**: all clients play the exact same audio frame at the exact same moment, regardless of how many devices are on the network. It achieves this by timestamping every audio chunk and buffering at the client side to compensate for network jitter.

### The master election

IoTSound uses **play-triggered auto-election**. There is no permanent master device. The device that has audio playing right now is the master:

1. You start streaming to any device (via Bluetooth, AirPlay, Spotify, etc.)
2. That device's audio block detects audio on the `balena-sound.input` sink
3. sound-supervisor broadcasts `fleet-update: master = <this device's IP>` to all devices on the local network via UDP (using the `cote` pub/sub library)
4. Every other device receives the update and restarts its snapclient pointing to the new master
5. All devices sync up within a few seconds and play the same audio

To switch which device is playing, just start streaming to a different device. It announces itself as the new master and all snapclients follow automatically.

```
You → Spotify → Device A (master)
                    │
                    │  fleet-update broadcast (UDP)
                    ▼
              Device B (client)   ─┐
              Device C (client)   ─┤── all play in sync via Snapcast TCP stream
              Device D (client)   ─┘
```

---

## Setup (current)

### 1. Hardware

Connect all devices to your network. They need to be on the **same subnet** — UDP broadcast does not cross router boundaries.

### 2. Fleet mode

By default, devices capable of running snapserver will start in `MULTI_ROOM` mode. You can verify or override this with the `SOUND_MODE` fleet variable:

| Value | Meaning |
|-------|---------|
| `MULTI_ROOM` | Runs both snapserver and snapclient. Can be master or client. |
| `MULTI_ROOM_CLIENT` | Runs only snapclient. Never becomes master. Saves resources on weak devices. |
| `STANDALONE` | Disables multiroom entirely. Device plays independently. |

Leave `SOUND_MODE` unset on all devices for fully automatic behaviour.

### 3. Stream

Start playing audio to any device. After a few seconds all other devices in `MULTI_ROOM` or `MULTI_ROOM_CLIENT` mode will sync and play the same audio.

That's it — no additional setup required.

---

## Advanced configuration

### Force a fixed master

If you always want a specific device to be the master (e.g. your most powerful Pi), set on that device:

```
SOUND_MULTIROOM_MASTER = <IP address of the master device>
```

This pins all snapclients to that IP and prevents automatic master switching.

### Lock master switching

To prevent a device from switching masters when a different device starts playing:

```
SOUND_MULTIROOM_DISALLOW_UPDATES = 1
```

Useful when you want a dedicated server device that never repoints to another master.

### Latency tuning

If speakers across devices are noticeably out of sync, tune per-device with:

```
SOUND_MULTIROOM_LATENCY = 100   # milliseconds
```

Increase this value on a device whose audio arrives early (you hear it before the others).

### Blacklisted device types

Raspberry Pi 1 and 2 cannot run snapserver due to CPU constraints. These devices automatically start in `MULTI_ROOM_CLIENT` mode even if `SOUND_MODE` is unset.

---

## Troubleshooting

**Devices don't sync after streaming starts**
- Wait 10–15 seconds the first time — cote needs a few seconds to establish UDP connections
- Reboot the master device to force it to re-announce itself

**Only some devices sync**
- Ensure all devices are on the same subnet (same router, no VLAN separation)
- Check that UDP broadcast is not blocked by a firewall or managed switch

**Audio drops or stutters on clients**
- Increase `SOUND_MULTIROOM_LATENCY` on the affected device
- Use a wired network connection for the master device if possible

---

## Under the hood: what actually happens technically

```
Audio source (Bluetooth/AirPlay/Spotify/etc.)
        │
        ▼
PipeWire (audio block, TCP :4317)
  sink: balena-sound.input
        │
        │  ALSA bridge (libpulse0 + libasound2-plugins)
        ▼
snapserver reads stream = alsa://?device=pulse
        │
        │  TCP :1704  (Snapcast binary protocol, timestamped chunks)
        ▼
snapclient (on every device)
        │
        │  ALSA bridge → libpulse0 → PipeWire
        ▼
  sink: balena-sound.output → hardware
```

The cote pub/sub layer runs parallel to this on UDP, purely for the master election. It does not carry audio.

---

## Future: Simplified multiroom (planned)

> This section describes the direction we are heading, not what is shipped today.

The current mode system (STANDALONE / MULTI\_ROOM / MULTI\_ROOM\_CLIENT) and cote-based election are a workaround for the fact that Snapcast has had built-in mDNS/Avahi discovery since v0.24. The planned simplification removes the workaround entirely.

### What changes

| Today | Future |
|-------|--------|
| Three modes (STANDALONE, MULTI\_ROOM, MULTI\_ROOM\_CLIENT) | No modes — every device always runs both server and client |
| cote pub/sub UDP election | Snapcast mDNS (Avahi) — snapserver advertises itself, snapclient discovers it automatically |
| sound-supervisor restarts snapclient with new `--host` flag | snapclient auto-switches via mDNS when a new server is active |
| ALSA bridge (libpulse0 + libasound2-plugins) | PipeWire native pipe: `stream = pipe:///tmp/snapfifo` |
| Snapcast 0.26.0 | Snapcast latest (built from source at pinned tag) |

### How you'd use it (future)

1. Flash your devices — no mode configuration needed
2. Start streaming to any device
3. All other devices automatically discover and sync

Switching masters works the same way: start streaming to a different device. The previous server goes idle, the new one advertises via mDNS, clients switch automatically.

The `SOUND_MODE`, `SOUND_MULTIROOM_MASTER`, and `SOUND_MULTIROOM_DISALLOW_UPDATES` variables would be removed. The only remaining variable is `SOUND_MULTIROOM_LATENCY` for per-device latency tuning.

### Why PipeWire pipe instead of ALSA bridge

The audio block already runs PipeWire natively. The ALSA bridge (libpulse0 + libasound2-plugins) is a translation layer that makes snapserver think it's talking to PulseAudio over ALSA — when it's actually going through three layers to reach PipeWire. The pipe approach is direct:

```
PipeWire pipe-sink → /tmp/snapfifo → snapserver reads pipe source
```

Zero ALSA, zero libpulse. The multiroom containers become thin wrappers around the snapcast binaries.

### References

- Original PR exploring this simplification: [iotsound#541](https://github.com/iotsound/iotsound/pull/541)
- Original developer's vision for PipeWire + mode simplification: [iotsound#689](https://github.com/iotsound/iotsound/issues/689)
- Snapcast mDNS documentation: [badaix/snapcast](https://github.com/badaix/snapcast)
