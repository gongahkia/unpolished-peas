-- Deliberately narrow Tiled JSON importer. It preserves tile-layer geometry
-- and reports unsupported features instead of silently inventing semantics.
local Json = require("core.json")

local Tiled = {}

local function failure(code, reason)
  return nil, { code = code, reason = reason }
end

local function tile_id(gid)
  -- Tiled reserves the high three bits for tile transforms. Native v1 maps do
  -- not apply those transforms yet, so retain the base tile and report it.
  return gid % 536870912, gid >= 536870912
end

local function add_cells(cells, data, width, offset_x, offset_y, warnings)
  if type(data) ~= "table" then return nil, "Layer tile data must be an array" end
  for index, gid in ipairs(data) do
    if type(gid) ~= "number" or gid % 1 ~= 0 or gid < 0 then return nil, "Layer GIDs must be non-negative integers" end
    local value, transformed = tile_id(gid)
    if transformed then warnings[#warnings + 1] = "Tile transform flags were discarded for gid " .. gid end
    if value > 0 then
      local local_index = index - 1
      cells[#cells + 1] = { x = offset_x + local_index % width, y = offset_y + math.floor(local_index / width), tile = value }
    end
  end
  return true
end

local function sparse_chunks(cells, chunk_width, chunk_height)
  local by_key, result = {}, {}
  for _, cell in ipairs(cells) do
    local chunk_x, chunk_y = math.floor(cell.x / chunk_width), math.floor(cell.y / chunk_height)
    local key = chunk_x .. ":" .. chunk_y
    local chunk = by_key[key]
    if not chunk then
      chunk = { x = chunk_x, y = chunk_y, cells = {} }
      by_key[key], result[#result + 1] = chunk, chunk
    end
    chunk.cells[#chunk.cells + 1] = { x = cell.x - chunk_x * chunk_width, y = cell.y - chunk_y * chunk_height, tile = cell.tile }
  end
  table.sort(result, function(a, b) return a.y == b.y and a.x < b.x or a.y < b.y end)
  for _, chunk in ipairs(result) do table.sort(chunk.cells, function(a, b) return a.y == b.y and a.x < b.x or a.y < b.y end) end
  return result
end

function Tiled.import_map(payload, options)
  options = options or {}
  local source, reason
  if type(payload) == "string" then
    source, reason = Json.decode(payload)
    if not source then return failure("tiled_json_invalid", tostring(reason)) end
  else
    source = payload
  end
  if type(source) ~= "table" or source.type ~= "map" or source.orientation ~= "orthogonal" or type(source.tilewidth) ~= "number" or type(source.tileheight) ~= "number" or type(source.layers) ~= "table" then
    return failure("unsupported_tiled_map", "Only orthogonal Tiled JSON maps with layers are supported")
  end
  local warnings, layers = {}, {}
  for _, layer in ipairs(source.layers) do
    if layer.type == "tilelayer" then
      local cells = {}
      if source.infinite then
        for _, chunk in ipairs(layer.chunks or {}) do
          local ok, chunk_reason = add_cells(cells, chunk.data, chunk.width, chunk.x, chunk.y, warnings)
          if not ok then return failure("invalid_tiled_layer", chunk_reason) end
        end
      else
        local ok, layer_reason = add_cells(cells, layer.data, source.width, 0, 0, warnings)
        if not ok then return failure("invalid_tiled_layer", layer_reason) end
      end
      layers[#layers + 1] = {
        id = "layer.tiled_" .. tostring(layer.id or #layers + 1), name = layer.name or ("Layer " .. #layers + 1),
        tileset_id = options.tileset_id or "tileset.imported", visible = layer.visible ~= false,
        chunks = sparse_chunks(cells, options.chunk_width or 32, options.chunk_height or 32),
      }
    elseif layer.type == "objectgroup" or layer.type == "imagelayer" or layer.type == "group" then
      warnings[#warnings + 1] = "Skipped unsupported Tiled layer '" .. tostring(layer.name or layer.type) .. "'"
    end
  end
  local map = {
    format = "unpolished_bees.tilemap", version = 1, type = "tilemap", id = options.id or "tilemap.imported",
    infinite = source.infinite == true, width = source.width, height = source.height,
    tile_width = source.tilewidth, tile_height = source.tileheight,
    chunk_width = options.chunk_width or 32, chunk_height = options.chunk_height or 32, layers = layers,
    source = { format = "tiled_json", tiled_version = source.tiledversion },
  }
  return map, warnings
end

return Tiled
