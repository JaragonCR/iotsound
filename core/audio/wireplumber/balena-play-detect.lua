-- balena-play-detect.lua (no-op stub)
-- Play/stop detection is handled by the pactl subscribe watcher in start.sh.
-- WirePlumber link events for module-null-sink nodes (balena-sound.input) are
-- not accessible from the WirePlumber Lua ObjectManager in this environment —
-- pipewire-pulse manages those links internally and does not expose them to the
-- WirePlumber session manager. The pactl subscribe approach is simpler and works
-- regardless of PipeWire version or routing configuration.
print("[play-detect] loaded (detection handled by start.sh pactl watcher)")
