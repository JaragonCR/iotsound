#!/bin/sh
# SOUND_DEVICE_NAME is injected automatically by balena from fleet/device variables
TARGET_HOSTNAME="${SOUND_DEVICE_NAME:-iotsound}"
CURRENT_HOSTNAME=$(hostname)

echo "[hostname] Current hostname: $CURRENT_HOSTNAME"
echo "[hostname] Target hostname: $TARGET_HOSTNAME"

if [ "$CURRENT_HOSTNAME" = "$TARGET_HOSTNAME" ]; then
  echo "[hostname] Hostname already matches target. Skipping update."
  exit 0
fi

echo "[hostname] Setting hostname to: $TARGET_HOSTNAME"

curl -s -X PATCH \
  --header "Content-Type: application/json" \
  --data "{\"network\": {\"hostname\": \"$TARGET_HOSTNAME\"}}" \
  "$BALENA_SUPERVISOR_ADDRESS/v1/device/host-config?apikey=$BALENA_SUPERVISOR_API_KEY"

echo "[hostname] Done"
