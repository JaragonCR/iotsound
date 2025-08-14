#!/bin/sh
#audio_backend: pulseaudio  removed temporarly from line 28
CONFIG_DIR="/config"
CONFIG_PATH="$CONFIG_DIR/config.yml"

mkdir -p "$CONFIG_DIR"

SOUND_DEVICE_NAME=${SOUND_DEVICE_NAME:-"balenaSound Spotify $(echo "$BALENA_DEVICE_UUID" | cut -c -4)"}
SOUND_DEVICE_NAME=${SOUND_DEVICE_NAME}-test
SOUND_SPOTIFY_BITRATE=${SOUND_SPOTIFY_BITRATE:-160}
SOUND_SPOTIFY_INITIAL_VOLUME="${SOUND_SPOTIFY_INITIAL_VOLUME:-50}"
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
log_level: $LOG_LEVEL
device_name: $SOUND_DEVICE_NAME
device_type: speaker
initial_volume: $SOUND_SPOTIFY_INITIAL_VOLUME
bitrate: $SOUND_SPOTIFY_BITRATE
normalisation_disabled: $NORMALISATION_BOOL
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

exec /usr/src/daemon --config_dir $CONFIG_DIR
