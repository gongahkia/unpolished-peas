-- Deterministic assembly for tagged, connector-based room-template corpora.
-- It is intentionally data-only and can drive both ROAG previews and native
-- project generators without loading either game's simulation.
local RoomGraph = {}

local SIDES = { north = { 0, -1, south = "south" }, east = { 1, 0, south = "west" }, south = { 0, 1, south = "north" }, west = { -1, 0, south = "east" } }

local function copy(value)
  local result = {}
  for key, field in pairs(value) do result[key] = type(field) == "table" and copy(field) or field end
  return result
end

local function random(seed)
  seed = (1103515245 * seed + 12345) % 2147483648
  return seed, seed / 2147483648
end

local function connector_set(template)
  local result = {}
  for _, connector in ipairs(template.connectors or {}) do result[connector.side] = true end
  return result
end

local CLOCKWISE = { north = "east", east = "south", south = "west", west = "north" }

local function rotated(template, turns)
  local result = copy(template)
  result.base_id, result.rotation = template.base_id or template.id, turns * 90
  result.connectors = {}
  for _, connector in ipairs(template.connectors or {}) do
    local side = connector.side
    for _ = 1, turns do side = CLOCKWISE[side] end
    result.connectors[#result.connectors + 1] = { side = side, offset = connector.offset }
  end
  return result
end

local function same_connectors(template, needed)
  local actual, count = connector_set(template), 0
  for side in pairs(actual) do if not needed[side] then return false end count = count + 1 end
  for side in pairs(needed) do if not actual[side] then return false end end
  local required_count = 0; for _ in pairs(needed) do required_count = required_count + 1 end
  return count == required_count
end

function RoomGraph.assemble(templates, width, height, seed)
  if type(templates) ~= "table" or #templates == 0 or type(width) ~= "number" or width < 1 or type(height) ~= "number" or height < 1 then
    return nil, { code = "invalid_room_graph", reason = "Templates and positive width/height are required" }
  end
  local cells, state = {}, math.floor(seed or 1)
  for y = 0, height - 1 do
    for x = 0, width - 1 do
      local required = {}
      for side, rule in pairs(SIDES) do
        local nx, ny = x + rule[1], y + rule[2]
        if nx >= 0 and nx < width and ny >= 0 and ny < height then required[side] = true end
      end
      local candidates = {}
      for _, template in ipairs(templates) do
        local rotations = template.allow_rotation and 4 or 1
        for turns = 0, rotations - 1 do
          local candidate = rotated(template, turns)
          if same_connectors(candidate, required) then candidates[#candidates + 1] = candidate end
        end
      end
      if #candidates == 0 then
        return nil, { code = "missing_connector_pattern", reason = "No template matches " .. x .. ":" .. y, x = x, y = y }
      end
      local next_state, unit = random(state)
      state = next_state
      local selected = candidates[math.floor(unit * #candidates) + 1]
      cells[#cells + 1] = { x = x, y = y, template_id = selected.id, template = copy(selected) }
    end
  end
  return { format = "unpolished_bees.room_graph_preview", version = 1, width = width, height = height, seed = math.floor(seed or 1), cells = cells }
end

return RoomGraph
