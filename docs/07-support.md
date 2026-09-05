# Support

## Troubleshooting

This section provides troubleshooting guidance for a few common pitfalls users have faced when deploying IoTSound.

### No audio

#### Description

No audio is coming out of your speaker system.

#### Solution

Ensure that:

- You correctly plugged an audio or HDMI cable to your device
- You are connected to the device and streaming audio to it via any of the supported alternatives

If you are using a DAC, make sure your DAC is on the supported list [here](audio-interfaces#dac-boards) and that you applied the required configuration changes. If your DAC is not on the list, please let us know by opening an [issue](https://github.com/JaragonCR/iotsound/issues/new). 

### Audio cuts or is very stuttery

#### Description

When streaming audio via bluetooth to a Raspberry Pi 3 B/B+ that is running IoTSound, you experience the following:

- Audio output has intermittent cuts every few seconds. This can be anything from once every few seconds to multiple bursts per second.
- The service logs show one of the following errors:

```log
21.12.19 22:35:35 (+1100) bluetooth-audio /usr/bin/bluealsa: SBC decoding error: No such process
21.12.19 22:35:35 (+1100) bluetooth-audio /usr/bin/bluealsa: Missing RTP packet: 27632 != 27630
```

```log
audio  E: [bluetooth] a2dp-codec-sbc.c: SBC decoding error (-3)
audio  E: [bluetooth] module-bluez5-device.c: Decoding error
audio  D: [bluetooth] module-bluez5-device.c: IO thread failed
audio  D: [pulseaudio] module-bluez5-device.c: Switching the profile to off due to IO thread failure.
audio  D: [pulseaudio] module-rescue-streams.c: No evacuation source found.
```

#### Explanation

Stuttering issues on the Raspberry Pi 3 family are related to a known problem with the BCM43438/CYW43438 chip where Bluetooth and WiFi signals interfere with each other. Both the chip manufacturer (Cypress) and the Raspberry Pi Foundation have acknowledged this and there are several upstream open issues that address it. Unfortunately this doesn't seem to be a high priority task for them. Here are the relevant GitHub issues:

- https://github.com/raspberrypi/linux/issues/1552
- https://github.com/raspberrypi/linux/issues/2264
- https://github.com/raspberrypi/linux/issues/1444
- https://github.com/raspberrypi/linux/issues/1402
- https://github.com/Arkq/bluez-alsa/issues/60

#### Known workarounds

At the moment there is no "official" solution to this problem. The following workarounds have proven to work or at least reduce the frequency of the audio cuts. Your milleage might vary depending on your use case so be sure to test them all.

##### Use a USB Bluetooth dongle

This is the official recommendation made by the Raspberry Pi Foundation. Adding a USB Bluetooth dongle to your board removes the interference problems happening at the onboard WiFi/BT chip. IoTSound will automatically detect the bluetooth dongle and configure itself to use it in place of the board's bluetooth.

[This](https://www.amazon.com/TP-Link-Bluetooth-Receiver-Controllers-UB400/dp/B07V1SZCY6/ref=sr_1_7) dongle has been tested to work for this, but any dongle really should work.

##### Disable multi-room feature

Using multi-room has proven to make this issue a lot more frequent and noticeable; most likely due to the increased resource usage that it requires.

- If you are _not_ using multi-room (you only have one device on your IoTSound fleet) you can disable it to alleviate the problem. Check our [docs](customization/#general) to find out how.
- If you are using multi-room consider changing the `master server` from which you stream to other devices to a Raspberry Pi 4. Raspberry Pi 3's can exhibit audio stuttering when working as `master server` but they work fine if you use them as `clients`.

##### Change Power Supply Unit (PSU)

Bad quality power supply units are more likely to trigger this problem. Investing in a good power supply unit is always a good idea!
We recommend using the [original Raspberry Pi power supply](https://www.raspberrypi.org/products/raspberry-pi-universal-power-supply/) and if not possible at least one that conforms to the power requirements described in [here](https://www.raspberrypi.org/documentation/hardware/raspberrypi/power/README.md).

Thank you [@MatthewCroughan](https://github.com/MatthewCroughan) for the thorough [investigation and testing](https://github.com/iotsound/iotsound/issues/62#issuecomment-605265537)!

##### Rolling back to balenaOS 2.38 / Reduce Bluetooth UART baud rate

Raspberry Pi 3's before rev 1.3 have no HW flow control on the UART that controls the Bluetooth modem. This causes occasional data loss which result in the audio stuttering problem described above. Reducing the UART baud rate to `460800` lessens the problem significantly when compared to the default value of `921600`.

This however requires advanced knowledge and usage of balenaOS. So the advised change is to roll back to balenaOS version 2.38.0+rev1 which uses a default baud rate of `921600` but has other firmware configuration that avoids this problem. In order to roll back your balenaOS version you will need to re-flash your SD card and re-provision your device.

We are currently working on bringing back the configuration present in balenaOS 2.38 to the latest version so that the roll back is not necessary; you can keep track of it [here](https://github.com/balena-os/balena-raspberrypi/issues/476).

##### Avoid WPA3 / PMF on 2.4 GHz

The BCM43438/CYW43438 chip on Raspberry Pi 3 B/B+ can mishandle multicast frames when the access point enforces WPA3 or Protected Management Frames (PMF) on the 2.4 GHz band. This can cause mDNS discovery failures (devices not appearing in Spotify Connect or multi-room) in addition to audio cuts. If your router offers a separate 2.4 GHz SSID or per-band security settings, configure that network to use WPA2-only with PMF disabled for Pi 3 clients.

### Audio is delayed

#### Description

When playing audio from any source it takes a few seconds for it to start/stop playing (usually 2-3 seconds). This is especially noticeable when streaming audio from a video source as it's not in sync with the image.

#### Explanation

IoTSound uses many technologies to provide audio streaming capabilities. All these layers of software introduce a small amount of delay that in the end add up to something that can be noticeable. We understand that this means that IoTSound is not suitable for certain applications (streaming audio from video sources for instance) but we believe this is an acceptable tradeoff for all the cool features we offer.

#### Workarounds

There are however workarounds that you might want to take if you are willing to sacrifice some features:

- Airplay streaming has a built-in two-second delay. Using a different audio source will obviously yield better results.
- If you are _not_ using the multi-room feature you can disable it; multi-room adds the most of the perceived delay as it needs it to sync audio across devices. Check our [docs](customization/#general) to find out how to disable it.

### Multiroom is not working

#### Description

Streaming audio to a device works fine but other devices on the network don't sync to it.

#### Solution

Multi-room is enabled by default in all device types. Ensure your device is properly configured. You can see the list of default modes of operation [here](device-support).

IoTSound uses mDNS (Bonjour/Avahi) for master discovery. Client devices browse for the `_snapcast._tcp` advertisement and connect `snapclient` to the discovered master. If a client doesn't pick up the master within a minute of audio starting, check the following:

- **Same subnet** — mDNS is link-local and will not cross VLANs or subnet boundaries. All IoTSound devices must be on the same IP subnet. If they are on different subnets, set `SOUND_MULTIROOM_MASTER` to the master device's IP to bypass discovery.
- **Inter-band multicast** — If devices are on different WiFi bands (e.g. one on 2.4 GHz, another on 5 GHz/WiFi 6), your router may not forward multicast between them. Check your router for a "multicast between bands" or "band bridge" setting, or move all IoTSound devices to the same band.
- **WPA3 / PMF on Pi 3** — See the note under [Audio cuts or is very stuttery](#audio-cuts-or-is-very-stuttery) above.
- **Manual override** — Set `SOUND_MULTIROOM_MASTER=<master-ip>` on client devices to skip mDNS entirely while you diagnose the network issue.

### No audio on HDMI output on Raspberry Pi 4

#### Description

HDMI audio output is currently not working as intended on Raspberry Pi 4. See this [issue](https://github.com/iotsound/iotsound/issues/79) for details.

#### Workaround

You can force HDMI audio to work by setting the device environment variable `BALENA_HOST_CONFIG_hdmi_mode` to `2`. Thanks to [@zchbndcc9](https://github.com/zchbndcc9) for finding this workaround.

### No audio when using balenaOS 64 bit on Raspberry Pi 3s

#### Description

No audio coming out from either the audio jack or HDMI when using balenaOS 64 bit on a Raspberry Pi 3.

For details see:

- https://github.com/iotsound/iotsound/issues/82
- https://github.com/balena-io/balena-supervisor/issues/1245

#### Workaround

For the onboard 3.5mm headphone jack, set these values on the specific Pi 3 device in balenaCloud `Device Configuration`:

| Variable | Value |
| -------- | ----- |
| `BALENA_HOST_CONFIG_dtoverlay` | `"vc4-kms-v3d,noaudio"` |
| `BALENA_HOST_CONFIG_dtparam` | `"i2c_arm=on","spi=on","audio=on"` |

The important detail is `noaudio` on the `vc4-kms-v3d` overlay. Do not use `vc4-kms-v3d,audio=off`; on recent 64-bit balenaOS and Supervisor releases that value can make the device repeatedly apply host configuration. Do not rely on manual edits to `/mnt/boot/config.txt` either, because Supervisor rewrites that file from balenaCloud-managed configuration.

## Enabling debug mode

Setting `LOG_LEVEL=debug` on a device (or fleet) is the universal debug switch. It enables verbose logging across all IoTSound services simultaneously:

| Service | Effect |
|---|---|
| `sound-supervisor` | Play/stop/election events logged in detail |
| `audio` | PulseAudio log level raised to debug |
| `librespot` | Spotify client logs at debug verbosity |
| `multiroom-client` | Periodic waiting heartbeat logged every 5 minutes |
| `support-toolkit` | Debug toolkit container stays running |

### Setting the variable

To enable on a single device via balena CLI:
```bash
balena env set LOG_LEVEL debug --device <uuid>
```

To enable fleet-wide:
```bash
balena env set LOG_LEVEL debug --fleet <fleet-slug>
```

To disable (reverts all services to normal verbosity):
```bash
balena env rm LOG_LEVEL --device <uuid>
```

### Using the debug toolkit

IoTSound ships a `support-toolkit` container that stays dormant (exits immediately) unless `LOG_LEVEL=debug` is set. When active, you can shell into it for live network diagnostics:

```bash
balena ssh <uuid> -s support-toolkit
```

Inside you have access to standard network tools: `tcpdump`, `curl`, `dig`, `nslookup`, `netstat`, and others. This is useful for diagnosing mDNS/multiroom discovery issues — for example:

```bash
# Watch mDNS traffic on the LAN interface
tcpdump -n -i wlan0 udp port 5353

# Check if snapserver is reachable
curl -s http://localhost:1780/jsonrpc -d '{"id":1,"jsonrpc":"2.0","method":"Server.GetStatus"}'
```

The container exits automatically when `LOG_LEVEL` is removed or set to any value other than `debug`.

## Contact us

If you have any questions regarding IoTSound, whether it's an issue not listed in the troubleshooting section, a request for a new feature or DAC, or simply if you want to discuss about the project, feel free to open an [issue](https://github.com/JaragonCR/iotsound/issues/new) on our GitHub repository. Thanks for trying out IoTSound!
