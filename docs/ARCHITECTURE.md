# Architecture

Community contributions have been a staple of this open source project since its inception. However, as IoTSound grew in features it also grew in terms of complexity. It's currently a multi-container app with four core services and as many plugin services. This documentation section aims to provide an overview of IoTSound's architecture, with the intention of lowering the barrier to entry for folks out there wanting to contribute. If you are interested in contributing and after reading this guide you still have questions please [reach out](support#contact-us) and we'll gladly help.

## Overview

![](https://raw.githubusercontent.com/iotsound/iotsound/master/docs/images/arch-overview.png)

IoTSound services can be divided in three groups:

- Sound core: `sound-supervisor` and `audio`.
- Multiroom: `multiroom-server` and `multiroom-client`
- Plugins: `librespot`, `airplay`, `bluetooth`, etc.

### Sound core

This is the heart of IoTSound as it contains the most important services: `sound-supervisor` and `audio`.

**audio**
The `audio` service runs PipeWire + WirePlumber on Alpine 3.21. It is the main "audio router" — it connects to all audio sources and sinks and handles audio routing, which changes depending on the mode of operation (multi-room vs standalone), the output interface selected (onboard audio, HDMI, DAC, USB soundcard), etc. `pipewire-pulse` exposes a PulseAudio-compatible TCP server on port 4317, so all plugin containers can connect via `PULSE_SERVER=tcp:localhost:4317` without any PipeWire-specific configuration. One of the key features for IoTSound is that it allows us to define input and output audio layers and then perform all the complex audio routing without knowing/caring about where the audio is being generated or where it should go to. The `audio routing` section below covers this process in detail.

**sound-supervisor**
The `sound-supervisor`, as its name suggests, is the service that orchestrates all the others. It's not really involved in the audio routing but it does a few key things that enable the other services to be simpler. Here are some of the most important features of the `sound-supervisor`:

- **Multi-room election**: using mDNS (`_snapcast._tcp`) and play-triggered master promotion, the `sound-supervisor` ensures that all devices in the same group (`SOUND_GROUP_NAME`) agree on which device is the master. The device you stream to instantly promotes itself to master, advertises via mDNS, and all other devices in the group discover it and connect their snapclient automatically. No UDP broadcast or external pub/sub library is required.
- **API**: creates a REST API on port 80. The API allows other services to access the current IoTSound configuration, which allows us to update the configuration dynamically and have services react accordingly. As a general rule of thumb, if we are interested in a service's configuration being able to be dynamically updated, the service should rely on configuration reported by `sound-supervisor` and not on environment variables. At this moment, all of the services support this behavior but their configuration is mostly static: you set it at startup via environment variables and that's it. However, there are _experimental_ endpoints in the API to update configuration values and all of the services support it already. There's even a _secret_ UI that allows for some configuration changes at runtime, it's located at `http://<DEVICE_IP>`.

### Multi-room

Multi-room services provide multiroom capabilities to IoTSound.

**multiroom-server**
This service runs a [Snapcast](https://github.com/badaix/snapcast) server which is responsible for broadcasting (and syncing) audio from the `audio` service into Snapcast clients. Clients can be running on the same device or on separate devices.

**multiroom-client**
Runs the client version of Snapcast. It needs to connect to a Snapcast server (can be a separate device) to receive audio packets. It will then forward the audio back into the `audio` service.

### Plugins

Plugins are the audio sources that generate the audio to be streamed/played (e.g. Spotify). Refer to the plugins section below for pointers on how to add new plugins.

## Audio routing

Audio routing is the most crucial part of IoTSound, and it also changes significantly depending on what the current configuration is, with the biggest change being the mode of operation (multi-room vs standalone). There are two services controlling audio routing:

- the `audio` block is the key one as it's the one actually routing audio so we'll zoom into it in sections below.
- `sound-supervisor` on the other hand, is responsible for changing the routing according to what the current mode is. It will modify how sinks are internally connected depending on the mode of operation.

**Note**: audio routing relies mainly on routing PipeWire sinks (exposed via the PulseAudio-compatible `pipewire-pulse` interface). [Here](https://pipewire.pages.freedesktop.org/wireplumber/) is the WirePlumber documentation for background on the session manager that coordinates routing.

### Input and output layers

One of the advantages of using the `audio` block is that, since it's based on PipeWire (with `pipewire-pulse` providing a PulseAudio-compatible interface), we can use all the audio processing tools and tricks that are widely available, in this particular case `virtual sinks`. PipeWire clients can send audio to sinks; usually audio soundcards have a sink that represents them, so sending audio to the audio jack sink will result in that audio coming out of the audio jack. Virtual sinks are virtual nodes that can be used to route audio in and out of them.

For IoTSound we use two virtual sinks in order to simplify how audio is being routed:

- balena-sound.input
- balena-sound.output

Creation and configuration scripts for these virtual sinks are located at `core/audio/balena-sound.pa` and `core/audio/start.sh`.

**balena-sound.input**
`balena-sound.input` acts as an input audio multiplexer/mixer. It's the default sink on IoTSound, so all plugins that send audio to the `audio` block will send it to this sink by default. This allows us to route audio internally without worrying where it came from: any audio generated by a plugin will pass through the `balena-sound.input` sink, so by controlling where it sends it's audio we are effectively controlling all plugins at the same time.

**balena-sound.output**
`balena-sound.output` on the other hand is the output audio multiplexer/mixer. This one is pretty useful in scenarios where there are multiple soundcards available (onboard, DAC, USB, etc). `balena-sound.output` is always wired to whatever the desired soundcard sink is. So even if we dynamically change the output selection, sending audio to `balena-sound.output` will always result in audio going to the current selection. Again, this is useful to route audio internally without worrying about user selection at runtime.

### Standalone

![](https://raw.githubusercontent.com/iotsound/iotsound/master/docs/images/arch-standalone.png)

Standalone mode is easy to understand. You just pipe ` balena-sound.input` to `balena-sound.output` and that's it. Audio coming in from any plugin will find it's way to the selected output. If this was the only mode, we could simplify the setup and use a single sink. Having the two layers however is important for the multiroom mode which is more complicated.

### Multiroom

![](https://raw.githubusercontent.com/iotsound/iotsound/master/docs/images/arch-multiroom.png)

Multiroom feature relies on `snapcast` to broadcast the audio to multiple devices. Snapcast has two binaries working alongside: server and client.

Snapcast server can receive audio from an ALSA stream, so we create an additional sink (`snapcast` sink) that routes audio from `balena-sound.input` and configure snapcast to grab the audio from the sink monitor. The server will then use TCP packets to broadcast audio to all clients that are connected to it, whether they run in the same device or others. Note that the audio is "exiting" the `audio` block and no longer under PulseAudio's control.

Snapcast client receives the audio from the server and sends it back into the `audio` block, in particular to `balena-sound.output` sink which will in turn send the audio to whatever output was selected by the user.

This setup allows us to decouple the multiroom feature from the `audio` block while retaining it's advantages.

## Plugins

As described above, plugins are the services generating the audio to be streamed/played. Plugins are responsible for sending the audio into the `audio` block, particularly into `balena-sound.input` sink. There are two alternatives for how this can be accomplished. A detailed explanation can be found [here](https://github.com/balenablocks/audio#usage), in our case:

**PulseAudio-compatible backend (recommended)**

Most audio applications support PulseAudio as an audio backend. Since `pipewire-pulse` is fully compatible with the PulseAudio protocol, any application that can talk to PulseAudio will work without modification. This is usually configurable via a CLI flag or config file — check your application's documentation.

Set the `PULSE_SERVER` environment variable in your plugin `Dockerfile`:

```
ENV PULSE_SERVER=tcp:localhost:4317
```

**ALSA bridge**

If your application does not have built-in PulseAudio support, you can create a bridge to it by using ALSA. Install the `pipewire-alsa` package (Alpine) or `pipewire-audio` (Debian) in the plugin container, and set:

```
ENV PULSE_SERVER=tcp:localhost:4317
```

The ALSA→PipeWire bridge will route audio through the shared `PULSE_SERVER` socket.
