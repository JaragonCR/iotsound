#!/usr/bin/env sh

if [ -n "$SOUND_DISABLE_AIRPLAY" ]; then
  echo "Airplay is disabled, exiting..."
  exit 0
fi

SOUND_DEVICE_NAME=${SOUND_DEVICE_NAME:-"balenaSound AirPlay $(echo "$BALENA_DEVICE_UUID" | cut -c -4)"}

echo "Starting AirPlay plugin..."
echo "Device name: $SOUND_DEVICE_NAME"

# Wait for PulseAudio to be available before starting shairport-sync.
# Audio block can take 15–30s to init PipeWire/PulseAudio on boot;
# without this delay each fast-fail counts against startretries=20.
_tries=0
until nc -z localhost 4317 2>/dev/null; do
  echo "Waiting for audio block on port 4317..."
  sleep 3
  _tries=$((_tries + 1))
  [ "$_tries" -ge 20 ] && break
done

echo "Starting Shairport Sync"
exec shairport-sync \
  --name="$SOUND_DEVICE_NAME" \
  --output=pulseaudio
