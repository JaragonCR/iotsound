#!/bin/bash
set -e

# Run balena base image entrypoint script
/usr/bin/entry.sh echo ""

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
  if [[ "${options[$PA_LOG_LEVEL]}" ]]; then
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

function pa_set_default_output () {
  local OUTPUT="$1"
  local PA_SINK=""

  declare -A options=(
    ["RPI_AUTO"]=0
    ["RPI_HEADPHONES"]=1
    ["RPI_HDMI0"]=2
    ["RPI_HDMI1"]=3
    ["AUTO"]=4
    ["DAC"]=5
  )

  BCM2835_CARDS=($(cat /proc/asound/cards | mawk -F '\[|\]:' '/bcm2835/ && NR%2==1 {gsub(/ /, "", $0); print $2}'))
  USB_CARDS=($(cat /proc/asound/cards | mawk -F '\[|\]:' '/usb/ && NR%2==1 {gsub(/ /, "", $0); print $2}'))
  DAC_CARD=$(cat /proc/asound/cards | mawk -F '\[|\]:' '/dac|DAC|Dac/ && NR%2==1 {gsub(/ /, "", $0); print $2}')
  HDA_CARD=$(cat /proc/asound/cards | mawk -F '\[|\]:' '/hda-intel/ && NR%2==1 {gsub(/ /, "", $0); print $2}')

  case "${options[$OUTPUT]}" in
    ${options["RPI_AUTO"]} | ${options["RPI_HEADPHONES"]} | ${options["RPI_HDMI0"]} | ${options["RPI_HDMI1"]})
      if [[ -n "$BCM2835_CARDS" ]]; then
        if [[ "${BCM2835_CARDS[@]}" =~ "bcm2835-alsa" ]]; then
          amixer --card bcm2835-alsa --quiet cset numid=3 "${options[$OUTPUT]}"
          PA_SINK="alsa_output.bcm2835-alsa.stereo-fallback"
        else
          if [[ "${options[$OUTPUT]}" == "${options["RPI_HEADPHONES"]}" ]]; then
            PA_SINK="alsa_output.bcm2835-jack.stereo-fallback"
          elif [[ "${options[$OUTPUT]}" == "${options["RPI_HDMI0"]}" ]]; then
            PA_SINK="alsa_output.bcm2835-hdmi0.stereo-fallback"
          elif [[ "${options[$OUTPUT]}" == "${options["RPI_HDMI1"]}" ]]; then
            PA_SINK="alsa_output.bcm2835-hdmi1.stereo-fallback"
          else
            echo "WARNING: Option not supported for this kernel version. Using defaults..."
          fi
        fi
      else
        echo "WARNING: BCM2835 audio card not found."
      fi
      ;;

    ${options["DAC"]})
      if [[ -n "$DAC_CARD" ]]; then
        PA_SINK="alsa_output.dac.stereo-fallback"
      else
        echo "WARNING: No DAC found. Falling back to defaults."
      fi
      ;;

    ${options["AUTO"]})
      declare -a sound_cards=("${USB_CARDS[@]}" "$DAC_CARD" "${BCM2835_CARDS[@]}")
      for sound_card in "${sound_cards[@]}"; do
        if [[ -n "$sound_card" ]]; then
          if [[ -n "$USB_CARDS" ]]; then
            PA_SINK="alsa_output.${USB_CARDS[0]}.analog-stereo"
          elif [[ -n "$DAC_CARD" ]]; then
            PA_SINK="alsa_output.dac.stereo-fallback"
          elif [[ -n "$BCM2835_CARDS" ]]; then
            if [[ "${BCM2835_CARDS[@]}" =~ "bcm2835-alsa" ]]; then
              PA_SINK="alsa_output.bcm2835-alsa.stereo-fallback"
            else
              PA_SINK="alsa_output.bcm2835-jack.stereo-fallback"
            fi
          fi
          break
        fi
      done
      ;;

    *)
      PA_SINK="$OUTPUT"
      ;;
  esac

  if [[ -n "$PA_SINK" ]]; then
    # Verify sink exists in PipeWire before writing - sink names differ between PulseAudio and PipeWire
    ACTUAL_SINK=$(pactl list short sinks 2>/dev/null | awk '{print $2}' | grep -F "$PA_SINK" | head -1)
    if [[ -z "$ACTUAL_SINK" ]]; then
      echo "WARNING: Sink $PA_SINK not found, using PipeWire auto-detected sink"
      PA_SINK=$(pactl list short sinks 2>/dev/null | grep -v "null-sink\|monitor\|balena-sound\|snapcast" | awk 'NR==1{print $2}')
    fi
    echo "$PA_SINK" > /run/pulse/pulseaudio.sink
    echo -e "\nset-default-sink $PA_SINK" >> /etc/pulse/default.pa.d/00-audioblock.pa
  fi
}

function init_audio_hardware () {
  sleep 10
  HDA_CARD=$(cat /proc/asound/cards | mawk -F '\[|\]:' '/hda-intel/ && NR%2==1 {gsub(/ /, "", $0); print $2}')
  if [[ -n "$HDA_CARD" ]]; then
    amixer --card hda-intel --quiet cset numid=2 on,on
    amixer --card hda-intel --quiet cset numid=1 87,87
    PA_SINK="alsa_output.hda-intel.analog-stereo"
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

function pa_set_default_volume () {
  local VOLUME_PERCENTAGE=$(sanitize_volume "$1")
  local VOLUME_ABSOLUTE=$(( VOLUME_PERCENTAGE * 65536 / 100 ))
  if [[ -n "$VOLUME_ABSOLUTE" ]]; then
    echo -e "\nset-sink-volume @DEFAULT_SINK@ $VOLUME_ABSOLUTE" >> /etc/pulse/default.pa.d/00-audioblock.pa
  fi
}

# Environment variables and defaults
INIT_LOG="${AUDIO_INIT_LOG:-true}"
LOG_LEVEL="${AUDIO_LOG_LEVEL:-NOTICE}"
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

# Configure audio hardware
init_audio_hardware
pa_set_default_volume "$DEFAULT_VOLUME"

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

# Start PipeWire stack if available, fallback to PulseAudio
if command -v pipewire &> /dev/null; then
  echo "Setting audio routing rules..."
  pipewire &
  sleep 1
  wireplumber &
  sleep 1
  if [[ "${1#-}" != "$1" ]]; then
    set -- pipewire-pulse "$@"
  fi
  exec "$@"
else
  if [[ "${1#-}" != "$1" ]]; then
    set -- pulseaudio "$@"
  fi
  exec "$@"
fi
