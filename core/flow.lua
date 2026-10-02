-- Graph mutations with no executable behavior; runtime interprets the result.
local Flow = {}

local NODE_TYPES = {
  entry = true, event = true, transition = true, condition = true, set_variable = true,
  timer = true, arithmetic = true, action = true, hook = true, subgraph = true,
}

function Flow.next_id(flow, node_type)
  local seen, number = {}, 1
  for _, node in ipairs(flow.nodes or {}) do seen[node.id] = true end
  local candidate = "graph." .. node_type
  while seen[candidate] do number = number + 1; candidate = "graph." .. node_type .. "_" .. number end
  return candidate
end

function Flow.add_node(flow, node_type)
  if not NODE_TYPES[node_type] then return nil, "Unsupported graph node type" end
  flow.nodes = flow.nodes or {}
  local index = #flow.nodes
  local node = { id = Flow.next_id(flow, node_type), type = node_type, editor = { x = 28 + (index % 4) * 150, y = 46 + math.floor(index / 4) * 92 } }
  if node_type == "event" then node.event = "event_name" end
  if node_type == "transition" then node.scene_id = flow.entry_scene_id end
  if node_type == "set_variable" then node.variable, node.value = "value", 0 end
  flow.nodes[#flow.nodes + 1] = node
  return node
end

function Flow.remove_node(flow, node_id)
  local found
  for index, node in ipairs(flow.nodes or {}) do if node.id == node_id then found = index; break end end
  if not found then return nil, "Graph node does not exist" end
  table.remove(flow.nodes, found)
  local edges = {}
  for _, edge in ipairs(flow.edges or {}) do if edge.from ~= node_id and edge.to ~= node_id then edges[#edges + 1] = edge end end
  flow.edges = edges
  return true
end

function Flow.connect(flow, from, to)
  if from == to then return nil, "A graph node cannot connect to itself" end
  local nodes = {}; for _, node in ipairs(flow.nodes or {}) do nodes[node.id] = true end
  if not nodes[from] or not nodes[to] then return nil, "Both graph nodes must exist" end
  flow.edges = flow.edges or {}
  for _, edge in ipairs(flow.edges) do if edge.from == from and edge.to == to then return nil, "Graph edge already exists" end end
  flow.edges[#flow.edges + 1] = { from = from, to = to }
  return true
end

function Flow.disconnect(flow, from, to)
  for index, edge in ipairs(flow.edges or {}) do
    if edge.from == from and edge.to == to then table.remove(flow.edges, index); return true end
  end
  return nil, "Graph edge does not exist"
end

return Flow
