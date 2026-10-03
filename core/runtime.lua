-- Minimal data-first scene runtime. Rendering is optional so headless tests
-- and embedding can share the same asset and event behavior.

local Runtime = {}
Runtime.__index = Runtime

-- These are intentionally smaller than the project schema.  The schema can
-- preserve future authoring data; Runtime must never imply that it executes or
-- renders data whose semantics it does not know yet.
Runtime.SCENE_NODE_CAPABILITIES = { scene = true, panel = true, label = true, button = true }
Runtime.FLOW_NODE_CAPABILITIES = { event = true, transition = true, set_variable = true, arithmetic = true, hook = true }

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, field in pairs(value) do result[key] = copy(field) end
  return result
end

local function failure(code, reason)
  return nil, { code = code, reason = reason }
end

function Runtime.new(project, hooks, options)
  options = options or {}
  return setmetatable({
    project = project,
    hooks = hooks or {},
    -- A preview may provide a single active document snapshot without writing
    -- it to disk.  Runtime always clones it again before using it so runtime
    -- state cannot leak back into the editor's authored document.
    asset_overrides = options.asset_overrides or {},
    variables = {}, scene = nil, scene_id = nil, flow = nil, flow_id = nil,
    events = {}, diagnostics = {}, last_error = nil,
  }, Runtime)
end

function Runtime:load_asset(asset_id)
  local overridden = self.asset_overrides[asset_id]
  if overridden then return copy(overridden) end
  return self.project:load_asset(asset_id)
end

function Runtime:load_scene(scene_id)
  local scene, failure_data = self:load_asset(scene_id)
  if not scene then return nil, failure_data end
  if scene.type ~= "scene" then return failure("not_a_scene", tostring(scene_id) .. " is not a scene") end
  self.scene, self.scene_id = copy(scene), scene_id
  return self.scene
end

function Runtime:start(flow_id)
  local flow, failure_data = self:load_asset(flow_id)
  if not flow then return nil, failure_data end
  if flow.type ~= "flow" then return failure("not_a_flow", tostring(flow_id) .. " is not a flow") end
  self.flow, self.flow_id, self.variables = copy(flow), flow_id, copy(flow.variables or {})
  return self:load_scene(flow.entry_scene_id)
end

function Runtime:emit(name, payload)
  self.events[#self.events + 1] = { name = name, payload = payload }
end

function Runtime:transition(scene_id)
  local loaded, failure_data = self:load_scene(scene_id)
  if not loaded then
    self.diagnostics[#self.diagnostics + 1], self.last_error = failure_data, failure_data
    return nil, failure_data
  end
  return loaded
end

function Runtime:scene_capability_warnings(scene)
  local unsupported = {}
  local function visit(node)
    if node.type and not Runtime.SCENE_NODE_CAPABILITIES[node.type] then unsupported[node.type] = (unsupported[node.type] or 0) + 1 end
    for _, child in ipairs(node.children or {}) do visit(child) end
  end
  if scene and scene.root then visit(scene.root) end
  local warnings = {}
  for node_type, count in pairs(unsupported) do
    warnings[#warnings + 1] = { code = "unsupported_scene_node", node_type = node_type, count = count, reason = tostring(count) .. " " .. node_type .. " Scene node" .. (count == 1 and " is" or "s are") .. " not rendered by this runtime" }
  end
  table.sort(warnings, function(a, b) return a.node_type < b.node_type end)
  return warnings
end

function Runtime:flow_capability_warnings(flow)
  local unsupported = {}
  for _, node in ipairs((flow or {}).nodes or {}) do
    if node.type and not Runtime.FLOW_NODE_CAPABILITIES[node.type] then unsupported[node.type] = (unsupported[node.type] or 0) + 1 end
  end
  local warnings = {}
  for node_type, count in pairs(unsupported) do
    warnings[#warnings + 1] = { code = "unsupported_flow_node", node_type = node_type, count = count, reason = tostring(count) .. " " .. node_type .. " Flow node" .. (count == 1 and " is" or "s are") .. " not executed by this runtime" }
  end
  table.sort(warnings, function(a, b) return a.node_type < b.node_type end)
  return warnings
end

function Runtime:capability_warnings()
  local warnings = self:scene_capability_warnings(self.scene)
  for _, warning in ipairs(self:flow_capability_warnings(self.flow)) do warnings[#warnings + 1] = warning end
  return warnings
end

function Runtime:visual_bounds()
  local left, top, right, bottom
  local function include(x, y, width, height)
    left = left and math.min(left, x) or x
    top = top and math.min(top, y) or y
    right = right and math.max(right, x + width) or x + width
    bottom = bottom and math.max(bottom, y + height) or y + height
  end
  local function visit(node)
    local properties = node.properties or {}
    local x, y = properties.x or 0, properties.y or 0
    if node.type == "panel" then
      include(x, y, properties.width or 120, properties.height or 40)
    elseif node.type == "label" or node.type == "button" then
      -- Runtime text has no persisted layout dimensions.  This conservative
      -- authoring viewport estimate frames the text without changing it.
      include(x, y, 180, 28)
    end
    for _, child in ipairs(node.children or {}) do visit(child) end
  end
  if self.scene and self.scene.root then visit(self.scene.root) end
  if not left then return nil end
  return { x = left, y = top, width = math.max(1, right - left), height = math.max(1, bottom - top) }
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
      local continue_edges = true
      if node.type == "transition" and node.scene_id then
        local transitioned, transition_failure = self:transition(node.scene_id)
        if not transitioned then return nil, transition_failure end
      elseif node.type == "set_variable" then self.variables[node.variable] = node.value
      elseif node.type == "arithmetic" and type(self.variables[node.variable]) == "number" and type(node.value) == "number" then
        self.variables[node.variable] = node.operation == "subtract" and self.variables[node.variable] - node.value or self.variables[node.variable] + node.value
      elseif node.type == "hook" then
        local hook = self.hooks[node.hook]
        if hook then hook(self, payload, node) else self.diagnostics[#self.diagnostics + 1] = { code = "unknown_hook", reason = tostring(node.hook) } end
      elseif not Runtime.FLOW_NODE_CAPABILITIES[node.type] then
        local failure_data = { code = "unsupported_flow_node", reason = "Runtime does not execute Flow node type " .. tostring(node.type), node_id = node.id }
        self.diagnostics[#self.diagnostics + 1] = failure_data
        -- Do not traverse beyond an unsupported semantic node.  Passing
        -- through it would falsely execute transitions/side effects.
        continue_edges = false
      end
      if continue_edges then
        for _, next_id in ipairs(outgoing[node_id] or {}) do queue[#queue + 1] = next_id end
      end
    end
  end
  return true
end

function Runtime:update()
  local pending, events = self.events, {}
  self.events = events
  for _, event in ipairs(pending) do
    local ok, failure_data = self:run_graph_event(event.name, event.payload)
    if not ok then self.last_error = failure_data; return nil, failure_data end
  end
  return true
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
