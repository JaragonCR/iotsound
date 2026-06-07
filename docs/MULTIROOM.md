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
            ▼
     sink: snapcast
            │
            │  pacat records snapcast.monitor
            ▼
    snapserver (port 1704)
            │
            │  TCP :1704 (Snapcast binary protocol, timestamped chunks)
            ▼
    snapclient (on every device in the group, including the master)
            │
            ▼
    hardware sink (DAC) → speakers
```

Snapcast delivers **sample-accurate synchronisation** by timestamping every audio chunk and buffering at the client side to absorb network jitter. Snapclient plays **straight to the hardware sink** (not through the `balena-sound.output` null sink), so PipeWire reports the real device output latency and Snapcast compensates it automatically — heterogeneous devices (different DACs / Pi models) stay in sync without per-device latency tuning.

### Play-triggered master (transient source-master)

There is no permanent master device. The device you play to becomes the group master:

1. You stream to any device (Bluetooth, AirPlay, Spotify, etc.)
2. The audio block detects audio on `balena-sound.input` via `pactl subscribe`
3. That device promotes itself in place — starts capturing into snapserver and advertises via mDNS (`_snapcast._tcp`)
4. All other devices in the same group discover the master and connect their snapclient
5. All devices sync within a few seconds and play the same audio

When you stop playing for 30 seconds, the master demotes in place — capture stops and its advertisement is withdrawn; containers are not restarted. The next play event promotes it again instantly.

**Newest source wins:** if you start playing on a second device, *that* device takes the group (its advertisement carries a newer timestamp) and the previous master yields. If two devices are genuinely playing different sources at once, the newest owns the synced group and the other plays locally on its own until it stops, then rejoins.

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

### Buffer tuning

**Sync is automatic — you should not need per-device latency tuning.** Snapclient plays
straight to each device's hardware sink, so PipeWire reports the real output latency and
Snapcast compensates it; devices with different DACs stay in sync on their own. The only knobs
you may touch are the **buffers** that absorb network/CPU jitter, and only if you hear dropouts:

| Symptom | Knob | Default |
|---|---|---|
| All clients stutter together | `SOUND_MULTIROOM_BUFFER_MS` (snapserver buffer) | `400` |
| The master itself stutters at capture | `SOUND_MULTIROOM_CAPTURE_MS` (pacat buffer) | `50` |
| One client pops/crackles locally | `SOUND_MULTIROOM_PA_LATENCY_MS` (client PA buffer) | `200` |
| Frequent Wi‑Fi dropouts | leave codec at `flac` (lower bandwidth than `pcm`) | `flac` |

`SOUND_MULTIROOM_LATENCY` (snapclient `--latency`) is an **advanced** escape hatch, default `0`.
Only set a non-zero value if one specific device has a known fixed output delay that Snapcast
genuinely cannot see; otherwise leave it at `0` and let the automatic compensation do its job.

---

## Troubleshooting

**Karaoke or Spotify appears to play but no speakers output**
- Check `sound-supervisor` first. `/internal/play` should trigger AUTO promotion, `/multiroom/active` should become `true` on the master, and `/multiroom/master` should return a usable IPv4 address.
- Check `multiroom-client` logs. It should wait for `/multiroom/client-ready`, start `snapclient --player pulse`, and target the current `/multiroom/master` address.
- Check `multiroom-server` logs. It should wait for `snapcast.monitor`, start `pacat`, and keep `snapserver` alive on TCP `1704`.
- Check networking. The Snapcast master IP advertised by mDNS must be reachable from each `multiroom-client` container on TCP `1704`.

**Devices don't sync after streaming starts**
- Wait up to 10 seconds — mDNS discovery can take a moment on first connection
- Confirm `SOUND_GROUP_NAME` is the same on all devices you expect to sync
- Ensure all devices are on the same subnet (no VLAN separation without a reflector)

**Only some devices sync**
- Check that `SOUND_MULTIROOM_ROLE` is not `disabled` or `join` on devices that should auto-promote
- mDNS is link-local — it will not cross routed subnet boundaries

**Audio drops or stutters on clients**
- Increase `SOUND_MULTIROOM_BUFFER_MS` (try 600–800ms)
- Use wired Ethernet on the master device if possible

**A device stopped syncing after a reboot**
- With `auto` role, a device rejoins automatically the next time audio plays — no action needed
- If it stays disconnected, check sound-supervisor logs for mDNS or election errors

**Group name not showing in the web UI dropdown**
- The dropdown populates from groups discovered via mDNS in the last 7 days
- If the group is new, it appears after the first device in that group starts playing
