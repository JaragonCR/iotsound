#!/bin/sh
set -eu

INTERVAL="${HOSTNAME_SYNC_INTERVAL:-60}"
_logged_match=false

apply_hostname() {
  TARGET_HOSTNAME="${SOUND_DEVICE_NAME:-iotsound}"

  # `hostname` returns the container's own short ID, not the host OS hostname.
  # Read the applied value from the supervisor host-config API instead.
  CURRENT_HOSTNAME=$(curl -sf \
    "$BALENA_SUPERVISOR_ADDRESS/v1/device/host-config?apikey=$BALENA_SUPERVISOR_API_KEY" \
    | grep -o '"hostname":"[^"]*"' | cut -d'"' -f4 || true)

  if [ -z "$CURRENT_HOSTNAME" ]; then
    echo "[hostname] Could not read current hostname from supervisor — skipping"
    return 0
  fi

  if [ "$CURRENT_HOSTNAME" = "$TARGET_HOSTNAME" ]; then
    if [ "$_logged_match" = "false" ]; then
      echo "[hostname] $CURRENT_HOSTNAME matches target — nothing to do"
      _logged_match=true
    fi
    return 0
  fi

  _logged_match=false
  echo "[hostname] Current: $CURRENT_HOSTNAME → Target: $TARGET_HOSTNAME — applying"

  # Check the PATCH explicitly: apply_hostname runs on the left of `||`, which
  # disables `set -e` inside the function, so a failed PATCH would otherwise fall
  # through to the reboot below and loop on every boot.
  if ! curl -fsS -X PATCH \
    --header "Content-Type: application/json" \
    --data "{\"network\": {\"hostname\": \"$TARGET_HOSTNAME\"}}" \
    "$BALENA_SUPERVISOR_ADDRESS/v1/device/host-config?apikey=$BALENA_SUPERVISOR_API_KEY"; then
    echo "[hostname] PATCH failed — not rebooting"
    return 1
  fi

  echo "[hostname] Applied — rebooting to take effect"
  curl -fsS -X POST \
    "$BALENA_SUPERVISOR_ADDRESS/v1/reboot?apikey=$BALENA_SUPERVISOR_API_KEY"
}

while true; do
  apply_hostname || echo "[hostname] Update failed; will retry"
  sleep "$INTERVAL"
done
