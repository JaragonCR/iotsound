#!/usr/bin/env sh
set -e

if [ -n "$SOUND_DISABLE_KARAOKE" ]; then
  echo "Karaoke is disabled, exiting..."
  exit 0
fi

exec ./karaoke
