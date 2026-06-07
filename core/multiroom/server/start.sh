#!/bin/bash
set -e

SOUND_SUPERVISOR_PORT=${SOUND_SUPERVISOR_PORT:-80}
SOUND_SUPERVISOR="localhost:$SOUND_SUPERVISOR_PORT"
# host networking: audio and sound-supervisor share the host network stack
export PULSE_SERVER="tcp:localhost:4317"
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
    echo "You should use this device with role='join' if you have other devices in the fleet, or role='disabled' if this is your only device."
  fi
  exit 0
fi

if [[ "$MODE" == "MULTI_ROOM" ]]; then
  echo "Starting multi-room server..."

  REQUESTED_BUFFER_MS=${SOUND_MULTIROOM_BUFFER_MS:-400}
  CLIENT_LATENCY_MS=${SOUND_MULTIROOM_LATENCY:-400}
  if ! [[ "$REQUESTED_BUFFER_MS" =~ ^[0-9]+$ ]]; then
    echo "[multiroom-server] WARN: invalid SOUND_MULTIROOM_BUFFER_MS '$REQUESTED_BUFFER_MS', falling back to 400ms"
    REQUESTED_BUFFER_MS=400
  fi
  if ! [[ "$CLIENT_LATENCY_MS" =~ ^-?[0-9]+$ ]]; then
    echo "[multiroom-server] WARN: invalid SOUND_MULTIROOM_LATENCY '$CLIENT_LATENCY_MS', falling back to 400ms"
    CLIENT_LATENCY_MS=400
  fi

  MIN_BUFFER_MS=$(( CLIENT_LATENCY_MS + 100 ))
  if [ "$MIN_BUFFER_MS" -lt 100 ]; then
    MIN_BUFFER_MS=100
  fi

  BUFFER_MS="$REQUESTED_BUFFER_MS"
  if [ "$BUFFER_MS" -lt "$MIN_BUFFER_MS" ]; then
    BUFFER_MS="$MIN_BUFFER_MS"
  fi
  echo "- Snapcast buffer: ${BUFFER_MS}ms (requested ${REQUESTED_BUFFER_MS}ms, minimum ${MIN_BUFFER_MS}ms)"

  # Stream codec. flac (lossless, ~half the bandwidth of pcm) is snapcast's default and
  # is more robust on lossy WiFi — fewer burst-induced dropouts. pcm has zero codec
  # latency but heavier bandwidth. A/B these on hardware via SOUND_MULTIROOM_CODEC.
  CODEC="${SOUND_MULTIROOM_CODEC:-flac}"
  case "$CODEC" in
    pcm|flac|ogg|opus) ;;
    *) echo "[multiroom-server] WARN: invalid SOUND_MULTIROOM_CODEC '$CODEC', using flac"; CODEC="flac" ;;
  esac
  echo "- Snapcast codec: ${CODEC}"

  # Write dynamic snapserver config with the current effective buffer
  cat > /tmp/snapserver.conf << SNAPEOF
[server]
datadir = /var/cache/snapcast/

[http]
enabled = true
bind_to_address = 0.0.0.0
port = 1780
doc_root = /var/www/

[stream]
stream = pipe:///tmp/snapserver-audio?name=balenaSound&sampleformat=48000:16:2&codec=${CODEC}&bufferMs=${BUFFER_MS}
sampleformat = 48000:16:2

[logging]
filter = *:error,ControlSessionHTTP:fatal
SNAPEOF

  FIFO=/tmp/snapserver-audio
  rm -f "$FIFO"
  mkfifo "$FIFO"

  # PACAT_PID is global — updated by start_pacat() and read by the watchdog.
  PACAT_PID=""

  start_pacat() {
    # Wait for snapcast.monitor to exist before starting — prevents the startup
    # race where the audio container hasn't loaded the snapcast sink module yet.
    # Timeout after 120s so the container exits and on-failure restarts it if PA is down.
    local waited=0
    until PULSE_SERVER="tcp:localhost:4317" pactl list short sources 2>/dev/null | grep -q "snapcast.monitor"; do
      echo "[pacat] Waiting for PulseAudio snapcast.monitor... (${waited}s)"
      sleep 2
      waited=$((waited + 2))
      if [ "$waited" -ge 120 ]; then
        echo "[pacat] ERROR: snapcast.monitor unavailable after 120s — exiting for container restart"
        exit 1
      fi
    done
    PULSE_SERVER="tcp:localhost:4317" pacat \
      --record \
      --device=snapcast.monitor \
      --format=s16le \
      --rate=48000 \
      --channels=2 \
      --raw \
      --latency-msec=${SOUND_MULTIROOM_CAPTURE_MS:-50} \
      > "$FIFO" &
    PACAT_PID=$!
    echo "[pacat] Started (PID: $PACAT_PID)"
  }

  # Stop pacat in place (transient-master demotion). snapserver and the held FIFO fd stay
  # alive, so the container never restarts and the audio graph is untouched.
  stop_pacat() {
    if [[ -n "$PACAT_PID" ]] && kill -0 "$PACAT_PID" 2>/dev/null; then
      echo "[pacat] Stopping (PID $PACAT_PID)"
      kill "$PACAT_PID" 2>/dev/null || true
      wait "$PACAT_PID" 2>/dev/null || true
    fi
    PACAT_PID=""
  }

  is_active() {
    curl -sf "$SOUND_SUPERVISOR/multiroom/active" 2>/dev/null | grep -q '"active":true'
  }

  # Start snapserver in background (it blocks on FIFO open until a writer appears).
  /usr/bin/snapserver --config /tmp/snapserver.conf &
  SNAPSERVER_PID=$!

  # Hold the FIFO write-end open in this shell so snapserver never reads EOF while
  # pacat is stopped/restarting. Blocks here until snapserver opens the read end.
  exec 3>"$FIFO"

  # Reconcile loop: pacat runs only while the supervisor reports this device as the
  # SOURCING master (/multiroom/active). Promotion and demotion are an in-place pacat
  # start/stop — snapserver and the FIFO stay up, so there is no container churn and no
  # audio-graph teardown on either transition. Also covers pacat crash recovery.
  POLL_S="${SOUND_MULTIROOM_POLL_S:-2}"
  echo "[multiroom-server] snapserver up — reconciling pacat against /multiroom/active (every ${POLL_S}s)"
  while kill -0 "$SNAPSERVER_PID" 2>/dev/null; do
    if is_active; then
      if [[ -z "$PACAT_PID" ]] || ! kill -0 "$PACAT_PID" 2>/dev/null; then
        [[ -n "$PACAT_PID" ]] && echo "[pacat-watchdog] pacat exited — restarting"
        start_pacat
      fi
    else
      if [[ -n "$PACAT_PID" ]]; then
        echo "[multiroom-server] Demoted — stopping pacat in place"
        stop_pacat
      fi
    fi
    sleep "$POLL_S"
  done

  wait "$SNAPSERVER_PID"
else
  echo "Multi-room server disabled. Exiting..."
  exit 0
fi
