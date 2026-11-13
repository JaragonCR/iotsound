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
until nc -z 127.0.0.1 4317 2>/dev/null; do
  echo "Waiting for audio block on port 4317..."
  sleep 3
  _tries=$((_tries + 1))
  [ "$_tries" -ge 20 ] && break
done

# Wait for avahi-daemon sentinel (written by sound-supervisor entrypoint).
if [ -n "$DBUS_SYSTEM_BUS_ADDRESS" ]; then
  until [ -f /run/iotsound-dbus/avahi-ready ]; do
    echo "Waiting for avahi-daemon..."
    sleep 1
  done
  echo "avahi-daemon ready"
fi

# Shairport Sync settings.
# - volume_range_db: with no hardware mixer Shairport spreads the AirPlay volume slider over a
#   very wide software range, so the lower half of the slider is inaudible. 30 dB (its
#   minimum) makes the whole slider usable. Override with SOUND_AIRPLAY_VOLUME_RANGE_DB (30-150).
# - output_format: AirPlay 2 defaults to S32_LE. The multiroom path is 16-bit end to end
#   (snapserver sampleformat 48000:16:2), so ask for 16-bit and skip a conversion.
AIRPLAY_RANGE_DB=$(printf '%s' "${SOUND_AIRPLAY_VOLUME_RANGE_DB:-30}" | tr -cd '0-9')
AIRPLAY_RANGE_DB=${AIRPLAY_RANGE_DB:-30}
[ "$AIRPLAY_RANGE_DB" -lt 30 ] && AIRPLAY_RANGE_DB=30
[ "$AIRPLAY_RANGE_DB" -gt 150 ] && AIRPLAY_RANGE_DB=150
cat > /tmp/shairport-sync.conf <<EOF
general =
{
  volume_range_db = $AIRPLAY_RANGE_DB;
};
pulseaudio =
{
  output_format = "S16_LE";
};
EOF

echo "Starting Shairport Sync (volume range ${AIRPLAY_RANGE_DB} dB)"
exec shairport-sync \
  --configfile=/tmp/shairport-sync.conf \
  --name="$SOUND_DEVICE_NAME" \
  --output=pulseaudio
