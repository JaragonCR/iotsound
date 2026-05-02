# Multi-Room Audio (v4.6.0+)

IoTSound turns multiple Raspberry Pis into a perfectly-synchronized whole-home audio system using Snapcast for audio delivery and mDNS (Bonjour) for automatic device discovery.

> **Multiroom is a group broadcast, not a zone selector.** All devices in the same group play the same audio simultaneously. For independent playback, set `SOUND_MULTIROOM_ROLE=disabled`.

---

## How it works

### Audio pipeline

```
Bluetooth / AirPlay / Spotify / UPnP
            │
            ▼
    PipeWire (audio block, TCP :4317)
     sink: balena-sound.input
            │
            │  pacat (capture, 50ms latency)
            ▼
    snapserver (port 1704)
            │
            │  TCP :1704 (Snapcast binary protocol, timestamped chunks)
            ▼
    snapclient (on every device in the group)
            │
            ▼
    balena-sound.output → speakers
```

Snapcast delivers **sample-accurate synchronisation** by timestamping every audio chunk and buffering at the client side to absorb network jitter.

### Play-triggered master election

There is no permanent master device. IoTSound uses **optimistic instant promotion**:

1. You stream to any device (Bluetooth, AirPlay, Spotify, etc.)
2. The audio block detects audio on `balena-sound.input` via `pactl subscribe`
3. That device **immediately** promotes itself to master — starts snapserver, advertises via mDNS (`_snapcast._tcp`)
4. All other devices in the same group discover the master and connect their snapclient
5. All devices sync within a few seconds and play the same audio

When you stop playing for 30 seconds, the master releases its role — snapserver and snapclient both stop, and the device returns to idle. The next play event promotes it instantly again.

Collision (two devices promoted simultaneously) is handled by Snapcast conflict resolution and is rare in practice.

### Groups

Devices with the same `SOUND_GROUP_NAME` form a group and sync together. Devices with different group names are independent and can play different audio on the same network. Group names are discovered via mDNS and shown in the web UI dropdown.

---

## Roles

Set `SOUND_MULTIROOM_ROLE` on each device (or change it live from the web UI):

| Role | Streaming plugins | Joins multiroom | Becomes master |
|---|---|---|---|
| `auto` (default) | ✅ Bluetooth, AirPlay, Spotify | ✅ | ✅ On first play |
| `host` | ✅ | ✅ | ✅ Always |
| `join` | ❌ Stopped | ✅ | ❌ Never |
| `disabled` | ✅ | ❌ | ❌ Never |

- **auto** — best for most devices. Idles at boot; promotes to master the moment you start streaming to it.
- **host** — dedicated server device. Always runs snapserver. Use for a Pi with a reliable wired connection that you always want as the source.
- **join** — passive receiver. No Bluetooth/AirPlay/Spotify — invisible to streaming apps. Use for speakers in secondary rooms that should only receive audio from the group master.
- **disabled** — fully standalone. All streaming plugins active, no Snapcast at all. Use when a room should never participate in whole-home audio.

You can change role and group name live from the web UI at `http://<device-ip>/`. Changes are persisted to `SOUND_MULTIROOM_ROLE` and `SOUND_GROUP_NAME` device variables.

---

## Setup

### 1. Hardware

All devices must be on the same subnet — mDNS is link-local and does not cross router boundaries. For VLAN setups, configure an mDNS reflector (e.g. Avahi daemon or UniFi's mDNS service).

### 2. Configure

For a basic fleet with automatic behaviour: leave `SOUND_MULTIROOM_ROLE` unset (defaults to `auto`) and `SOUND_GROUP_NAME` unset (defaults to `default`). No further configuration needed.

For separate groups (e.g. upstairs / downstairs):

```
# On all upstairs devices:
SOUND_GROUP_NAME = upstairs

# On all downstairs devices:
SOUND_GROUP_NAME = downstairs
```

### 3. Stream

Start playing audio to any device. After a few seconds all other devices in the same group will sync and play the same audio.

---

## Advanced configuration

### Force a dedicated master (host role)

If you want a specific device to always serve audio — for example, the Pi directly connected to your amp:

```
SOUND_MULTIROOM_ROLE = host
```

The host device runs snapserver at all times regardless of whether audio is playing.

### Standalone (disabled role)

For a device that should always play independently:

```
SOUND_MULTIROOM_ROLE = disabled
```

All streaming plugins remain active. Only Snapcast is not started.

### Override master IP

If mDNS discovery doesn't work on your network (strict managed switches, VLANs without a reflector):

```
SOUND_MULTIROOM_MASTER = 192.168.1.100
```

This pins all snapclients to the specified IP and bypasses mDNS entirely.

### Latency tuning

If speakers are noticeably out of sync, increase the group buffer:

```
SOUND_GROUP_LATENCY = 600   # milliseconds (default: 400)
```

For per-device fine-tuning (e.g. a device with a slow DAC):

```
SOUND_MULTIROOM_LATENCY = 100   # milliseconds, added on top of group latency
```

---

## Troubleshooting

**Devices don't sync after streaming starts**
- Wait up to 10 seconds — mDNS discovery can take a moment on first connection
- Confirm `SOUND_GROUP_NAME` is the same on all devices you expect to sync
- Ensure all devices are on the same subnet (no VLAN separation without a reflector)

**Only some devices sync**
- Check that `SOUND_MULTIROOM_ROLE` is not `disabled` or `join` on devices that should auto-promote
- mDNS is link-local — it will not cross routed subnet boundaries

**Audio drops or stutters on clients**
- Increase `SOUND_GROUP_LATENCY` (try 600–800ms)
- Use wired Ethernet on the master device if possible

**A device stopped syncing after a reboot**
- With `auto` role, a device rejoins automatically the next time audio plays — no action needed
- If it stays disconnected, check sound-supervisor logs for mDNS or election errors

**Group name not showing in the web UI dropdown**
- The dropdown populates from groups discovered via mDNS in the last 7 days
- If the group is new, it appears after the first device in that group starts playing
