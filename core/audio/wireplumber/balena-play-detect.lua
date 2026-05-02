-- balena-play-detect.lua
-- Detects playback streams targeting balena-sound.input via WirePlumber 0.5.
-- Notifies sound-supervisor via HTTP on stream link (play) and unlink (stop).
--
-- Env vars (set by start.sh before wireplumber starts):
--   SOUND_SUPERVISOR_URL  e.g. "http://172.17.0.1:80"
--   SOUND_INPUT_SINK      e.g. "balena-sound.input" (default)

local supervisor_url = os.getenv("SOUND_SUPERVISOR_URL") or ""
local input_sink     = os.getenv("SOUND_INPUT_SINK") or "balena-sound.input"

print("[play-detect] script loaded. input_sink=" .. input_sink .. " supervisor=" .. supervisor_url)

if supervisor_url == "" then
  print("[play-detect] WARNING: SOUND_SUPERVISOR_URL not set — play/stop events will only be logged")
end

-- Watch for client output stream nodes targeting balena-sound.input.
local streams_om = ObjectManager {
  Interest {
    type = "node",
    Constraint { "media.class", "=", "Stream/Output/Audio" },
  }
}

streams_om:connect("object-added", function(_, node)
  local name   = node.properties["node.name"]    or "(nil)"
  local target = node.properties["node.target"]  or
                 node.properties["target.object"] or "(none)"
  print(string.format("[play-detect] stream-added: name=%s target=%s id=%d", name, target, node.id))
  if target == input_sink then
    print("[play-detect] Playback started on " .. input_sink)
    if supervisor_url ~= "" then
      os.execute(string.format(
        "curl -sf -X POST %s/internal/play >/dev/null 2>&1 &",
        supervisor_url
      ))
    end
  end
end)

streams_om:connect("object-removed", function(_, node)
  local name   = node.properties["node.name"]    or "(nil)"
  local target = node.properties["node.target"]  or
                 node.properties["target.object"] or "(none)"
  print(string.format("[play-detect] stream-removed: name=%s target=%s id=%d", name, target, node.id))
  if target == input_sink then
    print("[play-detect] Playback stopped on " .. input_sink)
    if supervisor_url ~= "" then
      os.execute(string.format(
        "curl -sf -X POST %s/internal/stop >/dev/null 2>&1 &",
        supervisor_url
      ))
    end
  end
end)

streams_om:activate()
