#!/bin/bash
set -e

SOUND_SUPERVISOR_PORT=${SOUND_SUPERVISOR_PORT:-80}
GW="$(ip route | awk '/default / { print $3 }')"
SOUND_SUPERVISOR="$GW:$SOUND_SUPERVISOR_PORT"
# audio container uses network_mode:host; override PULSE_SERVER/PULSE_SOURCE to reach it via gateway IP
export PULSE_SERVER="tcp:$GW:4317"
# Wait for sound supervisor to start
while ! curl --silent --output /dev/null "$SOUND_SUPERVISOR/ping"; do sleep 5; echo "Waiting for sound supervisor to start at $SOUND_SUPERVISOR"; done

# Get mode from sound supervisor. 
# mode: default to MULTI_ROOM
MODE=$(curl --silent "$SOUND_SUPERVISOR/mode" || true)

# Multi-room server can't run properly in some platforms because of resource constraints, so we disable them
declare -A blacklisted=(
  ["raspberry-pi"]=0
  ["raspberry-pi2"]=1
)

if [[ -n "${blacklisted[$BALENA_DEVICE_TYPE]}" ]]; then
  echo "Multi-room server blacklisted for $BALENA_DEVICE_TYPE. Exiting..."

  if [[ "$MODE" == "MULTI_ROOM" ]]; then
    echo "Multi-room has been disabled on this device type due to performance constraints."
    echo "You should use this device in 'MULTI_ROOM_CLIENT' mode if you have other devices running balenaSound, or 'STANDALONE' mode if this is your only device."
  fi
  exit 0
fi

# Tell ALSA to use PulseAudio as the default PCM so snapserver can reach pipewire-pulse
# Start snapserver
if [[ "$MODE" == "MULTI_ROOM" ]]; then
  echo "Starting multi-room server..."
  # Create a FIFO for snapserver to read from
  FIFO=/tmp/snapserver-audio
  rm -f "$FIFO"
  mkfifo "$FIFO"
  # Capture snapcast.monitor via pacat (raw s16le 48000 stereo) and feed the FIFO
  PULSE_SERVER="tcp:${GW}:4317" pacat \
    --record \
    --device=snapcast.monitor \
    --format=s16le \
    --rate=48000 \
    --channels=2 \
    --raw \
    > "$FIFO" &
  echo "pacat PID: $!"
  /usr/bin/snapserver
else
  echo "Multi-room server disabled. Exiting..."
  exit 0
fi