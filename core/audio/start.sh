#!/bin/bash
set -e

# ============================================================================
# IoTSound Audio Service Startup Script
# ============================================================================
# This script initializes PipeWire/PulseAudio audio stack with proper
# sequencing to avoid race conditions and initialization failures.
# ============================================================================

# Logging utilities
LOG_FILE="/var/log/audio-startup.log"
mkdir -p "$(dirname "$LOG_FILE")"

log() { 
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] $@" | tee -a "$LOG_FILE"
}

log_section() {
  log ""
  log "============================================"
  log "$@"
  log "============================================"
}

log_step() {
  log "[STEP] $@"
}

log_ok() {
  log "[✓] $@"
}

log_warn() {
  log "[⚠] $@"
}

log_error() {
  log "[✗] $@"
}

# ============================================================================
# CONFIGURATION
# ============================================================================

CONFIG_TEMPLATE=/usr/src/balena-sound.pa
CONFIG_FILE=/etc/pulse/default.pa.d/01-balenasound.pa
SOUND_SUPERVISOR_PORT=${SOUND_SUPERVISOR_PORT:-80}

# Timeouts (in seconds)
PULSEAUDIO_TIMEOUT=30
SOUND_SUPERVISOR_TIMEOUT=60
HARDWARE_SINK_TIMEOUT=20

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

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
      log "Routing 'balena-sound.input' to 'balena-sound.output'."
      ;;
    ${options["MULTI_ROOM"]} | *)
      sed -i "s/%INPUT_SINK%/sink=snapcast/" "$CONFIG_FILE"
      log "Routing 'balena-sound.input' to 'snapcast'."
      ;;
  esac
}

function route_input_source() {
  local INPUT_DEVICE=$(arecord -l | awk '/card [0-9]:/ { print $3 }')
  if [[ -n "$INPUT_DEVICE" ]]; then
    local INPUT_DEVICE_FULLNAME="alsa_input.$INPUT_DEVICE.analog-stereo"
    log "Routing audio from '$INPUT_DEVICE_FULLNAME' into 'balena-sound.input sink'"
    echo -e "\nload-module module-loopback source=$INPUT_DEVICE_FULLNAME sink=balena-sound.input" >> "$CONFIG_FILE"
  fi
}

function reset_sound_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    rm "$CONFIG_FILE"
  fi
  cp "$CONFIG_TEMPLATE" "$CONFIG_FILE"
}

function wait_for_sound_supervisor() {
  log_step "Waiting for sound supervisor at $SOUND_SUPERVISOR..."
  local timeout=$SOUND_SUPERVISOR_TIMEOUT
  
  while [ $timeout -gt 0 ]; do
    if curl --silent --output /dev/null --connect-timeout 2 "$SOUND_SUPERVISOR/ping" 2>/dev/null; then
      log_ok "Sound supervisor is responding"
      return 0
    fi
    log "  Waiting... ($((SOUND_SUPERVISOR_TIMEOUT - timeout + 1))/$SOUND_SUPERVISOR_TIMEOUT seconds)"
    sleep 1
    timeout=$((timeout - 1))
  done
  
  log_warn "Sound supervisor did not respond within timeout, using defaults"
  return 1
}

function get_sound_supervisor_mode() {
  local mode=$(curl --silent --output /dev/null "$SOUND_SUPERVISOR/mode" 2>/dev/null || echo "")
  if [ -z "$mode" ]; then
    log_warn "Could not retrieve mode from sound supervisor, defaulting to STANDALONE"
    mode="STANDALONE"
  fi
  echo "$mode"
}

function wait_for_pulseaudio() {
  log_step "Waiting for PulseAudio to initialize..."
  local timeout=$PULSEAUDIO_TIMEOUT
  
  while [ $timeout -gt 0 ]; do
    if pactl info > /dev/null 2>&1; then
      log_ok "PulseAudio is ready"
      return 0
    fi
    log "  Attempt $((PULSEAUDIO_TIMEOUT - timeout + 1))/$PULSEAUDIO_TIMEOUT... waiting"
    sleep 1
    timeout=$((timeout - 1))
  done
  
  log_error "PulseAudio failed to initialize after $PULSEAUDIO_TIMEOUT seconds"
  return 1
}

function detect_hardware_sink() {
  log_step "Detecting hardware audio sink..."
  local timeout=$HARDWARE_SINK_TIMEOUT
  
  while [ $timeout -gt 0 ]; do
    # Get all non-null sinks
    local hw_sinks=$(pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -v 'balena-sound\|snapcast' | grep 'alsa_output' || true)
    
    if [ -n "$hw_sinks" ]; then
      log_ok "Found hardware sinks"
      echo "$hw_sinks"
      return 0
    fi
    
    log "  Waiting for sink detection... ($((HARDWARE_SINK_TIMEOUT - timeout + 1))/$HARDWARE_SINK_TIMEOUT seconds)"
    sleep 1
    timeout=$((timeout - 1))
  done
  
  log_warn "No hardware sink detected after $HARDWARE_SINK_TIMEOUT seconds"
  return 1
}

function select_hardware_sink() {
  local hw_sinks="$1"
  local selected_sink=""
  
  # Try preferred sink names in order
  for preferred in 'soc_sound' 'usb' 'dac' 'hifiberry'; do
    selected_sink=$(echo "$hw_sinks" | grep -i "$preferred" | head -n 1 || true)
    if [ -n "$selected_sink" ]; then
      log_ok "Selected preferred sink: $selected_sink"
      echo "$selected_sink"
      return 0
    fi
  done
  
  # Fall back to first available sink
  selected_sink=$(echo "$hw_sinks" | head -n 1)
  if [ -n "$selected_sink" ]; then
    log_ok "Selected first available sink: $selected_sink"
    echo "$selected_sink"
    return 0
  fi
  
  log_warn "No sinks available, will attempt to use system default"
  return 1
}

# ============================================================================
# MAIN INITIALIZATION
# ============================================================================

log_section "IOTSOUND AUDIO SERVICE STARTUP"
log "Start time: $(date)"

# ============================================================================
# PHASE 1: CONTACT SOUND SUPERVISOR
# ============================================================================

log_section "PHASE 1: Sound Supervisor Configuration"

SOUND_SUPERVISOR="$(ip route | awk '/default / { print $3 }'):$SOUND_SUPERVISOR_PORT"
log "Sound supervisor address: $SOUND_SUPERVISOR"

if wait_for_sound_supervisor; then
  MODE=$(get_sound_supervisor_mode)
else
  MODE="STANDALONE"
fi

log_ok "Sound supervisor mode: $MODE"

# ============================================================================
# PHASE 2: PULSEAUDIO CONFIGURATION
# ============================================================================

log_section "PHASE 2: PulseAudio Configuration"

SOUND_INPUT_LATENCY=${SOUND_INPUT_LATENCY:-200}
SOUND_OUTPUT_LATENCY=${SOUND_OUTPUT_LATENCY:-200}

log_step "Preparing audio routing configuration..."
reset_sound_config
route_input_sink "$MODE"
set_loopback_latency "INPUT_LATENCY" "$SOUND_INPUT_LATENCY"
set_loopback_latency "OUTPUT_LATENCY" "$SOUND_OUTPUT_LATENCY"

if [[ -n "$SOUND_ENABLE_SOUNDCARD_INPUT" ]]; then
  log_step "Enabling soundcard input routing..."
  route_input_source
fi

log_ok "Audio routing configuration prepared"

# ============================================================================
# PHASE 3: CLEANUP AND ENVIRONMENT SETUP
# ============================================================================

log_section "PHASE 3: Environment Setup"

log_step "Cleaning up any stale processes..."
killall pipewire wireplumber pipewire-pulse dbus-daemon 2>/dev/null || true
sleep 1
log_ok "Stale processes cleaned"

log_step "Setting up runtime directories..."
export XDG_RUNTIME_DIR=/tmp/pw-runtime
mkdir -p $XDG_RUNTIME_DIR
chmod 0700 $XDG_RUNTIME_DIR

mkdir -p /run/pulse
chmod 0777 /run/pulse

export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
log_ok "Runtime directories ready"

# ============================================================================
# PHASE 4: START DBUS DAEMON
# ============================================================================

log_section "PHASE 4: D-Bus Daemon"

log_step "Starting D-Bus daemon..."
dbus-daemon --session --address=$DBUS_SESSION_BUS_ADDRESS --nofork --nopidfile --syslog-only &
sleep 1
log_ok "D-Bus daemon started"

# ============================================================================
# PHASE 5: START PIPEWIRE STACK
# ============================================================================

log_section "PHASE 5: PipeWire Stack Initialization"

log_step "Starting PipeWire daemon..."
pipewire > /var/log/pipewire.log 2>&1 &
PIPEWIRE_PID=$!
sleep 1
log_ok "PipeWire daemon started (PID: $PIPEWIRE_PID)"

log_step "Starting WirePlumber daemon..."
wireplumber > /var/log/wireplumber.log 2>&1 &
WIREPLUMBER_PID=$!
sleep 1
log_ok "WirePlumber daemon started (PID: $WIREPLUMBER_PID)"

log_step "Starting PipeWire-Pulse compatibility layer..."
pipewire-pulse > /var/log/pipewire-pulse.log 2>&1 &
PW_PULSE_PID=$!
log_ok "PipeWire-Pulse started (PID: $PW_PULSE_PID)"

# ============================================================================
# PHASE 6: WAIT FOR PULSEAUDIO READINESS
# ============================================================================

log_section "PHASE 6: PulseAudio Readiness Check"

if ! wait_for_pulseaudio; then
  log_error "PulseAudio stack failed to initialize!"
  log_error "Check /var/log/pipewire*.log for details"
  exit 1
fi

# ============================================================================
# PHASE 7: HARDWARE SINK DETECTION AND SELECTION
# ============================================================================

log_section "PHASE 7: Hardware Sink Detection"

echo "--- Available Hardware Sinks ---"
HW_SINKS=$(pactl list short sinks | awk '{print $2}' | grep -v 'balena-sound\|snapcast' | grep 'alsa_output' || true)
if [ -z "$HW_SINKS" ]; then
  HW_SINKS=$(pactl list short sinks | awk '{print $2}' | grep -v 'balena-sound\|snapcast' || true)
fi
echo "$HW_SINKS" | sed 's/^/ - /'
echo "--------------------------------"

AUDIO_OUTPUT="${AUDIO_OUTPUT:-AUTO}"
HW_SINK=""

# Parse AUDIO_OUTPUT environment variable
if [ "$AUDIO_OUTPUT" = "ALL" ]; then
  log_step "Loading combine-sink for all outputs..."
  pactl load-module module-combine-sink sink_name=combined_all_sinks || log_warn "Failed to load combine sink"
  HW_SINK="combined_all_sinks"
elif [ "$AUDIO_OUTPUT" != "AUTO" ]; then
  # Check if specified sink exists
  if echo "$HW_SINKS" | grep -q "^${AUDIO_OUTPUT}$"; then
    HW_SINK="$AUDIO_OUTPUT"
    log_ok "Using explicitly specified sink: $HW_SINK"
  else
    log_warn "Specified sink '$AUDIO_OUTPUT' not found, falling back to auto-detection"
  fi
fi

# Auto-detect if not already selected
if [ -z "$HW_SINK" ]; then
  log_step "Auto-detecting optimal sink from available options..."
  
  # Try to detect sinks in order of preference
  HW_SINKS_DETECTED=$(detect_hardware_sink)
  if [ $? -eq 0 ]; then
    HW_SINK=$(select_hardware_sink "$HW_SINKS_DETECTED")
  else
    # Fallback: try to get default sink from pactl info
    log_warn "Hardware sink detection timeout, attempting to use system default"
    HW_SINK=$(pactl info | awk '/Default Sink:/ {print $3}' || true)
  fi
fi

# Final validation
if [ -z "$HW_SINK" ]; then
  log_error "No hardware sink available! Audio output will not work."
  log_warn "Available sinks: $HW_SINKS"
  HW_SINK="alsa_output.platform-soc_sound.stereo-fallback"  # Last resort fallback
  log_warn "Using last-resort fallback: $HW_SINK"
fi

log_ok "Selected Hardware Sink: $HW_SINK"

# Set as default with error handling
if pactl set-default-sink "$HW_SINK" 2>/dev/null; then
  log_ok "Default sink configured successfully"
else
  log_warn "Failed to set default sink (continuing anyway)"
fi

# Update the balena-sound config file with the detected sink
if sed -i "s/%OUTPUT_SINK%/sink=$HW_SINK/" "$CONFIG_FILE" 2>/dev/null; then
  log_ok "Audio configuration updated with selected sink"
else
  log_warn "Failed to update configuration file"
fi

# ============================================================================
# PHASE 8: APPLY PULSEAUDIO ROUTING RULES
# ============================================================================

log_section "PHASE 8: Applying PulseAudio Routing Rules"

log_step "Processing PulseAudio configuration files..."
shopt -s nullglob
CONFIG_COUNT=0
FAILED_COUNT=0

for pa_file in /etc/pulse/default.pa.d/*.pa; do
  log "Processing $pa_file..."
  
  while IFS= read -r cmd || [ -n "$cmd" ]; do
    # Skip comments and empty lines
    [[ "$cmd" =~ ^#.*$ ]] || [[ -z "$cmd" ]] && continue
    
    # GUARD: Skip commands with unexpanded variables
    if [[ "$cmd" == *\$* ]]; then
      log_warn "  Skipping command with unexpanded variable: $cmd"
      continue
    fi

    # Execute the command
    log "  Executing: pactl $cmd"
    if pactl $cmd > /dev/null 2>&1; then
      CONFIG_COUNT=$((CONFIG_COUNT + 1))
    else
      log_warn "  Command failed -> $cmd"
      FAILED_COUNT=$((FAILED_COUNT + 1))
    fi
  done < "$pa_file"
done

log_ok "Applied $CONFIG_COUNT routing rules ($FAILED_COUNT warnings)"

# ============================================================================
# PHASE 9: STARTUP COMPLETE
# ============================================================================

log_section "IOTSOUND AUDIO SERVICE READY"
log "Startup completed at: $(date)"
log "PipeWire-Pulse PID: $PW_PULSE_PID"
log "All audio services initialized and ready"
log ""
log "Audio Configuration Summary:"
log "  - Output Sink: $HW_SINK"
log "  - Input Latency: ${SOUND_INPUT_LATENCY}ms"
log "  - Output Latency: ${SOUND_OUTPUT_LATENCY}ms"
log "  - Mode: $MODE"
log ""

# Wait for PipeWire-Pulse to continue running
wait $PW_PULSE_PID