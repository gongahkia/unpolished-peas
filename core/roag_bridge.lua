-- The only write boundary between Unpolished Bees and ROAG.  It is purposefully
-- allow-listed: presentation files only, never active runs, profiles, archives,
-- content simulation, or any executable Lua source.
local Json = require("core.json")

local Bridge = {}
Bridge.__index = Bridge

Bridge.FORMAT = "unpolished_bees.roag_bridge"
Bridge.VERSION = 1
Bridge.DEFAULT_TARGET = "../roag"
Bridge.FILES = {
  screens = "content/screens/legacy.json",
  flow = "content/presentation/flow.json",
  art_pack = "content/presentation/art_pack.json",
  art_catalog = "content/presentation/art_packs.json",
  sprites = "sprite_editor/mappings.json",
}
Bridge.ROLE_SHEET = "assets/kenney/Tilesheet/colored-transparent_packed.png"

local function copy(value)
  local encoded, reason = Json.encode(value)
  assert(encoded, reason)
  return assert(Json.decode(encoded))
end

local function trim_trailing_slash(path)
  return (path:gsub("/+$", ""))
end

local function failure(code, reason)
  return nil, { code = code, reason = reason }
end

local function safe_relative(path)
  return type(path) == "string" and path ~= "" and not path:match("^/") and not path:match("^%.%./")
    and not path:match("/%.%./") and not path:match("/%.%.$")
end

local function read_file(path)
  local file, reason = io.open(path, "rb")
  if not file then return nil, reason end
  local payload = file:read("*a")
  file:close()
  return payload
end

local function atomic_write(path, payload)
  local temporary = path .. ".unpolished-bees.tmp"
  local file, reason = io.open(temporary, "wb")
  if not file then return nil, reason end
  local ok, write_reason = file:write(payload)
  file:close()
  if not ok then return nil, write_reason end
  local verified = read_file(temporary)
  if verified ~= payload then return nil, "Temporary write verification failed" end
  local renamed, rename_reason = os.rename(temporary, path)
  if not renamed then return nil, rename_reason end
  return true
end

local function json_file(path, label)
  local payload, reason = read_file(path)
  if not payload then return failure("bridge_read_failed", label .. ": " .. tostring(reason)) end
  local data, decode_reason = Json.decode(payload)
  if not data then return failure("bridge_json_invalid", label .. ": " .. tostring(decode_reason)) end
  return data
end

local function validate_screens(data)
  if type(data) ~= "table" or data.format ~= "roag.screen_definitions" or data.version ~= 1 or type(data.screens) ~= "table" then
    return failure("invalid_screens", "ROAG screen definitions are not the supported v1 data format")
  end
  local ids, layouts, accents = {}, { title_menu = true, catalog = true, list_detail = true, route = true, menu = true, notice = true }, { cyan = true, amber = true, mint = true, coral = true, violet = true }
  for _, screen in ipairs(data.screens) do
    if type(screen) ~= "table" or type(screen.id) ~= "string" or not screen.id:match("^[a-z][a-z0-9_]*$") or ids[screen.id]
      or not layouts[screen.layout] or not accents[screen.accent]
      or type(screen.title) ~= "string" or screen.title == "" or type(screen.subtitle) ~= "string" or screen.subtitle == "" or type(screen.footer) ~= "string" or screen.footer == "" then
      return failure("invalid_screens", "A screen is missing required validated copy, layout, or accent data")
    end
    ids[screen.id] = true
  end
  return true
end

-- These pairs are the title actions that this Studio version understands well
-- enough to edit. They are intentionally not the complete ROAG flow schema:
-- newer ROAG builds may add structurally valid actions that must survive a
-- load/edit/publish cycle even when this editor cannot safely change them.
local EDITABLE_FLOW_TARGETS = { new_run = "replace_save", continue = "game", research = "research", fallen = "fallen_archive" }

local function valid_action_id(value)
  return type(value) == "string" and value:match("^[a-z][a-z0-9_]*$") ~= nil
end

function Bridge.is_title_action_editable(action)
  return type(action) == "table" and EDITABLE_FLOW_TARGETS[action.id] == action.target
end

local function validate_flow(data)
  if type(data) ~= "table" or data.format ~= "roag.presentation_flow" or data.version ~= 1 or data.home ~= "title" or type(data.title_actions) ~= "table" then
    return failure("invalid_flow", "ROAG presentation flow is not the supported v1 data format")
  end
  local ids = {}
  for index, action in ipairs(data.title_actions) do
    if type(action) ~= "table" or not valid_action_id(action.id) or ids[action.id]
      or type(action.target) ~= "string" or action.target == ""
      or type(action.label) ~= "string" or action.label == "" or type(action.description) ~= "string" or action.description == "" then
      return failure("invalid_flow", "Title action " .. tostring(index) .. " needs a unique safe id plus non-empty target, label, and description")
    end
    ids[action.id] = true
  end
  if not ids.new_run then return failure("invalid_flow", "NEW RUN may not be removed") end
  return true
end

local function validate_catalog(data)
  if type(data) ~= "table" or data.format ~= "roag.presentation_art_pack_catalog" or data.version ~= 1 or type(data.art_packs) ~= "table" then
    return failure("invalid_art_catalog", "ROAG art catalog is not the supported v1 data format")
  end
  local ids = {}
  for _, pack in ipairs(data.art_packs) do
    if type(pack) ~= "table" or type(pack.id) ~= "string" or ids[pack.id] or type(pack.label) ~= "string" or pack.label == "" then
      return failure("invalid_art_catalog", "Art catalog contains invalid pack metadata")
    end
    ids[pack.id] = true
  end
  return true
end

local function valid_sprite_coordinate(value, maximum)
  return type(value) == "number" and value % 1 == 0 and value >= 1 and value <= maximum
end

function Bridge.validate_sprite_data(data)
  if type(data) ~= "table" or data.version ~= 1 or type(data.sprites) ~= "table" then return failure("invalid_sprite_map", "Sprite map must contain v1 sprite data") end
  for role, tile in pairs(data.sprites) do
    if type(role) ~= "string" or type(tile) ~= "table" or not valid_sprite_coordinate(tile.column, 49) or not valid_sprite_coordinate(tile.row, 22) then
      return failure("invalid_sprite_map", "Sprite mapping has an invalid role or 49 × 22 coordinate")
    end
  end
  return true
end

function Bridge.new(target)
  return setmetatable({ target = trim_trailing_slash(target or Bridge.DEFAULT_TARGET) }, Bridge)
end

function Bridge:path(key)
  local relative = Bridge.FILES[key]
  assert(relative and safe_relative(relative), "Unknown or unsafe bridge path")
  return self.target .. "/" .. relative
end

function Bridge:sheet_path()
  return self.target .. "/" .. Bridge.ROLE_SHEET
end

function Bridge:load()
  local screens, err = json_file(self:path("screens"), "Screen definitions"); if not screens then return nil, err end
  local ok, failure_data = validate_screens(screens); if not ok then return nil, failure_data end
  local flow; flow, err = json_file(self:path("flow"), "Presentation flow"); if not flow then return nil, err end
  ok, failure_data = validate_flow(flow); if not ok then return nil, failure_data end
  local art_pack; art_pack, err = json_file(self:path("art_pack"), "Art pack selection"); if not art_pack then return nil, err end
  local catalog; catalog, err = json_file(self:path("art_catalog"), "Art catalog"); if not catalog then return nil, err end
  ok, failure_data = validate_catalog(catalog); if not ok then return nil, failure_data end
  local known = {}
  for _, pack in ipairs(catalog.art_packs) do known[pack.id] = true end
  if type(art_pack) ~= "table" or art_pack.format ~= "roag.presentation_art_pack" or art_pack.version ~= 1 or not known[art_pack.art_pack_id] then
    return failure("invalid_art_pack_selection", "Selected art pack is missing from ROAG's declared catalog")
  end
  local sprites; sprites, err = json_file(self:path("sprites"), "Sprite mappings"); if not sprites then return nil, err end
  ok, failure_data = Bridge.validate_sprite_data(sprites); if not ok then return nil, failure_data end
  return { screens = screens, flow = flow, art_pack = art_pack, catalog = catalog, sprites = sprites }
end

function Bridge:save(data)
  local ok, failure_data = validate_screens(data.screens); if not ok then return nil, failure_data end
  ok, failure_data = validate_flow(data.flow); if not ok then return nil, failure_data end
  ok, failure_data = validate_catalog(data.catalog); if not ok then return nil, failure_data end
  local known = {}; for _, pack in ipairs(data.catalog.art_packs) do known[pack.id] = true end
  if type(data.art_pack) ~= "table" or data.art_pack.format ~= "roag.presentation_art_pack" or data.art_pack.version ~= 1 or not known[data.art_pack.art_pack_id] then
    return failure("invalid_art_pack_selection", "Selected art pack is missing from catalog")
  end
  ok, failure_data = Bridge.validate_sprite_data(data.sprites); if not ok then return nil, failure_data end
  -- All payloads are encoded and validated before the first write.  Each file
  -- is independently atomic; the editor never touches any other ROAG path.
  local payloads = {}
  for key, value in pairs({ screens = data.screens, flow = data.flow, art_pack = data.art_pack, sprites = data.sprites }) do
    local payload, reason = Json.encode(value)
    if not payload then return failure("bridge_encode_failed", key .. ": " .. tostring(reason)) end
    payloads[key] = payload .. "\n"
  end
  for _, key in ipairs({ "screens", "flow", "art_pack", "sprites" }) do
    local written, reason = atomic_write(self:path(key), payloads[key])
    if not written then return failure("bridge_write_failed", key .. ": " .. tostring(reason)) end
  end
  return true
end

function Bridge.copy(data)
  return copy(data)
end

function Bridge.title_targets()
  return copy(EDITABLE_FLOW_TARGETS)
end

return Bridge
