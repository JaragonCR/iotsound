#!/bin/sh

CONFIG_DIR="/config"
CONFIG_PATH="$CONFIG_DIR/config.yml"

mkdir -p "$CONFIG_DIR"

SOUND_DEVICE_NAME=${SOUND_DEVICE_NAME:-"balenaSound Spotify $(echo "$BALENA_DEVICE_UUID" | cut -c -4)"}
SOUND_DEVICE_NAME=${SOUND_DEVICE_NAME}-test
SOUND_SPOTIFY_BITRATE=${SOUND_SPOTIFY_BITRATE:-160}
LOG_LEVEL=${LOG_LEVEL:-info}


AUTH_TYPE="zeroconf"
if [[ -n "$SOUND_SPOTIFY_USERNAME" && -n "$SOUND_SPOTIFY_PASSWORD" ]]; then
  AUTH_TYPE="spotify_token"
fi

cat > "$CONFIG_PATH" <<EOF
log_level: $LOG_LEVEL
device_name: $SOUND_DEVICE_NAME
device_type: speaker
audio_backend: pulseaudio
bitrate: $SOUND_SPOTIFY_BITRATE
normalisation_disabled: ${SOUND_SPOTIFY_DISABLE_NORMALISATION:-false}
credentials:
  type: "$AUTH_TYPE"
EOF

if [[ "$AUTH_TYPE" == "spotify_token" ]]; then
  cat >> "$CONFIG_PATH" <<EOF
  spotify_token:
    username: $SOUND_SPOTIFY_USERNAME
    access_token: $SOUND_SPOTIFY_PASSWORD
EOF
fi

echo "Generated config:"
cat "$CONFIG_PATH"

exec /go-librespot/daemon --config_dir $CONFIG_DIR
