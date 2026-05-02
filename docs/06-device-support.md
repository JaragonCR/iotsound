# Device support

## Recommended

IoTSound has been developed and tested to work on the following devices:

| Device Type                                   | Default role | `disabled` (standalone) | `auto` / `host` (master) | `join` (client only) |
| --------------------------------------------- | ------------ | ----------------------- | ------------------------ | -------------------- |
| Raspberry Pi (v1 / Zero / Zero W)<sup>1</sup> | `disabled`   | ✔                       | ✘ <sup>2</sup>           | ✔                    |
| Raspberry Pi 2                                | `disabled`   | ✔                       | ✘ <sup>2</sup>           | ✔                    |
| Raspberry Pi 3 <sup>3</sup>                   | `auto`       | ✔                       | ✔ <sup>4</sup>           | ✔                    |
| Raspberry Pi 4 <sup>3</sup>                   | `auto`       | ✔                       | ✔                        | ✔                    |
| Intel NUC                                     | `auto`       | ✔                       | ✔                        | ✔                    |
| balenaFin<sup>1</sup>                         | `auto`       | ✔                       | ✔                        | ✔                    |

**Notes**

[1]: We recommend using a DAC or USB sound card for these device types. See [audio interfaces](audio-interfaces) for more details.

[2]: Master functionality (`auto`/`host` role) is disabled on Raspberry Pi 1 and 2 family devices due to performance constraints. They can function as multi-room clients using the `join` role. Read more about roles [here](./02-usage.md#roles).

[3]: There is a known issue where on the 64 bit version of balenaOS no output is coming through the audio jack/hdmi. See troubleshooting section [here](https://iotsound.github.io//support#troubleshooting) (Scroll down to `No audio when using balenaOS 64 bit on Raspberry Pi 3's`)

[4]: There is a [known issue](https://github.com/raspberrypi/linux/issues/1444) with all variants of the Raspberry Pi 3 where Bluetooth and WiFi interfere with each other. This will only impact the performance of IoTSound if you use a **Pi 3 as the master server to do multi-room bluetooth streaming**, resulting in stuttering audio (Airplay and Spotify Connect will work fine, as well as all streaming methods with multi-room disabled). In this cases we recommend the use of a Raspberry Pi 4 as the `master` server or a Pi 3 with a bluetooth dongle.

## Experimental

Devices with experimental support **have been tested to work**, though we have found compelling reasons for not including them as first-class citizens of IoTSound. If you are shopping for parts, we do not recommend you buy a device from this list.

Some of the reasons we've flagged devices as experimental include:

- device requires multiple extra hardware pieces (USB dongles, adapters, etc)
- device has known bugs that prevent some features to work properly and the timeline for a fix is not clear

| Device Type        | `disabled` (standalone) | `auto` / `host` (master) | `join` (client only) | Comments                                                                                                                                                                                                                                       |
| ------------------ | ----------------------- | ------------------------ | -------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| NVIDIA Jetson Nano | ✔                              | ✔                              | ✔                                            | - Requires WiFi USB dongle (or ethernet cable)<br></br>- Requires Bluetooth USB dongle.<br></br>- No built-in audio support (see [this](https://github.com/balenablocks/audio/issues/35) bug). As a workaround, requires USB or DAC soundcard. |
| BeagleBone Black   | ✔                              | ✔                              | ✔                                            | - Requires WiFi USB dongle (or ethernet cable)<br></br>- Requires Bluetooth USB dongle.<br></br>- Requires USB sound card<br></br>- Requires USB hub as it has a single USB port                                                               |
