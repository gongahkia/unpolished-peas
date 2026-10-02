-- Sparse tilemap mutation helpers. They keep the JSON representation compact
-- and free the editor from a dense in-memory grid for infinite maps.
local Tilemap = {}

local function layer_for(map, layer_id)
  for _, layer in ipairs(map.layers or {}) do if layer.id == layer_id then return layer end end
end

local function chunk_for(layer, x, y)
  for _, chunk in ipairs(layer.chunks or {}) do if chunk.x == x and chunk.y == y then return chunk end end
end

local function order_cells(a, b)
  return a.y == b.y and a.x < b.x or a.y < b.y
end

function Tilemap.get(map, layer_id, x, y)
  local layer = layer_for(map, layer_id)
  if not layer then return nil, "Unknown layer" end
  local chunk_x, chunk_y = math.floor(x / map.chunk_width), math.floor(y / map.chunk_height)
  local chunk = chunk_for(layer, chunk_x, chunk_y)
  if not chunk then return nil end
  local local_x, local_y = x - chunk_x * map.chunk_width, y - chunk_y * map.chunk_height
  for _, cell in ipairs(chunk.cells) do if cell.x == local_x and cell.y == local_y then return cell.tile end end
end

function Tilemap.set(map, layer_id, x, y, tile)
  if type(x) ~= "number" or x % 1 ~= 0 or x < 0 or type(y) ~= "number" or y % 1 ~= 0 or y < 0 or type(tile) ~= "number" or tile % 1 ~= 0 or tile < 0 then
    return nil, "Map coordinates and tile must be non-negative/integer"
  end
  local layer = layer_for(map, layer_id)
  if not layer then return nil, "Unknown layer" end
  if not map.infinite and (x >= map.width or y >= map.height) then return nil, "Map coordinates are outside the fixed map bounds" end
  local chunk_x, chunk_y = math.floor(x / map.chunk_width), math.floor(y / map.chunk_height)
  local chunk = chunk_for(layer, chunk_x, chunk_y)
  if not chunk and tile == 0 then return true end
  if not chunk then
    chunk = { x = chunk_x, y = chunk_y, cells = {} }
    layer.chunks[#layer.chunks + 1] = chunk
  end
  local local_x, local_y = x - chunk_x * map.chunk_width, y - chunk_y * map.chunk_height
  for index, cell in ipairs(chunk.cells) do
    if cell.x == local_x and cell.y == local_y then
      if tile == 0 then table.remove(chunk.cells, index) else cell.tile = tile end
      table.sort(chunk.cells, order_cells)
      return true
    end
  end
  if tile > 0 then chunk.cells[#chunk.cells + 1] = { x = local_x, y = local_y, tile = tile }; table.sort(chunk.cells, order_cells) end
  return true
end

function Tilemap.next_layer_id(map, seed)
  local known, number = {}, 1
  for _, layer in ipairs(map.layers or {}) do known[layer.id] = true end
  local base, candidate = tostring(seed or "layer"):gsub("[^a-zA-Z0-9_]", "_"):lower(), nil
  candidate = "layer." .. base
  while known[candidate] do number = number + 1; candidate = "layer." .. base .. "_" .. number end
  return candidate
end

function Tilemap.add_layer(map, tileset_id, seed)
  local layer = { id = Tilemap.next_layer_id(map, seed), tileset_id = tileset_id or "tileset.default", chunks = {}, visible = true }
  map.layers[#map.layers + 1] = layer
  return layer
end

function Tilemap.remove_layer(map, layer_id)
  if #map.layers <= 1 then return nil, "A tilemap must retain at least one layer" end
  for index, layer in ipairs(map.layers) do if layer.id == layer_id then table.remove(map.layers, index); return layer end end
  return nil, "Unknown layer"
end

return Tilemap
