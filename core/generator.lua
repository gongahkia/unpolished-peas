-- Deterministic native generator runner. Algorithms consume serializable
-- settings and emit ordinary native tilemap/room-graph data, never callbacks.
local RoomGraph = require("core.room_graph")

local Generator = {}

local function failure(code, reason)
  return nil, { code = code, reason = reason }
end

local function random(seed)
  seed = (1103515245 * seed + 12345) % 2147483648
  return seed, seed / 2147483648
end

local function hash(x, y, seed)
  local state = (x * 73856093 + y * 19349663 + seed * 83492791) % 2147483648
  local _, value = random(state)
  return value
end

local function tilemap(id, width, height, cells)
  return {
    format = "unpolished_bees.tilemap", version = 1, type = "tilemap", id = id,
    infinite = false, width = width, height = height, tile_width = 16, tile_height = 16,
    chunk_width = math.max(32, width), chunk_height = math.max(32, height),
    layers = { { id = "layer.generated", tileset_id = "tileset.generated", chunks = { { x = 0, y = 0, cells = cells } } } },
  }
end

local function noise(generator)
  local settings = generator.settings
  if type(settings.width) ~= "number" or settings.width < 1 or type(settings.height) ~= "number" or settings.height < 1 then
    return failure("invalid_noise_settings", "Noise generation requires positive width and height")
  end
  local width, height, threshold, seed = math.floor(settings.width), math.floor(settings.height), settings.threshold or .5, math.floor(settings.seed or 1)
  if threshold < 0 or threshold > 1 then return failure("invalid_noise_settings", "Noise threshold must be between zero and one") end
  local cells = {}
  for y = 0, height - 1 do
    for x = 0, width - 1 do if hash(x, y, seed) >= threshold then cells[#cells + 1] = { x = x, y = y, tile = settings.fill_tile or 1 } end end
  end
  return tilemap("tilemap.generated." .. generator.id:gsub("^generator%.", ""), width, height, cells)
end

local OPPOSITE = { north = "south", east = "west", south = "north", west = "east" }
local DELTAS = { north = { 0, -1 }, east = { 1, 0 }, south = { 0, 1 }, west = { -1, 0 } }

local function list_has(values, wanted)
  if values == nil then return true end
  for _, value in ipairs(values) do if value == wanted then return true end end
  return false
end

local function compatible(rules, first, direction, second)
  return list_has(rules[first] and rules[first][direction], second) and list_has(rules[second] and rules[second][OPPOSITE[direction]], first)
end

local function wfc(generator)
  local settings = generator.settings
  local width, height = math.floor(settings.width or 0), math.floor(settings.height or 0)
  if width < 1 or height < 1 or type(settings.tiles) ~= "table" or #settings.tiles == 0 then
    return failure("invalid_wfc_settings", "WFC requires positive width/height and at least one tile")
  end
  local tiles, rules, attempts = settings.tiles, settings.rules or {}, math.max(1, math.floor(settings.attempts or 8))
  for attempt = 1, attempts do
    local seed, domains = math.floor(settings.seed or 1) + attempt - 1, {}
    for y = 0, height - 1 do for x = 0, width - 1 do domains[x .. ":" .. y] = { unpack(tiles) } end end
    local function reduce()
      local changed = true
      while changed do
        changed = false
        for y = 0, height - 1 do
          for x = 0, width - 1 do
            local domain = domains[x .. ":" .. y]
            for direction, delta in pairs(DELTAS) do
              local nx, ny = x + delta[1], y + delta[2]
              if nx >= 0 and nx < width and ny >= 0 and ny < height then
                local neighbor = domains[nx .. ":" .. ny]
                local remaining = {}
                for _, candidate in ipairs(domain) do
                  for _, adjacent in ipairs(neighbor) do
                    if compatible(rules, candidate, direction, adjacent) then remaining[#remaining + 1] = candidate; break end
                  end
                end
                if #remaining == 0 then return false end
                if #remaining < #domain then domains[x .. ":" .. y], domain, changed = remaining, remaining, true end
              end
            end
          end
        end
      end
      return true
    end
    if reduce() then
      local failed = false
      while true do
        local choice_key, choice, count
        for y = 0, height - 1 do
          for x = 0, width - 1 do
            local key, domain = x .. ":" .. y, domains[x .. ":" .. y]
            if #domain > 1 and (not count or #domain < count) then choice_key, choice, count = key, domain, #domain end
          end
        end
        if not choice then break end
        local unit; seed, unit = random(seed)
        domains[choice_key] = { choice[math.floor(unit * #choice) + 1] }
        if not reduce() then failed = true; break end
      end
      if not failed then
        local cells, indices = {}, {}; for index, name in ipairs(tiles) do indices[name] = index end
        for y = 0, height - 1 do for x = 0, width - 1 do cells[#cells + 1] = { x = x, y = y, tile = indices[domains[x .. ":" .. y][1]] } end end
        return tilemap("tilemap.generated." .. generator.id:gsub("^generator%.", ""), width, height, cells)
      end
    end
  end
  return failure("wfc_unsatisfied", "WFC constraints could not be satisfied within configured attempts")
end

function Generator.generate(generator, context)
  if type(generator) ~= "table" or generator.type ~= "generator" then return failure("invalid_generator", "Expected native generator asset") end
  if generator.generator_type == "noise" then return noise(generator) end
  if generator.generator_type == "wfc" then return wfc(generator) end
  if generator.generator_type == "room_graph" then
    local settings, templates = generator.settings or {}, context and context.templates
    return RoomGraph.assemble(templates or {}, settings.width, settings.height, settings.seed)
  end
  return failure("unknown_generator", "Unsupported generator type")
end

return Generator
