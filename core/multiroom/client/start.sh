#!/usr/bin/env bash
set -e

SOUND_SUPERVISOR_PORT=${SOUND_SUPERVISOR_PORT:-80}
GW="$(ip route | awk '/default / { print $3 }')"
SOUND_SUPERVISOR="$GW:$SOUND_SUPERVISOR_PORT"
# audio container uses network_mode:host; override PULSE_SERVER to reach it via gateway IP
export PULSE_SERVER="tcp:$GW:4317"
# Wait for sound supervisor to start
while ! curl --silent --output /dev/null "$SOUND_SUPERVISOR/ping"; do sleep 5; echo "Waiting for sound supervisor to start at $SOUND_SUPERVISOR"; done

# Get mode from sound supervisor (determines whether to start snapclient at all).
MODE=$(curl --silent "$SOUND_SUPERVISOR/mode" || true)

# --- ENV VARS ---
# SOUND_MULTIROOM_LATENCY: latency in milliseconds to compensate for speaker hardware sync issues
LATENCY=${SOUND_MULTIROOM_LATENCY:+"--latency $SOUND_MULTIROOM_LATENCY"}

# Wait until PulseAudio is actually ready to serve connections.
# pactl info speaks the PA protocol — it only succeeds once pipewire-pulse
# is fully initialised, unlike /dev/tcp which passes on stale sockets.
# Poll at 5s intervals so we don't hammer PA during audio container startup.
# Log only on first wait and every 30s after to keep logs readable.
_pa_waited=0
_pa_log_interval=30
until PULSE_SERVER="tcp:${GW}:4317" pactl info >/dev/null 2>&1; do
  if [ $_pa_waited -eq 0 ] || [ $(( _pa_waited % _pa_log_interval )) -eq 0 ]; then
    echo "[snapclient] Waiting for PulseAudio at tcp:${GW}:4317... (${_pa_waited}s)"
  fi
  sleep 5
  _pa_waited=$(( _pa_waited + 5 ))
done
echo "[snapclient] PulseAudio ready (waited ${_pa_waited}s)"

# AUTO role: container is pre-warmed at boot. Wait for master promotion before
# fetching the master IP so we connect to the right server (our own snapserver,
# which is also pre-warmed and will have pacat running by the time we start).
# JOIN/HOST: proceed immediately — they always have a master to connect to.
ROLE=$(curl -sf "$SOUND_SUPERVISOR/multiroom" 2>/dev/null | grep -o '"role":"[^"]*"' | cut -d'"' -f4 || echo "unknown")
if [[ "$ROLE" == "auto" ]]; then
  echo "[snapclient] AUTO role — waiting for master promotion..."
  until curl -sf "$SOUND_SUPERVISOR/multiroom/active" 2>/dev/null | grep -q '"active":true'; do
    sleep 0.5
  done
  echo "[snapclient] Promoted — connecting to snapserver"
fi

# Fetch master IP after election completes (supervisor election runs in parallel with audio init).
SNAPSERVER=$(curl --silent "$SOUND_SUPERVISOR/multiroom/master" || true)
echo "Starting multi-room client..."
echo "- balenaSound mode: $MODE"
echo "- Target snapcast server: $SNAPSERVER"

# Set the snapcast device name for https://github.com/iotsound/iotsound/issues/332
if [[ -z $SOUND_DEVICE_NAME ]]; then
    SNAPCAST_CLIENT_ID=$BALENA_DEVICE_UUID
else
    # The sed command replaces invalid host name characters with dash
    SNAPCAST_CLIENT_ID=$(echo $SOUND_DEVICE_NAME | sed -e 's/[^A-Za-z0-9.-]/-/g')
fi

# Tell ALSA to use PulseAudio as the default PCM so snapclient can reach pipewire-pulse
# Start snapclient using the native PulseAudio player (built in at compile time via libpulse-dev).
# This bypasses ALSA entirely and connects directly to pipewire-pulse.
# PULSE_SINK=balena-sound.output (set in Dockerfile) routes output to the right PipeWire sink.
if [[ "$MODE" == "MULTI_ROOM" || "$MODE" == "MULTI_ROOM_CLIENT" ]]; then
  PULSE_SERVER="tcp:${GW}:4317" \
  PULSE_LATENCY_MSEC=200 \
  /usr/bin/snapclient \
    --player pulse \
    --host $SNAPSERVER \
    $LATENCY \
    --hostID $SNAPCAST_CLIENT_ID \
    --logfilter *:error
else
  echo "Multi-room client disabled. Exiting..."
  exit 0
fi
