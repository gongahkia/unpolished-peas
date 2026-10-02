-- JSON-only ROAG workspace. This intentionally refuses all Lua, save, and
-- profile paths; the editor may only touch declared serialised content.
local Json = require("core.json")
local Fs = require("core.fs")
local Bridge = require("core.roag_bridge")

local Workspace = {}
Workspace.__index = Workspace
Workspace.CORPORA = { "dungeon", "reactor" }

local function failure(code, reason, extra)
  local value = { code = code, reason = reason }
  for key, field in pairs(extra or {}) do value[key] = field end
  return nil, value
end

local function room_filename(value)
  return type(value) == "string" and value:match("^[a-z0-9_%-]+%.room%.json$") ~= nil
end

local function copy(value)
  local payload, reason = Json.encode(value)
  assert(payload, reason)
  return assert(Json.decode(payload))
end

local ROTATE = { north = "east", east = "south", south = "west", west = "north" }
local SIDES = { "north", "east", "south", "west" }

local function pattern(template, turns)
  local selected = {}
  for _, connector in ipairs(template.connectors or {}) do
    local side = connector.side
    for _ = 1, turns do side = ROTATE[side] end
    selected[side] = true
  end
  local result = {}
  for _, side in ipairs(SIDES) do if selected[side] then result[#result + 1] = side end end
  return table.concat(result, "+")
end

function Workspace.validate_room(template)
  if type(template) ~= "table" or template.format ~= "roag.room_template" or template.version ~= 1 or type(template.id) ~= "string"
    or type(template.biome) ~= "string" or type(template.width) ~= "number" or template.width % 1 ~= 0 or template.width < 1
    or not template.id:match("^room%." .. template.biome .. "%.[a-z0-9_%.]+$") or type(template.weight) ~= "number" or template.weight <= 0
    or type(template.allow_rotation) ~= "boolean" or type(template.tags) ~= "table" or type(template.legend) ~= "table"
    or type(template.height) ~= "number" or template.height % 1 ~= 0 or template.height < 1 or type(template.layout) ~= "table" or #template.layout ~= template.height then
    return failure("invalid_roag_room", "Room template has unsupported required fields")
  end
  for _, tag in ipairs(template.tags) do if type(tag) ~= "string" or tag == "" then return failure("invalid_roag_room", "Room tags must be non-empty strings") end end
  -- ROAG serializes rows top-to-bottom while its connector coordinates use a
  -- bottom-origin grid, matching the runtime template contract.
  local function glyph_at(x, y) return template.layout[template.height - y]:sub(x + 1, x + 1) end
  local function passable(x, y)
    local material = template.legend[glyph_at(x, y)]
    return type(material) == "string" and not material:match("^material%.structure%.")
  end
  for _, row in ipairs(template.layout) do
    if type(row) ~= "string" or #row ~= template.width then return failure("invalid_roag_room", "Room layout dimensions do not match") end
    for column = 1, #row do if type(template.legend[row:sub(column, column)]) ~= "string" then return failure("invalid_roag_room", "Room layout uses glyph missing from legend") end end
  end
  local connectors, sides = {}, { north = true, east = true, south = true, west = true }
  for _, connector in ipairs(template.connectors or {}) do
    local maximum = type(connector) == "table" and (connector.side == "east" or connector.side == "west") and template.height or template.width
    if type(connector) ~= "table" or not sides[connector.side] or connectors[connector.side] or type(connector.offset) ~= "number" or connector.offset % 1 ~= 0 or connector.offset < 0 or connector.offset >= maximum then
      return failure("invalid_roag_room", "Room connectors must have unique valid sides and offsets")
    end
    connectors[connector.side] = connector
  end
  local connector_positions = {}
  for side, connector in pairs(connectors) do
    local x, y = side == "north" and connector.offset or side == "south" and connector.offset or side == "east" and template.width - 1 or 0,
      side == "north" and template.height - 1 or side == "south" and 0 or connector.offset
    connector_positions[x .. ":" .. y] = true
    if not passable(x, y) then return failure("invalid_roag_room", "Room connector must open onto passable material") end
  end
  local first, all_open = nil, {}
  for y = 0, template.height - 1 do
    for x = 0, template.width - 1 do
      if passable(x, y) then
        local key = x .. ":" .. y; first, all_open[key] = first or { x = x, y = y }, true
        if (x == 0 or y == 0 or x == template.width - 1 or y == template.height - 1) and not connector_positions[key] then
          return failure("invalid_roag_room", "Passable boundary cell must be declared as a connector")
        end
      end
    end
  end
  if not first then return failure("invalid_roag_room", "Room has no passable cells") end
  local visited, queue, cursor = { [first.x .. ":" .. first.y] = true }, { first }, 1
  while queue[cursor] do
    local point = queue[cursor]; cursor = cursor + 1
    for _, delta in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
      local x, y, key = point.x + delta[1], point.y + delta[2], nil
      if x >= 0 and x < template.width and y >= 0 and y < template.height then
        key = x .. ":" .. y
        if all_open[key] and not visited[key] then visited[key] = true; queue[#queue + 1] = { x = x, y = y } end
      end
    end
  end
  for key in pairs(all_open) do if not visited[key] then return failure("invalid_roag_room", "All passable room cells must connect") end end
  return true
end

function Workspace.new(target)
  return setmetatable({ target = (target or Bridge.DEFAULT_TARGET):gsub("/+$", ""), bridge = Bridge.new(target), data = nil, corpora = {} }, Workspace)
end

function Workspace:corpus_path(id, filename)
  assert(Workspace.CORPORA[id] or id == "dungeon" or id == "reactor", "Unknown ROAG corpus")
  assert(filename == nil or (filename == "manifest.json" or room_filename(filename)), "Unsafe ROAG room path")
  return self.target .. "/content/rooms/" .. id .. (filename and "/" .. filename or "")
end

function Workspace:load_corpus(id)
  local manifest_text, reason = Fs.read(self:corpus_path(id, "manifest.json"))
  if not manifest_text then return failure("roag_manifest_read_failed", tostring(reason), { corpus = id }) end
  local manifest, decode_reason = Json.decode(manifest_text)
  if not manifest or manifest.format ~= "roag.room_manifest" or manifest.version ~= 1 or type(manifest.files) ~= "table" then
    return failure("invalid_roag_manifest", tostring(decode_reason or "Unsupported room manifest"), { corpus = id })
  end
  local files, rooms = {}, {}
  for _, filename in ipairs(manifest.files) do
    if not room_filename(filename) or files[filename] then return failure("invalid_roag_manifest", "Invalid or duplicate room filename", { corpus = id }) end
    files[filename] = true
    local text, read_reason = Fs.read(self:corpus_path(id, filename))
    if not text then return failure("roag_room_read_failed", tostring(read_reason), { corpus = id, filename = filename }) end
    local room, room_reason = Json.decode(text)
    if not room then return failure("invalid_roag_room_json", tostring(room_reason), { corpus = id, filename = filename }) end
    local ok, validation = Workspace.validate_room(room)
    if not ok then validation.corpus, validation.filename = id, filename; return nil, validation end
    rooms[#rooms + 1] = { filename = filename, data = room }
  end
  table.sort(rooms, function(a, b) return a.filename < b.filename end)
  return { manifest = manifest, rooms = rooms }
end

function Workspace:diagnose_corpus(id)
  local corpus = self.corpora[id]
  if not corpus then return nil, { code = "unknown_corpus", reason = "Corpus is not loaded" } end
  local errors, ids, coverage = {}, {}, {}
  for _, room in ipairs(corpus.rooms) do
    local ok, failure_data = Workspace.validate_room(room.data)
    if not ok then errors[#errors + 1] = room.filename .. ": " .. failure_data.reason end
    if ids[room.data.id] then errors[#errors + 1] = room.filename .. ": duplicate semantic id " .. room.data.id end
    ids[room.data.id] = true
    local turns = room.data.allow_rotation and 4 or 1
    for turn = 0, turns - 1 do coverage[pattern(room.data, turn)] = (coverage[pattern(room.data, turn)] or 0) + 1 end
  end
  local required, missing = {
    "north", "east", "south", "west", "north+east", "north+south", "north+west", "east+south", "east+west", "south+west",
    "north+east+south", "north+east+west", "north+south+west", "east+south+west", "north+east+south+west",
  }, {}
  for _, key in ipairs(required) do if not coverage[key] then missing[#missing + 1] = key end end
  return { valid = #errors == 0 and #missing == 0, errors = errors, coverage = coverage, missing_patterns = missing, room_count = #corpus.rooms }
end

function Workspace:write_manifest(corpus_id, files)
  local unique, output = {}, {}
  for _, filename in ipairs(files or {}) do
    if not room_filename(filename) or unique[filename] then return failure("invalid_roag_manifest", "Invalid or duplicate room filename") end
    unique[filename], output[#output + 1] = true, filename
  end
  table.sort(output)
  local payload, reason = Json.encode({ format = "roag.room_manifest", version = 1, files = output })
  if not payload then return failure("roag_manifest_encode_failed", tostring(reason)) end
  local written, write_reason = Fs.write_atomic(self:corpus_path(corpus_id, "manifest.json"), payload .. "\n")
  if not written then return failure("roag_manifest_write_failed", tostring(write_reason)) end
  self.corpora[corpus_id].manifest.files = output
  return true
end

function Workspace:next_room_filename(corpus_id, seed)
  local corpus = self.corpora[corpus_id]
  if not corpus then return nil end
  local base, number = tostring(seed or "untitled"):lower():gsub("[^a-z0-9_%-]+", "_"):gsub("_+", "_"), 1
  if base == "" then base = "untitled" end
  local known = {}; for _, room in ipairs(corpus.rooms) do known[room.filename] = true end
  local filename = base .. ".room.json"
  while known[filename] do number = number + 1; filename = base .. "_" .. number .. ".room.json" end
  return filename
end

function Workspace:create_room(corpus_id, seed)
  local corpus = self.corpora[corpus_id]
  if not corpus or not corpus.rooms[1] then return failure("unknown_corpus", "Corpus is not loaded") end
  local filename = self:next_room_filename(corpus_id, seed)
  local prototype = corpus.rooms[1].data
  local room = copy(prototype)
  local name = filename:gsub("%.room%.json$", ""):gsub("[^a-z0-9_]+", "_")
  room.id, room.tags, room.weight, room.connectors = "room." .. corpus_id .. ".custom." .. name, { "standard" }, 1, {}
  local wall, open = "#", "."
  if not room.legend[wall] then for glyph, material in pairs(room.legend) do if material:match("^material%.structure%.") then wall = glyph end end end
  if not room.legend[open] then for glyph, material in pairs(room.legend) do if not material:match("^material%.structure%.") then open = glyph break end end end
  room.layout = {}
  for y = 1, room.height do
    local cells = {}
    for x = 1, room.width do cells[x] = (x == 1 or y == 1 or x == room.width or y == room.height) and wall or open end
    room.layout[y] = table.concat(cells)
  end
  local saved, failure_data = self:save_room(corpus_id, filename, room)
  if not saved then return nil, failure_data end
  local files = copy(corpus.manifest.files); files[#files + 1] = filename
  local indexed, index_failure = self:write_manifest(corpus_id, files)
  if not indexed then return nil, index_failure end
  corpus.rooms[#corpus.rooms + 1] = { filename = filename, data = room }
  table.sort(corpus.rooms, function(a, b) return a.filename < b.filename end)
  return { filename = filename, data = room }
end

function Workspace:remove_room(corpus_id, filename)
  local corpus = self.corpora[corpus_id]
  if not corpus then return failure("unknown_corpus", "Corpus is not loaded") end
  local files, found = {}, false
  for _, existing in ipairs(corpus.manifest.files) do
    if existing == filename then found = true else files[#files + 1] = existing end
  end
  if not found then return failure("unknown_room", "Room is not in this corpus manifest") end
  if #files == 0 then return failure("cannot_remove_last_room", "A corpus must retain at least one room") end
  local written, failure_data = self:write_manifest(corpus_id, files)
  if not written then return nil, failure_data end
  for index, room in ipairs(corpus.rooms) do if room.filename == filename then table.remove(corpus.rooms, index); break end end
  return true
end

function Workspace:load()
  local data, bridge_failure = self.bridge:load()
  if not data then return nil, bridge_failure end
  local corpora = {}
  for _, id in ipairs(Workspace.CORPORA) do
    local corpus, failure_data = self:load_corpus(id)
    if not corpus then return nil, failure_data end
    corpora[id] = corpus
  end
  self.data, self.corpora = data, corpora
  return { presentation = data, corpora = corpora }
end

function Workspace:save_room(corpus_id, filename, template)
  if not self.corpora[corpus_id] then return failure("workspace_not_loaded", "Load workspace before saving rooms") end
  if not room_filename(filename) then return failure("unsafe_roag_room_path", "Room filename is not allowed") end
  local ok, validation = Workspace.validate_room(template)
  if not ok then return nil, validation end
  local payload, reason = Json.encode(template)
  if not payload then return failure("roag_room_encode_failed", tostring(reason)) end
  local written, write_reason = Fs.write_atomic(self:corpus_path(corpus_id, filename), payload .. "\n")
  if not written then return failure("roag_room_write_failed", tostring(write_reason)) end
  return true
end

return Workspace
