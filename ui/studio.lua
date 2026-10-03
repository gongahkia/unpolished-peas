local Bridge = require("core.roag_bridge")
local Fs = require("core.fs")
local Json = require("core.json")
local Flow = require("core.flow")
local Project = require("core.project")
local History = require("core.history")
local Generator = require("core.generator")
local RoomGraph = require("core.room_graph")
local Runtime = require("core.runtime")
local Scene = require("core.scene")
local Tilemap = require("core.tilemap")
local Tiled = require("core.tiled_import")
local Workspace = require("core.roag_workspace")
local RecentProjects = require("core.recent_projects")
local ProjectPicker = require("core.project_picker")
local ArtSources = require("core.art_sources")
local Theme = require("ui.theme")
local Widgets = require("ui.widgets")
local Chrome = require("ui.chrome")
local ImageLoader = require("ui.image_loader")
local NativeWorkspace = require("ui.native_workspace")
local Launcher = require("ui.views.launcher")
local Presentation = require("ui.views.presentation")
local ArtView = require("ui.views.art")
local NativeSceneView = require("ui.views.native_scene")
local NativePreviewView = require("ui.views.native_preview")

local Studio = {}
Studio.__index = Studio
Widgets.install(Studio)

local COLORS, ROLES = Theme.colors, ArtSources.roles

local color, inside, clamp, dock_width = Theme.color, Theme.inside, Theme.clamp, Theme.dock_width

local function path_arg(arguments, flag)
  flag = flag or "--roag"
  for index, value in ipairs(arguments or {}) do
    if value == flag then return arguments[index + 1] end
    local path = value:match("^" .. flag:gsub("([^%w])", "%%%1") .. "=(.+)$")
    if path then return path end
  end
end

local function normalize_project_root(path)
  if type(path) ~= "string" then return nil, "Choose a project folder or " .. Project.MANIFEST end
  path = path:gsub("^%s+", ""):gsub("%s+$", ""):gsub("\\", "/")
  if path == "" then return nil, "Choose a project folder or " .. Project.MANIFEST end
  local leaf = path:match("([^/]+)$")
  if path:match("%.json$") and leaf ~= Project.MANIFEST then
    return nil, "Choose the " .. Project.MANIFEST .. " file, not an arbitrary JSON file"
  end
  if leaf == Project.MANIFEST then path = path:match("^(.*)/[^/]+$") or "." end
  if not path:match("^/") and not path:match("^[A-Za-z]:/") then
    local base = love and love.filesystem and love.filesystem.getWorkingDirectory and love.filesystem.getWorkingDirectory()
    if base and base ~= "" then path = base:gsub("/+$", "") .. "/" .. path end
  end
  if path ~= "/" then path = path:gsub("/+$", "") end
  return path
end

local function normalize_new_project_root(path)
  if type(path) == "string" and Fs.basename(path:gsub("^%s+", ""):gsub("%s+$", "")) == Project.MANIFEST then
    return nil, "Choose the final project folder, not its manifest file"
  end
  return normalize_project_root(path)
end

local image_from_path = ImageLoader.load

function Studio.new(arguments)
  local target = path_arg(arguments, "--roag") or Bridge.DEFAULT_TARGET
  local project_root = normalize_project_root(path_arg(arguments, "--project") or ".") or "."
  local self = setmetatable({ bridge = Bridge.new(target), project_root = project_root, tab = "projects", selected_screen = 1, selected_action = 1, selected_role = 1, selected_corpus = "dungeon", selected_room = 1, selected_asset = 1, selected_map_layer = 1, native_asset_scroll = 0, room_scroll = 0, role_filter = "", role_filtering = false, scroll = 0, sheet_zoom = 1, sheet_pan_x = 0, sheet_pan_y = 0, sheet_panning = false, art_sheet_selection = {}, art_source_scroll = 0, art_sheet_zoom = 1, art_sheet_pan_x = 0, art_sheet_pan_y = 0, art_sheet_panning = false, art_images = {}, map_zoom = 1, map_pan_x = 0, map_pan_y = 0, map_panning = false, dirty = false, room_dirty = false, native_dirty = false, native_preview = nil, undo_stack = {}, redo_stack = {}, room_histories = {}, active = nil, draft = "", controls = {}, status = "Loading data-driven workspace…", fonts = {}, images = {}, native_images = {}, native_quads = {}, cursors = {}, sounds = {}, recent_projects = {} }, Studio)
  self:load_assets()
  self:load_recent_projects()
  self:reload()
  return self
end

function Studio:load_assets()
  love.graphics.setDefaultFilter("nearest", "nearest")
  self.fonts = {
    -- The built-in proportional face is deliberately neutral: UI copy and
    -- user-authored names should be readable rather than part of the game's
    -- visual identity. Pixel assets still render with nearest-neighbor.
    small = love.graphics.newFont(12), normal = love.graphics.newFont(14), large = love.graphics.newFont(20), title = love.graphics.newFont(28),
  }
  local cursor_base = "assets/kenney/cursor_pack/PNG/Basic/Default/"
  self.cursors.default = love.mouse.newCursor(cursor_base .. "pointer_scifi_a.png", 3, 2)
  self.cursors.action = love.mouse.newCursor(cursor_base .. "hand_point.png", 3, 3)
  self.cursors.picker = love.mouse.newCursor(cursor_base .. "drawing_picker.png", 4, 4)
  self.cursors.pan = love.mouse.newCursor(cursor_base .. "hand_closed.png", 4, 4)
  self.cursors.text = love.mouse.newCursor(cursor_base .. "drawing_pen.png", 3, 3)
  self.sounds.click = love.audio.newSource("assets/kenney/ui_pack/Sounds/click-a.ogg", "static")
end

function Studio:play_click()
  if self.sounds.click then self.sounds.click:stop(); self.sounds.click:play() end
end

function Studio:reload()
  self.workspace = Workspace.new(self.bridge.target)
  local loaded, failure = self.workspace:load()
  if not loaded then
    self.data, self.roag_error = nil, failure
    self:load_native_project()
    self.status = "Could not open ROAG JSON workspace: " .. failure.reason .. ". Native project tools remain available."
    return nil, failure
  end
  self.data, self.corpora, self.roag_error, self.dirty, self.room_dirty, self.undo_stack, self.redo_stack, self.active = loaded.presentation, loaded.corpora, nil, false, false, {}, {}, nil
  self.selected_screen = clamp(self.selected_screen, 1, #self.data.screens.screens)
  self.selected_action = clamp(self.selected_action, 1, #self.data.flow.title_actions)
  self.selected_room = clamp(self.selected_room, 1, #(self.corpora[self.selected_corpus].rooms))
  self:load_native_project()
  self.status = "Loaded native project and ROAG JSON workspace from " .. self.bridge.target
  self:load_sheet()
  return true
end

function Studio:load_native_project()
  self.native_preview = nil
  self.project = Project.new(self.project_root)
  local manifest, failure = self.project:load()
  if not manifest then
    self.project, self.project_manifest, self.project_error = nil, nil, failure.reason
    self:update_window_title()
    return
  end
  self.project_manifest, self.project_error, self.native_assets = manifest, nil, {}
  for asset_id, entry in pairs(manifest.assets) do self.native_assets[#self.native_assets + 1] = { id = asset_id, entry = entry } end
  table.sort(self.native_assets, function(a, b) return a.id < b.id end)
  self.selected_asset = clamp(self.selected_asset, 1, math.max(1, #self.native_assets))
  self.runtime = Runtime.new(self.project)
  self:select_native_asset(self.selected_asset)
  self:remember_project(self.project.root, manifest.name)
  self:update_window_title()
end

function Studio:has_project()
  return self.project_manifest ~= nil
end

function Studio:is_roag_available()
  return self.data ~= nil
end

function Studio:workspace_breadcrumb()
  local project_name = self.project_manifest and self.project_manifest.name or "Unpolished Bees"
  local labels = {
    home = "Overview", projects = "Projects", native = "Native Assets", rooms = "Rooms", art = "Art & Sprites", scenes = "Scenes", flow = "Title Flow", publish = "Publish",
  }
  local label = labels[self.tab] or "Workspace"
  if self.tab == "native" and self.native_preview then return project_name .. "  /  Native Assets  /  Preview" end
  if self.tab == "rooms" or self.tab == "art" or self.tab == "scenes" or self.tab == "flow" or self.tab == "publish" then
    return project_name .. "  /  ROAG  /  " .. label
  end
  return project_name .. "  /  " .. label
end

function Studio:update_window_title()
  if not (love and love.window and love.window.setTitle) then return end
  local name = self.project_manifest and self.project_manifest.name
  love.window.setTitle(name and ("Unpolished Bees — " .. name) or "Unpolished Bees")
end

function Studio:load_recent_projects()
  self.recent_projects = RecentProjects.load()
end

function Studio:remember_project(path, name)
  self.recent_projects = RecentProjects.remember(self.recent_projects, path, name)
  -- Recents improve the launcher but must never make opening a valid project
  -- fail if the platform save area is unavailable.
  RecentProjects.save(self.recent_projects)
end

function Studio:confirm_project_switch()
  if not (self.dirty or self.room_dirty or self.native_dirty) then return true end
  local choice = self:choice("Switch project", "Save all pending Studio changes before switching projects?", { "Cancel", "Save all", "Discard" })
  if choice == 3 then return true end
  if choice ~= 2 then return false end
  if self.native_dirty and not self:save_native() then return false end
  if self.room_dirty and not self:save_room() then return false end
  if self.dirty and not self:save() then return false end
  return true
end

function Studio:open_project(path)
  local root, reason = normalize_project_root(path)
  if not root then self.status = reason; return nil, { reason = reason } end
  local candidate = Project.new(root)
  local manifest, failure = candidate:load()
  if not manifest then
    self.tab, self.status = "projects", "Could not open project: " .. failure.reason
    return nil, failure
  end
  -- A successful project switch is the last possible point to release the
  -- old runtime. Failed opens leave a useful Preview session intact.
  self:stop_native_preview("Stopped Preview before switching projects.")
  self.project_root, self.project, self.project_manifest, self.project_error = root, candidate, manifest, nil
  self.native_images, self.native_quads = {}, {}
  self:load_native_project()
  self.new_project = nil
  self.tab, self.status = "native", "Opened " .. manifest.name .. "."
  return true
end

function Studio:request_project_open(path)
  local root, reason = normalize_project_root(path)
  if not root then self.status = reason; return nil, { reason = reason } end
  if root == self.project_root then self.tab, self.status = "native", "This project is already open."; return true end
  if not self:confirm_project_switch() then return nil, { reason = "Project switch cancelled" } end
  return self:open_project(root)
end

function Studio:choose_project(kind)
  if not self:confirm_project_switch() then return end
  local path, reason = kind == "manifest" and ProjectPicker.choose_manifest() or ProjectPicker.choose_folder()
  if not path then
    if reason ~= "cancelled" then self.status = "Project picker: " .. tostring(reason) end
    return
  end
  self:open_project(path)
end

function Studio:begin_new_project()
  self:commit_field()
  self:stop_native_preview("Stopped Preview before creating a project.")
  self.new_project = { name = "", folder = "", error = nil, collision_path = nil }
  self.tab, self.status = "projects", "Choose a project name and an empty folder."
end

function Studio:cancel_new_project()
  self:cancel_field()
  self.new_project = nil
  self.status = "New project creation cancelled."
end

function Studio:begin_new_project_field(field)
  local creation = self.new_project
  if not creation then return end
  self:commit_field()
  self.active, self.draft = { kind = "new_project", field = field }, tostring(creation[field] or "")
end

function Studio:choose_new_project_folder()
  local creation = self.new_project
  if not creation then return end
  self:commit_field()
  local path, reason = ProjectPicker.choose_folder("new_project")
  if not path then
    if reason ~= "cancelled" then self.status = "Project folder picker: " .. tostring(reason) end
    return
  end
  local root, normalize_reason = normalize_new_project_root(path)
  if not root then
    creation.error, self.status = normalize_reason, normalize_reason
    return
  end
  creation.folder, creation.error, creation.collision_path = root, nil, nil
  self.status = "Selected project folder " .. root
end

function Studio:create_new_project()
  self:commit_field()
  local creation = self.new_project
  if not creation then return end
  local root, normalize_reason = normalize_new_project_root(creation.folder)
  if not root then
    creation.error, self.status = normalize_reason, normalize_reason
    return nil, { reason = normalize_reason }
  end
  creation.folder = root
  local plan, validation = Project.validate_creation(root, creation.name)
  if not plan then
    creation.error = validation.reason
    creation.collision_path = validation.code == "project_exists" and root or nil
    self.status = "Could not create project: " .. validation.reason
    return nil, validation
  end
  -- Validate before asking about dirty work.  A cancelled or invalid creation
  -- attempt must leave the active project and its in-memory edits untouched.
  if not self:confirm_project_switch() then
    self.status = "New project creation cancelled; current project remains open."
    return nil, { reason = "Project switch cancelled" }
  end
  local created, failure = Project.create(plan.root, plan.name)
  if not created then
    creation.error, self.status = failure.reason, "Could not create project: " .. failure.reason
    return nil, failure
  end
  local opened, open_failure = self:open_project(created.root)
  if not opened then
    creation.error, self.status = "Created the project, but could not open it: " .. open_failure.reason
    return nil, open_failure
  end
  self.new_project = nil
  self.status = "Created and opened " .. plan.name .. "."
  return true
end

function Studio:open_new_project_collision()
  local creation = self.new_project
  if not (creation and creation.collision_path) then return end
  if self:request_project_open(creation.collision_path) then self.new_project = nil end
end

function Studio:begin_project_path()
  self:commit_field()
  -- Start blank so a clipboard paste replaces the path in one action instead
  -- of requiring an author to erase the current absolute path first.
  self.active, self.draft = { kind = "project_path" }, ""
end

function Studio:select_native_asset(index)
  self.selected_asset = index
  local asset = self:current_native_asset()
  if not asset then self.native_asset_data, self.native_asset_error = nil, "No native asset selected"; return end
  self.native_asset_data, self.native_asset_error = self.project:load_asset(asset.id)
  self.native_dirty, self.native_history = false, History.new()
  self.native_selected_node = self.native_asset_data and self.native_asset_data.type == "scene" and self.native_asset_data.root or nil
  self.native_selected_flow_node, self.native_drag, self.generated_preview = nil, nil, nil
  self.native_reparent_source, self.scene_panning = nil, false
  NativeSceneView.reset(self)
  self.selected_map_layer, self.map_zoom, self.map_pan_x, self.map_pan_y = 1, 1, 0, 0
end

function Studio:select_scene_node(node_or_id)
  local scene = self.native_asset_data
  if not (scene and scene.type == "scene") then return nil end
  local node_id = type(node_or_id) == "table" and node_or_id.id or node_or_id
  local selected = node_id and Scene.find(scene, node_id) or nil
  self.native_selected_node = selected or scene.root
  return self.native_selected_node
end

function Studio:scene_creation_parent()
  local scene = self.native_asset_data
  local selected = self.native_selected_node or scene.root
  -- Panels and the root are the visual containers exposed by this editor. A
  -- new primitive selected from a label/button is placed beside it instead of
  -- creating a surprising invisible containment relationship.
  if selected.type == "scene" or selected.type == "panel" then return selected end
  local parent = Scene.parent_of(scene, selected.id)
  return parent and parent.node or scene.root
end

function Studio:record_native()
  if self.native_asset_data then self.native_history:record(self.native_asset_data); self.native_dirty = true end
end

function Studio:room_history_key()
  local room = self:current_room()
  return room and self.selected_corpus .. "/" .. room.filename
end

function Studio:record_room()
  local key, room = self:room_history_key(), self:current_room()
  if key and room then
    self.room_histories[key] = self.room_histories[key] or History.new()
    self.room_histories[key]:record(room.data); self.room_dirty = true
  end
end

function Studio:undo_native()
  local selected_id = self.native_selected_node and self.native_selected_node.id
  local data = self.native_history and self.native_history:undo(self.native_asset_data)
  if not data then self.status = "Nothing to undo in this asset."; return end
  self.native_asset_data, self.native_dirty = data, true
  if data.type == "scene" then self:select_scene_node(selected_id) else self.native_selected_node = nil end
  self.native_reparent_source, self.native_drag = nil, nil
  self.status = "Undid native asset edit."
end

function Studio:redo_native()
  local selected_id = self.native_selected_node and self.native_selected_node.id
  local data = self.native_history and self.native_history:redo(self.native_asset_data)
  if not data then self.status = "Nothing to redo in this asset."; return end
  self.native_asset_data, self.native_dirty = data, true
  if data.type == "scene" then self:select_scene_node(selected_id) else self.native_selected_node = nil end
  self.native_reparent_source, self.native_drag = nil, nil
  self.status = "Redid native asset edit."
end

function Studio:undo_room()
  local key, room = self:room_history_key(), self:current_room()
  local data = key and self.room_histories[key] and self.room_histories[key]:undo(room.data)
  if not data then self.status = "Nothing to undo in this room."; return end
  room.data, self.room_dirty = data, true; self.status = "Undid room edit."
end

function Studio:redo_room()
  local key, room = self:room_history_key(), self:current_room()
  local data = key and self.room_histories[key] and self.room_histories[key]:redo(room.data)
  if not data then self.status = "Nothing to redo in this room."; return end
  room.data, self.room_dirty = data, true; self.status = "Redid room edit."
end

function Studio:load_sheet()
  local path = self.bridge:sheet_path()
  local ok, image = pcall(image_from_path, path)
  self.sheet = ok and image or nil
  self.sheet_error = ok and nil or tostring(image)
end

function Studio:art_sheets(pack)
  return ArtSources.for_pack(pack)
end

function Studio:current_art_sheet(pack)
  local sheets = self:art_sheets(pack)
  if #sheets == 0 then return nil end
  local index = clamp(self.art_sheet_selection[pack.id] or 1, 1, #sheets)
  self.art_sheet_selection[pack.id] = index
  return sheets[index], index
end

function Studio:art_sheet_path(sheet)
  return self.bridge.target:gsub("/+$", "") .. "/" .. sheet.path
end

function Studio:art_sheet_image(sheet)
  if not sheet then return nil, "No source sheet is declared for this art pack." end
  local path = self:art_sheet_path(sheet)
  local cached = self.art_images[path]
  if cached then return cached.image, cached.error end
  local ok, image = pcall(image_from_path, path)
  local value = { image = ok and image or nil, error = ok and nil or tostring(image) }
  self.art_images[path] = value
  return value.image, value.error
end

function Studio:select_art_sheet(pack_id, index)
  self.art_sheet_selection[pack_id] = index
  self.art_sheet_zoom, self.art_sheet_pan_x, self.art_sheet_pan_y = 1, 0, 0
end

function Studio:select_imported_tileset(asset_id)
  self.native_images, self.native_quads = {}, {}
  self:load_native_project()
  for index, asset in ipairs(self.native_assets or {}) do
    if asset.id == asset_id then self:select_native_asset(index); break end
  end
  self.tab = "native"
end

function Studio:import_art_sheet(pack, sheet)
  if not self.project_manifest or not self.project then
    self.status = "Open a native project before adding this sheet. The source preview remains read-only."
    return
  end
  local target_path = "assets/" .. Project.slug(pack.label) .. "_" .. Project.slug(sheet.id) .. ".png"
  for asset_id, entry in pairs(self.project_manifest.assets) do
    if entry.type == "tileset" then
      local tileset = self.project:load_asset(asset_id)
      if tileset and tileset.texture and tileset.texture.path == target_path then
        self:select_imported_tileset(asset_id)
        self.status = "This source sheet is already available as " .. asset_id .. "."
        return true, tileset
      end
    end
  end
  if not self:resolve_native_before_change() then return end
  local source = self:art_sheet_path(sheet)
  local tileset, failure = self.project:import_tileset(source, pack.label .. " " .. sheet.id, {
    texture_path = target_path,
    tile_width = sheet.tile_width,
    tile_height = sheet.tile_height,
  })
  if not tileset then
    self.status = "Could not add source sheet: " .. failure.reason
    return
  end
  self:select_imported_tileset(tileset.id)
  self.status = "Added " .. sheet.label .. " as " .. tileset.id .. ". It is now available to native tilemaps."
  return true, tileset
end

function Studio:record()
  self.undo_stack[#self.undo_stack + 1] = Bridge.copy(self.data)
  if #self.undo_stack > 60 then table.remove(self.undo_stack, 1) end
  self.redo_stack = {}
  self.dirty = true
end

function Studio:undo()
  local prior = self.undo_stack[#self.undo_stack]
  if not prior then self.status = "Nothing to undo."; return end
  self.redo_stack[#self.redo_stack + 1] = Bridge.copy(self.data)
  self.data = prior; table.remove(self.undo_stack); self.dirty = #self.undo_stack > 0
  self.status = "Undid presentation edit."
end

function Studio:redo()
  local next_data = self.redo_stack[#self.redo_stack]
  if not next_data then self.status = "Nothing to redo."; return end
  self.undo_stack[#self.undo_stack + 1] = Bridge.copy(self.data)
  self.data = next_data; table.remove(self.redo_stack); self.dirty = true
  self.status = "Redid presentation edit."
end

function Studio:save()
  self:commit_field()
  local ok, failure = self.bridge:save(self.data)
  if not ok then self.status = "Could not publish: " .. failure.reason; return nil, failure end
  self.dirty, self.status = false, "Published validated presentation files. Refocus ROAG to preview them."
  self:play_click()
  return true
end

function Studio:current_screen()
  return self.data.screens.screens[self.selected_screen]
end

function Studio:current_action()
  return self.data.flow.title_actions[self.selected_action]
end

function Studio:current_role()
  return ROLES[self.selected_role]
end

function Studio:begin_field(kind, field)
  self:commit_field()
  local item = kind == "screen" and self:current_screen() or self:current_action()
  if kind == "action" and not Bridge.is_title_action_editable(item) then
    self.status = "This ROAG title action is preserved read-only by this Studio version."
    return
  end
  self.active, self.draft = { kind = kind, field = field }, tostring(item[field] or "")
end

function Studio:begin_native_field(target, field, value_type)
  self:commit_field()
  local value = target[field]
  self.active = { kind = "native_field", target = target, field = field, value_type = value_type or "text" }
  self.draft = tostring(value == nil and "" or value)
end

function Studio:commit_field()
  if not self.active then return end
  if self.active.kind == "new_project" then
    local creation = self.new_project
    if creation then
      creation[self.active.field], creation.error, creation.collision_path = self.draft, nil, nil
    end
    self.active, self.draft = nil, ""
    return
  end
  if self.active.kind == "project_path" then
    local path = self.draft
    self.active, self.draft = nil, ""
    self:request_project_open(path)
    return
  end
  if self.active.kind == "native_field" then
    local target, field, value_type = self.active.target, self.active.field, self.active.value_type
    local value = self.draft
    if value_type == "number" then
      value = tonumber(value)
      if type(value) ~= "number" or value ~= value or value == math.huge or value == -math.huge then
        self.active, self.draft = nil, ""
        self.status = tostring(field):upper() .. " must be a valid number; the previous value was kept."
        return
      end
    end
    if value ~= target[field] and (value_type == "text" or value ~= nil) then
      self:record_native(); target[field] = value
      if self.native_asset_data and self.native_asset_data.type == "tileset" then self.native_images, self.native_quads = {}, {} end
      self.status = "Updated serializable " .. field .. ". Save writes this JSON asset."
    end
    self.active, self.draft = nil, ""
    return
  end
  local item = self.active.kind == "screen" and self:current_screen() or self:current_action()
  if self.draft ~= item[self.active.field] and self.draft ~= "" then self:record(); item[self.active.field] = self.draft end
  self.active, self.draft = nil, ""
end

function Studio:cancel_field()
  self.active, self.draft = nil, ""
end

function Studio:layout()
  local width, height = love.graphics.getDimensions()
  local nav_width = width >= 1100 and 154 or 124
  return {
    width = width, height = height,
    header = { x = 0, y = 0, width = width, height = 66 },
    nav = { x = 8, y = 74, width = nav_width, height = height - 110 },
    body = { x = nav_width + 18, y = 74, width = width - nav_width - 26, height = height - 110 },
    footer = { x = 8, y = height - 28, width = width - 16, height = 20 },
  }
end

function Studio:can_undo_current()
  if self.native_preview then return false end
  if self.tab == "native" then return self.native_history and self.native_history:can_undo() end
  if self.tab == "rooms" then
    local history = self.room_histories and self.room_histories[self:room_history_key()]
    return history and history:can_undo()
  end
  return #self.undo_stack > 0
end

function Studio:can_redo_current()
  if self.native_preview then return false end
  if self.tab == "native" then return self.native_history and self.native_history:can_redo() end
  if self.tab == "rooms" then
    local history = self.room_histories and self.room_histories[self:room_history_key()]
    return history and history:can_redo()
  end
  return #self.redo_stack > 0
end

function Studio:save_current()
  if self.native_preview then self.status = "Stop Preview before saving authored data."; return nil, { reason = "Preview is active" } end
  if self.tab == "native" then return self:save_native() end
  if self.tab == "rooms" then return self:save_room() end
  if self.tab == "projects" then self.status = "Choose a project, then edit an asset before saving."; return end
  return self:save()
end

function Studio:undo_current()
  if self.native_preview then self.status = "Stop Preview before editing authored history."; return end
  self:commit_field()
  if self.tab == "native" then return self:undo_native() end
  if self.tab == "rooms" then return self:undo_room() end
  return self:undo()
end

function Studio:redo_current()
  if self.native_preview then self.status = "Stop Preview before editing authored history."; return end
  self:commit_field()
  if self.tab == "native" then return self:redo_native() end
  if self.tab == "rooms" then return self:redo_room() end
  return self:redo()
end

function Studio:show_help(topic)
  local title, message
  if topic == "shortcuts" then
    title = "Unpolished Bees shortcuts"
    message = "Cmd/Ctrl+O  Open a project\nCmd/Ctrl+S  Save the current workspace\nCmd/Ctrl+Z  Undo\nCmd/Ctrl+Y or Cmd/Ctrl+R  Redo\nEsc (Preview)  Stop Preview\nF (Art & Sprites)  Filter ROAG 1-bit roles\nWheel over a sheet  Zoom\nRight-drag a sheet  Pan"
  else
    title = "About Unpolished Bees"
    message = "A small Lua/LÖVE authoring studio for serializable 2D project data and the safe ROAG presentation boundary.\n\nProject and asset data are JSON; ROAG Lua, saves, routes, and profiles are never edited."
  end
  if love and love.window and love.window.showMessageBox then
    pcall(love.window.showMessageBox, title, message, { "OK" }, "info", true)
  end
  self.status = topic == "shortcuts" and "Keyboard shortcuts shown." or "About Unpolished Bees shown."
end

function Studio:current_native_asset()
  return self.native_assets and self.native_assets[self.selected_asset]
end

local function snapshot(value)
  local encoded, encode_reason = Json.encode(value)
  if not encoded then return nil, { code = "preview_snapshot_failed", reason = tostring(encode_reason) } end
  local decoded, decode_reason = Json.decode(encoded)
  if not decoded then return nil, { code = "preview_snapshot_failed", reason = tostring(decode_reason) } end
  return decoded
end

function Studio:preview_flow_id()
  if not self.project_manifest then return nil end
  local main = self.project_manifest.assets["flow.main"]
  if main and main.type == "flow" then return "flow.main" end
  local candidates = {}
  for asset_id, entry in pairs(self.project_manifest.assets) do
    if entry.type == "flow" then candidates[#candidates + 1] = asset_id end
  end
  table.sort(candidates)
  return candidates[1]
end

function Studio:preview_source(scene_only)
  if not (self.project and self.project_manifest) then return nil, { code = "project_required", reason = "Open a native project before previewing" } end
  local flow_id = scene_only and nil or self:preview_flow_id()
  local main_scene_id = self.project_manifest.main_scene_id
  local overrides, included_asset = {}, nil
  local selected = self:current_native_asset()
  -- Native editing has a single active document.  Include it only when it is
  -- a runtime prerequisite, so Preview cannot be blocked by an unrelated
  -- unsaved map/generator and never has a silent partial dirty overlay.
  if self.native_dirty and selected and self.native_asset_data and (selected.id == main_scene_id or selected.id == flow_id) then
    local valid, validation = Project.validate_asset(self.native_asset_data, selected.entry.type)
    if not valid then return nil, validation end
    local document, snapshot_failure = snapshot(self.native_asset_data)
    if not document then return nil, snapshot_failure end
    overrides[selected.id], included_asset = document, selected.id
  end
  return {
    main_scene_id = main_scene_id,
    flow_id = flow_id,
    asset_overrides = overrides,
    included_asset = included_asset,
    scene_only = scene_only == true,
  }
end

function Studio:build_native_preview_runtime(source)
  local runtime = Runtime.new(self.project, nil, { asset_overrides = source.asset_overrides })
  local loaded, failure
  if source.flow_id then loaded, failure = runtime:start(source.flow_id)
  else loaded, failure = runtime:load_scene(source.main_scene_id) end
  if not loaded then return nil, failure end
  return runtime
end

function Studio:start_native_preview(scene_only)
  self:commit_field()
  if self.native_preview then return self:restart_native_preview() end
  local source, source_failure = self:preview_source(scene_only)
  if not source then
    self.status = "Cannot preview project: " .. tostring(source_failure.reason)
    return nil, source_failure
  end
  local runtime, runtime_failure = self:build_native_preview_runtime(source)
  if not runtime then
    self.status = "Cannot preview project: " .. tostring(runtime_failure.reason)
    return nil, runtime_failure
  end
  local selected_node = self.native_selected_node and self.native_selected_node.id or nil
  self.native_preview = {
    runtime = runtime,
    source = source,
    flow_id = source.flow_id,
    warnings = runtime:capability_warnings(),
    context = {
      tab = self.tab,
      selected_asset = self.selected_asset,
      selected_node_id = selected_node,
      scene_zoom = self.scene_zoom,
      scene_pan_x = self.scene_pan_x,
      scene_pan_y = self.scene_pan_y,
    },
  }
  self.native_drag, self.native_reparent_source, self.active = nil, nil, nil
  local source_note = source.included_asset and (" using current unsaved " .. source.included_asset) or " using saved project data"
  self.status = "Preview started" .. source_note .. "."
  return true
end

function Studio:restart_native_preview()
  local preview = self.native_preview
  if not preview then return self:start_native_preview(false) end
  local runtime, failure = self:build_native_preview_runtime(preview.source)
  if not runtime then
    preview.error = failure
    self.status = "Could not restart preview: " .. tostring(failure.reason)
    return nil, failure
  end
  preview.runtime, preview.warnings, preview.error = runtime, runtime:capability_warnings(), nil
  self.status = "Preview restarted without saving authored data."
  return true
end

function Studio:stop_native_preview(reason)
  local preview = self.native_preview
  if not preview then return false end
  self.native_preview, self.native_drag, self.native_reparent_source = nil, nil, nil
  local context = preview.context or {}
  if self.tab == "native" and context.selected_asset and context.selected_asset ~= self.selected_asset then self:select_native_asset(context.selected_asset) end
  if self.tab == "native" and context.selected_node_id then self:select_scene_node(context.selected_node_id) end
  if self.tab == "native" then
    self.scene_zoom = context.scene_zoom or self.scene_zoom
    self.scene_pan_x = context.scene_pan_x or self.scene_pan_x
    self.scene_pan_y = context.scene_pan_y or self.scene_pan_y
  end
  self.status = reason or "Stopped Preview and returned to the editor."
  return true
end

function Studio:draw_native_flow(flow, canvas)
  local by_id, positions = {}, {}
  for index, node in ipairs(flow.nodes) do
    local point = node.editor or { x = 28 + ((index - 1) % 4) * 150, y = 46 + math.floor((index - 1) / 4) * 92 }
    by_id[node.id], positions[node.id] = node, point
  end
  for _, edge in ipairs(flow.edges) do
    local from, to = positions[edge.from], positions[edge.to]
    if from and to then color(COLORS.border); love.graphics.line(canvas.x + from.x + 120, canvas.y + from.y + 30, canvas.x + to.x, canvas.y + to.y + 30) end
  end
  for _, node in ipairs(flow.nodes) do
    local point, selected = positions[node.id], self.native_selected_flow_node == node
    local rect = { x = canvas.x + point.x, y = canvas.y + point.y, width = 120, height = 60 }
    self:panel(rect, selected and COLORS.selected or COLORS.surface2, selected and COLORS.selected_border or COLORS.border)
    self:text(node.type:upper(), rect.x + 7, rect.y + 8, .58, selected and COLORS.gold or COLORS.muted)
    self:line(node.id:gsub("^graph%.", ""), rect.x + 7, rect.y + 28, .68, COLORS.text, rect.width - 14)
    self.controls[#self.controls + 1] = { rect = rect, action = { type = "native_flow_node", node = node }, cursor = "action" }
  end
end

function Studio:current_map_layer(map)
  if not map or not map.layers or #map.layers == 0 then return nil end
  self.selected_map_layer = clamp(self.selected_map_layer or 1, 1, #map.layers)
  return map.layers[self.selected_map_layer]
end

function Studio:tileset_image(tileset)
  if not tileset or not tileset.texture then return nil end
  local relative = tileset.texture.path
  local path = self.project and self.project.root:gsub("/+$", "") .. "/" .. relative or relative
  local cached = self.native_images[path]
  if cached ~= nil then return cached or nil end
  local ok, image = pcall(image_from_path, path)
  self.native_images[path] = ok and image or false
  return ok and image or nil
end

function Studio:tileset_for_layer(layer)
  if not layer or not self.project then return nil end
  local tileset = self.project:load_asset(layer.tileset_id)
  return tileset
end

function Studio:draw_native_tile(image, tileset, tile, x, y, size)
  if not image or tile <= 0 then return false end
  local tile_width, tile_height = tileset.tile_width, tileset.tile_height
  local columns = math.floor(image:getWidth() / tile_width)
  if columns < 1 then return false end
  local index = tile - 1
  local source_x, source_y = (index % columns) * tile_width, math.floor(index / columns) * tile_height
  if source_y + tile_height > image:getHeight() then return false end
  self.native_quads = self.native_quads or {}
  local key = tileset.id .. ":" .. tile_width .. "x" .. tile_height .. ":" .. tile
  local quad = self.native_quads[key]
  if not quad then
    quad = love.graphics.newQuad(source_x, source_y, tile_width, tile_height, image:getDimensions())
    self.native_quads[key] = quad
  end
  color({ 1, 1, 1 }); love.graphics.draw(image, quad, x, y, 0, size / tile_width, size / tile_height)
  return true
end

function Studio:draw_native_tilemap(map, canvas)
  local layer = self:current_map_layer(map)
  if not layer then self:text("Tilemap has no layers.", canvas.x + 18, canvas.y + 18, .8, COLORS.red); return end
  local tileset = self:tileset_for_layer(layer)
  local image = self:tileset_image(tileset)
  local cell = clamp(math.floor(24 * self.map_zoom), 10, 64)
  local origin_x, origin_y = canvas.x + 12 + self.map_pan_x, canvas.y + 34 + self.map_pan_y
  local start_x = math.floor((canvas.x - origin_x) / cell) - 1
  local start_y = math.floor((canvas.y - origin_y) / cell) - 1
  local end_x = math.ceil((canvas.x + canvas.width - origin_x) / cell) + 1
  local end_y = math.ceil((canvas.y + canvas.height - origin_y) / cell) + 1
  if not map.infinite then
    start_x, start_y = math.max(0, start_x), math.max(0, start_y)
    end_x, end_y = math.min(map.width - 1, end_x), math.min(map.height - 1, end_y)
  end
  love.graphics.setScissor(canvas.x + 1, canvas.y + 1, canvas.width - 2, canvas.height - 2)
  for y = start_y, end_y do
    for x = start_x, end_x do
      local tile = Tilemap.get(map, layer.id, x, y) or 0
      local fill = tile == 0 and COLORS.surface or (tile % 3 == 0 and COLORS.mint or tile % 2 == 0 and COLORS.gold or COLORS.blue)
      local tile_x, tile_y = origin_x + x * cell, origin_y + y * cell
      color(fill); love.graphics.rectangle("fill", tile_x, tile_y, cell - 1, cell - 1)
      local drawn = tileset and self:draw_native_tile(image, tileset, tile, tile_x, tile_y, cell)
      if tile > 0 and not drawn then self:text(tile, tile_x, tile_y + math.floor(cell / 2 - 6), .55, COLORS.dark, cell - 1, "center") end
      self.controls[#self.controls + 1] = { rect = { x = origin_x + x * cell, y = origin_y + y * cell, width = cell, height = cell }, action = { type = "native_map_paint", map = map, x = x, y = y, layer_id = layer.id }, cursor = "picker" }
    end
  end
  love.graphics.setScissor()
  self.map_viewport = canvas
end

function Studio:draw_native_tileset(tileset, canvas)
  local image = self:tileset_image(tileset)
  if not image then
    self:text("No readable PNG at " .. tileset.texture.path .. ".\nDrop a PNG into the Studio to copy it into assets and create an image-backed tileset.", canvas.x + 20, canvas.y + 26, .78, COLORS.muted, canvas.width - 40)
    return
  end
  local tile_width, tile_height = tileset.tile_width, tileset.tile_height
  local columns, rows = math.floor(image:getWidth() / tile_width), math.floor(image:getHeight() / tile_height)
  local scale = math.min(3, math.max(.35, math.min((canvas.width - 32) / math.max(1, columns * tile_width), (canvas.height - 50) / math.max(1, rows * tile_height))))
  local width, height = columns * tile_width * scale, rows * tile_height * scale
  local x, y = canvas.x + 16, canvas.y + 30
  color({ 1, 1, 1 }); love.graphics.draw(image, x, y, 0, scale, scale)
  for row = 0, rows - 1 do
    for column = 0, columns - 1 do
      local index = row * columns + column + 1
      local rect = { x = x + column * tile_width * scale, y = y + row * tile_height * scale, width = tile_width * scale, height = tile_height * scale }
      if self.map_brush == index then color(COLORS.gold); love.graphics.setLineWidth(2); love.graphics.rectangle("line", rect.x, rect.y, rect.width, rect.height) end
      self.controls[#self.controls + 1] = { rect = rect, action = { type = "native_map_brush", tile = index }, cursor = "picker" }
    end
  end
  love.graphics.setLineWidth(1)
end

function Studio:current_room()
  local corpus = self.corpora and self.corpora[self.selected_corpus]
  return corpus and corpus.rooms[self.selected_room]
end

function Studio:draw_native_document_header(workspace, selected)
  local rect = workspace.header
  self:panel(rect, COLORS.surface, COLORS.border)
  if not selected then
    self:line("NO ASSET SELECTED", rect.x + 12, rect.y + 18, .82, COLORS.muted, rect.width - 24)
    return
  end
  local metadata_width = math.min(118, math.max(96, math.floor(rect.width * .22)))
  self:line(selected.id, rect.x + 12, rect.y + 9, .9, COLORS.text, rect.width - metadata_width - 28)
  self:line(selected.entry.path, rect.x + 12, rect.y + 32, .57, COLORS.muted, rect.width - metadata_width - 28)
  self:line(selected.entry.type:upper(), rect.x + rect.width - metadata_width - 10, rect.y + 10, .61, COLORS.gold, metadata_width, "right")
  self:line(self.native_dirty and "UNSAVED" or "SAVED", rect.x + rect.width - metadata_width - 10, rect.y + 31, .55, self.native_dirty and COLORS.gold or COLORS.mint, metadata_width, "right")
end

function Studio:draw_native_toolbar(workspace, tools)
  local rect = workspace.toolbar
  self:panel(rect, COLORS.surface, COLORS.border)
  local selected, history = self:current_native_asset(), self.native_history
  local function row(label, y, items)
    self:line(label, rect.x + 10, y + 8, .52, COLORS.muted, 56)
    local x = rect.x + 68
    for _, item in ipairs(items or {}) do
      self:button({ x = x, y = y, width = item.width, height = 30 }, item.label, item.action, item.options)
      x = x + item.width + 6
    end
  end
  row("DOC", rect.y + 5, {
    { label = "UNDO", width = 58, action = { type = "undo_native" }, options = { enabled = history and history:can_undo() } },
    { label = "REDO", width = 58, action = { type = "redo_native" }, options = { enabled = history and history:can_redo() } },
    { label = self.native_dirty and "SAVE ASSET" or "VALIDATE ASSET", width = 126, action = { type = "save_native" }, options = { selected = self.native_dirty } },
    { label = "REMOVE ASSET", width = 112, action = { type = "remove_native_asset" }, options = { danger = true, enabled = selected and selected.id ~= self.project_manifest.main_scene_id } },
  })
  if tools and #tools > 0 then
    row("TOOLS", rect.y + 41, tools)
  else
    self:line("No asset-specific tools for this document.", rect.x + 68, rect.y + 49, .58, COLORS.muted, rect.width - 78)
  end
end

function Studio:draw_native_footer(workspace, message, tint)
  local rect = workspace.footer
  self:panel(rect, COLORS.dark, COLORS.border)
  self:line(message, rect.x + 10, rect.y + 7, .58, tint or COLORS.muted, rect.width - 20)
end

function Studio:draw_native_scene_workspace(workspace)
  NativeSceneView.draw(self, workspace)
end

function Studio:draw_native_flow_workspace(workspace)
  local panes, flow = NativeWorkspace.editor_with_inspector(workspace.body), self.native_asset_data
  self:canvas_surface(panes.center)
  self:panel(panes.right, COLORS.surface, COLORS.border)
  self:draw_native_flow(flow, panes.center)
  local node = self.native_selected_flow_node
  self:dock_title(panes.right, "INSPECTOR", node and node.type:upper() or nil)
  if node then
    self:line(node.id, panes.right.x + 9, panes.right.y + 39, .62, COLORS.gold, panes.right.width - 18)
    local x, y, width = panes.right.x + 8, panes.right.y + 60, panes.right.width - 16
    if node.event then self:native_field({ x = x, y = y, width = width, height = 36 }, "EVENT", node, "event", "text"); y = y + 42 end
    if node.scene_id then self:native_field({ x = x, y = y, width = width, height = 36 }, "SCENE ID", node, "scene_id", "text"); y = y + 42 end
    if node.variable then self:native_field({ x = x, y = y, width = width, height = 36 }, "VARIABLE", node, "variable", "text"); y = y + 42 end
    self:button({ x = x, y = y, width = width, height = 30 }, self.native_connect_from and "PICK DESTINATION" or "CONNECT FROM", { type = "start_flow_connection" }, { selected = self.native_connect_from ~= nil })
    self:button({ x = x, y = y + 36, width = width, height = 30 }, "DELETE NODE", { type = "delete_flow_node" }, { danger = true })
  else
    self:text("Select a graph node to inspect its existing fields or connect it.", panes.right.x + 10, panes.right.y + 44, .67, COLORS.muted, panes.right.width - 20)
  end
  self:draw_native_footer(workspace, "Drag nodes to reposition · connect source, then destination", COLORS.mint)
end

function Studio:draw_native_tilemap_workspace(workspace)
  local panes, map = NativeWorkspace.three_columns(workspace.body), self.native_asset_data
  local layer = self:current_map_layer(map)
  self:panel(panes.left, COLORS.surface, COLORS.border)
  self:canvas_surface(panes.center)
  self:panel(panes.right, COLORS.surface, COLORS.border)
  self:dock_title(panes.left, "LAYERS", nil)
  for index, item in ipairs(map.layers) do
    local y = panes.left.y + 39 + (index - 1) * 36
    if y + 30 > panes.left.y + panes.left.height - 6 then break end
    self:button({ x = panes.left.x + 8, y = y, width = panes.left.width - 16, height = 30 }, item.id:gsub("^layer%.", ""), { type = "select_map_layer", index = index }, { selected = index == self.selected_map_layer })
  end
  self:draw_native_tilemap(map, panes.center)
  self:dock_title(panes.right, "PROPERTIES", layer and "LAYER" or nil)
  if layer then
    self:line(layer.id, panes.right.x + 9, panes.right.y + 39, .62, COLORS.gold, panes.right.width - 18)
    self:native_field({ x = panes.right.x + 8, y = panes.right.y + 60, width = panes.right.width - 16, height = 36 }, "TILESET ID", layer, "tileset_id", "text")
    self:line("Brush: " .. tostring(self.map_brush or 1), panes.right.x + 9, panes.right.y + 110, .61, COLORS.mint, panes.right.width - 18)
    self:line(map.infinite and "Infinite sparse map" or (map.width .. " × " .. map.height .. " map"), panes.right.x + 9, panes.right.y + 130, .56, COLORS.muted, panes.right.width - 18)
  end
  self:draw_native_footer(workspace, "Click to paint · wheel zooms · right-drag pans", COLORS.mint)
end

function Studio:draw_native_generator_workspace(workspace)
  local panes, data = NativeWorkspace.settings_and_editor(workspace.body), self.native_asset_data
  local settings = data.settings
  self:panel(panes.left, COLORS.surface, COLORS.border)
  self:canvas_surface(panes.center)
  self:dock_title(panes.left, "SETTINGS", data.generator_type:upper())
  local x, y, width = panes.left.x + 8, panes.left.y + 42, panes.left.width - 16
  self:native_field({ x = x, y = y, width = width, height = 36 }, "WIDTH", settings, "width", "number")
  self:native_field({ x = x, y = y + 42, width = width, height = 36 }, "HEIGHT", settings, "height", "number")
  self:native_field({ x = x, y = y + 84, width = width, height = 36 }, "SEED", settings, "seed", "number")
  self:native_field({ x = x, y = y + 126, width = width, height = 36 }, "THRESHOLD", settings, "threshold", "number")
  self:line("Deterministic preview", x, y + 180, .56, COLORS.mint, width)
  if self.generated_preview and self.generated_preview.type == "tilemap" then
    self:draw_native_tilemap(self.generated_preview, panes.center)
  else
    self:text("No preview generated yet.\n\nUse Generate Preview to inspect the current deterministic settings.", panes.center.x + 22, panes.center.y + 26, .77, COLORS.muted, panes.center.width - 44)
  end
  self:draw_native_footer(workspace, "Generated from current deterministic settings", COLORS.mint)
end

function Studio:draw_native_tileset_workspace(workspace)
  local panes, data = NativeWorkspace.settings_and_editor(workspace.body), self.native_asset_data
  self:panel(panes.left, COLORS.surface, COLORS.border)
  self:canvas_surface(panes.center)
  self:dock_title(panes.left, "PROPERTIES", "TILESET")
  local x, y, width = panes.left.x + 8, panes.left.y + 42, panes.left.width - 16
  self:native_field({ x = x, y = y, width = width, height = 36 }, "PNG PATH", data.texture, "path", "text")
  self:native_field({ x = x, y = y + 42, width = width, height = 36 }, "TILE WIDTH", data, "tile_width", "number")
  self:native_field({ x = x, y = y + 84, width = width, height = 36 }, "TILE HEIGHT", data, "tile_height", "number")
  self:draw_native_tileset(data, panes.center)
  self:draw_native_footer(workspace, "Click a visible tile to select the map brush", COLORS.mint)
end

function Studio:draw_native_room_template_workspace(workspace)
  self:canvas_surface(workspace.body)
  self:line("ROOM TEMPLATE", workspace.body.x + 20, workspace.body.y + 22, .72, COLORS.gold, workspace.body.width - 40)
  self:text("Native room-template visual editing is not implemented yet.\n\nThis asset remains valid and can be saved or validated. ROAG Rooms remains the live companion corpus editor.", workspace.body.x + 20, workspace.body.y + 52, .76, COLORS.muted, workspace.body.width - 40)
  self:draw_native_footer(workspace, "This document has no native visual editor yet", COLORS.muted)
end

function Studio:draw_native(view)
  if self.native_preview then
    NativePreviewView.draw(self, view)
    return
  end
  local list = { x = view.body.x, y = view.body.y, width = dock_width(view.body.width, .24, 258, 332), height = view.body.height }
  local editor = { x = list.x + list.width + 16, y = view.body.y, width = view.body.width - list.width - 16, height = view.body.height }
  self:panel(list); self:canvas_surface(editor); self:dock_title(list, "ASSETS", "JSON")
  if not self.project_manifest then
    self:text("Project manifest unavailable:\n" .. tostring(self.project_error), list.x + 14, list.y + 48, .78, COLORS.red, list.width - 28)
    return
  end
  self:line(self.project_manifest.name, list.x + 14, list.y + 41, .72, COLORS.text, list.width - 28)
  self:line("CREATE", list.x + 14, list.y + 65, .56, COLORS.muted, list.width - 28)
  local creates = { { "SCENE", "scene" }, { "TILESET", "tileset" }, { "MAP", "tilemap" }, { "FLOW", "flow" }, { "ROOM", "room_template" }, { "GEN", "generator" } }
  for index, item in ipairs(creates) do
    local column, row = (index - 1) % 3, math.floor((index - 1) / 3)
    self:button({ x = list.x + 10 + column * (list.width - 26) / 3, y = list.y + 83 + row * 36, width = (list.width - 32) / 3, height = 32 }, "+ " .. item[1], { type = "create_native_asset", asset_type = item[2] })
  end
  self:line("DROP PNG / TILED JSON TO IMPORT", list.x + 14, list.y + 158, .56, COLORS.mint, list.width - 28)
  self:line("JSON ASSETS · WHEEL TO SCROLL", list.x + 14, list.y + 178, .58, COLORS.muted, list.width - 28)
  local preview_y = list.y + list.height - 88
  local asset_top, asset_bottom, row_height = list.y + 197, preview_y - 12, 34
  local visible_rows = math.max(1, math.floor((asset_bottom - asset_top) / row_height))
  self.native_asset_scroll = clamp(self.native_asset_scroll or 0, 0, math.max(0, #self.native_assets - visible_rows))
  for index = self.native_asset_scroll + 1, math.min(#self.native_assets, self.native_asset_scroll + visible_rows) do
    local asset = self.native_assets[index]
    local selected = index == self.selected_asset
    local rect = { x = list.x + 9, y = asset_top + (index - self.native_asset_scroll - 1) * row_height, width = list.width - 18, height = 29 }
    self:panel(rect, selected and COLORS.selected or COLORS.surface2, selected and COLORS.selected_border or COLORS.border)
    self:line(asset.id, rect.x + 8, rect.y + 4, .68, COLORS.text, rect.width - 16)
    self:line(asset.entry.type:upper(), rect.x + 8, rect.y + 18, .50, COLORS.muted, rect.width - 16)
    self.controls[#self.controls + 1] = { rect = rect, action = { type = "native_asset", index = index }, cursor = "action" }
  end
  self.native_asset_list_rect = { x = list.x + 6, y = asset_top, width = list.width - 12, height = math.max(0, asset_bottom - asset_top) }
  self:line("PROJECT PREVIEW", list.x + 14, preview_y, .56, COLORS.muted, list.width - 28)
  self:button({ x = list.x + 10, y = preview_y + 18, width = list.width - 20, height = 28 }, "PREVIEW PROJECT", { type = "run_project" })
  self:button({ x = list.x + 10, y = preview_y + 50, width = list.width - 20, height = 28 }, "PREVIEW MAIN SCENE", { type = "run_scene" })

  local workspace, selected = NativeWorkspace.layout(editor), self:current_native_asset()
  self:draw_native_document_header(workspace, selected)
  if not (selected and self.native_asset_data) then
    self:draw_native_toolbar(workspace)
    self:canvas_surface(workspace.body)
    self:text("Select an asset to begin editing.", workspace.body.x + 22, workspace.body.y + 26, .8, COLORS.muted, workspace.body.width - 44)
    self:draw_native_footer(workspace, "Native assets are declared JSON documents", COLORS.muted)
    return
  end
  local kind = self.native_asset_data.type
  local tools = {
    scene = {
      { label = "+ PANEL", width = 76, action = { type = "add_native_node", node_type = "panel" } },
      { label = "+ LABEL", width = 76, action = { type = "add_native_node", node_type = "label" } },
      { label = "+ BUTTON", width = 84, action = { type = "add_native_node", node_type = "button" } },
      { label = self.native_reparent_source and "CANCEL" or "REPARENT", width = 112, action = { type = self.native_reparent_source and "cancel_scene_reparent" or "native_reparent_mode" }, options = { selected = self.native_reparent_source ~= nil, enabled = self.native_reparent_source ~= nil or self.native_selected_node ~= self.native_asset_data.root } },
    },
    flow = {
      { label = "+ EVENT", width = 78, action = { type = "add_flow_node", node_type = "event" } },
      { label = "+ TRANSITION", width = 108, action = { type = "add_flow_node", node_type = "transition" } },
      { label = "+ VARIABLE", width = 100, action = { type = "add_flow_node", node_type = "set_variable" } },
    },
    tilemap = {
      { label = "+ LAYER", width = 82, action = { type = "add_map_layer" } },
      { label = "DELETE LAYER", width = 128, action = { type = "remove_map_layer" }, options = { danger = true, enabled = #(self.native_asset_data.layers or {}) > 1 } },
      { label = "ERASE", width = 70, action = { type = "native_map_brush", tile = 0 }, options = { selected = self.map_brush == 0 } },
    },
    generator = {
      { label = "GENERATE PREVIEW", width = 150, action = { type = "generate_native" } },
    },
  }
  self:draw_native_toolbar(workspace, tools[kind])
  if kind == "scene" then self:draw_native_scene_workspace(workspace)
  elseif kind == "flow" then self:draw_native_flow_workspace(workspace)
  elseif kind == "tilemap" then self:draw_native_tilemap_workspace(workspace)
  elseif kind == "generator" then self:draw_native_generator_workspace(workspace)
  elseif kind == "tileset" then self:draw_native_tileset_workspace(workspace)
  elseif kind == "room_template" then self:draw_native_room_template_workspace(workspace)
  else
    self:canvas_surface(workspace.body)
    self:text("This native asset type has no editor view yet.", workspace.body.x + 22, workspace.body.y + 26, .8, COLORS.muted, workspace.body.width - 44)
    self:draw_native_footer(workspace, "Native asset document", COLORS.muted)
  end
end

function Studio:draw_rooms(view)
  local list = { x = view.body.x, y = view.body.y, width = dock_width(view.body.width, .23, 246, 320), height = view.body.height }
  local editor = { x = list.x + list.width + 16, y = view.body.y, width = view.body.width - list.width - 16, height = view.body.height }
  self:panel(list); self:canvas_surface(editor); self:dock_title(list, "ROOMS", "JSON")
  for index, corpus_id in ipairs(Workspace.CORPORA) do
    self:button({ x = list.x + 10, y = list.y + 43 + (index - 1) * 43, width = list.width - 20, height = 34 }, corpus_id:upper(), { type = "corpus", id = corpus_id }, { selected = self.selected_corpus == corpus_id })
  end
  local corpus = self.corpora[self.selected_corpus]
  self:line("DECLARED TEMPLATES · WHEEL TO SCROLL", list.x + 14, list.y + 142, .58, COLORS.muted, list.width - 28)
  local list_top, controls_top, row_height = list.y + 161, list.y + list.height - 213, 34
  local visible_rows = math.max(1, math.floor((controls_top - list_top - 6) / row_height))
  self.room_scroll = clamp(self.room_scroll or 0, 0, math.max(0, #corpus.rooms - visible_rows))
  for index = self.room_scroll + 1, math.min(#corpus.rooms, self.room_scroll + visible_rows) do
    local room = corpus.rooms[index]
    local selected = index == self.selected_room
    local rect = { x = list.x + 8, y = list_top + (index - self.room_scroll - 1) * row_height, width = list.width - 16, height = 28 }
    self:panel(rect, selected and COLORS.selected or COLORS.surface2, selected and COLORS.selected_border or COLORS.border)
    self:line(room.data.id:gsub("^room%." .. self.selected_corpus .. "%.", ""), rect.x + 7, rect.y + 6, .64, COLORS.text, rect.width - 14)
    self.controls[#self.controls + 1] = { rect = rect, action = { type = "room", index = index }, cursor = "action" }
  end
  self.room_list_rect = { x = list.x + 6, y = list_top, width = list.width - 12, height = math.max(0, controls_top - list_top - 6) }
  self:button({ x = list.x + 10, y = list.y + list.height - 205, width = (list.width - 28) / 2, height = 32 }, "+ ROOM", { type = "new_room" })
  self:button({ x = list.x + list.width / 2 + 4, y = list.y + list.height - 205, width = (list.width - 28) / 2, height = 32 }, "REMOVE", { type = "remove_room" }, { danger = true, enabled = #corpus.rooms > 1 })
  self:button({ x = list.x + 10, y = list.y + list.height - 167, width = list.width - 20, height = 32 }, "CORPUS DIAGNOSTICS", { type = "room_diagnostics" }, { selected = self.room_diagnostics ~= nil })
  self:button({ x = list.x + 10, y = list.y + list.height - 129, width = list.width - 20, height = 32 }, "PREVIEW 3 × 2", { type = "room_preview" })
  self:button({ x = list.x + 10, y = list.y + list.height - 91, width = (list.width - 28) / 2, height = 32 }, "UNDO", { type = "undo_room" }, { enabled = self.room_histories[self:room_history_key()] and self.room_histories[self:room_history_key()]:can_undo() })
  self:button({ x = list.x + list.width / 2 + 4, y = list.y + list.height - 91, width = (list.width - 28) / 2, height = 32 }, "REDO", { type = "redo_room" }, { enabled = self.room_histories[self:room_history_key()] and self.room_histories[self:room_history_key()]:can_redo() })
  self:button({ x = list.x + 10, y = list.y + list.height - 48, width = list.width - 20, height = 40 }, self.room_dirty and "SAVE ROOM" or "VALIDATE ROOM", { type = "save_room" }, { selected = self.room_dirty })
  local room = self:current_room()
  self:panel({ x = editor.x + 8, y = editor.y + 8, width = editor.width - 16, height = 62 }, COLORS.surface, COLORS.border)
  self:line(room.data.id:upper(), editor.x + 18, editor.y + 19, .78, COLORS.text, editor.width - 36)
  self:line("Click cells to paint the declared JSON template. Runtime generator code stays untouched.", editor.x + 18, editor.y + 43, .60, COLORS.muted, editor.width - 36)
  local grid = { x = editor.x + 18, y = editor.y + 82, width = math.min(editor.width * .48, editor.height - 154), height = math.min(editor.width * .48, editor.height - 154) }
  self:canvas_surface(grid)
  local tile = math.floor(math.min((grid.width - 20) / room.data.width, (grid.height - 20) / room.data.height))
  local grid_width, grid_height = room.data.width * tile, room.data.height * tile
  local origin_x, origin_y = grid.x + (grid.width - grid_width) / 2, grid.y + (grid.height - grid_height) / 2
  for row = 1, room.data.height do
    for column = 1, room.data.width do
      local glyph = room.data.layout[row]:sub(column, column)
      local fill = glyph == "#" and { .34, .38, .40 } or { .075, .09, .095 }
      color(fill); love.graphics.rectangle("fill", origin_x + (column - 1) * tile, origin_y + (row - 1) * tile, tile - 1, tile - 1)
      self.controls[#self.controls + 1] = { rect = { x = origin_x + (column - 1) * tile, y = origin_y + (row - 1) * tile, width = tile, height = tile }, action = { type = "room_paint", row = row, column = column }, cursor = "picker" }
    end
  end
  local palette_x = grid.x + grid.width + 20
  self:line("PALETTE", palette_x, grid.y + 5, .68, COLORS.gold, editor.x + editor.width - palette_x - 16)
  local glyphs = {}; for glyph in pairs(room.data.legend or {}) do glyphs[#glyphs + 1] = glyph end; table.sort(glyphs)
  self.room_brush = self.room_brush or glyphs[1]
  for index, glyph in ipairs(glyphs) do
    local material = tostring(room.data.legend[glyph]):gsub("^material%.", "")
    local label = material == "structure" and ("WALL " .. glyph) or (material == "terrain.air" and ("AIR " .. glyph) or glyph)
    self:button({ x = palette_x, y = grid.y + 30 + (index - 1) * 38, width = 130, height = 32 }, label, { type = "room_brush", glyph = glyph }, { selected = self.room_brush == glyph })
  end
  local connector_text = {}; for _, connector in ipairs(room.data.connectors or {}) do connector_text[#connector_text + 1] = connector.side .. "@" .. connector.offset end
  self:line("CONNECTORS  " .. table.concat(connector_text, "  "), palette_x, grid.y + 30 + #glyphs * 42, .63, COLORS.muted, editor.x + editor.width - palette_x - 16)
  local valid, validation = Workspace.validate_room(room.data)
  local health_y = grid.y + 56 + #glyphs * 42
  self:line(valid and "CURRENT ROOM: VALID" or ("CURRENT ROOM: " .. validation.reason), palette_x, health_y, .61, valid and COLORS.mint or COLORS.red, editor.x + editor.width - palette_x - 16)
  if self.room_diagnostics then
    local report, detail_y = self.room_diagnostics, health_y + 26
    local message
    if report.valid then
      message = "CORPUS: VALID · " .. report.room_count .. " rooms · all cardinal connector patterns represented."
    else
      local reasons = {}
      for _, reason in ipairs(report.errors) do reasons[#reasons + 1] = reason end
      if #report.missing_patterns > 0 then reasons[#reasons + 1] = "missing patterns: " .. table.concat(report.missing_patterns, ", ") end
      message = "CORPUS DIAGNOSTICS\n" .. table.concat(reasons, "\n")
    end
    self:text(message, palette_x, detail_y, .57, report.valid and COLORS.mint or COLORS.red, editor.x + editor.width - palette_x - 16)
  end
  if self.room_graph then
    local preview_y = grid.y + grid.height + 22
    self:line("DETERMINISTIC ROOM-GRAPH PREVIEW", editor.x + 18, preview_y, .7, COLORS.mint, editor.width - 36)
    for _, cell in ipairs(self.room_graph.cells) do
      local x, y = editor.x + 18 + cell.x * 116, preview_y + 24 + cell.y * 37
      self:panel({ x = x, y = y, width = 108, height = 30 }, COLORS.surface2, COLORS.border)
      self:line(cell.template_id:gsub("^room%." .. self.selected_corpus .. "%.", ""), x + 6, y + 8, .52, COLORS.text, 96)
    end
  end
end

function Studio:draw()
  local view = self:layout(); self.controls = {}; love.graphics.clear(COLORS.backdrop)
  Chrome.draw_header(self, view); Chrome.draw_nav(self, view)
  if self.tab == "projects" then Launcher.draw_projects(self, view)
  elseif self.tab == "native" then self:draw_native(view)
  elseif not self.data and (self.tab == "rooms" or self.tab == "art" or self.tab == "scenes" or self.tab == "flow" or self.tab == "publish") then
    self:panel(view.body)
    self:text("ROAG WORKSPACE FAILED TO LOAD", view.body.x + 24, view.body.y + 24, 1.5, COLORS.red)
    self:text("Reason: " .. tostring(self.roag_error and self.roag_error.reason or "Unknown ROAG workspace error"), view.body.x + 24, view.body.y + 70, .82, COLORS.text, view.body.width - 48)
    self:text(self.project_manifest and "The native project is still open. Choose Native Assets to continue native editing." or "No native project is open. Choose Open Project from File to select a project folder or manifest.", view.body.x + 24, view.body.y + 112, .74, COLORS.muted, view.body.width - 48)
  elseif self.tab == "rooms" then self:draw_rooms(view)
  elseif self.tab == "art" then ArtView.draw(self, view)
  elseif self.tab == "scenes" then Presentation.draw_scenes(self, view)
  elseif self.tab == "flow" then Presentation.draw_flow(self, view)
  elseif self.tab == "publish" then Presentation.draw_publish(self, view)
  else Launcher.draw_home(self, view) end
  self:panel(view.footer, COLORS.dark, COLORS.border); self:line(self.status, view.footer.x + 10, view.footer.y + 4, .58, COLORS.muted, view.footer.width - 20)
  -- Menus are composited after every dock and canvas so they are never hidden
  -- behind the navigation rail and their controls receive the top-most click.
  Chrome.draw_menu(self)
end

function Studio:move(list, index, delta)
  local destination = index + delta
  if destination < 1 or destination > #list then return end
  self:record(); list[index], list[destination] = list[destination], list[index]
end

function Studio:save_native()
  self:commit_field()
  local selected = self:current_native_asset()
  if not selected or not self.native_asset_data then return nil, { reason = "No native asset selected" } end
  local ok, failure = self.project:save_asset(self.native_asset_data, selected.entry.path)
  self.native_dirty = not ok
  self.status = ok and "Saved validated native JSON asset." or ("Could not save native asset: " .. failure.reason)
  return ok, failure
end

function Studio:save_room()
  local room = self:current_room()
  if not room then return nil, { reason = "No room selected" } end
  local ok, failure = self.workspace:save_room(self.selected_corpus, room.filename, room.data)
  self.room_dirty = not ok
  self.status = ok and "Saved validated ROAG room JSON." or ("Could not save room: " .. failure.reason)
  return ok, failure
end

function Studio:choice(title, message, buttons)
  if not love or not love.window or not love.window.showMessageBox then return nil end
  local ok, pressed = pcall(love.window.showMessageBox, title, message, buttons, "warning", true)
  return ok and pressed or nil
end

function Studio:resolve_native_before_change()
  self:commit_field()
  if not self.native_dirty then return true end
  local choice = self:choice("Unsaved native asset", "Save changes to the current native JSON asset before changing selection?", { "Cancel", "Save", "Discard" })
  if choice == 2 then return self:save_native() ~= nil end
  return choice == 3
end

function Studio:resolve_room_before_change()
  if not self.room_dirty then return true end
  local choice = self:choice("Unsaved room", "Save changes to the selected ROAG room before changing selection?", { "Cancel", "Save", "Discard" })
  if choice == 2 then return self:save_room() ~= nil end
  return choice == 3
end

function Studio:confirm_discard(title, message)
  self:commit_field()
  if not self.dirty and not self.room_dirty and not self.native_dirty then return true end
  return self:choice(title, message, { "Cancel", "Discard" }) == 2
end

function Studio:create_native_asset(asset_type)
  if not self:resolve_native_before_change() then return end
  local options, support = {}, nil
  if asset_type == "tilemap" then
    for asset_id, entry in pairs(self.project_manifest.assets) do if entry.type == "tileset" then options.tileset_id = asset_id; break end end
    if not options.tileset_id then
      local tileset, failure = self.project:create_asset("tileset", "default")
      if not tileset then self.status = "Could not create the map's default tileset: " .. failure.reason; return end
      options.tileset_id, support = tileset.id, tileset.id
    end
  elseif asset_type == "flow" then
    options.entry_scene_id = self.project_manifest.main_scene_id
  end
  local data, path = self.project:create_asset(asset_type, "untitled", options)
  if not data then self.status = "Could not create " .. asset_type .. ": " .. path.reason; return end
  self:load_native_project()
  for index, asset in ipairs(self.native_assets) do if asset.id == data.id then self:select_native_asset(index); break end end
  self.status = "Created " .. data.id .. " at " .. path .. (support and (" (linked to " .. support .. ")") or "")
end

function Studio:remove_native_asset()
  if not self:resolve_native_before_change() then return end
  local selected = self:current_native_asset()
  if not selected then return end
  if self:choice("Remove Asset", "Remove \"" .. selected.id .. "\" from this project?\n\nIts source JSON will remain on disk.", { "Cancel", "Remove" }) ~= 2 then return end
  local ok, failure = self.project:remove_asset(selected.id)
  if not ok then
    local suffix = failure.references and (" Referenced by " .. table.concat((function() local ids = {}; for _, ref in ipairs(failure.references) do ids[#ids + 1] = ref.id end; return ids end)(), ", ") .. ".") or ""
    self.status = "Could not remove asset: " .. failure.reason .. suffix
    return
  end
  self:load_native_project(); self.status = "Removed " .. selected.id .. " from this project. Its source JSON remains recoverable on disk."
end

function Studio:filedropped(file)
  if not file or not file.getFilename then return end
  local path = file:getFilename()
  if path:match("[^/\\]+$") == Project.MANIFEST then
    self:request_project_open(path)
    return
  end
  if self.native_preview then self.status = "Stop Preview before importing an asset."; return end
  if not self.project_manifest then self.status = "Open a project before importing assets."; return end
  if not self:resolve_native_before_change() then return end
  local extension = (path:match("%.([^.]+)$") or ""):lower()
  if extension == "png" then
    local tileset, failure = self.project:import_tileset(path)
    if not tileset then self.status = "PNG import failed: " .. failure.reason; return end
    self.native_images, self.native_quads = {}, {}; self:load_native_project()
    for index, asset in ipairs(self.native_assets) do if asset.id == tileset.id then self:select_native_asset(index); break end end
    self.status = "Copied PNG into assets and created image-backed " .. tileset.id .. "."
  elseif extension == "json" or extension == "tmj" then
    local opened, open_reason = file:open("r")
    if not opened then self.status = "Tiled import failed: " .. tostring(open_reason); return end
    local payload = file:read(); file:close()
    local tileset_id
    for asset_id, entry in pairs(self.project_manifest.assets) do if entry.type == "tileset" then tileset_id = asset_id; break end end
    if not tileset_id then
      local tileset, tileset_failure = self.project:create_asset("tileset", "default")
      if not tileset then self.status = "Tiled import could not create its default tileset: " .. tileset_failure.reason; return end
      tileset_id = tileset.id
    end
    local asset_id = self.project:next_asset_id("tilemap", "imported")
    local map, failure = Tiled.import_map(payload, { id = asset_id, tileset_id = tileset_id })
    if not map then self.status = "Tiled import failed: " .. failure.reason; return end
    local saved, save_failure = self.project:save_asset(map, self.project:default_asset_path("tilemap", asset_id))
    if not saved then self.status = "Could not save imported map: " .. save_failure.reason; return end
    self:load_native_project()
    for index, asset in ipairs(self.native_assets) do if asset.id == asset_id then self:select_native_asset(index); break end end
    self.status = "Imported Tiled JSON as sparse, serializable " .. asset_id .. "."
  else
    self.status = "Unsupported drop. Use a PNG tilesheet or Tiled JSON (.json/.tmj)."
  end
end

function Studio:quit()
  return not self:confirm_discard("Unsaved changes", "Discard unsaved Studio changes and quit?")
end

function Studio:cycle(field, values)
  self:commit_field(); self:record(); local screen = self:current_screen(); local at = 1
  for index, value in ipairs(values) do if value == screen[field] then at = index break end end
  screen[field] = values[at % #values + 1]
end

function Studio:activate(action)
  if type(action) == "string" then return end
  local kind = action.type
  if kind == "header_menu" then
    if self.header_menu == action.menu then self.header_menu = nil else self.header_menu = action.menu end
  else
    self.header_menu = nil
  end
  if kind == "tab" then
    if self.native_preview and action.tab ~= "native" then self:stop_native_preview("Stopped Preview before leaving Native Assets.") end
    self:commit_field(); self.tab = action.tab
  elseif kind == "save_current" then self:save_current()
  elseif kind == "undo_current" then self:undo_current()
  elseif kind == "redo_current" then self:redo_current()
  elseif kind == "show_help" then self:show_help(action.topic)
  elseif kind == "quit_app" then
    if love and love.event then love.event.quit() else self.status = "Quit is available when the Studio is running in LÖVE." end
  elseif kind == "choose_project" then self:choose_project(action.kind)
  elseif kind == "new_project" then self:begin_new_project()
  elseif kind == "cancel_new_project" then self:cancel_new_project()
  elseif kind == "new_project_field" then self:begin_new_project_field(action.field)
  elseif kind == "choose_new_project_folder" then self:choose_new_project_folder()
  elseif kind == "create_new_project" then self:create_new_project()
  elseif kind == "open_new_project_collision" then self:open_new_project_collision()
  elseif kind == "open_recent_project" then self:request_project_open(action.path)
  elseif kind == "project_path" then self:begin_project_path()
  elseif kind == "native_asset" then
    if self.native_preview then self.status = "Stop Preview before selecting another asset."
    elseif action.index ~= self.selected_asset and self:resolve_native_before_change() then self:select_native_asset(action.index) end
  elseif kind == "create_native_asset" then
    if self.native_preview then self.status = "Stop Preview before creating an asset." else self:create_native_asset(action.asset_type) end
  elseif kind == "remove_native_asset" then
    if self.native_preview then self.status = "Stop Preview before removing an asset." else self:remove_native_asset() end
  elseif kind == "native_node" then
    local node = self:select_scene_node(action.node)
    self.native_drag = (action.movable == false or not NativeSceneView.is_movable(node)) and nil or { scene_node = node }
    self.status = self.native_drag and ("Selected " .. node.id .. ". Drag to reposition; save writes its JSON asset.") or ("Selected " .. node.id .. ".")
  elseif kind == "native_scene_resize" then
    local node = self:select_scene_node(action.node)
    if NativeSceneView.is_resizable(node) then
      self.native_drag = { scene_resize = node }
      self.status = "Resizing " .. node.id .. ". Release to finish one undoable edit."
    end
  elseif kind == "native_reparent_here" then
    local source = self.native_reparent_source
    if not source then self.status = "Choose a node to reparent first."; return end
    local allowed, reason = Scene.can_reparent(self.native_asset_data, source.id, action.node.id)
    if not allowed then self.status = "Could not reparent: " .. reason; return end
    self:record_native()
    local ok, reason = Scene.reparent(self.native_asset_data, source.id, action.node.id)
    if ok then self.native_reparent_source, self.status = nil, "Reparented " .. source.id .. " under " .. action.node.id .. "." else self:undo_native(); self.native_reparent_source, self.status = nil, "Could not reparent: " .. reason end
  elseif kind == "add_native_node" then
    local parent = self:scene_creation_parent()
    self:record_native()
    local node, reason = Scene.add(self.native_asset_data, parent.id, action.node_type)
    if node then self:select_scene_node(node); self.status = "Added " .. node.id .. " under " .. parent.id .. "." else self:undo_native(); self.status = "Could not add node: " .. reason end
  elseif kind == "delete_native_node" then
    local node = self.native_selected_node
    if node then
      local former_parent = Scene.parent_of(self.native_asset_data, node.id)
      self:record_native(); local removed, reason = Scene.remove(self.native_asset_data, node.id)
      if removed then self:select_scene_node(former_parent and former_parent.node); self.native_reparent_source = nil; self.status = "Removed " .. removed.id .. " and its descendants." else self:undo_native(); self.status = "Could not remove node: " .. reason end
    end
  elseif kind == "native_reparent_mode" then
    local node = self.native_selected_node
    if node and node ~= self.native_asset_data.root then self.native_reparent_source = node; self.status = "Reparenting " .. node.id .. ". Select a new parent or press Escape to cancel." end
  elseif kind == "cancel_scene_reparent" then
    self.native_reparent_source = nil
    self.status = "Reparenting cancelled."
  elseif kind == "move_scene_node" then
    local node = self.native_selected_node
    if node then
      self:record_native()
      local moved, reason = Scene.move_sibling(self.native_asset_data, node.id, action.direction)
      if moved then self.status = "Moved " .. node.id .. (action.direction < 0 and " earlier." or " later.") else self:undo_native(); self.status = "Could not reorder node: " .. reason end
    end
  elseif kind == "set_main_scene" then
    local selected = self:current_native_asset()
    local ok, failure = selected and self.project:set_main_scene(selected.id)
    if ok then self.project_manifest = self.project.manifest; self.status = "Set " .. selected.id .. " as the project main scene." else self.status = "Could not set main scene: " .. failure.reason end
  elseif kind == "native_flow_node" then
    if self.native_connect_from and self.native_connect_from ~= action.node then
      self:record_native(); local ok, reason = Flow.connect(self.native_asset_data, self.native_connect_from.id, action.node.id)
      if ok then self.status = "Connected " .. self.native_connect_from.id .. " > " .. action.node.id else self:undo_native(); self.status = "Could not connect nodes: " .. reason end
      self.native_connect_from = nil
    end
    self.native_selected_flow_node, self.native_drag = action.node, { flow_node = action.node }
    self.status = "Selected " .. action.node.id .. ". Drag to arrange the serialized flow graph."
  elseif kind == "add_flow_node" then
    self:record_native(); self.native_selected_flow_node = Flow.add_node(self.native_asset_data, action.node_type); self.status = "Added " .. self.native_selected_flow_node.id .. "."
  elseif kind == "delete_flow_node" then
    local node = self.native_selected_flow_node
    if node then
      self:record_native(); local ok, reason = Flow.remove_node(self.native_asset_data, node.id)
      if ok then self.native_selected_flow_node, self.status = nil, "Removed graph node and its incident edges." else self:undo_native(); self.status = "Could not remove graph node: " .. reason end
    end
  elseif kind == "start_flow_connection" then
    self.native_connect_from = self.native_connect_from and nil or self.native_selected_flow_node
    self.status = self.native_connect_from and "Choose a destination graph node." or "Graph connection cancelled."
  elseif kind == "native_map_brush" then self.map_brush = action.tile
  elseif kind == "native_map_paint" then
    if action.map == self.native_asset_data then self:record_native() end
    local ok, reason = Tilemap.set(action.map, action.layer_id, action.x, action.y, self.map_brush or 1)
    if not ok and action.map == self.native_asset_data then self:undo_native() end
    self.status = ok and (action.map == self.native_asset_data and "Painted sparse native tilemap cell. Save writes JSON." or "Painted generated preview only.") or ("Could not paint tilemap: " .. tostring(reason))
  elseif kind == "select_map_layer" then self.selected_map_layer = action.index
  elseif kind == "add_map_layer" then
    self:record_native(); local layer = Tilemap.add_layer(self.native_asset_data, self:current_map_layer(self.native_asset_data).tileset_id)
    self.selected_map_layer, self.status = #self.native_asset_data.layers, "Added " .. layer.id .. "."
  elseif kind == "remove_map_layer" then
    local layer = self:current_map_layer(self.native_asset_data)
    self:record_native(); local removed, reason = Tilemap.remove_layer(self.native_asset_data, layer.id)
    if removed then self.selected_map_layer, self.status = clamp(self.selected_map_layer, 1, #self.native_asset_data.layers), "Removed " .. removed.id .. "." else self:undo_native(); self.status = "Could not remove layer: " .. reason end
  elseif kind == "generate_native" then
    local result, failure = Generator.generate(self.native_asset_data)
    self.generated_preview = result
    self.status = result and "Generated deterministic native preview." or ("Could not generate preview: " .. failure.reason)
  elseif kind == "save_native" then
    if self.native_preview then self.status = "Stop Preview before saving authored data." else self:save_native() end
  elseif kind == "run_project" then self:start_native_preview(false)
  elseif kind == "run_scene" then self:start_native_preview(true)
  elseif kind == "restart_native_preview" then self:restart_native_preview()
  elseif kind == "stop_native_preview" then self:stop_native_preview()
  elseif kind == "corpus" then
    if self:resolve_room_before_change() then self.selected_corpus, self.selected_room, self.room_graph, self.room_brush, self.room_diagnostics, self.room_scroll = action.id, 1, nil, nil, nil, 0 end
  elseif kind == "room" then if action.index ~= self.selected_room and self:resolve_room_before_change() then self.selected_room, self.room_graph, self.room_diagnostics = action.index, nil, nil end
  elseif kind == "room_brush" then self.room_brush = action.glyph
  elseif kind == "room_paint" then
    local room = self:current_room().data
    local row = room.layout[action.row]
    if row:sub(action.column, action.column) ~= self.room_brush then
      self:record_room(); room.layout[action.row] = row:sub(1, action.column - 1) .. self.room_brush .. row:sub(action.column + 1)
      self.room_diagnostics = nil
      self.status = "Painted room JSON cell. Save writes " .. self:current_room().filename
    end
  elseif kind == "room_preview" then
    local templates = {}; for _, room in ipairs(self.corpora[self.selected_corpus].rooms) do templates[#templates + 1] = room.data end
    local preview, failure = RoomGraph.assemble(templates, 3, 2, 73102)
    self.room_graph = preview
    self.status = preview and "Generated deterministic connector-based room preview." or ("Could not assemble room graph: " .. failure.reason)
  elseif kind == "save_room" then self:save_room()
  elseif kind == "new_room" then
    if self:resolve_room_before_change() then
      local room, failure = self.workspace:create_room(self.selected_corpus, "custom")
      if room then
        self.corpora = self.workspace.corpora
        for index, item in ipairs(self.corpora[self.selected_corpus].rooms) do if item.filename == room.filename then self.selected_room = index; break end end
        self.status = "Created blank room template " .. room.filename .. " and indexed it in the corpus manifest."
      else self.status = "Could not create room: " .. failure.reason end
    end
  elseif kind == "remove_room" then
    local room = self:current_room()
    if room and self:choice("Remove room from corpus", "The JSON file will remain on disk for recovery. Remove " .. room.filename .. " from this corpus manifest?", { "Cancel", "Remove" }) == 2 then
      local ok, failure = self.workspace:remove_room(self.selected_corpus, room.filename)
      if ok then self.corpora, self.selected_room, self.status = self.workspace.corpora, 1, "Removed room from corpus manifest. JSON source remains recoverable." else self.status = "Could not remove room: " .. failure.reason end
    end
  elseif kind == "room_diagnostics" then
    self.room_diagnostics = self.workspace:diagnose_corpus(self.selected_corpus)
    local report = self.room_diagnostics
    self.status = report.valid and "Corpus covers every cardinal connector pattern." or ("Corpus needs " .. #report.missing_patterns .. " connector patterns; see diagnostics.")
  elseif kind == "save" then self:save()
  elseif kind == "reload" then if self:confirm_discard("Reload Studio", "Discard unsaved Studio changes and reload from disk?") then self:stop_native_preview("Stopped Preview before reloading ROAG."); self:reload() end
  elseif kind == "undo" then self:commit_field(); self:undo()
  elseif kind == "undo_native" then self:undo_native()
  elseif kind == "redo_native" then self:redo_native()
  elseif kind == "undo_room" then self:undo_room()
  elseif kind == "redo_room" then self:redo_room()
  elseif kind == "pack" then
    self:commit_field(); self:record(); self.data.art_pack.art_pack_id = self.data.catalog.art_packs[action.index].id
    self.art_source_scroll, self.art_sheet_zoom, self.art_sheet_pan_x, self.art_sheet_pan_y = 0, 1, 0, 0
    self.status = "Selected pack. Browse its source sheets here; publish to make ROAG use it on next focus/launch."
  elseif kind == "pack_sheet_source" then
    self:select_art_sheet(action.pack_id, action.index)
    local sheet = (ArtSources.sheets[action.pack_id] or {})[action.index]
    self.status = "Viewing " .. (sheet and sheet.label or "source sheet") .. "."
  elseif kind == "import_pack_sheet" then self:import_art_sheet(action.pack, action.sheet)
  elseif kind == "role" then self:commit_field(); self.selected_role = action.index
  elseif kind == "sheet" and self.sheet_hover then self:commit_field(); self:record(); local role = self:current_role(); self.data.sprites.sprites[role[1]] = { column = self.sheet_hover.column, row = self.sheet_hover.row }; self.status = role[2] .. " mapped to [" .. self.sheet_hover.column .. ", " .. self.sheet_hover.row .. "]."
  elseif kind == "screen" then self:commit_field(); self.selected_screen = action.index
  elseif kind == "screen_move" then self:commit_field(); self:move(self.data.screens.screens, self.selected_screen, action.delta); self.selected_screen = self.selected_screen + action.delta
  elseif kind == "action" then self:commit_field(); self.selected_action = action.index
  elseif kind == "action_move" then
    self:commit_field()
    if Bridge.is_title_action_editable(self:current_action()) then
      self:move(self.data.flow.title_actions, self.selected_action, action.delta); self.selected_action = self.selected_action + action.delta
    else
      self.status = "This ROAG title action is preserved read-only and cannot be reordered here."
    end
  elseif kind == "cycle_layout" then self:cycle("layout", { "title_menu", "catalog", "list_detail", "route", "menu", "notice" })
  elseif kind == "cycle_accent" then self:cycle("accent", { "cyan", "amber", "mint", "coral", "violet" })
  elseif kind == "field" then self:begin_field(action.kind, action.field)
  elseif kind == "native_field" then self:begin_native_field(action.target, action.field, action.value_type) end
  self:play_click()
end

function Studio:update()
  if self.native_preview and self.native_preview.runtime and not self.native_preview.error then
    local advanced, failure = self.native_preview.runtime:update()
    if not advanced then
      self.native_preview.error = failure or { reason = "Runtime execution failed" }
      self.status = "Preview stopped after a runtime error: " .. tostring(self.native_preview.error.reason)
    end
  end
  local x, y = love.mouse.getPosition(); local cursor = "default"
  if self.sheet_panning or self.art_sheet_panning or self.map_panning or self.scene_panning then cursor = "pan" else
    for _, control in ipairs(self.controls) do if control.enabled ~= false and inside(x, y, control.rect) then cursor = control.cursor or "action" end end
  end
  love.mouse.setCursor(self.cursors[cursor])
end

function Studio:mousepressed(x, y, button)
  if button == 2 and self.tab == "art" and self.pack_sheet_rect and inside(x, y, self.pack_sheet_rect) then self.art_sheet_panning = true; return end
  if button == 2 and self.tab == "art" and self.sheet_hover then self.sheet_panning = true; return end
  if button == 2 and self.tab == "native" and not self.native_preview and self.map_viewport and inside(x, y, self.map_viewport) then self.map_panning = true; return end
  if button == 2 and self.tab == "native" and not self.native_preview and self.scene_viewport and inside(x, y, self.scene_viewport) then self.scene_panning = true; return end
  if button ~= 1 then return end
  for index = #self.controls, 1, -1 do local control = self.controls[index]; if control.enabled ~= false and inside(x, y, control.rect) then self:activate(control.action); return end end
  self.header_menu = nil
  self:commit_field()
end

function Studio:mousereleased(_, _, button)
  if button == 2 then self.sheet_panning, self.art_sheet_panning, self.map_panning, self.scene_panning = false, false, false, false end
  if button == 1 then self.native_drag = nil end
end

function Studio:mousemoved(_, _, dx, dy)
  if self.sheet_panning then self.sheet_pan_x, self.sheet_pan_y = self.sheet_pan_x + dx, self.sheet_pan_y + dy end
  if self.art_sheet_panning then self.art_sheet_pan_x, self.art_sheet_pan_y = self.art_sheet_pan_x + dx, self.art_sheet_pan_y + dy end
  if self.map_panning then self.map_pan_x, self.map_pan_y = self.map_pan_x + dx, self.map_pan_y + dy end
  if self.scene_panning then self.scene_pan_x, self.scene_pan_y = (self.scene_pan_x or 0) + dx, (self.scene_pan_y or 0) + dy end
  if self.native_drag and self.tab == "native" and not self.native_preview then
    if not self.native_drag.recorded then self:record_native(); self.native_drag.recorded = true end
    if self.native_drag.flow_node then
      local point = self.native_drag.flow_node.editor or { x = 0, y = 0 }
      self.native_drag.flow_node.editor = point; point.x, point.y = point.x + dx, point.y + dy
    elseif self.native_drag.scene_resize then
      local node = self.native_drag.scene_resize
      local properties, zoom = node.properties or {}, self.scene_zoom or 1
      node.properties = properties
      properties.width = math.max(1, (properties.width or 150) + dx / zoom)
      properties.height = math.max(1, (properties.height or 42) + dy / zoom)
    else
      local node = self.native_drag.scene_node
      if node then
        local properties, zoom = node.properties or {}, self.scene_zoom or 1; node.properties = properties
        properties.x, properties.y = (properties.x or 0) + dx / zoom, (properties.y or 0) + dy / zoom
      end
    end
    self.native_dirty = true
  end
end

function Studio:wheelmoved(_, dy)
  if self.tab == "art" then
    local x, y = love.mouse.getPosition()
    if self.pack_sheet_rect and inside(x, y, self.pack_sheet_rect) then
      self.art_sheet_zoom = clamp(self.art_sheet_zoom * (1.14 ^ dy), .20, 8)
    elseif self.art_source_list_rect and inside(x, y, self.art_source_list_rect) then
      self.art_source_scroll = clamp((self.art_source_scroll or 0) - dy, 0, math.max(0, (self.art_source_visible_count or 0) - (self.art_source_max_rows or 1)))
    elseif self.sheet_rect and inside(x, y, self.sheet_rect) then
      self.sheet_zoom = clamp(self.sheet_zoom * (1.14 ^ dy), .45, 6)
    elseif self.role_list_rect and inside(x, y, self.role_list_rect) then
      self.scroll = clamp(self.scroll - dy, 0, math.max(0, (self.role_visible_count or #ROLES) - (self.role_max_rows or 1)))
    end
    return
  end
  if self.tab == "native" and self.native_preview then
    return
  elseif self.tab == "native" and self.native_asset_data and self.native_asset_data.type == "scene" then
    local x, y = love.mouse.getPosition()
    if self.native_asset_list_rect and inside(x, y, self.native_asset_list_rect) then
      local rows = math.max(1, math.floor(self.native_asset_list_rect.height / 34))
      self.native_asset_scroll = clamp((self.native_asset_scroll or 0) - dy, 0, math.max(0, #self.native_assets - rows))
    else
      NativeSceneView.zoom_at(self, x, y, dy)
    end
  elseif self.tab == "native" and self.native_asset_data and self.native_asset_data.type == "tilemap" then
    local x, y = love.mouse.getPosition()
    if self.native_asset_list_rect and inside(x, y, self.native_asset_list_rect) then
      local rows = math.max(1, math.floor(self.native_asset_list_rect.height / 34))
      self.native_asset_scroll = clamp((self.native_asset_scroll or 0) - dy, 0, math.max(0, #self.native_assets - rows))
    else
      self.map_zoom = clamp(self.map_zoom * (1.14 ^ dy), .45, 3)
    end
  elseif self.tab == "native" and self.native_asset_list_rect then
    local x, y = love.mouse.getPosition()
    if inside(x, y, self.native_asset_list_rect) then
      local rows = math.max(1, math.floor(self.native_asset_list_rect.height / 34))
      self.native_asset_scroll = clamp((self.native_asset_scroll or 0) - dy, 0, math.max(0, #self.native_assets - rows))
    end
  elseif self.tab == "rooms" and self.room_list_rect then
    local x, y = love.mouse.getPosition()
    if inside(x, y, self.room_list_rect) then
      local rows = math.max(1, math.floor(self.room_list_rect.height / 34))
      local corpus = self.corpora[self.selected_corpus]
      self.room_scroll = clamp((self.room_scroll or 0) - dy, 0, math.max(0, #corpus.rooms - rows))
    end
  end
end

function Studio:textinput(value)
  if self.active then self.draft = self.draft .. value elseif self.role_filtering then self.role_filter, self.scroll = self.role_filter .. value, 0 end
end

function Studio:keypressed(key)
  if self.native_preview and key == "escape" then
    self:stop_native_preview()
    return
  end
  local modifier = love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl") or love.keyboard.isDown("lgui") or love.keyboard.isDown("rgui")
  if modifier and key == "o" then
    self:choose_project("folder")
    return
  end
  if modifier and key == "s" then
    self:save_current()
    return
  end
  if modifier and key == "z" then
    self:undo_current()
    return
  end
  if modifier and (key == "y" or key == "r") then
    self:redo_current()
    return
  end
  if self.active then
    if key == "return" then self:commit_field() elseif key == "escape" then self:cancel_field() elseif key == "backspace" then self.draft = self.draft:sub(1, -2) end
    return
  end
  if self.role_filtering then
    if key == "escape" or key == "return" then self.role_filtering = false elseif key == "backspace" then self.role_filter = self.role_filter:sub(1, -2) end
    return
  end
  if self.tab == "native" and self.native_asset_data and self.native_asset_data.type == "scene" then
    if key == "escape" and self.native_reparent_source then
      self:activate({ type = "cancel_scene_reparent" })
      return
    end
    if (key == "delete" or key == "backspace") and self.native_selected_node and self.native_selected_node ~= self.native_asset_data.root then
      self:activate({ type = "delete_native_node" })
      return
    end
  end
  if key == "f" and self.tab == "art" then self.role_filtering = true; return end
  if key == "f1" then self:show_help("shortcuts"); return end
  if key == "escape" then love.event.quit() end
end

return Studio
