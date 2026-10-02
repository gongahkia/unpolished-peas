-- Minimal data-first scene runtime. Rendering is optional so headless tests
-- and embedding can share the same asset and event behavior.
local Project = require("core.project")

local Runtime = {}
Runtime.__index = Runtime

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, field in pairs(value) do result[key] = copy(field) end
  return result
end

local function failure(code, reason)
  return nil, { code = code, reason = reason }
end

function Runtime.new(project, hooks)
  return setmetatable({ project = project, hooks = hooks or {}, variables = {}, scene = nil, scene_id = nil, events = {}, diagnostics = {} }, Runtime)
end

function Runtime:load_scene(scene_id)
  local scene, failure_data = self.project:load_asset(scene_id)
  if not scene then return nil, failure_data end
  if scene.type ~= "scene" then return failure("not_a_scene", tostring(scene_id) .. " is not a scene") end
  self.scene, self.scene_id = copy(scene), scene_id
  return self.scene
end

function Runtime:start(flow_id)
  local flow, failure_data = self.project:load_asset(flow_id)
  if not flow then return nil, failure_data end
  if flow.type ~= "flow" then return failure("not_a_flow", tostring(flow_id) .. " is not a flow") end
  self.flow, self.variables = flow, copy(flow.variables or {})
  return self:load_scene(flow.entry_scene_id)
end

function Runtime:emit(name, payload)
  self.events[#self.events + 1] = { name = name, payload = payload }
end

function Runtime:transition(scene_id)
  local loaded, failure_data = self:load_scene(scene_id)
  if not loaded then self.diagnostics[#self.diagnostics + 1] = failure_data; return nil, failure_data end
  return loaded
end

function Runtime:run_graph_event(name, payload)
  if not self.flow then return true end
  local queue, cursor = {}, 1
  for _, node in ipairs(self.flow.nodes) do if node.type == "event" and node.event == name then queue[#queue + 1] = node.id end end
  local node_by_id, outgoing = {}, {}
  for _, node in ipairs(self.flow.nodes) do node_by_id[node.id] = node end
  for _, edge in ipairs(self.flow.edges) do outgoing[edge.from] = outgoing[edge.from] or {}; outgoing[edge.from][#outgoing[edge.from] + 1] = edge.to end
  local visited = {}
  while queue[cursor] do
    local node_id = queue[cursor]; cursor = cursor + 1
    if not visited[node_id] then
      visited[node_id] = true
      local node = node_by_id[node_id]
      if node.type == "transition" and node.scene_id then self:transition(node.scene_id)
      elseif node.type == "set_variable" then self.variables[node.variable] = node.value
      elseif node.type == "arithmetic" and type(self.variables[node.variable]) == "number" and type(node.value) == "number" then
        self.variables[node.variable] = node.operation == "subtract" and self.variables[node.variable] - node.value or self.variables[node.variable] + node.value
      elseif node.type == "hook" then
        local hook = self.hooks[node.hook]
        if hook then hook(self, payload, node) else self.diagnostics[#self.diagnostics + 1] = { code = "unknown_hook", reason = tostring(node.hook) } end
      end
      for _, next_id in ipairs(outgoing[node_id] or {}) do queue[#queue + 1] = next_id end
    end
  end
  return true
end

function Runtime:update()
  local pending, events = self.events, {}
  self.events = events
  for _, event in ipairs(pending) do self:run_graph_event(event.name, event.payload) end
end

function Runtime:draw_node(node)
  if not love or not love.graphics then return end
  local properties = node.properties or {}
  local x, y = properties.x or 0, properties.y or 0
  if node.type == "panel" then
    local color = properties.color or { 0.12, 0.16, 0.22, 1 }
    love.graphics.setColor(color); love.graphics.rectangle("fill", x, y, properties.width or 120, properties.height or 40, 6, 6)
  elseif node.type == "label" or node.type == "button" then
    love.graphics.setColor(1, 1, 1, 1); love.graphics.print(properties.text or node.id, x, y)
  end
  for _, child in ipairs(node.children or {}) do self:draw_node(child) end
end

function Runtime:draw()
  if self.scene then self:draw_node(self.scene.root) end
end

return Runtime
