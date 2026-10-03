-- Native project and asset contract.  The editor never stores runtime-only
-- tables: every authored primitive has a versioned JSON representation.
local Json = require("core.json")
local Fs = require("core.fs")

local Project = {}
Project.__index = Project

Project.FORMAT = "unpolished_bees.project"
Project.VERSION = 2
Project.MANIFEST = "unpolished_bees.project.json"

local FORMATS = {
  scene = "unpolished_bees.scene",
  tileset = "unpolished_bees.tileset",
  tilemap = "unpolished_bees.tilemap",
  flow = "unpolished_bees.flow",
  room_template = "unpolished_bees.room_template",
  generator = "unpolished_bees.generator",
}

local NODE_TYPES = {
  scene = true, transform = true, sprite = true, tilemap = true, camera = true,
  panel = true, label = true, button = true, image = true, container = true,
  instance = true,
}

local GRAPH_NODES = {
  entry = true, event = true, transition = true, condition = true, set_variable = true,
  timer = true, arithmetic = true, action = true, hook = true, subgraph = true,
}

local ASSET_NAMESPACES = {
  scene = "scene", tileset = "tileset", tilemap = "tilemap", flow = "flow", room_template = "room", generator = "generator",
}

local function failure(code, reason, extra)
  local value = { code = code, reason = reason }
  for key, field in pairs(extra or {}) do value[key] = field end
  return nil, value
end

local function id(value, namespace)
  return type(value) == "string" and value:match("^" .. namespace .. "%.[a-z][a-z0-9_%.]*$") ~= nil
end

local function finite_number(value)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function positive_integer(value)
  return finite_number(value) and value % 1 == 0 and value > 0
end

local function array(value)
  return type(value) == "table"
end

local function primitive(value)
  local kind = type(value)
  return value == nil or kind == "string" or kind == "boolean" or (kind == "number" and finite_number(value))
end

local function json_value(value, seen)
  if primitive(value) then return true end
  if type(value) ~= "table" then return false end
  seen = seen or {}
  if seen[value] then return false end
  seen[value] = true
  for key, field in pairs(value) do
    if (type(key) ~= "string" and (type(key) ~= "number" or key % 1 ~= 0 or key < 1)) or not json_value(field, seen) then
      seen[value] = nil
      return false
    end
  end
  seen[value] = nil
  return true
end

local function validate_node(node, seen)
  if type(node) ~= "table" or not id(node.id, "node") or seen[node.id] or not NODE_TYPES[node.type] then
    return false, "Each scene node needs a unique node.* id and supported type"
  end
  seen[node.id] = true
  if node.properties ~= nil and type(node.properties) ~= "table" then return false, "Node properties must be an object" end
  for key, value in pairs(node.properties or {}) do
    if type(key) ~= "string" or not json_value(value) then return false, "Node properties must be JSON data" end
  end
  if node.type == "instance" and not id(node.scene_id, "scene") then return false, "Instance nodes require a scene_id" end
  if node.children ~= nil and not array(node.children) then return false, "Node children must be an array" end
  for _, child in ipairs(node.children or {}) do
    local valid, reason = validate_node(child, seen)
    if not valid then return false, reason end
  end
  return true
end

local function validate_scene(data)
  if not id(data.id, "scene") or type(data.root) ~= "table" then return failure("invalid_scene", "Scene requires a scene.* id and root node") end
  if data.root.type ~= "scene" then return failure("invalid_scene", "A scene root must use the scene node type") end
  local valid, reason = validate_node(data.root, {})
  if not valid then return failure("invalid_scene", reason) end
  return true
end

local function validate_tileset(data)
  if not id(data.id, "tileset") or type(data.texture) ~= "table" or (data.texture.mode ~= "linked" and data.texture.mode ~= "imported")
    or not Fs.safe_relative(data.texture.path) or not positive_integer(data.tile_width) or not positive_integer(data.tile_height) then
    return failure("invalid_tileset", "Tileset requires an id, linked/imported relative image path, and positive tile dimensions")
  end
  local seen = {}
  for _, region in ipairs(data.regions or {}) do
    if type(region) ~= "table" or not id(region.id, "tile") or seen[region.id] or not positive_integer(region.x) or not positive_integer(region.y) then
      return failure("invalid_tileset", "Tileset regions require unique tile.* ids and positive grid coordinates")
    end
    seen[region.id] = true
  end
  return true
end

local function validate_tilemap(data)
  if not id(data.id, "tilemap") or type(data.infinite) ~= "boolean" or not positive_integer(data.tile_width) or not positive_integer(data.tile_height)
    or not positive_integer(data.chunk_width) or not positive_integer(data.chunk_height) or not array(data.layers) then
    return failure("invalid_tilemap", "Tilemap requires dimensions, chunk dimensions, infinite flag, and layers")
  end
  if not data.infinite and (not positive_integer(data.width) or not positive_integer(data.height)) then
    return failure("invalid_tilemap", "Fixed tilemaps require width and height")
  end
  local layer_ids = {}
  for _, layer in ipairs(data.layers) do
    if type(layer) ~= "table" or not id(layer.id, "layer") or layer_ids[layer.id] or not id(layer.tileset_id, "tileset") or not array(layer.chunks) then
      return failure("invalid_tilemap", "Layers require unique layer.* ids, a tileset.* id, and chunks")
    end
    layer_ids[layer.id] = true
    local chunks = {}
    for _, chunk in ipairs(layer.chunks) do
      local key = type(chunk) == "table" and tostring(chunk.x) .. ":" .. tostring(chunk.y)
      if type(chunk) ~= "table" or not finite_number(chunk.x) or chunk.x % 1 ~= 0 or not finite_number(chunk.y) or chunk.y % 1 ~= 0 or chunks[key] or not array(chunk.cells) then
        return failure("invalid_tilemap", "Chunks require unique integer coordinates and sparse cells")
      end
      chunks[key] = true
      local cells = {}
      for _, cell in ipairs(chunk.cells) do
        local cell_key = type(cell) == "table" and tostring(cell.x) .. ":" .. tostring(cell.y)
        if type(cell) ~= "table" or not positive_integer(cell.tile) or not finite_number(cell.x) or cell.x % 1 ~= 0 or not finite_number(cell.y) or cell.y % 1 ~= 0 or cells[cell_key] then
          return failure("invalid_tilemap", "Sparse cells require unique integer x/y coordinates and a positive tile index")
        end
        cells[cell_key] = true
      end
    end
  end
  return true
end

local function validate_flow(data)
  if not id(data.id, "flow") or not id(data.entry_scene_id, "scene") or not array(data.nodes) or not array(data.edges) then
    return failure("invalid_flow", "Flow requires flow.* id, entry scene, nodes, and edges")
  end
  for key, value in pairs(data.variables or {}) do
    if not id("variable." .. key, "variable") or not primitive(value) then return failure("invalid_flow", "Variables must have safe names and primitive default values") end
  end
  local nodes = {}
  for _, node in ipairs(data.nodes) do
    if type(node) ~= "table" or not id(node.id, "graph") or nodes[node.id] or not GRAPH_NODES[node.type] then
      return failure("invalid_flow", "Graph nodes need unique graph.* ids and supported types")
    end
    if node.hook ~= nil and (type(node.hook) ~= "string" or not node.hook:match("^[a-zA-Z_][a-zA-Z0-9_%.]*$")) then
      return failure("invalid_flow", "Lua hooks are named references, not embedded code")
    end
    nodes[node.id] = true
  end
  local edges = {}
  for _, edge in ipairs(data.edges) do
    local key = type(edge) == "table" and edge.from .. ">" .. edge.to
    if type(edge) ~= "table" or edge.from == edge.to or not nodes[edge.from] or not nodes[edge.to] or edges[key] then
      return failure("invalid_flow", "Edges must reference distinct declared graph nodes")
    end
    edges[key] = true
  end
  return true
end

local function validate_room_template(data)
  if not id(data.id, "room") or not positive_integer(data.width) or not positive_integer(data.height) or not array(data.layout) or #data.layout ~= data.height then
    return failure("invalid_room_template", "Room template requires id, dimensions, and complete layout")
  end
  for _, row in ipairs(data.layout) do if type(row) ~= "string" or #row ~= data.width then return failure("invalid_room_template", "Room layout rows must match width") end end
  local connectors, allowed = {}, { north = true, east = true, south = true, west = true }
  for _, connector in ipairs(data.connectors or {}) do
    if type(connector) ~= "table" or not allowed[connector.side] or not finite_number(connector.offset) or connector.offset % 1 ~= 0 or connectors[connector.side] then
      return failure("invalid_room_template", "Room connectors require one valid integer-offset connector per side")
    end
    connectors[connector.side] = true
  end
  return true
end

local function validate_generator(data)
  if not id(data.id, "generator") or (data.generator_type ~= "room_graph" and data.generator_type ~= "noise" and data.generator_type ~= "wfc") or type(data.settings) ~= "table" then
    return failure("invalid_generator", "Generator requires id, room_graph/noise/wfc generator_type, and settings")
  end
  return true
end

local VALIDATORS = {
  scene = validate_scene, tileset = validate_tileset, tilemap = validate_tilemap, flow = validate_flow,
  room_template = validate_room_template, generator = validate_generator,
}

function Project.validate_asset(data, expected_type)
  if type(data) ~= "table" then return failure("invalid_asset", "Asset must be an object") end
  local asset_type = expected_type or data.type
  if not FORMATS[asset_type] or data.format ~= FORMATS[asset_type] or data.version ~= 1 then
    return failure("invalid_asset_format", "Asset needs a supported Unpolished Bees format and v1 version")
  end
  if data.type ~= asset_type then return failure("invalid_asset_type", "Asset type does not match its format") end
  return VALIDATORS[asset_type](data)
end

function Project.validate_manifest(data)
  if type(data) ~= "table" or data.format ~= Project.FORMAT or data.version ~= Project.VERSION or type(data.name) ~= "string" or data.name == "" or not id(data.main_scene_id, "scene") or type(data.assets) ~= "table" then
    return failure("invalid_project", "Project needs format, version, name, main scene, and asset index")
  end
  local ids = {}
  for asset_id, entry in pairs(data.assets) do
    if type(entry) ~= "table" or not FORMATS[entry.type] or not id(asset_id, ASSET_NAMESPACES[entry.type]) or not Fs.safe_relative(entry.path) or ids[asset_id] then
      return failure("invalid_project", "Project asset index contains an unsafe or unsupported entry")
    end
    ids[asset_id] = true
  end
  if not data.assets[data.main_scene_id] or data.assets[data.main_scene_id].type ~= "scene" then return failure("invalid_project", "Main scene must exist as a scene asset in project index") end
  return true
end

function Project.empty(name)
  return {
    format = Project.FORMAT, version = Project.VERSION, name = name or "Untitled Project",
    main_scene_id = "scene.main", assets = {},
  }
end

function Project.asset_types()
  return { "scene", "tileset", "tilemap", "flow", "room_template", "generator" }
end

function Project.slug(value)
  value = tostring(value or "untitled"):lower():gsub("[^a-z0-9_]+", "_"):gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
  return value == "" and "untitled" or value
end

function Project:next_asset_id(asset_type, seed)
  local manifest = self.manifest or assert(self:load())
  local base, number = Project.slug(seed or "untitled"), 1
  local candidate = asset_type .. "." .. base
  while manifest.assets[candidate] do number = number + 1; candidate = asset_type .. "." .. base .. "_" .. number end
  return candidate
end

function Project:default_asset_path(asset_type, asset_id)
  local leaf = asset_id:gsub("^[a-z_]+%.", ""):gsub("[^a-zA-Z0-9_%-]", "_")
  return "assets/" .. leaf .. "." .. asset_type .. ".json"
end

function Project.asset_template(asset_type, asset_id, options)
  options = options or {}
  if asset_type == "scene" then
    return { format = FORMATS.scene, version = 1, type = "scene", id = asset_id, root = { id = "node.root", type = "scene", properties = {}, children = {} } }
  elseif asset_type == "tileset" then
    return { format = FORMATS.tileset, version = 1, type = "tileset", id = asset_id, texture = { mode = options.texture_mode or "linked", path = options.texture_path or "assets/replace-me.png" }, tile_width = options.tile_width or 16, tile_height = options.tile_height or 16, regions = {} }
  elseif asset_type == "tilemap" then
    return { format = FORMATS.tilemap, version = 1, type = "tilemap", id = asset_id, infinite = options.infinite == true, width = options.width or 32, height = options.height or 18, tile_width = options.tile_width or 16, tile_height = options.tile_height or 16, chunk_width = options.chunk_width or 32, chunk_height = options.chunk_height or 32, layers = { { id = "layer.ground", tileset_id = options.tileset_id or "tileset.default", chunks = {} } } }
  elseif asset_type == "flow" then
    return { format = FORMATS.flow, version = 1, type = "flow", id = asset_id, entry_scene_id = options.entry_scene_id or "scene.main", variables = {}, nodes = { { id = "graph.start", type = "entry", editor = { x = 28, y = 46 } } }, edges = {} }
  elseif asset_type == "room_template" then
    return { format = FORMATS.room_template, version = 1, type = "room_template", id = asset_id, width = 11, height = 11, connectors = {}, layout = { "...........", "...........", "...........", "...........", "...........", "...........", "...........", "...........", "...........", "...........", "..........." } }
  elseif asset_type == "generator" then
    return { format = FORMATS.generator, version = 1, type = "generator", id = asset_id, generator_type = options.generator_type or "noise", settings = { width = 32, height = 18, seed = 1, threshold = .5, fill_tile = 1 } }
  end
  return nil, { code = "unknown_asset_type", reason = "Unsupported asset type " .. tostring(asset_type) }
end

function Project.new(root)
  return setmetatable({ root = root, manifest = nil }, Project)
end

local function trimmed(value)
  return type(value) == "string" and value:gsub("^%s+", ""):gsub("%s+$", "") or nil
end

-- Inspect a proposed project root without writing anything.  This is used by
-- the Studio before it asks an author to resolve unsaved work, and is checked
-- again by create() immediately before any durable write.
function Project.validate_creation(root, name)
  local clean_name = trimmed(name)
  if not clean_name or clean_name == "" then return failure("project_name_required", "Project name cannot be empty") end
  if type(root) ~= "string" or root:gsub("%s", "") == "" then return failure("project_folder_required", "Project folder is required") end
  root = root:gsub("^%s+", ""):gsub("%s+$", "")
  local without_trailing = root:gsub("[/\\]+$", "")
  if without_trailing ~= "" then root = without_trailing end
  if root == "" then return failure("project_folder_required", "Project folder is required") end

  local state, inspection_reason = Fs.directory_state(root)
  if not state then return failure("project_folder_unavailable", inspection_reason or "Could not inspect project folder") end
  if state == "file" then return failure("project_folder_invalid", "Project folder points to a file, not a folder") end
  if state == "missing" then
    local parent = Fs.parent(root) or "."
    local parent_state, parent_reason = Fs.directory_state(parent)
    if parent_state ~= "directory" then
      return failure("project_parent_missing", parent_reason or "The parent folder does not exist")
    end
    return { root = root, name = clean_name, create_root = true }
  end

  if Fs.exists(Fs.join(root, Project.MANIFEST)) then
    return failure("project_exists", "An Unpolished Bees project already exists in this folder", { root = root })
  end
  local entries, entries_reason = Fs.directory_entries(root)
  if not entries then return failure("project_folder_unavailable", entries_reason or "Could not inspect project folder") end
  if #entries > 0 then
    -- Earlier Project.create callers prepared an empty assets directory before
    -- creating the manifest.  It is still safe to accept that exact bootstrap
    -- shape, but no other pre-existing user files are adopted.
    local assets_root = Fs.join(root, "assets")
    local assets_empty = #entries == 1 and entries[1] == "assets" and Fs.directory_empty(assets_root)
    if not assets_empty then return failure("project_folder_not_empty", "This folder is not empty. Choose an empty folder for a new project") end
  end
  return { root = root, name = clean_name, create_root = false }
end

function Project.create(root, name)
  local plan, plan_failure = Project.validate_creation(root, name)
  if not plan then return nil, plan_failure end
  if plan.create_root then
    local made, make_reason = Fs.create_directory(plan.root)
    if not made then return failure("project_folder_create_failed", tostring(make_reason)) end
  end
  local assets_root = Fs.join(plan.root, "assets")
  local assets_created, assets_reason = Fs.create_directory(assets_root)
  if not assets_created then return failure("project_assets_folder_create_failed", tostring(assets_reason)) end

  local self = Project.new(plan.root)
  local manifest = Project.empty(plan.name)
  manifest.assets["scene.main"] = { type = "scene", path = "assets/main.scene.json" }
  local scene, template_failure = Project.asset_template("scene", "scene.main")
  if not scene then return nil, template_failure end
  local valid_scene, scene_failure = Project.validate_asset(scene, "scene")
  if not valid_scene then return nil, scene_failure end
  local valid_manifest, manifest_failure = Project.validate_manifest(manifest)
  if not valid_manifest then return nil, manifest_failure end
  local payload, encode_reason = Json.encode(scene)
  if not payload then return failure("project_encode_failed", tostring(encode_reason)) end
  local scene_path = Fs.join(plan.root, "assets/main.scene.json")
  if Fs.exists(scene_path) then return failure("project_asset_exists", "A native scene already exists at assets/main.scene.json") end
  -- The manifest is written last so a root becomes a discoverable project only
  -- after its required main scene has been validated and durably written.
  local written, write_reason = Fs.write_atomic(scene_path, payload .. "\n")
  if not written then return failure("project_create_failed", tostring(write_reason)) end
  local saved, failure_data = self:save_manifest(manifest)
  if not saved then return nil, failure_data end
  return self
end

function Project:load()
  local payload, reason = Fs.read(Fs.join(self.root, Project.MANIFEST))
  if not payload then return failure("project_read_failed", tostring(reason)) end
  local data, decode_reason = Json.decode(payload)
  if not data then return failure("project_json_invalid", tostring(decode_reason)) end
  local ok, validation = Project.validate_manifest(data)
  if not ok then return nil, validation end
  self.manifest = data
  return data
end

function Project:save_manifest(data)
  local ok, validation = Project.validate_manifest(data)
  if not ok then return nil, validation end
  local payload, reason = Json.encode(data)
  if not payload then return failure("project_encode_failed", tostring(reason)) end
  local written, write_reason = Fs.write_atomic(Fs.join(self.root, Project.MANIFEST), payload .. "\n")
  if not written then return failure("project_write_failed", tostring(write_reason)) end
  self.manifest = data
  return true
end

function Project:load_asset(asset_id)
  local manifest = self.manifest
  if not manifest then
    local loaded, failure_data = self:load()
    if not loaded then return nil, failure_data end
    manifest = loaded
  end
  local entry = manifest.assets[asset_id]
  if not entry then return failure("unknown_asset", "Asset is not indexed: " .. tostring(asset_id)) end
  local payload, reason = Fs.read(Fs.join(self.root, entry.path))
  if not payload then return failure("asset_read_failed", tostring(reason), { asset_id = asset_id }) end
  local data, decode_reason = Json.decode(payload)
  if not data then return failure("asset_json_invalid", tostring(decode_reason), { asset_id = asset_id }) end
  local ok, validation = Project.validate_asset(data, entry.type)
  if not ok then return nil, validation end
  if data.id ~= asset_id then return failure("asset_id_mismatch", "Asset id differs from its manifest key", { asset_id = asset_id }) end
  return data
end

function Project:save_asset(data, path)
  local ok, validation = Project.validate_asset(data)
  if not ok then return nil, validation end
  local manifest = self.manifest
  if not manifest then
    local loaded, failure_data = self:load()
    if not loaded then return nil, failure_data end
    manifest = loaded
  end
  path = path or (manifest.assets[data.id] and manifest.assets[data.id].path)
  if not Fs.safe_relative(path) then return failure("unsafe_asset_path", "Asset paths must remain inside project root") end
  local payload, encode_reason = Json.encode(data)
  if not payload then return failure("asset_encode_failed", tostring(encode_reason)) end
  local written, reason = Fs.write_atomic(Fs.join(self.root, path), payload .. "\n")
  if not written then return failure("asset_write_failed", tostring(reason)) end
  manifest.assets[data.id] = { type = data.type, path = path }
  return self:save_manifest(manifest)
end

function Project:create_asset(asset_type, seed, options)
  local manifest = self.manifest
  if not manifest then
    local loaded, failure_data = self:load()
    if not loaded then return nil, failure_data end
    manifest = loaded
  end
  if not FORMATS[asset_type] then return failure("unknown_asset_type", "Unsupported asset type " .. tostring(asset_type)) end
  local asset_id = self:next_asset_id(asset_type, seed)
  local data, template_failure = Project.asset_template(asset_type, asset_id, options)
  if not data then return nil, template_failure end
  local path = options and options.path or self:default_asset_path(asset_type, asset_id)
  local saved, failure_data = self:save_asset(data, path)
  if not saved then return nil, failure_data end
  return data, path
end

function Project:remove_asset(asset_id)
  local manifest = self.manifest
  if not manifest then
    local loaded, failure_data = self:load()
    if not loaded then return nil, failure_data end
    manifest = loaded
  end
  if asset_id == manifest.main_scene_id then return failure("cannot_remove_main_scene", "Set another main scene before removing the current entry scene") end
  if not manifest.assets[asset_id] then return failure("unknown_asset", "Asset is not indexed: " .. tostring(asset_id)) end
  local references = self:references_to(asset_id)
  if #references > 0 then
    return failure("asset_still_referenced", "Remove or update its references before removing this asset", { references = references })
  end
  -- Deliberately leave the JSON file in place. A manifest-only removal is
  -- reversible and avoids losing a designer’s work to a mistaken click.
  manifest.assets[asset_id] = nil
  return self:save_manifest(manifest)
end

-- Return manifest assets that would become invalid if asset_id disappeared.
-- This deliberately follows only the declared cross-asset primitives, so an
-- inspector can surface a useful answer without executing project code.
function Project:references_to(asset_id)
  local manifest = self.manifest or assert(self:load())
  local references = {}
  for owner_id, entry in pairs(manifest.assets) do
    if owner_id ~= asset_id then
      local data = self:load_asset(owner_id)
      if data then
        local uses = false
        if data.type == "scene" then
          local function visit(node)
            if node.type == "instance" and node.scene_id == asset_id then uses = true end
            for _, child in ipairs(node.children or {}) do visit(child) end
          end
          visit(data.root)
        elseif data.type == "tilemap" then
          for _, layer in ipairs(data.layers or {}) do if layer.tileset_id == asset_id then uses = true end end
        elseif data.type == "flow" then
          if data.entry_scene_id == asset_id then uses = true end
          for _, node in ipairs(data.nodes or {}) do if node.scene_id == asset_id then uses = true end end
        end
        if uses then references[#references + 1] = { id = owner_id, type = entry.type } end
      end
    end
  end
  table.sort(references, function(a, b) return a.id < b.id end)
  return references
end

function Project:set_main_scene(asset_id)
  local manifest = self.manifest or assert(self:load())
  local entry = manifest.assets[asset_id]
  if not entry or entry.type ~= "scene" then return failure("invalid_main_scene", "The project entry must be an indexed scene asset") end
  manifest.main_scene_id = asset_id
  return self:save_manifest(manifest)
end

function Project:import_tileset(source_path, seed, options)
  options = options or {}
  local name = Fs.basename(source_path)
  if not name or not name:match("%.[Pp][Nn][Gg]$") then return failure("unsupported_import", "Only PNG tileset images can be imported currently") end
  local target_path = options.texture_path or ("assets/" .. name)
  if not Fs.safe_relative(target_path) then return failure("unsafe_import_path", "Imported files must remain inside the project") end
  local destination = Fs.join(self.root, target_path)
  if Fs.exists(destination) and not options.overwrite then return failure("import_exists", "An asset already exists at " .. target_path) end
  local copied, copy_reason = Fs.copy_atomic(source_path, destination)
  if not copied then return failure("import_copy_failed", tostring(copy_reason)) end
  local data, failure_data = self:create_asset("tileset", seed or name:gsub("%.[Pp][Nn][Gg]$", ""), { texture_mode = "imported", texture_path = target_path, tile_width = options.tile_width or 16, tile_height = options.tile_height or 16 })
  if not data then return nil, failure_data end
  return data
end

return Project
