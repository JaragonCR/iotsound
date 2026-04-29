-- balena-play-detect.lua
-- Spike-1: detect playback streams targeting balena-sound.input via WirePlumber 0.5.
-- Watches for Stream/Output/Audio nodes whose target matches balena-sound.input.
-- Notifies sound-supervisor via HTTP to trigger master election.
--
-- Env vars (set by start.sh before wireplumber starts):
--   SOUND_SUPERVISOR_URL  e.g. "http://172.17.0.1:80"
--   SOUND_INPUT_SINK      e.g. "balena-sound.input" (default)

local supervisor_url = os.getenv("SOUND_SUPERVISOR_URL") or ""
local input_sink     = os.getenv("SOUND_INPUT_SINK") or "balena-sound.input"

print("[play-detect] script loaded. input_sink=" .. input_sink .. " supervisor=" .. supervisor_url)

if supervisor_url == "" then
  print("[play-detect] WARNING: SOUND_SUPERVISOR_URL not set — play events will only be logged")
end

-- Debug: log all nodes with their media.class to understand the object landscape.
-- Remove after spike is confirmed working.
local all_nodes_om = ObjectManager {
  Interest { type = "node" }
}
all_nodes_om:connect("object-added", function(_, node)
  local name  = node.properties["node.name"]  or "(nil)"
  local class = node.properties["media.class"] or "(nil)"
  print(string.format("[play-detect] node: name=%s class=%s id=%d", name, class, node.id))
end)
all_nodes_om:activate()

-- Watch for client output stream nodes. When a plugin (librespot, shairport, etc.)
-- starts playing, PipeWire creates a Stream/Output/Audio node for it. WirePlumber
-- routes it to a sink; the node's target properties tell us which sink.
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
    print("[play-detect] Playback detected targeting " .. input_sink)
    if supervisor_url ~= "" then
      os.execute(string.format(
        "curl -sf -X POST %s/internal/play >/dev/null 2>&1 &",
        supervisor_url
      ))
    end
  end
end)

streams_om:activate()
