#!/bin/bash
CONFIG_DIR="/config"
CONFIG_PATH="$CONFIG_DIR/config.yml"

mkdir -p "$CONFIG_DIR"

# Wait for PulseAudio (pipewire-pulse) to be ready before starting the daemon.
# Without this, go-librespot crashes immediately on restart and spins in a
# fast on-failure loop that can destabilise PipeWire for other plugins.
until (exec 3<>/dev/tcp/localhost/4317) 2>/dev/null; do
  echo "[librespot] Waiting for PulseAudio at localhost:4317..."
  sleep 2
done
echo "[librespot] PulseAudio ready"

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
cat "$CONFIG_PATH"

exec /usr/src/daemon --config_dir $CONFIG_DIR
