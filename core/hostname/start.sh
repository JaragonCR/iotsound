#!/bin/sh
# Use SET_HOSTNAME if provided, otherwise fall back to 'iotsound'
HOSTNAME="${SET_HOSTNAME:-iotsound}"

echo "[hostname] Setting hostname to: $HOSTNAME"

curl -s -X PATCH \
  --header "Content-Type: application/json" \
  --data "{\"network\": {\"hostname\": \"$HOSTNAME\"}}" \
  "$BALENA_SUPERVISOR_ADDRESS/v1/device/host-config?apikey=$BALENA_SUPERVISOR_API_KEY"

echo "[hostname] Done"
