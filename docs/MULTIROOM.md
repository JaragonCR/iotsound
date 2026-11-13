# Multi-Room Audio (v4.6.0+)

IoTSound turns multiple Raspberry Pis into a perfectly-synchronized whole-home audio system using Snapcast for audio delivery and mDNS (Bonjour) for automatic device discovery.

> **Multiroom is a group broadcast, not a zone selector.** All devices in the same group play the same audio simultaneously. For independent playback, set `SOUND_MULTIROOM_ROLE=disabled`.

---

## How it works

### Audio pipeline

```
Bluetooth / AirPlay / Spotify / Karaoke
            │
            ▼
    PipeWire (audio block, local TCP :4317)
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
4. All other devices in the same group discover the master and connect their snapclient. The master also broadcasts a small heartbeat every 10 seconds (UDP `1706`), so a speaker that missed the mDNS announcement still joins within about 10 seconds
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
| All clients stutter together | `SOUND_MULTIROOM_BUFFER_MS` (snapserver buffer) | `600` |
| The master itself stutters at capture | `SOUND_MULTIROOM_CAPTURE_MS` (pacat buffer) | `50` |
| One client pops/crackles locally | `SOUND_MULTIROOM_PA_LATENCY_MS` (client PA buffer) | `200` |
| Frequent Wi‑Fi dropouts | leave codec at `flac` (lower bandwidth than `pcm`) | `flac` |
| A Raspberry Pi 3 skips about once a minute | `SOUND_MULTIROOM_CODEC=pcm` (see below) | `flac` |

`SOUND_MULTIROOM_LATENCY` (snapclient `--latency`) is an **advanced** escape hatch, default `0`.
Only set a non-zero value if one specific device has a known fixed output delay that Snapcast
genuinely cannot see; otherwise leave it at `0` and let the automatic compensation do its job.

### Choosing the stream codec

`SOUND_MULTIROOM_CODEC` sets how the master encodes the Snapcast stream. The master decides, so
set it as a **fleet** variable: any speaker can become the master, and they should all agree.

| Codec | Quality | Bandwidth (48 kHz stereo) | CPU on each speaker | Use it when |
|---|---|---|---|---|
| `flac` (default) | lossless | varies with the music, below `pcm` | decode on every speaker | Pi 4 or better everywhere, or weak Wi‑Fi |
| `pcm` | lossless | 3.1 Mbit/s at 24 or 32-bit, 1.5 Mbit/s at 16-bit, constant | none | there is a Raspberry Pi 3 in the group |
| `opus` | lossy, always 16-bit | about 0.2 Mbit/s | decode on every speaker | very poor Wi‑Fi and quality matters less |
| `ogg` | lossy, always 16-bit | about 0.2 to 0.3 Mbit/s | decode on every speaker | same as `opus`; prefer `opus` |

**Bit depth.** `SOUND_MULTIROOM_BITS` (`16`, `24` or `32`, default `32`) sets the stream's bit
depth. Spotify lossless reaches 24-bit, so 16 would cut it. Snapcast carries 24-bit samples in
a 32-bit container, so with `pcm` 24 and 32 use the same bandwidth. With `flac`, `24` is
cheaper than `32` for the same audio; use it if Wi‑Fi is tight. Like the codec, set it for the
whole fleet: the master decides.

**Raspberry Pi 3 and `flac`.** On a Pi 3 we have seen `snapclient` crash and restart roughly once
a minute while decoding the `flac` stream, which is heard as a short skip on that speaker (and
only that speaker). Switching the fleet to `pcm` stopped it: no decoder runs on the speakers at
all, and the extra bandwidth is small for a home network. If a Pi 3 in your group skips at a
regular interval, set `SOUND_MULTIROOM_CODEC=pcm` before touching the buffers. `multiroom-client`
logs show the restarts if you want to confirm.

**Raspberry Pi and undervoltage (`avoid_warnings`).** Many Pi 3 boards report undervoltage for a
few seconds now and then even on a good supply and cable. While that lasts the firmware slows the
CPU, and on a speaker that can be heard as a skip. IoTSound therefore installs with
`BALENA_HOST_CONFIG_avoid_warnings=2`, which keeps the CPU at full speed during those blips.

| Value | Effect |
|---|---|
| `2` (IoTSound default) | no on-screen warning, no CPU slowdown on low voltage |
| `1` (balenaOS default) | no on-screen warning, CPU still slows down on low voltage |
| `0` | warning shown, CPU slows down |

- **New fleets** created with the Deploy with balena button get the variable automatically.
- **Existing fleets** and fleets pushed with the CLI do not: add `BALENA_HOST_CONFIG_avoid_warnings`
  = `2` under Configuration in the dashboard, for the fleet or for one device.
- **To override**, set the same variable to `1` or `0`. A device value wins over the fleet value.
  Changing it reboots the device.
- With a supply that really is too weak, `2` trades the slowdown for a risk of crashes. If a
  device becomes unstable, go back to `1` and replace the supply.
- balenaCloud may keep showing the device as undervolted; the setting changes what the firmware
  does about it, not what the kernel reports.

---

## Troubleshooting

**Karaoke or Spotify appears to play but no speakers output**
- Check `sound-supervisor` first. `/internal/play` should trigger AUTO promotion, `/multiroom/active` should become `true` on the master, and `/multiroom/master` should return a usable IPv4 address.
- Check `multiroom-client` logs. It should wait for `/multiroom/client-ready`, start `snapclient --player pulse`, and target the current `/multiroom/master` address.
- Check `multiroom-server` logs. It should wait for `snapcast.monitor`, start `pacat`, and keep `snapserver` alive on TCP `1704`.
- Check networking. The Snapcast master IP advertised by mDNS must be reachable from each `multiroom-client` container on TCP `1704`.

**Devices don't sync after streaming starts**
- Wait up to 10 seconds — discovery uses mDNS plus a 10 second master heartbeat on UDP `1706`
- Make sure nothing on the network blocks UDP broadcast on port `1706` between speakers (client isolation on guest Wi‑Fi does)
- Confirm `SOUND_GROUP_NAME` is the same on all devices you expect to sync
- Ensure all devices are on the same subnet (no VLAN separation without a reflector)

**Only some devices sync**
- Check that `SOUND_MULTIROOM_ROLE` is not `disabled` or `join` on devices that should auto-promote
- mDNS is link-local — it will not cross routed subnet boundaries

**Audio drops or stutters on clients**
- On a Raspberry Pi 3 that skips at a regular interval, set `SOUND_MULTIROOM_CODEC=pcm` first (see [Choosing the stream codec](#choosing-the-stream-codec))
- Increase `SOUND_MULTIROOM_BUFFER_MS` (try 600–800ms)
- Use wired Ethernet on the master device if possible

**A device stopped syncing after a reboot**
- With `auto` role, a device rejoins automatically the next time audio plays — no action needed
- If it stays disconnected, check sound-supervisor logs for mDNS or election errors

**Group name not showing in the web UI dropdown**
- The dropdown populates from groups discovered via mDNS in the last 7 days
- If the group is new, it appears after the first device in that group starts playing
