#!/usr/bin/env sh
set -e

if [ -n "$SOUND_DISABLE_KARAOKE" ]; then
  echo "Karaoke fetcher is disabled, exiting..."
  exit 0
fi

exec python fetcher.py
