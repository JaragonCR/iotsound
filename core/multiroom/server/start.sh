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

if [[ "$MODE" == "MULTI_ROOM" ]]; then
  echo "Starting multi-room server..."

  # Fetch the effective buffer from sound-supervisor.
  # Returns JSON: {"configured":400,"effective":50,"mode":"standalone"}
  # On first start there are no remote clients yet, so effective will be the standalone value (50ms).
  # The monitor will restart this service with the right buffer once a remote client joins.
  BUFFER_RESPONSE=$(curl --silent "$SOUND_SUPERVISOR/multiroom/buffer" || echo '{"effective":400}')
  BUFFER_MS=$(echo "$BUFFER_RESPONSE" | sed -n 's/.*"effective":\([0-9]*\).*/\1/p')
  if [[ -z "$BUFFER_MS" || ! "$BUFFER_MS" =~ ^[0-9]+$ ]]; then BUFFER_MS=400; fi
  echo "- Snapcast buffer: ${BUFFER_MS}ms"

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
stream = pipe:///tmp/snapserver-audio?name=balenaSound&sampleformat=48000:16:2&codec=pcm&bufferMs=${BUFFER_MS}
sampleformat = 48000:16:2

[logging]
filter = *:error
SNAPEOF

  FIFO=/tmp/snapserver-audio
  rm -f "$FIFO"
  mkfifo "$FIFO"

  # PACAT_PID is global — updated by start_pacat() and read by the watchdog.
  PACAT_PID=""

  start_pacat() {
    # Wait for snapcast.monitor to exist before starting — prevents the startup
    # race where the audio container hasn't loaded the snapcast sink module yet.
    until PULSE_SERVER="tcp:${GW}:4317" pactl list short sources 2>/dev/null | grep -q "snapcast.monitor"; do
      echo "[pacat] Waiting for PulseAudio snapcast.monitor..."
      sleep 2
    done
    PULSE_SERVER="tcp:${GW}:4317" pacat \
      --record \
      --device=snapcast.monitor \
      --format=s16le \
      --rate=48000 \
      --channels=2 \
      --raw \
      --latency-msec=50 \
      > "$FIFO" &
    PACAT_PID=$!
    echo "[pacat] Started (PID: $PACAT_PID)"
  }

  # Start snapserver in background (it blocks on FIFO open until a writer appears).
  /usr/bin/snapserver --config /tmp/snapserver.conf &
  SNAPSERVER_PID=$!

  # Hold the FIFO write-end open in this shell so snapserver never reads EOF while
  # pacat is restarting. Blocks here until snapserver opens the read end.
  exec 3>"$FIFO"

  start_pacat

  # Watchdog: if pacat exits for any reason, restart it.
  # The held fd 3 keeps the FIFO alive so snapserver doesn't see EOF during the gap.
  while kill -0 "$SNAPSERVER_PID" 2>/dev/null; do
    if [[ -n "$PACAT_PID" ]] && ! kill -0 "$PACAT_PID" 2>/dev/null; then
      echo "[pacat-watchdog] pacat (PID $PACAT_PID) exited — restarting..."
      start_pacat
    fi
    sleep 5
  done

  wait "$SNAPSERVER_PID"
else
  echo "Multi-room server disabled. Exiting..."
  exit 0
fi
