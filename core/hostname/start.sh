#!/bin/sh
# SOUND_DEVICE_NAME is injected automatically by balena from fleet/device variables
HOSTNAME="${SOUND_DEVICE_NAME:-iotsound}"

echo "[hostname] Setting hostname to: $HOSTNAME"

curl -s -X PATCH \
  --header "Content-Type: application/json" \
  --data "{\"network\": {\"hostname\": \"$HOSTNAME\"}}" \
  "$BALENA_SUPERVISOR_ADDRESS/v1/device/host-config?apikey=$BALENA_SUPERVISOR_API_KEY"

echo "[hostname] Done"
