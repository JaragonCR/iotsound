#!/bin/bash
# Spotify engine supervisor: go-librespot (default) or Spotify Soloist (opt-in).
#
# Sourced by start.sh after the common waits and after the go-librespot config is written.
#
# Soloist is Spotify's own headless Connect client (https://github.com/spotify/soloist).
# Spotify does not allow its archives or binaries to be redistributed, so nothing from
# Spotify is in this image. The binary is downloaded from Spotify's CDN at runtime, and only
# when the user has both selected the engine and supplied their own API key:
#
#   SOUND_SPOTIFY_ENGINE=soloist   and   SOLOIST_API_KEY=<key from Spotify for Developers>
#
# No key, no download: go-librespot runs instead.
#
# Both engines live in this one container so that only one of them is ever running and
# advertising the speaker name. If Soloist keeps failing to start, go-librespot takes over
# and Soloist is retried later.

SOLOIST_DIR="$CONFIG_DIR/soloist"
SOLOIST_BIN="$SOLOIST_DIR/bin/soloist"
SOLOIST_ETAG_FILE="$SOLOIST_DIR/bin/etag"
SOLOIST_UPDATE_FLAG="$SOLOIST_DIR/.restart-for-update"
SOLOIST_CDN="https://soloist-builds.spotifycdn.com"

SOLOIST_FAIL_LIMIT=3            # failed starts ...
SOLOIST_FAIL_WINDOW_S=300       # ... within this window trigger the fallback
SOLOIST_MIN_HEALTHY_S=60        # a run shorter than this counts as a failed start
SOLOIST_UPDATE_CHECK_S=21600    # look for a new build every 6 hours
SOLOIST_RETRY_MIN=$(printf '%s' "${SOUND_SPOTIFY_SOLOIST_RETRY_MIN:-30}" | tr -cd '0-9')
SOLOIST_RETRY_MIN=${SOLOIST_RETRY_MIN:-30}
SOLOIST_CACHE_MB=$(printf '%s' "${SOUND_SPOTIFY_SOLOIST_CACHE_MB:-500}" | tr -cd '0-9')
SOLOIST_CACHE_MB=${SOLOIST_CACHE_MB:-500}
[ "$SOLOIST_CACHE_MB" -ne 0 ] && [ "$SOLOIST_CACHE_MB" -lt 100 ] && SOLOIST_CACHE_MB=100

# Where Soloist keeps downloaded audio. Lossless tracks are 30 to 50 MB each and every one played
# is written to the cache, so on the SD card that is steady wear (and card I/O that competes
# with everything else). In RAM the cache is a tmpfs capped at SOLOIST_RAM_TMPFS_MB with
# Soloist's own limit at its minimum (100 MB), so it can never fill the tmpfs.
#   SOUND_SPOTIFY_SOLOIST_CACHE=auto (default): ram on devices with 1.5 GB of memory or more
#   SOUND_SPOTIFY_SOLOIST_CACHE=ram | disk: force one
# Login and settings (-D) always stay on disk so the speaker keeps its account.
SOLOIST_CACHE_MODE=$(printf '%s' "${SOUND_SPOTIFY_SOLOIST_CACHE:-auto}" | tr '[:upper:]' '[:lower:]')
SOLOIST_RAM_DIR=/run/soloist-cache
SOLOIST_RAM_TMPFS_MB=192
SOLOIST_RAM_CACHE_MB=100
SOLOIST_CACHE_DIR="$SOLOIST_DIR/cache"

soloist_prepare_cache() {
  local mode="$SOLOIST_CACHE_MODE" mem_kb
  case "$mode" in ram|disk) ;; *)
    mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
    if [ "${mem_kb:-0}" -ge 1500000 ]; then mode=ram; else mode=disk; fi ;;
  esac
  if [ "$mode" = "ram" ]; then
    mkdir -p "$SOLOIST_RAM_DIR"
    if mountpoint -q "$SOLOIST_RAM_DIR" \
       || mount -t tmpfs -o "size=${SOLOIST_RAM_TMPFS_MB}m,mode=0700" tmpfs "$SOLOIST_RAM_DIR" 2>/dev/null; then
      SOLOIST_CACHE_DIR="$SOLOIST_RAM_DIR"
      SOLOIST_CACHE_MB=$SOLOIST_RAM_CACHE_MB
      # The old on-disk cache is dead weight once the cache is in RAM.
      if [ -d "$SOLOIST_DIR/cache" ]; then
        rm -rf "$SOLOIST_DIR/cache" && echo "[spotify] Soloist: removed the old on-disk cache"
      fi
      echo "[spotify] Soloist: cache in RAM (${SOLOIST_RAM_CACHE_MB} MB limit, ${SOLOIST_RAM_TMPFS_MB} MB tmpfs)"
      return 0
    fi
    echo "[spotify] Soloist: could not mount a RAM cache, using the disk cache"
  fi
  SOLOIST_CACHE_DIR="$SOLOIST_DIR/cache"
  mkdir -p "$SOLOIST_CACHE_DIR"
  echo "[spotify] Soloist: cache on disk (${SOLOIST_CACHE_MB} MB limit)"
}

LIBRESPOT_BIN="${LIBRESPOT_BIN:-/usr/src/daemon}"
ENGINE_CHILD=""
WATCHER_PID=""

slog() { echo "[spotify] $*"; }

# Soloist can keep playing after it stops being the active Spotify Connect device (seen on
# device: the app disconnected, Soloist logged "no longer active device", audio kept coming
# out of the speakers and it took the session back a minute later). A speaker that is not the
# active device must be silent.
#
# "Playing" is judged from Soloist's own PulseAudio stream, never from `ctl now`: on an
# inactive device that reports the account's playback, i.e. what is playing somewhere else.
# For the same reason the remedy is to restart Soloist, not `ctl pause`, which from an
# inactive device would pause the music on whichever device is active.
# The state has to hold on three looks in a row, so a hand-over in progress is left alone.
soloist_stream_running() {
  PULSE_SERVER="${PULSE_SERVER:-tcp:127.0.0.1:4317}" pactl list sink-inputs 2>/dev/null | awk '
    /^Sink Input #/ { if (name && !corked) found = 1; name = 0; corked = 0 }
    /Corked: yes/ { corked = 1 }
    /application.name = "spotify"/ { name = 1 }
    END { if (name && !corked) found = 1; exit(found ? 0 : 1) }'
}

soloist_inactive_guard() {
  local pid="$1" state strikes=0
  local ctl=("$SOLOIST_BIN" ctl -D "$SOLOIST_DIR/data")
  command -v pactl >/dev/null 2>&1 || return 0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 4
    state=$("${ctl[@]}" now --json 2>/dev/null) || { strikes=0; continue; }
    if [[ "$state" == *'"is_active":false'* ]] && soloist_stream_running; then
      strikes=$((strikes + 1))
      if [ "$strikes" -ge 3 ]; then
        slog "Soloist is sending audio but is not the active device: restarting it"
        kill -TERM "$pid" 2>/dev/null
        return 0
      fi
    else
      strikes=0
    fi
  done
}

run_librespot_foreground() {
  # Default path, unchanged from before Soloist existed: replace this shell with the daemon.
  exec "$LIBRESPOT_BIN" --config_dir "$CONFIG_DIR"
}

soloist_arch() {
  case "$(dpkg --print-architecture 2>/dev/null || uname -m)" in
    arm64|aarch64) echo "arm64" ;;
    armhf|armv7l) echo "arm32" ;;
    amd64|x86_64) echo "x86_64" ;;
    *) return 1 ;;
  esac
}

soloist_url() {
  local arch
  arch=$(soloist_arch) || return 1
  echo "$SOLOIST_CDN/soloist_release_${arch}.tar.gz"
}

soloist_remote_etag() {
  curl -fsSI -m 20 "$1" 2>/dev/null | tr -d '\r' | awk 'tolower($1) == "etag:" { print $2; exit }'
}

# Make sure a Soloist binary is installed and current. "$1" = force re-downloads even if the
# CDN copy looks unchanged (used after "build expired"). Returns 0 if a usable binary exists.
soloist_install() {
  local force="$1" url remote local_etag tmp version
  url=$(soloist_url) || { slog "Soloist has no build for this CPU architecture"; return 1; }
  mkdir -p "$SOLOIST_DIR/bin" "$SOLOIST_DIR/data"

  remote=$(soloist_remote_etag "$url")
  local_etag=$(cat "$SOLOIST_ETAG_FILE" 2>/dev/null || true)
  if [ -x "$SOLOIST_BIN" ] && [ "$force" != "force" ]; then
    # Cannot reach the CDN, or nothing new: keep what we have.
    if [ -z "$remote" ] || [ "$remote" = "$local_etag" ]; then
      return 0
    fi
    slog "New Soloist build available, updating"
  fi

  tmp=$(mktemp -d "$SOLOIST_DIR/download.XXXXXX") || return 1
  if ! curl -fsSL -m 600 -o "$tmp/soloist.tar.gz" "$url"; then
    slog "Soloist download failed ($url)"
    rm -rf "$tmp"
    [ -x "$SOLOIST_BIN" ]
    return
  fi
  if ! tar -xzf "$tmp/soloist.tar.gz" -C "$tmp" || [ ! -f "$tmp/soloist" ]; then
    slog "Soloist archive is not what we expected, keeping the current build"
    rm -rf "$tmp"
    [ -x "$SOLOIST_BIN" ]
    return
  fi
  chmod 755 "$tmp/soloist"
  if ! version=$("$tmp/soloist" --version 2>&1); then
    slog "Downloaded Soloist build does not run here ($version), keeping the current build"
    rm -rf "$tmp"
    [ -x "$SOLOIST_BIN" ]
    return
  fi
  mv -f "$tmp/soloist" "$SOLOIST_BIN.new" && mv -f "$SOLOIST_BIN.new" "$SOLOIST_BIN"
  echo "$remote" > "$SOLOIST_ETAG_FILE"
  rm -rf "$tmp"
  slog "Soloist installed: $(echo "$version" | head -n 1)"
  return 0
}

# True while any source is playing on this device (sound-supervisor reports the plugin input
# sink as RUNNING). Used so an update or an engine switch never cuts a song.
something_playing() {
  curl -fs -m 3 "http://127.0.0.1:${SOUND_SUPERVISOR_PORT:-80}/audio/sinks" 2>/dev/null \
    | grep -o '{[^}]*"balena-sound.input"[^}]*}' | grep -q '"state":"RUNNING"'
}

# Background: every 6h look for a newer build; install it and restart Soloist while idle.
soloist_update_watcher() {
  local url remote
  url=$(soloist_url) || return 0
  while sleep "$SOLOIST_UPDATE_CHECK_S"; do
    remote=$(soloist_remote_etag "$url")
    [ -z "$remote" ] && continue
    [ "$remote" = "$(cat "$SOLOIST_ETAG_FILE" 2>/dev/null || true)" ] && continue
    while something_playing; do sleep 60; done
    if soloist_install; then
      touch "$SOLOIST_UPDATE_FLAG"
      kill -TERM "$1" 2>/dev/null || true
      return 0
    fi
  done
}

stop_children() {
  [ -n "$WATCHER_PID" ] && kill "$WATCHER_PID" 2>/dev/null
  WATCHER_PID=""
  if [ -n "$ENGINE_CHILD" ] && kill -0 "$ENGINE_CHILD" 2>/dev/null; then
    kill -TERM "$ENGINE_CHILD" 2>/dev/null
    wait "$ENGINE_CHILD" 2>/dev/null
  fi
  ENGINE_CHILD=""
}

run_soloist_supervised() {
  local fail_times=() expired_in_a_row=0 fallback_until=0 start code duration now kept t
  trap 'stop_children; exit 0' TERM INT
  rm -f "$SOLOIST_UPDATE_FLAG"

  while true; do
    if [ "$SECONDS" -ge "$fallback_until" ]; then
      # ---- Soloist ----
      code=1
      start=$SECONDS
      if soloist_install; then
        soloist_prepare_cache
        local args=(-n "$SOUND_DEVICE_NAME" -k "$SOLOIST_API_KEY"
                    -D "$SOLOIST_DIR/data" -C "$SOLOIST_CACHE_DIR" -z "$SOLOIST_CACHE_MB"
                    -i "$SOUND_SPOTIFY_INITIAL_VOLUME")
        [ "${LOG_LEVEL,,}" = "debug" ] && args+=(-v)
        # Local control API, loopback only by default. The inactive guard below needs it.
        args+=(-w "${SOUND_SPOTIFY_SOLOIST_WS:-127.0.0.1:0}")
        slog "Starting Soloist as \"$SOUND_DEVICE_NAME\" (initial volume $SOUND_SPOTIFY_INITIAL_VOLUME)"
        "$SOLOIST_BIN" "${args[@]}" &
        ENGINE_CHILD=$!
        soloist_update_watcher "$ENGINE_CHILD" &
        WATCHER_PID=$!
        soloist_inactive_guard "$ENGINE_CHILD" &
        GUARD_PID=$!
        wait "$ENGINE_CHILD"
        code=$?
        ENGINE_CHILD=""
        kill "$WATCHER_PID" 2>/dev/null; WATCHER_PID=""
        kill "$GUARD_PID" 2>/dev/null; GUARD_PID=""
      fi
      duration=$((SECONDS - start))

      if [ -f "$SOLOIST_UPDATE_FLAG" ]; then
        rm -f "$SOLOIST_UPDATE_FLAG"
        slog "Restarting Soloist on the new build"
        continue
      fi

      if [ "$code" -eq 10 ] && [ "$expired_in_a_row" -lt 1 ]; then
        # Builds expire 90 days after their build date. Not a failure: fetch the current one.
        expired_in_a_row=$((expired_in_a_row + 1))
        slog "Soloist build expired, downloading the current build"
        soloist_install force && continue
      fi
      [ "$code" -ne 10 ] && expired_in_a_row=0

      if [ "$duration" -ge "$SOLOIST_MIN_HEALTHY_S" ]; then
        fail_times=()
        slog "Soloist exited (code $code) after ${duration}s, restarting"
        sleep 3
        continue
      fi

      now=$SECONDS
      kept=()
      for t in "${fail_times[@]}"; do
        [ $((now - t)) -le "$SOLOIST_FAIL_WINDOW_S" ] && kept+=("$t")
      done
      fail_times=("${kept[@]}" "$now")
      slog "Soloist failed to start (code $code, ${duration}s): ${#fail_times[@]}/$SOLOIST_FAIL_LIMIT"
      if [ "${#fail_times[@]}" -ge "$SOLOIST_FAIL_LIMIT" ]; then
        fail_times=()
        expired_in_a_row=0
        fallback_until=$((SECONDS + SOLOIST_RETRY_MIN * 60))
        slog "FALLBACK: Soloist keeps failing, running go-librespot for ${SOLOIST_RETRY_MIN} minutes before retrying"
      else
        sleep 5
      fi
    else
      # ---- go-librespot fallback ----
      "$LIBRESPOT_BIN" --config_dir "$CONFIG_DIR" &
      ENGINE_CHILD=$!
      while kill -0 "$ENGINE_CHILD" 2>/dev/null; do
        sleep 15
        if [ "$SECONDS" -ge "$fallback_until" ] && ! something_playing; then
          slog "Fallback period over and nothing playing, retrying Soloist"
          stop_children
          break
        fi
      done
      if [ -n "$ENGINE_CHILD" ]; then
        wait "$ENGINE_CHILD" 2>/dev/null
        ENGINE_CHILD=""
        slog "go-librespot (fallback) exited, restarting"
        sleep 3
      fi
    fi
  done
}

run_spotify_engine() {
  local engine="${SOUND_SPOTIFY_ENGINE:-librespot}"
  engine="${engine,,}"
  case "$engine" in
    soloist)
      if [ -z "${SOLOIST_API_KEY:-}" ]; then
        slog "SOUND_SPOTIFY_ENGINE=soloist but SOLOIST_API_KEY is not set: nothing is downloaded, running go-librespot"
        run_librespot_foreground
      fi
      slog "Engine: Spotify Soloist (go-librespot is the fallback)"
      run_soloist_supervised
      ;;
    librespot|"")
      slog "Engine: go-librespot"
      run_librespot_foreground
      ;;
    *)
      slog "Unknown SOUND_SPOTIFY_ENGINE '$engine', running go-librespot"
      run_librespot_foreground
      ;;
  esac
}
