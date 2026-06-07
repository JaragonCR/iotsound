#!/usr/bin/env bash
set -e

SOUND_SUPERVISOR_PORT=${SOUND_SUPERVISOR_PORT:-80}
SOUND_SUPERVISOR="localhost:$SOUND_SUPERVISOR_PORT"
# host networking: audio and sound-supervisor share the host network stack
export PULSE_SERVER="tcp:localhost:4317"
# Wait for sound supervisor to start
while ! curl --silent --output /dev/null "$SOUND_SUPERVISOR/ping"; do sleep 5; echo "Waiting for sound supervisor to start at $SOUND_SUPERVISOR"; done

# Get mode from sound supervisor (determines whether to start snapclient at all).
MODE=$(curl --silent "$SOUND_SUPERVISOR/mode" || true)

# Wait until PulseAudio is actually ready to serve connections.
# pactl info speaks the PA protocol — it only succeeds once pipewire-pulse
# is fully initialised, unlike /dev/tcp which passes on stale sockets.
# Poll at 5s intervals so we don't hammer PA during audio container startup.
# Log only on first wait and every 30s after to keep logs readable.
_pa_waited=0
_pa_log_interval=30
until PULSE_SERVER="tcp:localhost:4317" pactl info >/dev/null 2>&1; do
  if [ $_pa_waited -eq 0 ] || [ $(( _pa_waited % _pa_log_interval )) -eq 0 ]; then
    echo "[snapclient] Waiting for PulseAudio at tcp:localhost:4317... (${_pa_waited}s)"
  fi
  sleep 5
  _pa_waited=$(( _pa_waited + 5 ))
done
echo "[snapclient] PulseAudio ready (waited ${_pa_waited}s)"

# Snapcast hostID is identity, not display name. It must be unique per device;
# using SOUND_DEVICE_NAME here breaks fleets where the name is set globally.
if [[ -n "$BALENA_DEVICE_UUID" ]]; then
  SNAPCAST_CLIENT_ID="$BALENA_DEVICE_UUID"
else
  SNAPCAST_CLIENT_ID="$(hostname | sed -e 's/[^A-Za-z0-9.-]/-/g')"
fi

if [[ "$MODE" != "MULTI_ROOM" && "$MODE" != "MULTI_ROOM_CLIENT" ]]; then
  echo "Multi-room client disabled. Exiting..."
  exit 0
fi

SNAPCLIENT_PID_FILE=/tmp/snapclient.pid

# Block until this device has a snapcast target: client-ready AND a non-empty master IP.
# A SOLO device (lost the UUID tiebreak but sourcing locally) reports not-ready and an
# empty master, so we correctly stay idle here and never join anyone while it plays local.
_wait_for_target() {
  local m
  while true; do
    if curl -sf "$SOUND_SUPERVISOR/multiroom/client-ready" 2>/dev/null | grep -q '"active":true'; then
      m=$(curl -sf "$SOUND_SUPERVISOR/multiroom/master" 2>/dev/null || true)
      if [[ -n "$m" ]]; then
        printf '%s' "$m"
        return 0
      fi
    fi
    sleep 1
  done
}

_spawn_snapclient() {
  local target="$1"
  local latency_ms
  latency_ms="${SOUND_MULTIROOM_LATENCY:-}"
  if [[ -z "$latency_ms" ]]; then
    latency_ms=$(curl -sf "$SOUND_SUPERVISOR/multiroom/latency" 2>/dev/null | grep -o '"latencyMs":-*[0-9]*' | cut -d':' -f2 || true)
    latency_ms=${latency_ms:-0}
  fi
  local pa_latency_ms="${SOUND_MULTIROOM_PA_LATENCY_MS:-200}"

  # Option C: play snapcast straight to the hardware sink instead of the balena-sound.output
  # null sink, so PipeWire reports the real device latency to snapclient. The caller passes a
  # verified, non-empty hardware sink ($2). We must NEVER target the PA default sink: it is
  # balena-sound.input (a null sink), and snapclient segfaults / plays into the void on it.
  export PULSE_SINK="$2"

  echo "[snapclient] Starting → $target (latency ${latency_ms}ms, pulse buffer ${pa_latency_ms}ms, sink $PULSE_SINK, hostID $SNAPCAST_CLIENT_ID)"
  PULSE_LATENCY_MSEC="$pa_latency_ms" \
  /usr/bin/snapclient \
    --player pulse \
    --host "$target" \
    --latency "$latency_ms" \
    --hostID "$SNAPCAST_CLIENT_ID" \
    --logfilter '*:error' \
    >/dev/null &
  echo $! > "$SNAPCLIENT_PID_FILE"
}

echo "Starting multi-room client (mode: $MODE)..."

# Target-driven supervisor loop. snapclient runs only while a target exists and follows
# target changes in place — master moved, or this device went SOLO (target cleared) — with
# no container restart. If snapclient dies, we re-evaluate and respawn in place too.
while true; do
  SNAPSERVER=$(_wait_for_target)
  # Resolve the hardware sink BEFORE spawning. If the supervisor cannot report one yet,
  # wait — do not fall back to the default sink (balena-sound.input null sink → segfault).
  HW_SINK=$(curl -sf "$SOUND_SUPERVISOR/audio/output-sink" 2>/dev/null || true)
  if [[ -z "$HW_SINK" ]]; then
    echo "[snapclient] Target $SNAPSERVER ready but no hardware sink reported yet — waiting"
    sleep 2
    continue
  fi
  echo "[snapclient] Target acquired: $SNAPSERVER (sink $HW_SINK)"
  _spawn_snapclient "$SNAPSERVER" "$HW_SINK"
  SNAPCLIENT_PID=$(cat "$SNAPCLIENT_PID_FILE" 2>/dev/null || true)

  while [[ -n "$SNAPCLIENT_PID" ]] && kill -0 "$SNAPCLIENT_PID" 2>/dev/null; do
    sleep 5
    NEW_SERVER=$(curl -sf "$SOUND_SUPERVISOR/multiroom/master" 2>/dev/null || true)
    if [[ "$NEW_SERVER" != "$SNAPSERVER" ]]; then
      echo "[snapclient] Target changed: '$SNAPSERVER' → '${NEW_SERVER:-<none>}' — stopping snapclient"
      kill "$SNAPCLIENT_PID" 2>/dev/null || true
      wait "$SNAPCLIENT_PID" 2>/dev/null || true
      break
    fi
  done

  echo "[snapclient] snapclient stopped — re-evaluating target"
  sleep 2
done
