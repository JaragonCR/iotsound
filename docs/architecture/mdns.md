# mDNS Architecture

## Current state (v5.x)

A single `avahi-daemon` instance in `sound-supervisor` owns mDNS. Other services use the shared D-Bus socket or Avahi CLI helpers instead of binding UDP `5353` directly.

| Service | Role | Implementation | Binds 5353 directly? |
|---|---|---|---|
| `sound-supervisor` entrypoint | Starts `dbus-daemon` and `avahi-daemon` | `core/sound-supervisor/entrypoint.sh` | Avahi owns it |
| `sound-supervisor` advertiser | Publishes `_snapcast._tcp` when elected master | `avahi-publish -s` via `AvahiAdvertiser.ts` | No |
| `sound-supervisor` browser | Discovers snapcast master IP for client join | `avahi-browse -r -p` via `AvahiBrowser.ts` | No |
| `librespot` | Advertises Spotify Connect via zeroconf | go-librespot uses Avahi through shared D-Bus when available | No |

The shared socket lives in the `iotsound-dbus` volume at `/run/iotsound-dbus/socket`. `sound-supervisor` writes `/run/iotsound-dbus/avahi-ready` after Avahi is healthy; `librespot` and `airplay` wait for that sentinel before advertising.

### Why this shape

- `sound-supervisor` already owns multiroom lifecycle and is the natural owner of Snapcast advertisement/discovery.
- `avahi-daemon` multiplexes mDNS safely so Spotify Connect and Snapcast discovery do not compete for UDP `5353`.
- `avahi-publish` automatically sends a goodbye when the process exits or is killed.
- `avahi-browse` enables persistent discovery without opening raw UDP sockets in Node.js.

---

## Historical problem

Before the Avahi migration, multiple processes competed for UDP port `5353` on the shared host network stack:

| Service | Role | Old implementation | Bound 5353? |
|---|---|---|---|
| `sound-supervisor` advertiser | Published `_snapcast._tcp` | `bonjour-service` npm -> `multicast-dns` | Yes, while master |
| `sound-supervisor` browser | Discovered snapcast master IP | `bonjour-service` npm -> `multicast-dns` | Yes, while browsing |
| `librespot` | Advertised Spotify Connect | Built-in Go mDNS responder | Yes |

All three used `SO_REUSEADDR` without `SO_REUSEPORT`. Linux delivered multicast mDNS packets to every joined socket, but unicast replies could land on only one socket. When the browser was open, it could starve librespot's responder of unicast replies, making the device invisible to Spotify Connect.

An ephemeral browser workaround reduced the collision but delayed master-loss detection. The current Avahi architecture replaces that workaround.

---

## Implementation map

| File | Responsibility |
|---|---|
| `core/sound-supervisor/Dockerfile.template` | Installs `dbus`, `avahi-daemon`, `avahi-utils`, and runtime dependencies. |
| `core/sound-supervisor/entrypoint.sh` | Starts D-Bus, starts Avahi, writes the readiness sentinel, then starts Node. |
| `core/sound-supervisor/iotsound-dbus.conf` | Configures the private D-Bus socket path. |
| `core/sound-supervisor/src/AvahiAdvertiser.ts` | Owns Snapcast service advertisement through `avahi-publish`. |
| `core/sound-supervisor/src/AvahiBrowser.ts` | Owns one-shot and persistent Snapcast discovery through `avahi-browse`. |
| `core/sound-supervisor/src/SnapserverMonitor.ts` | Switches between advertising while master and browsing while client. |
| `docker-compose.yml` | Mounts `iotsound-dbus` into `sound-supervisor`, `librespot`, and `airplay`. |
| `plugins/librespot/start.sh` | Waits for Avahi readiness before starting go-librespot. |
| `plugins/airplay/start.sh` | Waits for Avahi readiness before starting Shairport Sync. |

---

## IPv4-only resolution

`isUsableResolution()` in `AvahiBrowser.ts` rejects **all IPv6 addresses** (any address containing `:`). This is intentional:

- `snapclient --player pulse` on host networking is IPv4-only in practice.
- avahi-browse resolves the same physical host once per interface per protocol, so a dual-stack master appears as both `192.168.x.x` and a global-unicast IPv6 address. Allowing both causes spurious master-change events and silent connection failures when snapclient can't reach the IPv6 address.
- `SOUND_MULTIROOM_MASTER` override must therefore be an IPv4 address.

If IPv6-only networks need to be supported in the future, the fix is to bind snapserver/snapclient explicitly and update the filter — do not simply remove the IPv6 guard without solving the duplicate-resolution instability.

---

## Why not SO_REUSEPORT?

Node.js 16+ supports `SO_REUSEPORT` via `dgram.createSocket({ reusePort: true })`, which would let multiple sockets better share port 5353. The old `multicast-dns` dependency did not expose this option, and patching it would have been fragile across npm updates. The Avahi path is the standard solution and also enables instant goodbye detection, which `SO_REUSEPORT` alone would not provide.

## Master heartbeat (UDP beacon)

mDNS announces a new master with a short burst of unsolicited packets and then only answers
queries, and a long-running `avahi-browse` queries less and less often. A speaker that drops
the burst may not learn about the master for minutes; one that drops the goodbye keeps a
stale master.

To cover that, the sourcing master also broadcasts one small UDP datagram every 10 seconds on
port `1706` (`SOUND_MULTIROOM_BEACON_PORT`), plus a `bye` when it stops sourcing. Every
`sound-supervisor` listens on that port. Beacons and mDNS feed the same master table
(`SnapserverMonitor`, keyed by master UUID), so either path alone is enough:

| Event | mDNS | Beacon |
| --- | --- | --- |
| Master appears | announcement burst, then on query | within 10s, repeated |
| Master stops | goodbye burst | `bye` (sent twice), else checked over unicast after ~35s of silence |

Broadcast reception is lossy, so silence alone does not drop a master. After ~35s without a
beacon the listener asks the master directly (`GET /multiroom/active` on its
`sound-supervisor`, unicast HTTP). "Still sourcing" keeps it, "not sourcing" drops it at
once (this is the missed-goodbye case, even though its snapserver port still answers), and
three unanswered checks in a row drop it. A master on an older release that never beacons keeps the mDNS-only behaviour.
Cost is one packet per interval from the master, independent of the number of idle speakers.
