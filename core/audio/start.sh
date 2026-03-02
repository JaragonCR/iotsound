#!/bin/bash
set -e

CONFIG_TEMPLATE=/usr/src/balena-sound.pa
CONFIG_FILE=/etc/pulse/default.pa.d/01-balenasound.pa

function set_loopback_latency() {
  local LOOPBACK="$1"
  local LATENCY="$2"
  sed -i "s/%$LOOPBACK%/$LATENCY/" "$CONFIG_FILE"
}

function route_input_sink() {
  local MODE="$1"
  declare -A options=( ["MULTI_ROOM"]=0 ["MULTI_ROOM_CLIENT"]=1 ["STANDALONE"]=2 )
  case "${options[$MODE]}" in
    ${options["STANDALONE"]} | ${options["MULTI_ROOM_CLIENT"]})
      sed -i "s/%INPUT_SINK%/sink=balena-sound.output/" "$CONFIG_FILE"
      echo "Routing 'balena-sound.input' to 'balena-sound.output'."
      ;;
    ${options["MULTI_ROOM"]} | *)
      sed -i "s/%INPUT_SINK%/sink=snapcast/" "$CONFIG_FILE"
      echo "Routing 'balena-sound.input' to 'snapcast'."
      ;;
  esac
}

function route_input_source() {
  local INPUT_DEVICE=$(arecord -l | awk '/card [0-9]:/ { print $3 }')
  if [[ -n "$INPUT_DEVICE" ]]; then
    local INPUT_DEVICE_FULLNAME="alsa_input.$INPUT_DEVICE.analog-stereo"
    echo "Routing audio from '$INPUT_DEVICE_FULLNAME' into 'balena-sound.input sink'"
    echo -e "\nload-module module-loopback source=$INPUT_DEVICE_FULLNAME sink=balena-sound.input" >> "$CONFIG_FILE"
  fi
}

function reset_sound_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    rm "$CONFIG_FILE"
  fi
  cp "$CONFIG_TEMPLATE" "$CONFIG_FILE"
}

SOUND_SUPERVISOR_PORT=${SOUND_SUPERVISOR_PORT:-80}
SOUND_SUPERVISOR="$(ip route | awk '/default / { print $3 }'):$SOUND_SUPERVISOR_PORT"

while ! curl --silent --output /dev/null "$SOUND_SUPERVISOR/ping"; do sleep 5; echo "Waiting for sound supervisor to start at $SOUND_SUPERVISOR"; done

MODE=$(curl --silent "$SOUND_SUPERVISOR/mode" || true)

SOUND_INPUT_LATENCY=${SOUND_INPUT_LATENCY:-200}
SOUND_OUPUT_LATENCY=${SOUND_OUTPUT_LATENCY:-200}

echo "Preparing audio routing templates..."
reset_sound_config
route_input_sink "$MODE"
set_loopback_latency "INPUT_LATENCY" "$SOUND_INPUT_LATENCY"
set_loopback_latency "OUTPUT_LATENCY" "$SOUND_OUPUT_LATENCY"
if [[ -n "$SOUND_ENABLE_SOUNDCARD_INPUT" ]]; then
  route_input_source
fi

# Clean up any silent background processes
killall pipewire wireplumber pipewire-pulse dbus-daemon 2>/dev/null || true
sleep 1

export XDG_RUNTIME_DIR=/tmp/pw-runtime
mkdir -p $XDG_RUNTIME_DIR
chmod 0700 $XDG_RUNTIME_DIR

mkdir -p /run/pulse
chmod 0777 /run/pulse

export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
dbus-daemon --session --address=$DBUS_SESSION_BUS_ADDRESS --nofork --nopidfile --syslog-only &
sleep 1

echo "Starting PipeWire daemon..."
pipewire > /var/log/pipewire.log 2>&1 &
sleep 1

echo "Starting WirePlumber..."
wireplumber > /var/log/wireplumber.log 2>&1 &
sleep 1

echo "Starting PipeWire-Pulse..."
pipewire-pulse > /var/log/pipewire-pulse.log 2>&1 &
PW_PULSE_PID=$!

echo "Waiting for PipeWire-Pulse daemon..."
TIMEOUT=20
while ! pactl info > /dev/null 2>&1; do 
  sleep 0.5
  TIMEOUT=$((TIMEOUT-1))
  if [ "$TIMEOUT" -le 0 ]; then
    echo "ERROR: PipeWire stack failed to initialize!"
    cat /var/log/wireplumber.log
    cat /var/log/pipewire.log
    exit 1
  fi
done

# --- NEW OUTPUT DETECTION & OVERRIDE BLOCK ---
echo "--- Available Hardware Sinks ---"
HW_SINKS=$(pactl list short sinks | awk '{print $2}' | grep -v 'balena-sound\|snapcast')
echo "$HW_SINKS" | sed 's/^/ - /'
echo "--------------------------------"

AUDIO_OUTPUT="${AUDIO_OUTPUT:-AUTO}"
echo "Requested AUDIO_OUTPUT: $AUDIO_OUTPUT"

HW_SINK=""

if [ "$AUDIO_OUTPUT" = "ALL" ]; then
  echo "Feature Enabled: Routing audio to ALL available hardware sinks simultaneously!"
  pactl load-module module-combine-sink sink_name=combined_all_sinks
  HW_SINK="combined_all_sinks"
elif [ "$AUDIO_OUTPUT" != "AUTO" ] && echo "$HW_SINKS" | grep -q "^${AUDIO_OUTPUT}$"; then
  echo "Forcing specific hardware output: $AUDIO_OUTPUT"
  HW_SINK="$AUDIO_OUTPUT"
else
  if [ "$AUDIO_OUTPUT" != "AUTO" ] && [ "$AUDIO_OUTPUT" != "RPI_AUTO" ]; then
    echo "Warning: Sink '$AUDIO_OUTPUT' not found. Falling back to AUTO detection."
  fi
  echo "Auto-detecting optimal hardware sink..."
  
  # Priority 1: External DACs (I2S, USB)
  HW_SINK=$(echo "$HW_SINKS" | grep -iE 'soc_sound|usb|dac|hifiberry' | head -n 1)

  # Priority 2: Built-in 3.5mm / HDMI
  if [ -z "$HW_SINK" ]; then
    HW_SINK=$(echo "$HW_SINKS" | grep -iE 'mailbox|bcm2835|platform' | head -n 1)
  fi

  # Fallback to whatever PipeWire thinks is default
  if [ -z "$HW_SINK" ]; then
    HW_SINK=$(pactl info | awk '/Default Sink:/ {print $3}')
  fi
  echo "Selected Hardware Sink: $HW_SINK"
fi

pactl set-default-sink "$HW_SINK"

# Route our software output directly into the detected/forced hardware
sed -i "s/%OUTPUT_SINK%/sink=$HW_SINK/" "$CONFIG_FILE"
# ---------------------------------------------

echo "Applying PulseAudio routing rules..."
shopt -s nullglob
for pa_file in /etc/pulse/default.pa.d/*.pa; do
  echo "Processing $pa_file..."
  while IFS= read -r cmd || [ -n "$cmd" ]; do
    [[ "$cmd" =~ ^#.*$ ]] || [[ -z "$cmd" ]] && continue
    echo "Executing: pactl $cmd"
    pactl $cmd || echo "Warning: Command failed -> $cmd"
  done < "$pa_file"
done

wait $PW_PULSE_PID
