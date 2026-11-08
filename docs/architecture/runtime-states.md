# Runtime States

`SOUND_MULTIROOM_ROLE` is configuration. Runtime state is what the device is doing right now.

## Role matrix

| Configured role | Source plugins | Runs `multiroom-server` | Runs `multiroom-client` | Can become master | Typical use |
|---|---|---:|---:|---:|---|
| `auto` | yes | pre-warmed, active after promotion | pre-warmed, active after target exists | yes, on first play | Normal devices. |
| `host` | yes | yes | yes | always | Dedicated source/master device. |
| `join` | no | no | yes | no | Passive speaker. |
| `disabled` | yes | no | no | no | Independent standalone room. |

## Runtime audio paths

### Disabled standalone

```mermaid
flowchart LR
  Source["Plugin source"] --> Input["balena-sound.input"]
  Input --> Output["balena-sound.output"]
  Output --> Hardware["Hardware DAC / speakers"]
```

Owner notes:

- Configured by `core/audio/start.sh` when role is `disabled`.
- `sound-supervisor` stops both multiroom services and starts source plugins.

### Multiroom master with local playback (`SOURCING`)

```mermaid
flowchart LR
  Source["Plugin source"] --> Input["balena-sound.input"]
  Input --> SnapSink["snapcast sink"]
  SnapSink --> Pacat["pacat capture"]
  Pacat --> Server["snapserver"]
  Server --> LocalClient["local snapclient"]
  LocalClient -->|"Option C: PULSE_SINK=HW_SINK"| Hardware["Hardware DAC / speakers"]
  Server --> RemoteClient["remote snapclients"]
```

Owner notes:

- The master hears itself through its own local `snapclient`, which outputs directly to the detected hardware sink (`GET /audio/output-sink`) with the local hardware sink locked at `100%` unity gain and volume controlled via Snapcast `Client.SetVolume`.
- `multiroom-server` polls `/multiroom/active` and starts/stops `pacat` in place while keeping `snapserver` and `/tmp/snapserver-audio` warm.
- `multiroom-client` polls `/multiroom/client-ready`, fetches `/multiroom/master`, and respawns `snapclient` in place if the master IP changes.

### Remote client playback (`SLAVE`)

```mermaid
flowchart LR
  RemoteServer["remote snapserver"] --> Client["local snapclient"]
  Client -->|"Option C: PULSE_SINK=HW_SINK"| Hardware["Hardware DAC / speakers"]
```

Owner notes:

- `join` devices live here all the time.
- `auto` devices live here when another device in the group is sourcing.
- Source plugins are stopped for `join`, but remain active for `auto`.
- Local hardware sink is locked at `100%` unity gain; `GET`/`POST /audio/volume` proxies to the remote master's Snapcast `Client.SetVolume` on `:1780`.

### Simultaneous-source conflict fallback (`SOLO`)

```mermaid
flowchart LR
  Source["Plugin source"] --> Input["balena-sound.input"]
  Input --> Output["balena-sound.output"]
  Output --> Hardware["Hardware DAC / speakers"]
```

Owner notes:

- Triggered only when two devices in the same group start playing local sources at the exact same epoch and this device loses the `master_uuid` tie-breaker (or loses to a newer `epoch` while still playing locally).
- Implemented by unloading the `balena-sound.input -> snapcast` loopback and loading `balena-sound.input -> balena-sound.output`.
- On stop (`/internal/stop`), supervisor restores `balena-sound.input -> snapcast` and returns to `WARM` (or `SLAVE` if a remote master is still active).

## Promotion and demotion sequence (in-place, no container restarts)

```mermaid
sequenceDiagram
  participant Plugin as Source plugin
  participant Audio as audio (pactl subscribe)
  participant API as sound-supervisor
  participant Config as SoundConfig
  participant Monitor as SnapserverMonitor
  participant Server as multiroom-server (warm)
  participant Client as multiroom-client (warm)

  Plugin->>Audio: send audio to balena-sound.input
  Audio->>API: POST /internal/play
  API->>Config: enterSourcing()
  API->>Monitor: setMaster(true, epoch)
  Monitor->>Monitor: advertise _snapcast._tcp (epoch, master_uuid)
  Server->>API: poll /multiroom/active -> true
  Server->>Server: start pacat (snapcast.monitor -> FIFO)
  Client->>API: poll /multiroom/client-ready -> true
  Client->>API: GET /multiroom/master -> 127.0.0.1
  Client->>Server: connect snapclient (PULSE_SINK=HW_SINK)
```

## Stop sequence (in-place demotion)

```mermaid
sequenceDiagram
  participant Audio as audio (pactl subscribe)
  participant API as sound-supervisor
  participant Config as SoundConfig
  participant Monitor as SnapserverMonitor
  participant Server as multiroom-server

  Audio->>API: POST /internal/stop
  API->>API: start 30s demotion timer
  alt audio resumes before timer
    Audio->>API: POST /internal/play
    API->>API: cancel demotion timer
  else no replay after 30s
    API->>Config: enterWarm() (or enterSlave if remote master present)
    API->>Monitor: setMaster(false) (unpublish mDNS advert)
    Server->>API: poll /multiroom/active -> false
    Server->>Server: kill pacat, keep snapserver + FIFO warm
  end
```

## Discovery state

```mermaid
flowchart TD
  IdleClient["WARM / SLAVE auto or join device"] --> Browse["Avahi browse _snapcast._tcp (always running)"]
  Browse --> Filter["filter unusable IPs\nreject lo, 127.0.0.1, 169.254, Docker/veth, IPv6"]
  Filter --> TieBreak["pick newest epoch\n(lowest master_uuid breaks ties)"]
  TieBreak --> Found["discoveredMasterIp set"]
  Found --> Ready["/multiroom/client-ready true"]
  Ready --> Snapclient["snapclient connects to /multiroom/master\n(outputs directly to HW_SINK)"]
  Found --> TTL["probe TCP 1704 every 30s"]
  TTL -->|90s unreachable| Clear["clear master and let client watchdog reconnect"]
```

## State names to use in issues

Use these names in debugging notes and prompts:

- `disabled-standalone`
- `auto-idle`
- `auto-master-snapcast`
- `auto-master-direct-fallback`
- `auto-remote-client`
- `host-master`
- `join-remote-client`

These names prevent ambiguity around the word "local".
