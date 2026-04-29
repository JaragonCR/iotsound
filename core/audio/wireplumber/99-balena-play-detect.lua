-- 99-balena-play-detect.lua
-- Spike-1: detect streams linking to balena-sound.input via native WirePlumber events.
-- When a stream links, notifies sound-supervisor via HTTP so it can trigger master election.
--
-- Reads env vars (set by start.sh before wireplumber starts):
--   SOUND_SUPERVISOR_URL  e.g. "http://172.17.0.1:80"
--   SOUND_INPUT_SINK      e.g. "balena-sound.input" (default)

local supervisor_url = os.getenv("SOUND_SUPERVISOR_URL") or ""
local input_sink     = os.getenv("SOUND_INPUT_SINK") or "balena-sound.input"

-- print() goes straight to stdout regardless of WirePlumber log level
print("[play-detect] script loaded. input_sink=" .. input_sink .. " supervisor=" .. supervisor_url)

if supervisor_url == "" then
  print("[play-detect] WARNING: SOUND_SUPERVISOR_URL not set — play events will only be logged")
end

local input_node_id = nil

-- Track the balena-sound.input node so we can match links by node ID
local nodes_om = ObjectManager {
  Interest {
    type = "node",
    Constraint { "node.name", "=", input_sink },
  }
}

nodes_om:connect("object-added", function(_, node)
  input_node_id = node.id
  print(string.format("[play-detect] Tracking '%s' node id=%d", input_sink, node.id))
end)

nodes_om:connect("object-removed", function(_, node)
  if node.id == input_node_id then
    input_node_id = nil
    print("[play-detect] Input node removed")
  end
end)

-- Watch links; fire when a stream connects to balena-sound.input
local links_om = ObjectManager {
  Interest { type = "link" }
}

links_om:connect("object-added", function(_, link)
  local in_node = tonumber(link.properties["link.input.node"])
  if input_node_id and in_node == input_node_id then
    print("[play-detect] Stream linked to " .. input_sink)
    if supervisor_url ~= "" then
      os.execute(string.format(
        "curl -sf -X POST %s/internal/play >/dev/null 2>&1 &",
        supervisor_url
      ))
    end
  end
end)

nodes_om:activate()
links_om:activate()
