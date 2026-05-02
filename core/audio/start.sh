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
  local ROLE="$1"
  case "$ROLE" in
    disabled)
      sed -i "s/%INPUT_SINK%/sink=balena-sound.output/" "$CONFIG_FILE"
      log "Routing 'balena-sound.input' to 'balena-sound.output' (role: $ROLE)."
      ;;
    auto|host|join|*)
      sed -i "s/%INPUT_SINK%/sink=snapcast/" "$CONFIG_FILE"
      log "Routing 'balena-sound.input' to 'snapcast' (role: $ROLE)."
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

function get_sound_supervisor_role() {
  local role=$(curl --silent "$SOUND_SUPERVISOR/role" 2>/dev/null || echo "")
  if [ -z "$role" ]; then
    log_warn "Could not retrieve role from sound supervisor, defaulting to disabled"
    role="disabled"
  fi
  echo "$role"
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
  ROLE=$(get_sound_supervisor_role)
else
  ROLE="disabled"
fi

log_ok "Sound supervisor role: $ROLE"

# ============================================================================
# PHASE 2: PIPEWIRE FILTER CONFIGURATION (BEFORE services start)
# ============================================================================

log_section "PHASE 2: PipeWire Filter Configuration"

log_step "Configuring PipeWire audio filters for microphone input..."

# Easy button to disable all EQ at once
AUDIO_INPUT_EQ_DISABLED=${AUDIO_INPUT_EQ_DISABLED:-true}

if [ "$AUDIO_INPUT_EQ_DISABLED" = "true" ] || [ "$AUDIO_INPUT_EQ_DISABLED" = "1" ]; then
  log_ok "Microphone EQ DISABLED via AUDIO_INPUT_EQ_DISABLED=true"
  log "All filter customizations ignored - using raw USB input"
  # Skip all filter setup
  mkdir -p /etc/pipewire/pipewire.conf.d/
  rm -f /etc/pipewire/pipewire.conf.d/99-mic-filters.conf
else
  # Microphone filter parameters
# AUDIO_INPUT_HIGHPASS: High-pass cutoff frequency (Hz) - removes rumble/noise
#   Default: 130Hz (professional vocal standard)
# AUDIO_INPUT_LOWPASS: Low-pass cutoff frequency (Hz) - removes harshness  
#   Default: 15000Hz (bright, presence-focused)
# AUDIO_INPUT_HIGHPASS_Q: High-pass filter Q factor (bandwidth)
#   Default: 1.0 (wider, more natural sounding)
# AUDIO_INPUT_LOWPASS_Q: Low-pass filter Q factor (bandwidth)
#   Default: 1.0 (wider, more natural sounding)
# AUDIO_INPUT_BOXY_CUT: Peaking filter cut at 500Hz to remove boxy sound
#   Default: -2 dB (subtle cut), set to 0 to disable
#   Negative = cut (reduce boxy frequencies), Positive = boost
# AUDIO_INPUT_PROXIMITY_CUT: Peaking filter cut at 250Hz to remove proximity effect
#   Default: -2 dB (reduces low-mid boost from close miking), set to 0 to disable
#   Negative = cut (reduce proximity boost), Positive = boost
AUDIO_INPUT_HIGHPASS=${AUDIO_INPUT_HIGHPASS:-130}
AUDIO_INPUT_LOWPASS=${AUDIO_INPUT_LOWPASS:-15000}
AUDIO_INPUT_HIGHPASS_Q=${AUDIO_INPUT_HIGHPASS_Q:-1.0}
AUDIO_INPUT_LOWPASS_Q=${AUDIO_INPUT_LOWPASS_Q:-1.0}
AUDIO_INPUT_BOXY_CUT=${AUDIO_INPUT_BOXY_CUT:--2}
AUDIO_INPUT_PROXIMITY_CUT=${AUDIO_INPUT_PROXIMITY_CUT:--2}

log "Microphone filter settings:"
log "  Highpass: ${AUDIO_INPUT_HIGHPASS}Hz, Q=${AUDIO_INPUT_HIGHPASS_Q}"
log "  Proximity (250Hz): ${AUDIO_INPUT_PROXIMITY_CUT}dB"
log "  Boxy (500Hz): ${AUDIO_INPUT_BOXY_CUT}dB"
log "  Lowpass: ${AUDIO_INPUT_LOWPASS}Hz, Q=${AUDIO_INPUT_LOWPASS_Q}"
log "  (0/empty = disabled)"

mkdir -p /etc/pipewire/pipewire.conf.d/

# Determine which filters are active
HP_ACTIVE=false
LP_ACTIVE=false
BOXY_ACTIVE=false
PROXIMITY_ACTIVE=false
[ "$AUDIO_INPUT_HIGHPASS" != "0" ] && [ -n "$AUDIO_INPUT_HIGHPASS" ] && HP_ACTIVE=true
[ "$AUDIO_INPUT_LOWPASS" != "0" ] && [ -n "$AUDIO_INPUT_LOWPASS" ] && LP_ACTIVE=true
[ "$AUDIO_INPUT_BOXY_CUT" != "0" ] && [ -n "$AUDIO_INPUT_BOXY_CUT" ] && BOXY_ACTIVE=true
[ "$AUDIO_INPUT_PROXIMITY_CUT" != "0" ] && [ -n "$AUDIO_INPUT_PROXIMITY_CUT" ] && PROXIMITY_ACTIVE=true

if [ "$HP_ACTIVE" = true ] || [ "$LP_ACTIVE" = true ] || [ "$BOXY_ACTIVE" = true ] || [ "$PROXIMITY_ACTIVE" = true ]; then
  # Build filter chain
  NODES_SECTION=""
  LINKS_SECTION=""
  CURRENT_OUTPUT="hp:Out"
  
  if [ "$HP_ACTIVE" = true ]; then
    NODES_SECTION="${NODES_SECTION}
                    {
                        type   = builtin
                        name   = hp
                        label  = bq_highpass
                        control = { Freq = $AUDIO_INPUT_HIGHPASS Q = $AUDIO_INPUT_HIGHPASS_Q }
                    }"
    CURRENT_OUTPUT="hp:Out"
  fi
  
  # Add proximity cut filter (250Hz) after highpass
  if [ "$PROXIMITY_ACTIVE" = true ]; then
    NODES_SECTION="${NODES_SECTION}
                    {
                        type   = builtin
                        name   = proximity
                        label  = bq_peaking
                        control = { Freq = 250 Q = 0.707 Gain = $AUDIO_INPUT_PROXIMITY_CUT }
                    }"
    
    if [ "$HP_ACTIVE" = true ]; then
      LINKS_SECTION="${LINKS_SECTION}
                    { output = \"hp:Out\" input = \"proximity:In\" }"
    fi
    CURRENT_OUTPUT="proximity:Out"
  fi
  
  # Add boxy cut filter (500Hz) after proximity
  if [ "$BOXY_ACTIVE" = true ]; then
    NODES_SECTION="${NODES_SECTION}
                    {
                        type   = builtin
                        name   = boxy
                        label  = bq_peaking
                        control = { Freq = 500 Q = 0.707 Gain = $AUDIO_INPUT_BOXY_CUT }
                    }"
    
    if [ "$HP_ACTIVE" = true ] || [ "$PROXIMITY_ACTIVE" = true ]; then
      LINKS_SECTION="${LINKS_SECTION}
                    { output = \"$CURRENT_OUTPUT\" input = \"boxy:In\" }"
    fi
    CURRENT_OUTPUT="boxy:Out"
  fi
  
  # Add lowpass filter last
  if [ "$LP_ACTIVE" = true ]; then
    NODES_SECTION="${NODES_SECTION}
                    {
                        type   = builtin
                        name   = lp
                        label  = bq_lowpass
                        control = { Freq = $AUDIO_INPUT_LOWPASS Q = $AUDIO_INPUT_LOWPASS_Q }
                    }"
    
    LINKS_SECTION="${LINKS_SECTION}
                    { output = \"$CURRENT_OUTPUT\" input = \"lp:In\" }"
    CURRENT_OUTPUT="lp:Out"
  fi
  
  # Determine input/output ports
  if [ "$HP_ACTIVE" = true ]; then
    INPUT_PORT="hp:In"
  elif [ "$PROXIMITY_ACTIVE" = true ]; then
    INPUT_PORT="proximity:In"
  elif [ "$BOXY_ACTIVE" = true ]; then
    INPUT_PORT="boxy:In"
  else
    INPUT_PORT="lp:In"
  fi
  
  OUTPUT_PORT="$CURRENT_OUTPUT"
  
  cat > /etc/pipewire/pipewire.conf.d/99-mic-filters.conf << EOF
context.modules = [
    { name = libpipewire-module-filter-chain
        args = {
            node.description = "Mic Audio Filters"
            media.name       = "Mic Filtered"
            filter.graph = {
                nodes = [$NODES_SECTION
                ]
                links = [$LINKS_SECTION
                ]
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
  MIC_SOURCE="mic_filtered"
else
  log_ok "All microphone filters disabled - using raw USB input"
  MIC_SOURCE="$HW_SOURCE"
  # HW_SOURCE will be set to the detected USB mic in Phase 7B
fi
fi

# ============================================================================
# PHASE 3: PULSEAUDIO CONFIGURATION
# ============================================================================

log_section "PHASE 3: PulseAudio Configuration"

# Capture user overrides now; final defaults are set after output device
# detection (Phase 8A) so HDMI can use a larger buffer automatically.
SOUND_INPUT_LATENCY_OVERRIDE="${SOUND_INPUT_LATENCY:-}"
SOUND_OUTPUT_LATENCY_OVERRIDE="${SOUND_OUTPUT_LATENCY:-}"

log_step "Preparing audio routing configuration..."
reset_sound_config
route_input_sink "$ROLE"
# Latency placeholders (%INPUT_LATENCY%, %OUTPUT_LATENCY%) are filled after
# Phase 8A once the output device type is known.

if [[ -n "$SOUND_ENABLE_SOUNDCARD_INPUT" ]]; then
  log_step "Enabling soundcard input routing..."
  route_input_source
fi

log_ok "Audio routing configuration prepared"

# ============================================================================
# PHASE 4: CLEANUP AND ENVIRONMENT SETUP
# ============================================================================

log_section "PHASE 4: Environment Setup"

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
# PHASE 5: START DBUS DAEMON
# ============================================================================

log_section "PHASE 5: D-Bus Daemon"

log_step "Starting D-Bus daemon..."
dbus-daemon --session --address=$DBUS_SESSION_BUS_ADDRESS --nofork --nopidfile --syslog-only &
sleep 1
log_ok "D-Bus daemon started"

# ============================================================================
# PHASE 6: START PIPEWIRE STACK
# ============================================================================

log_section "PHASE 6: PipeWire Stack Initialization"

log_step "Starting PipeWire daemon..."
pipewire > /var/log/pipewire.log 2>&1 &
PIPEWIRE_PID=$!
sleep 1
log_ok "PipeWire daemon started (PID: $PIPEWIRE_PID)"

log_step "Starting WirePlumber daemon..."
log "WirePlumber version: $(wireplumber --version 2>&1 || echo 'unknown')"
log "  /usr/share/wireplumber: $(ls /usr/share/wireplumber/ 2>/dev/null | tr '\n' ' ')"
log "  /etc/wireplumber:       $(ls -R /etc/wireplumber/ 2>/dev/null | tr '\n' ' ')"
log "  /usr/share/wireplumber/scripts: $(ls /usr/share/wireplumber/scripts/ 2>/dev/null | tr '\n' ' ')"

# Expose supervisor URL so 99-balena-play-detect.lua can call back for play events
export SOUND_SUPERVISOR_URL="http://$(ip route | awk '/default / { print $3 }'):$SOUND_SUPERVISOR_PORT"
log "SOUND_SUPERVISOR_URL=$SOUND_SUPERVISOR_URL"

# Level W: warnings only from WirePlumber; our print() calls bypass this entirely
export WIREPLUMBER_DEBUG=W
wireplumber 2>&1 | tee /var/log/wireplumber.log &
sleep 1
log_ok "WirePlumber daemon started"

log_step "Starting PipeWire-Pulse compatibility layer..."
pipewire-pulse > /var/log/pipewire-pulse.log 2>&1 &
PW_PULSE_PID=$!
log_ok "PipeWire-Pulse started (PID: $PW_PULSE_PID)"

# ============================================================================
# PHASE 7: WAIT FOR PULSEAUDIO READINESS
# ============================================================================

if ! wait_for_pulseaudio; then
  log_error "PulseAudio stack failed to initialize!"
  log_error "Check /var/log/pipewire*.log for details"
  exit 1
fi

# ============================================================================
# PHASE 8: OUTPUT DEVICE DETECTION AND SELECTION (DAC PRIORITY)
# ============================================================================

log_section "PHASE 8: Hardware Output Device Detection"

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

# Resolve loopback latency defaults now that HW_SINK is known.
# HDMI (mailbox driver) can have hardware periods of 341-682ms, so it needs
# a large loopback buffer. I2S (HiFiBerry), USB, and 3.5mm run at ~21ms.
if echo "${HW_SINK:-}" | grep -qi "mailbox\|hdmi"; then
  SOUND_INPUT_LATENCY="${SOUND_INPUT_LATENCY_OVERRIDE:-500}"
  SOUND_OUTPUT_LATENCY="${SOUND_OUTPUT_LATENCY_OVERRIDE:-500}"
else
  SOUND_INPUT_LATENCY="${SOUND_INPUT_LATENCY_OVERRIDE:-100}"
  SOUND_OUTPUT_LATENCY="${SOUND_OUTPUT_LATENCY_OVERRIDE:-100}"
fi
set_loopback_latency "INPUT_LATENCY" "$SOUND_INPUT_LATENCY"
set_loopback_latency "OUTPUT_LATENCY" "$SOUND_OUTPUT_LATENCY"
log "Loopback latencies: input=${SOUND_INPUT_LATENCY}ms output=${SOUND_OUTPUT_LATENCY}ms"

# ============================================================================
# PHASE 8B: INPUT DEVICE DETECTION (FOR KARAOKE AND MIC INPUT)
# ============================================================================

log_section "PHASE 8B: Hardware Input Device Detection"

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
    # DETERMINE MIC SOURCE (filtered or raw based on what's available)
    # ========================================================================
    
    if pactl list sources short 2>/dev/null | grep -q "mic_filtered"; then
      MIC_SOURCE="mic_filtered"
      log_ok "Using filtered microphone input (mic_filtered)"
    else
      MIC_SOURCE="$HW_SOURCE"
      log_ok "Using raw microphone input: $HW_SOURCE"
    fi

    # ========================================================================
    # PHASE 8C: OPTIONAL MIC LOOPBACK FOR TESTING/MONITORING
    # ========================================================================
    
    AUDIO_INPUT_LOOPBACK=${AUDIO_INPUT_LOOPBACK:-false}
    AUDIO_MIC_INPUT_VOLUME=${AUDIO_MIC_INPUT_VOLUME:-35}
    
    if [ "$AUDIO_INPUT_LOOPBACK" = "true" ] || [ "$AUDIO_INPUT_LOOPBACK" = "1" ]; then
      log_step "Enabling mic loopback to speakers for real-time monitoring..."
      
      # Clean up any existing loopback modules first
      pactl list modules 2>/dev/null | grep -o "Module #[0-9]*" | awk '{print $2}' | while read mod; do
        pactl unload-module "$mod" 2>/dev/null || true
      done
      sleep 1
      
      # Set mic volume (default 40%)
      if pactl set-source-volume "$MIC_SOURCE" "$AUDIO_MIC_INPUT_VOLUME%" 2>/dev/null; then
        log_ok "Mic volume set to ${AUDIO_MIC_INPUT_VOLUME}%"
      else
        log_warn "Failed to set mic volume to ${AUDIO_MIC_INPUT_VOLUME}%"
      fi
      
      # Load fresh loopback using MIC_SOURCE (filtered or raw)
      if pactl load-module module-loopback source="$MIC_SOURCE" sink="$HW_SINK" latency_msec=50 remix=true > /dev/null 2>&1; then
        log_ok "Mic loopback enabled (${MIC_SOURCE} @ ${AUDIO_MIC_INPUT_VOLUME}%) - you will hear yourself through speakers"
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
# PHASE 9: APPLY PULSEAUDIO ROUTING RULES
# ============================================================================

log_section "PHASE 9: Applying PulseAudio Routing Rules"

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
# PHASE 10: STARTUP COMPLETE
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
log "  - Role: $ROLE"
log ""

# Background play-detector: watches for sink-inputs on balena-sound.input and
# notifies the supervisor via /internal/play and /internal/stop.
# Uses pactl subscribe (event-driven) + pactl list sink-inputs (state check) so
# it fires correctly regardless of how PipeWire routes streams internally.
if [ -n "$SOUND_SUPERVISOR_URL" ]; then
  (
    get_input_sink_idx() {
      pactl list short sinks 2>/dev/null | awk '/balena-sound\.input[[:space:]]/{print $1; exit}'
    }
    has_plugin_playing() {
      local idx; idx=$(get_input_sink_idx)
      [ -n "$idx" ] && pactl list sink-inputs 2>/dev/null | grep -q "Sink: ${idx}$"
    }
    _last_state=""
    pactl subscribe 2>/dev/null | while IFS= read -r _ev; do
      case "$_ev" in *"on sink-input"*)
        if has_plugin_playing; then _new="play"; else _new="stop"; fi
        if [ "$_new" != "$_last_state" ]; then
          _last_state="$_new"
          if [ "$_new" = "play" ]; then
            echo "[play-detect] play started → $SOUND_SUPERVISOR_URL/internal/play"
            curl -sf -X POST "$SOUND_SUPERVISOR_URL/internal/play" >/dev/null 2>&1 || true
          else
            echo "[play-detect] play stopped → $SOUND_SUPERVISOR_URL/internal/stop"
            curl -sf -X POST "$SOUND_SUPERVISOR_URL/internal/stop" >/dev/null 2>&1 || true
          fi
        fi
      ;; esac
    done
  ) &
  log "Play detector started (pactl subscribe → $SOUND_SUPERVISOR_URL)"
fi

wait $PW_PULSE_PID