-- balena-play-detect.lua
-- Detects audio links to/from balena-sound.input via WirePlumber 0.5.
-- Uses link-based detection (object-added/removed on Link objects) so that
-- it fires correctly regardless of whether the stream has an explicit target
-- property set (e.g. when routing via the default PulseAudio sink).
--
-- Env vars (set by start.sh before wireplumber starts):
--   SOUND_SUPERVISOR_URL  e.g. "http://172.17.0.1:80"
--   SOUND_INPUT_SINK      e.g. "balena-sound.input" (default)

local supervisor_url = os.getenv("SOUND_SUPERVISOR_URL") or ""
local input_sink     = os.getenv("SOUND_INPUT_SINK") or "balena-sound.input"

print("[play-detect] script loaded. input_sink=" .. input_sink .. " supervisor=" .. supervisor_url)

if supervisor_url == "" then
  print("[play-detect] WARNING: SOUND_SUPERVISOR_URL not set — events will only be logged")
end

-- Track all nodes by PipeWire object ID so links can resolve node names/classes.
local all_nodes = {}

local nodes_om = ObjectManager {
  Interest { type = "node" }
}
nodes_om:connect("object-added",   function(_, node) all_nodes[node.id] = node end)
nodes_om:connect("object-removed", function(_, node) all_nodes[node.id] = nil  end)
nodes_om:activate()

-- active_links: link.id → out_node_id, for links that target input_sink.
-- source_link_count: out_node_id → number of active links to input_sink.
-- Counts are needed because each stereo stream creates two links (L+R).
local active_links       = {}
local source_link_count  = {}

local links_om = ObjectManager {
  Interest { type = "link" }
}

links_om:connect("object-added", function(_, link)
  local out_id = tonumber(link.properties["link.output.node"])
  local in_id  = tonumber(link.properties["link.input.node"])
  if not out_id or not in_id then return end

  local in_node = all_nodes[in_id]
  if not in_node then return end
  if (in_node.properties["node.name"] or "") ~= input_sink then return end

  -- This link targets balena-sound.input — record it.
  active_links[link.id] = out_id
  local prev = source_link_count[out_id] or 0
  source_link_count[out_id] = prev + 1

  -- Only fire on the first link from this source (avoids duplicate play events for L+R).
  if prev == 0 then
    local out_node = all_nodes[out_id]
    local out_name = (out_node and out_node.properties["node.name"]) or "unknown"
    print("[play-detect] play started: " .. out_name .. " → " .. input_sink)
    if supervisor_url ~= "" then
      os.execute(string.format(
        "curl -sf -X POST %s/internal/play >/dev/null 2>&1 &", supervisor_url))
    end
  end
end)

links_om:connect("object-removed", function(_, link)
  local out_id = active_links[link.id]
  if not out_id then return end  -- link wasn't targeting input_sink

  active_links[link.id] = nil
  source_link_count[out_id] = (source_link_count[out_id] or 1) - 1

  -- Fire stop only when the last link from this source is gone.
  if source_link_count[out_id] <= 0 then
    source_link_count[out_id] = nil
    local out_node = all_nodes[out_id]
    local out_name = (out_node and out_node.properties["node.name"]) or "unknown"
    print("[play-detect] play stopped: " .. out_name .. " ← " .. input_sink)
    if supervisor_url ~= "" then
      os.execute(string.format(
        "curl -sf -X POST %s/internal/stop >/dev/null 2>&1 &", supervisor_url))
    end
  end
end)

links_om:activate()
