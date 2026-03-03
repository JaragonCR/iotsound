#!/bin/bash
set -e

# ============================================================================
# IoTSound Audio Service Startup Script
# Enhanced with Input Device Detection and DAC Prioritization
# ============================================================================

LOG_FILE="/var/log/audio-startup.log"
mkdir -p "$(dirname "$LOG_FILE")"

log() {
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] $@" | tee -a "$LOG_FILE" >&2
}

log_section() {
  log ""
  log "============================================"
  log "$@"
  log "============================================"
}

log_step() { log "[STEP] $@"; }
log_ok()   { log "[✓] $@"; }
log_warn() { log "[⚠] $@"; }
log_error(){ log "[✗] $@"; }

# ============================================================================
# CONFIGURATION
# ============================================================================

CONFIG_TEMPLATE=/usr/src/balena-sound.pa
CONFIG_FILE=/etc/pulse/default.pa.d/01-balenasound.pa
SOUND_SUPERVISOR_PORT=${SOUND_SUPERVISOR_PORT:-80}

PULSEAUDIO_TIMEOUT=30
SOUND_SUPERVISOR_TIMEOUT=60
HARDWARE_SINK_TIMEOUT=20
HARDWARE_SOURCE_TIMEOUT=10

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
  local mode=$(curl --silent "$SOUND_SUPERVISOR/mode" 2>/dev/null || echo "")
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
  log_step "Detecting hardware audio sinks..."
  local timeout=$HARDWARE_SINK_TIMEOUT

  while [ $timeout -gt 0 ]; do
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
  local audio_output_pref="$2"
  local selected_sink=""

  # If explicit preference (not AUTO), try to match it first
  if [ -n "$audio_output_pref" ] && [ "$audio_output_pref" != "AUTO" ]; then
    selected_sink=$(echo "$hw_sinks" | grep -i "$audio_output_pref" | head -n 1 || true)
    if [ -n "$selected_sink" ]; then
      log_ok "Selected sink matching preference '$audio_output_pref': $selected_sink"
      echo "$selected_sink"
      return 0
    fi
    log_warn "Preference '$audio_output_pref' not found, falling back to auto-detection"
  fi

  # Auto-detect by preference order: DAC > USB > HDMI > Built-in
  # This ensures HiFiBerry DAC+ is preferred over USB audio dongle
  for preferred in 'hifiberry' 'dac' 'soc_sound' 'usb' 'dac+' 'hdmi'; do
    selected_sink=$(echo "$hw_sinks" | grep -i "$preferred" | head -n 1 || true)
    if [ -n "$selected_sink" ]; then
      log_ok "Selected preferred sink: $selected_sink (matched: $preferred)"
      echo "$selected_sink"
      return 0
    fi
  done

  # Fall back to first available
  selected_sink=$(echo "$hw_sinks" | head -n 1)
  if [ -n "$selected_sink" ]; then
    log_ok "Selected first available sink: $selected_sink"
    echo "$selected_sink"
    return 0
  fi

  log_warn "No sinks available, will attempt to use system default"
  return 1
}

function detect_hardware_source() {
  log_step "Detecting hardware audio sources (microphones)..."
  local timeout=$HARDWARE_SOURCE_TIMEOUT

  while [ $timeout -gt 0 ]; do
    local hw_sources=$(pactl list short sources 2>/dev/null | awk '{print $2}' | grep -v 'balena-sound\|snapcast' | grep 'alsa_input' || true)

    if [ -n "$hw_sources" ]; then
      log_ok "Found hardware sources"
      echo "$hw_sources"
      return 0
    fi

    log "  Waiting for source detection... ($((HARDWARE_SOURCE_TIMEOUT - timeout + 1))/$HARDWARE_SOURCE_TIMEOUT seconds)"
    sleep 1
    timeout=$((timeout - 1))
  done

  log_warn "No hardware sources detected after $HARDWARE_SOURCE_TIMEOUT seconds"
  return 1
}

function select_hardware_source() {
  local hw_sources="$1"
  local selected_source=""

  # Prefer USB input devices (USB microphone/dongle) over built-in
  selected_source=$(echo "$hw_sources" | grep -i 'usb' | head -n 1 || true)
  if [ -n "$selected_source" ]; then
    log_ok "Selected USB input source: $selected_source"
    echo "$selected_source"
    return 0
  fi

  # Fall back to first available
  selected_source=$(echo "$hw_sources" | head -n 1)
  if [ -n "$selected_source" ]; then
    log_ok "Selected first available input source: $selected_source"
    echo "$selected_source"
    return 0
  fi

  log_warn "No input sources available"
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

# ========================================================================
# Create PipeWire Filter Configuration (for microphone audio processing)
# ========================================================================

log_step "Configuring PipeWire audio filters for microphone input..."

# Microphone filter frequencies (optimized for karaoke vocals)
# AUDIO_INPUT_HIGHPASS: High-pass cutoff frequency (Hz) - removes rumble/noise
#   Default: 120Hz (good for vocals), set to 0 or empty to disable
# AUDIO_INPUT_LOWPASS: Low-pass cutoff frequency (Hz) - removes harshness  
#   Default: 12000Hz (vocal range), set to 0 or empty to disable, 20000 for full spectrum
AUDIO_INPUT_HIGHPASS=${AUDIO_INPUT_HIGHPASS:-120}
AUDIO_INPUT_LOWPASS=${AUDIO_INPUT_LOWPASS:-12000}

log "Microphone filter configuration:"
log "  Highpass: ${AUDIO_INPUT_HIGHPASS}Hz (0/empty = disabled)"
log "  Lowpass: ${AUDIO_INPUT_LOWPASS}Hz (0/empty = disabled)"

mkdir -p /etc/pipewire/pipewire.conf.d/

# Determine which filters are active
HP_ACTIVE=false
LP_ACTIVE=false
[ "$AUDIO_INPUT_HIGHPASS" != "0" ] && [ -n "$AUDIO_INPUT_HIGHPASS" ] && HP_ACTIVE=true
[ "$AUDIO_INPUT_LOWPASS" != "0" ] && [ -n "$AUDIO_INPUT_LOWPASS" ] && LP_ACTIVE=true

if [ "$HP_ACTIVE" = true ] || [ "$LP_ACTIVE" = true ]; then
  # Build filter chain
  NODES_SECTION=""
  LINKS_SECTION=""
  
  if [ "$HP_ACTIVE" = true ]; then
    NODES_SECTION="${NODES_SECTION}
                    {
                        type   = builtin
                        name   = hp
                        label  = bq_highpass
                        control = { Freq = $AUDIO_INPUT_HIGHPASS Q = 0.707 }
                    }"
  fi
  
  if [ "$LP_ACTIVE" = true ]; then
    NODES_SECTION="${NODES_SECTION}
                    {
                        type   = builtin
                        name   = lp
                        label  = bq_lowpass
                        control = { Freq = $AUDIO_INPUT_LOWPASS Q = 0.707 }
                    }"
    
    if [ "$HP_ACTIVE" = true ]; then
      LINKS_SECTION="
                links = [
                    { output = \"hp:Out\" input = \"lp:In\" }
                ]"
    fi
  fi
  
  # Determine input/output ports
  if [ "$HP_ACTIVE" = true ]; then
    INPUT_PORT="hp:In"
  else
    INPUT_PORT="lp:In"
  fi
  
  if [ "$LP_ACTIVE" = true ]; then
    OUTPUT_PORT="lp:Out"
  else
    OUTPUT_PORT="hp:Out"
  fi
  
  cat > /etc/pipewire/pipewire.conf.d/99-mic-filters.conf << EOF
context.modules = [
    { name = libpipewire-module-filter-chain
        args = {
            node.description = "Mic Audio Filters"
            media.name       = "Mic Filtered"
            filter.graph = {
                nodes = [$NODES_SECTION
                ]$LINKS_SECTION
                inputs  = [ "$INPUT_PORT" ]
                outputs = [ "$OUTPUT_PORT" ]
            }
            capture.props = {
                node.name = "capture.mic_filtered"
            }
            playback.props = {
                node.name   = "mic_filtered"
                media.class = Audio/Source
            }
        }
    }
]
EOF
  log_ok "Microphone filter configuration created"
else
  log_ok "Microphone filters disabled (AUDIO_INPUT_HIGHPASS=0, AUDIO_INPUT_LOWPASS=0)"
fi

log_section "PHASE 6: PulseAudio Readiness Check"

if ! wait_for_pulseaudio; then
  log_error "PulseAudio stack failed to initialize!"
  log_error "Check /var/log/pipewire*.log for details"
  exit 1
fi

# ============================================================================
# PHASE 7: OUTPUT DEVICE DETECTION AND SELECTION (DAC PRIORITY)
# ============================================================================

log_section "PHASE 7: Hardware Output Device Detection"

# Read output preference (defaults to AUTO if not set)
AUDIO_OUTPUT=${AUDIO_OUTPUT:-AUTO}
log "Output preference: $AUDIO_OUTPUT"

log_step "Detecting hardware audio sinks..."
HW_SINKS=$(pactl list short sinks | awk '{print $2}' | grep -v 'balena-sound\|snapcast' || true)

if [ -n "$HW_SINKS" ]; then
  log_step "Available Hardware Output Sinks:"
  echo "$HW_SINKS" | nl -v 1 | sed 's/^/  /'
  log "  (Set AUDIO_OUTPUT=<name> to force a specific device)"
fi

HW_SINK=""

# If AUDIO_OUTPUT is explicitly set and not AUTO, force that device
if [ "$AUDIO_OUTPUT" != "AUTO" ]; then
  log_step "Forcing output device: $AUDIO_OUTPUT"
  HW_SINK=$(echo "$HW_SINKS" | grep -i "$AUDIO_OUTPUT" | head -n 1 || true)
  
  if [ -n "$HW_SINK" ]; then
    log_ok "Found matching device: $HW_SINK"
  else
    log_error "Device '$AUDIO_OUTPUT' not found! Available: $(echo "$HW_SINKS" | tr '\n' ', ')"
    log_warn "Falling back to auto-detection"
    AUDIO_OUTPUT="AUTO"
  fi
fi

# Auto-detect if AUDIO_OUTPUT is AUTO or device not found
if [ "$AUDIO_OUTPUT" = "AUTO" ] || [ -z "$HW_SINK" ]; then
  log_step "Auto-detecting best output device..."
  HW_SINKS_DETECTED=$(detect_hardware_sink) || true
  if [ -n "$HW_SINKS_DETECTED" ]; then
    log_step "Available Hardware Output Sinks (detected):"
    echo "$HW_SINKS_DETECTED" | nl -v 1 | sed 's/^/  /'
    log "  (Set AUDIO_OUTPUT=<name> to force a specific device)"
    HW_SINK=$(select_hardware_sink "$HW_SINKS_DETECTED" "") || true
  fi

  if [ -z "$HW_SINK" ]; then
    log_warn "Hardware sink detection timeout, attempting to use system default"
    HW_SINK=$(pactl info | awk '/Default Sink:/ {print $3}' || true)
  fi
fi

if [ -z "$HW_SINK" ]; then
  log_error "No hardware sink available! Audio output will not work."
  HW_SINK="alsa_output.platform-soc_sound.stereo-fallback"
  log_warn "Using last-resort fallback: $HW_SINK"
fi

log_ok "Selected Output Sink: $HW_SINK"

if pactl set-default-sink "$HW_SINK" 2>/dev/null; then
  log_ok "Default output sink configured successfully"
else
  log_warn "Failed to set default sink (continuing anyway)"
fi

# Apply volume now that sink is confirmed
SAVED_VOLUME=$(cat /run/pulse/audio-default-volume 2>/dev/null || echo "49152")
if pactl set-sink-volume @DEFAULT_SINK@ "$SAVED_VOLUME" 2>/dev/null; then
  log_ok "Default volume set to $SAVED_VOLUME"
else
  log_warn "Failed to set default volume"
fi

# Update balena-sound config with detected sink
if sed -i "s/%OUTPUT_SINK%/sink=$HW_SINK/" "$CONFIG_FILE" 2>/dev/null; then
  log_ok "Audio configuration updated with selected output sink"
else
  log_warn "Failed to update configuration file"
fi

# ============================================================================
# PHASE 7B: INPUT DEVICE DETECTION (FOR KARAOKE AND MIC INPUT)
# ============================================================================

log_section "PHASE 7B: Hardware Input Device Detection"

# Read input preference (defaults to AUTO if not set)
AUDIO_INPUT=${AUDIO_INPUT:-AUTO}
log "Input preference: $AUDIO_INPUT"

log_step "Detecting hardware audio sources (microphones)..."
HW_SOURCES=$(pactl list short sources 2>/dev/null | awk '{print $2}' | grep -v 'balena-sound\|snapcast\|\.monitor' || true)

if [ -n "$HW_SOURCES" ]; then
  log_step "Available Hardware Input Sources:"
  echo "$HW_SOURCES" | nl -v 1 | sed 's/^/  /'
  log "  (Set AUDIO_INPUT=<n> to force a specific device)"
  
  HW_SOURCE=""
  
  # If AUDIO_INPUT is explicitly set and not AUTO, force that device
  if [ "$AUDIO_INPUT" != "AUTO" ]; then
    log_step "Forcing input device: $AUDIO_INPUT"
    HW_SOURCE=$(echo "$HW_SOURCES" | grep -i "$AUDIO_INPUT" | head -n 1 || true)
    
    if [ -n "$HW_SOURCE" ]; then
      log_ok "Found matching device: $HW_SOURCE"
    else
      log_error "Device '$AUDIO_INPUT' not found! Available: $(echo "$HW_SOURCES" | tr '\n' ', ')"
      log_warn "Falling back to auto-detection"
      AUDIO_INPUT="AUTO"
    fi
  fi

  # Auto-detect if AUDIO_INPUT is AUTO or device not found
  if [ "$AUDIO_INPUT" = "AUTO" ] || [ -z "$HW_SOURCE" ]; then
    log_step "Auto-detecting best input device..."
    HW_SOURCES_DETECTED=$(detect_hardware_source) || true
    if [ -n "$HW_SOURCES_DETECTED" ]; then
      HW_SOURCE=$(select_hardware_source "$HW_SOURCES_DETECTED") || true
    fi
  fi

  if [ -n "$HW_SOURCE" ]; then
    log_ok "Selected Input Source: $HW_SOURCE"
    echo "$HW_SOURCE" > /run/pulse/audio-input-device
    
    if pactl set-default-source "$HW_SOURCE" 2>/dev/null; then
      log_ok "Default input source configured successfully"
    else
      log_warn "Failed to set default input source (continuing anyway)"
    fi

    # ========================================================================
    # PHASE 7C: OPTIONAL MIC LOOPBACK FOR TESTING/MONITORING
    # ========================================================================
    
    AUDIO_INPUT_LOOPBACK=${AUDIO_INPUT_LOOPBACK:-false}
    AUDIO_MIC_INPUT_VOLUME=${AUDIO_MIC_INPUT_VOLUME:-40}
    
    if [ "$AUDIO_INPUT_LOOPBACK" = "true" ] || [ "$AUDIO_INPUT_LOOPBACK" = "1" ]; then
      log_step "Enabling mic loopback to speakers for real-time monitoring..."
      
      # Clean up any existing loopback modules first
      pactl list modules 2>/dev/null | grep -o "Module #[0-9]*" | awk '{print $2}' | while read mod; do
        pactl unload-module "$mod" 2>/dev/null || true
      done
      sleep 1
      
      # Set mic volume (default 40%)
      if pactl set-source-volume mic_filtered "$AUDIO_MIC_INPUT_VOLUME%" 2>/dev/null; then
        log_ok "Mic volume set to ${AUDIO_MIC_INPUT_VOLUME}%"
      else
        log_warn "Failed to set mic volume to ${AUDIO_MIC_INPUT_VOLUME}%"
      fi
      
      # Load fresh loopback
      if pactl load-module module-loopback source=mic_filtered sink="$HW_SINK" latency_msec=50 remix=true > /dev/null 2>&1; then
        log_ok "Mic loopback enabled (filtered @ ${AUDIO_MIC_INPUT_VOLUME}%) - you will hear yourself through speakers"
        log "  (This is useful for testing. Disable with AUDIO_INPUT_LOOPBACK=false)"
      else
        log_warn "Failed to enable mic loopback (continuing without it)"
      fi
    else
      log_ok "Mic loopback disabled (AUDIO_INPUT_LOOPBACK=false)"
      log "  To enable: set AUDIO_INPUT_LOOPBACK=true in Balena"
    fi
  else
    log_warn "Could not select input source"
    echo "" > /run/pulse/audio-input-device
  fi
else
  log_warn "No input devices (microphones) detected"
  echo "" > /run/pulse/audio-input-device
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
    [[ "$cmd" =~ ^#.*$ ]] || [[ -z "$cmd" ]] && continue

    if [[ "$cmd" == *\$* ]]; then
      log_warn "  Skipping command with unexpanded variable: $cmd"
      continue
    fi
    
    # Skip empty/malformed set-default-sink commands
    if [[ "$cmd" =~ ^set-default-sink[[:space:]]*$ ]]; then
       log_warn "  Skipping malformed command: $cmd (Missing sink name)"
       continue
    fi

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
log "Audio Configuration Summary:"
log "  - Output Sink: $HW_SINK (DAC > USB > HDMI priority)"
log "  - Input Source: $(cat /run/pulse/audio-input-device 2>/dev/null || echo 'None detected')"
log "  - Mic Loopback: ${AUDIO_INPUT_LOOPBACK:-false}"
log "  - Input Latency: ${SOUND_INPUT_LATENCY}ms"
log "  - Output Latency: ${SOUND_OUTPUT_LATENCY}ms"
log "  - Mode: $MODE"
log ""

wait $PW_PULSE_PID