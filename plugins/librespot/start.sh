#!/bin/bash
CONFIG_DIR="/config"
CONFIG_PATH="$CONFIG_DIR/config.yml"

if [[ -n "$SOUND_DISABLE_SPOTIFY" ]]; then
  echo "Spotify is disabled, exiting..."
  exit 0
fi

mkdir -p "$CONFIG_DIR"

# Wait for PulseAudio (pipewire-pulse) to be ready before starting the daemon.
# Without this, go-librespot crashes immediately on restart and spins in a
# fast on-failure loop that can destabilise PipeWire for other plugins.
until (exec 3<>/dev/tcp/127.0.0.1/4317) 2>/dev/null; do
  echo "[librespot] Waiting for PulseAudio at 127.0.0.1:4317..."
  sleep 2
done
echo "[librespot] PulseAudio ready"

# Wait for a routable network interface before starting — on slow Pi 3 boards
# wlan0 can be assigned an IP after PulseAudio is ready. go-librespot's built-in
# mDNS responder binds at startup; if no real interface exists yet it falls back
# to loopback and becomes invisible to Spotify Connect on the LAN.
until ip -4 addr show scope global | grep -q inet; do
  echo "[librespot] Waiting for network interface..."
  sleep 2
done
echo "[librespot] Network ready"

# Wait for avahi-daemon (sentinel written by sound-supervisor entrypoint).
# avahi-daemon --check reads a local PID file so it cannot cross container
# boundaries — we use a sentinel file on the shared iotsound-dbus volume instead.
if [ -n "$DBUS_SYSTEM_BUS_ADDRESS" ]; then
  until [ -f /run/iotsound-dbus/avahi-ready ]; do
    echo "[librespot] Waiting for avahi-daemon..."
    sleep 1
  done
  echo "[librespot] avahi-daemon ready"
fi

SOUND_DEVICE_NAME=${SOUND_DEVICE_NAME:-"balenaSound Spotify $(echo "$BALENA_DEVICE_UUID" | cut -c -4)"}
SOUND_DEVICE_NAME=${SOUND_DEVICE_NAME}
SOUND_SPOTIFY_BITRATE=$(printf '%s' "${SOUND_SPOTIFY_BITRATE:-160}" | tr -cd '0-9'); SOUND_SPOTIFY_BITRATE=${SOUND_SPOTIFY_BITRATE:-160}
SOUND_SPOTIFY_INITIAL_VOLUME=$(printf '%s' "${SOUND_SPOTIFY_INITIAL_VOLUME:-50}" | tr -cd '0-9'); SOUND_SPOTIFY_INITIAL_VOLUME=${SOUND_SPOTIFY_INITIAL_VOLUME:-50}
# Use pulseaudio backend so go-librespot routes through pipewire-pulse →
# balena-sound.input, not raw ALSA which PipeWire holds exclusively.
SOUND_SPOTIFY_BACKEND=${SOUND_SPOTIFY_BACKEND:-pulseaudio}
LOG_LEVEL=${LOG_LEVEL:-info}

if [ "$SOUND_SPOTIFY_DISABLE_NORMALISATION" = "1" ]; then
  NORMALISATION_BOOL=true
else
  NORMALISATION_BOOL=false
fi

# mDNS backend. go-librespot defaults to its own built-in responder, which then
# competes with the avahi-daemon that sound-supervisor already runs on the host
# network. When the shared avahi D-Bus socket is wired in, register through it
# instead. Override with SOUND_SPOTIFY_ZEROCONF_BACKEND=builtin to roll back.
ZEROCONF_BACKEND="builtin"
if [ -n "$DBUS_SYSTEM_BUS_ADDRESS" ]; then
  ZEROCONF_BACKEND="avahi"
fi
case "${SOUND_SPOTIFY_ZEROCONF_BACKEND:-}" in
  avahi|builtin) ZEROCONF_BACKEND="$SOUND_SPOTIFY_ZEROCONF_BACKEND" ;;
esac

AUTH_TYPE="zeroconf"
if [[ -n "$SOUND_SPOTIFY_USERNAME" && -n "$SOUND_SPOTIFY_PASSWORD" ]]; then
  AUTH_TYPE="spotify_token"
fi

cat > "$CONFIG_PATH" <<EOF
log_level: "$LOG_LEVEL"
device_name: "$SOUND_DEVICE_NAME"
audio_backend: "$SOUND_SPOTIFY_BACKEND"
device_type: "speaker"
initial_volume: $SOUND_SPOTIFY_INITIAL_VOLUME
bitrate: $SOUND_SPOTIFY_BITRATE
normalisation_disabled: $NORMALISATION_BOOL
zeroconf_backend: "$ZEROCONF_BACKEND"
credentials:
  type: "$AUTH_TYPE"
EOF

if [[ "$AUTH_TYPE" == "spotify_token" ]]; then
  cat >> "$CONFIG_PATH" <<EOF
  spotify_token:
    username: "$SOUND_SPOTIFY_USERNAME"
    access_token: "$SOUND_SPOTIFY_PASSWORD"
EOF
fi

echo "Generated config:"
sed 's/^\( *access_token:\).*/\1 "<redacted>"/' "$CONFIG_PATH"

# Pick and run the engine: go-librespot (default) or Spotify Soloist (opt-in, see the file).
. /usr/src/soloist-engine.sh
run_spotify_engine
