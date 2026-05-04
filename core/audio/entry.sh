#!/bin/bash
set -e

# WirePlumber uses libudev to enumerate ALSA devices. Without a running
# udevd the SPA ALSA plugin finds nothing and PipeWire falls back to
# auto_null. Start udevd early so it populates /run/udev before PipeWire
# launches in start.sh Phase 6.
/sbin/udevd --daemon 2>/dev/null || true
udevadm trigger 2>/dev/null || true

# Helper functions
function pa_disable_module() {
  local MODULE="$1"
  if [ -f /etc/pulse/default.pa ]; then
   sed -i "s/load-module $MODULE/#load-module $MODULE/" /etc/pulse/default.pa
  fi
}

function pa_set_log_level() {
  local PA_LOG_LEVEL="$1"
  declare -A options=(["ERROR"]=0 ["WARN"]=1 ["NOTICE"]=2 ["INFO"]=3 ["DEBUG"]=4)
  if [[ -v options[$PA_LOG_LEVEL] ]]; then
    LOWER_LOG_LEVEL=$(echo "$PA_LOG_LEVEL" | tr '[:upper:]' '[:lower:]')
    if [[ -f /etc/pulse/daemon.conf ]]; then
      sed -i "s/log-level = notice/log-level = $LOWER_LOG_LEVEL/g" /etc/pulse/daemon.conf
    fi
  fi
}

function pa_set_cookie() {
  local PA_COOKIE="$1"
  if [[ ${#PA_COOKIE} == 512 && "$PA_COOKIE" =~ ^[0-9A-Fa-f]{1,}$ ]]; then
    echo "$PA_COOKIE" | xxd -r -p | tee /run/pulse/pulseaudio.cookie > /dev/null
  fi
}

function pa_read_cookie () {
  if [[ -f /run/pulse/pulseaudio.cookie ]]; then
    xxd -c 512 -p /run/pulse/pulseaudio.cookie
  fi
}

function init_audio_hardware () {
  sleep 10
  HDA_CARD=$(cat /proc/asound/cards | mawk -F '\[|\]:' '/hda-intel/ && NR%2==1 {gsub(/ /, "", $0); print $2}')
  if [[ -n "$HDA_CARD" ]]; then
    amixer --card hda-intel --quiet cset numid=2 on,on
    amixer --card hda-intel --quiet cset numid=1 87,87
  fi
}

function print_audio_cards () {
  cat /proc/asound/cards | mawk -F '\[|\]:' 'NR%2==1 {gsub(/ /, "", $0); print $1,$2,$3}'
}

function sanitize_volume () {
  local VOLUME="${1//%}"
  if [[ "$VOLUME" -ge 0 && "$VOLUME" -le 100 ]]; then
    echo "$VOLUME"
  fi
}

# Environment variables and defaults
INIT_LOG="${AUDIO_INIT_LOG:-true}"
LOG_LEVEL="${AUDIO_LOG_LEVEL:-${LOG_LEVEL:-NOTICE}}"
LOG_LEVEL=$(echo "$LOG_LEVEL" | tr '[:lower:]' '[:upper:]')
COOKIE="${AUDIO_PULSE_COOKIE}"
DEFAULT_OUTPUT="${AUDIO_OUTPUT:-AUTO}"
DEFAULT_VOLUME="${AUDIO_VOLUME:-75}"

if [[ "$INIT_LOG" != "false" ]]; then
  echo "--- Audio ---"
  echo "Starting audio service with settings:"
  if command -v pipewire &> /dev/null; then
    echo "- pipewire $(pipewire --version 2>/dev/null | head -1) (pipewire-pulse active)"
  else
    echo "- $(pulseaudio --version)"
  fi
  echo "- Pulse log level: $LOG_LEVEL"
  [[ -n ${COOKIE} ]] && echo "- Pulse cookie: $COOKIE"
  echo "- Default output: $DEFAULT_OUTPUT"
  echo "- Default volume: $DEFAULT_VOLUME%"
  echo -e "\nDetected audio cards:"
  print_audio_cards
  echo -e "\n"
fi

# Create dir for temp/share files
mkdir -p /run/pulse

# Save preferences for start.sh to apply after PipeWire initializes
echo "$DEFAULT_OUTPUT" > /run/pulse/audio-output-preference
VOLUME_ABSOLUTE=$(( $(sanitize_volume "$DEFAULT_VOLUME") * 65536 / 100 ))
echo "$VOLUME_ABSOLUTE" > /run/pulse/audio-default-volume

# Initialize hardware (HDA amixer settings only, no sink selection)
init_audio_hardware

# Disable unused PulseAudio modules (safe no-ops if default.pa absent)
pa_disable_module module-console-kit
pa_disable_module module-dbus-protocol
pa_disable_module module-jackdbus-detect
pa_disable_module module-bluetooth-discover
pa_disable_module module-bluetooth-policy
pa_disable_module module-native-protocol-unix

pa_set_log_level "$LOG_LEVEL"

if [[ -n "$COOKIE" ]]; then
  pa_set_cookie "$COOKIE"
fi

# Execute the CMD passed by Docker (which is /bin/bash /usr/src/start.sh)
exec "$@"
