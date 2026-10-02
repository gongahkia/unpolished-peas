local Bridge = require("core.roag_bridge")
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

local Studio = {}
Studio.__index = Studio

local COLORS = {
  backdrop = { 0.025, 0.045, 0.075 }, surface = { 0.055, 0.09, 0.14 }, surface2 = { 0.075, 0.125, 0.19 },
  border = { 0.16, 0.31, 0.42 }, text = { 0.88, 0.94, 0.98 }, muted = { 0.54, 0.67, 0.76 },
  blue = { 0.28, 0.72, 1.0 }, mint = { 0.35, 0.90, 0.67 }, gold = { 1.0, 0.79, 0.25 }, red = { 1.0, 0.38, 0.32 }, dark = { 0.015, 0.027, 0.045 },
}

local ROLES = {
  { "player", "Player", "Core" }, { "target", "Target", "Core" }, { "ammo", "Ammo", "Core" }, { "torch", "Torch", "Core" }, { "door", "Exit door", "Core" }, { "bullet", "Bullet", "Core" }, { "bomb", "Bomb", "Core" }, { "flare", "Flare", "Core" },
  { "wall_left", "Wall left face", "Terrain" }, { "wall_right", "Wall right face", "Terrain" }, { "wall_up", "Wall up face", "Terrain" }, { "wall_down", "Wall down face", "Terrain" },
  { "wolf", "Wolf", "Enemies" }, { "bomber", "Bomber", "Enemies" }, { "necromancer", "Necromancer", "Enemies" }, { "cultist", "Cultist", "Enemies" }, { "ripper", "Ripper", "Enemies" }, { "skirmisher", "Skirmisher", "Enemies" }, { "conductor", "Conductor", "Enemies" }, { "bulwark", "Bulwark", "Enemies" }, { "reclaimer", "Reclaimer", "Enemies" },
  { "gunner_elite", "Redundant gunner", "Elites" }, { "shock_bruiser", "Shock bruiser", "Elites" }, { "volatile_heavy", "Volatile heavy", "Elites" },
  { "arc_cutter", "Arc cutter", "Reactor" }, { "maintenance_heavy", "Maintenance heavy", "Reactor" }, { "reactor_suppressor", "Reactor suppressor", "Reactor" }, { "arc_warden", "Arc warden", "Reactor" }, { "boss", "Boss", "Boss" },
}

local function color(value, alpha)
  love.graphics.setColor(value[1], value[2], value[3], alpha or value[4] or 1)
end

local function inside(x, y, rect)
  return x >= rect.x and y >= rect.y and x <= rect.x + rect.width and y <= rect.y + rect.height
end

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

local function path_arg(arguments, flag)
  flag = flag or "--roag"
  for index, value in ipairs(arguments or {}) do
    if value == flag then return arguments[index + 1] end
    local path = value:match("^" .. flag:gsub("([^%w])", "%%%1") .. "=(.+)$")
    if path then return path end
  end
end

function Studio.new(arguments)
  local target = path_arg(arguments, "--roag") or Bridge.DEFAULT_TARGET
  local self = setmetatable({ bridge = Bridge.new(target), project_root = path_arg(arguments, "--project") or ".", tab = "home", selected_screen = 1, selected_action = 1, selected_role = 1, selected_corpus = "dungeon", selected_room = 1, selected_asset = 1, selected_map_layer = 1, native_asset_scroll = 0, role_filter = "", role_filtering = false, scroll = 0, sheet_zoom = 1, sheet_pan_x = 0, sheet_pan_y = 0, sheet_panning = false, map_zoom = 1, map_pan_x = 0, map_pan_y = 0, map_panning = false, dirty = false, room_dirty = false, native_dirty = false, undo_stack = {}, redo_stack = {}, room_histories = {}, active = nil, draft = "", controls = {}, status = "Loading data-driven workspace…", fonts = {}, images = {}, native_images = {}, native_quads = {}, cursors = {}, sounds = {} }, Studio)
  self:load_assets()
  self:reload()
  return self
end

function Studio:load_assets()
  love.graphics.setDefaultFilter("nearest", "nearest")
  local font_path = "assets/kenney/ui_pack/Font/Kenney Future Narrow.ttf"
  self.fonts = {
    small = love.graphics.newFont(font_path, 13), normal = love.graphics.newFont(font_path, 16), large = love.graphics.newFont(font_path, 23), title = love.graphics.newFont(font_path, 36),
  }
  self.images.button = love.graphics.newImage("assets/kenney/ui_pack/PNG/Blue/Default/button_rectangle_depth_gradient.png")
  self.images.button_selected = love.graphics.newImage("assets/kenney/ui_pack/PNG/Green/Default/button_rectangle_depth_gradient.png")
  self.images.button_danger = love.graphics.newImage("assets/kenney/ui_pack/PNG/Red/Default/button_rectangle_depth_gradient.png")
  self.images.icon_check = love.graphics.newImage("assets/kenney/ui_pack/PNG/Blue/Default/icon_checkmark.png")
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
  if not loaded then self.data, self.status = nil, "Could not open ROAG JSON workspace: " .. failure.reason; return nil, failure end
  self.data, self.corpora, self.dirty, self.room_dirty, self.undo_stack, self.redo_stack, self.active = loaded.presentation, loaded.corpora, false, false, {}, {}, nil
  self.selected_screen = clamp(self.selected_screen, 1, #self.data.screens.screens)
  self.selected_action = clamp(self.selected_action, 1, #self.data.flow.title_actions)
  self.selected_room = clamp(self.selected_room, 1, #(self.corpora[self.selected_corpus].rooms))
  self:load_native_project()
  self.status = "Loaded native project and ROAG JSON workspace from " .. self.bridge.target
  self:load_sheet()
  return true
end

function Studio:load_native_project()
  self.project = Project.new(self.project_root)
  local manifest, failure = self.project:load()
  if not manifest then self.project, self.project_manifest, self.project_error = nil, nil, failure.reason; return end
  self.project_manifest, self.project_error, self.native_assets = manifest, nil, {}
  for asset_id, entry in pairs(manifest.assets) do self.native_assets[#self.native_assets + 1] = { id = asset_id, entry = entry } end
  table.sort(self.native_assets, function(a, b) return a.id < b.id end)
  self.selected_asset = clamp(self.selected_asset, 1, math.max(1, #self.native_assets))
  self.runtime = Runtime.new(self.project)
  self:select_native_asset(self.selected_asset)
end

function Studio:select_native_asset(index)
  self.selected_asset = index
  local asset = self:current_native_asset()
  if not asset then self.native_asset_data, self.native_asset_error = nil, "No native asset selected"; return end
  self.native_asset_data, self.native_asset_error = self.project:load_asset(asset.id)
  self.native_dirty, self.native_history = false, History.new()
  self.native_selected_node = self.native_asset_data and self.native_asset_data.type == "scene" and self.native_asset_data.root or nil
  self.native_selected_flow_node, self.native_drag, self.generated_preview = nil, nil, nil
  self.selected_map_layer, self.map_zoom, self.map_pan_x, self.map_pan_y = 1, 1, 0, 0
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
  local data = self.native_history and self.native_history:undo(self.native_asset_data)
  if not data then self.status = "Nothing to undo in this asset."; return end
  self.native_asset_data, self.native_dirty = data, true
  self.native_selected_node = data.type == "scene" and data.root or nil
  self.status = "Undid native asset edit."
end

function Studio:redo_native()
  local data = self.native_history and self.native_history:redo(self.native_asset_data)
  if not data then self.status = "Nothing to redo in this asset."; return end
  self.native_asset_data, self.native_dirty = data, true
  self.native_selected_node = data.type == "scene" and data.root or nil
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
  local ok, image = pcall(love.graphics.newImage, path)
  self.sheet = ok and image or nil
  self.sheet_error = ok and nil or tostring(image)
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
  if self.active.kind == "native_field" then
    local target, field, value_type = self.active.target, self.active.field, self.active.value_type
    local value = self.draft
    if value_type == "number" then value = tonumber(value) end
    if value ~= nil and value ~= "" and value ~= target[field] then
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
  return { width = width, height = height, header = { x = 0, y = 0, width = width, height = 86 }, nav = { x = 16, y = 104, width = 182, height = height - 176 }, body = { x = 218, y = 104, width = width - 234, height = height - 176 }, footer = { x = 16, y = height - 56, width = width - 32, height = 38 } }
end

function Studio:font(scale)
  if scale >= 2 then return self.fonts.title end
  if scale >= 1.25 then return self.fonts.large end
  if scale < .86 then return self.fonts.small end
  return self.fonts.normal
end

function Studio:text(value, x, y, scale, tint, width, align)
  love.graphics.setFont(self:font(scale or 1)); color(tint or COLORS.text)
  if width then love.graphics.printf(tostring(value), x, y, width, align or "left") else love.graphics.print(tostring(value), x, y) end
end

function Studio:panel(rect, fill, outline)
  color(fill or COLORS.surface); love.graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height, 8, 8)
  color(outline or COLORS.border); love.graphics.setLineWidth(1); love.graphics.rectangle("line", rect.x + .5, rect.y + .5, rect.width - 1, rect.height - 1, 8, 8)
end

function Studio:button(rect, label, action, options)
  options = options or {}; self.controls[#self.controls + 1] = { rect = rect, action = action, enabled = options.enabled ~= false, cursor = options.cursor or "action" }
  local selected = options.selected == true
  local image = options.danger and self.images.button_danger or (selected and self.images.button_selected or self.images.button)
  local enabled = options.enabled ~= false
  color({ 1, 1, 1 }, enabled and 1 or .28)
  love.graphics.draw(image, rect.x, rect.y, 0, rect.width / image:getWidth(), rect.height / image:getHeight())
  self:text(label, rect.x + 10, rect.y + math.floor(rect.height / 2 - 8), .78, enabled and (selected and COLORS.dark or COLORS.text) or COLORS.muted, rect.width - 20, "center")
end

function Studio:field(rect, label, kind, field)
  local focused = self.active and self.active.kind == kind and self.active.field == field
  self:panel(rect, focused and { .08, .20, .29 } or COLORS.surface2, focused and COLORS.blue or COLORS.border)
  self:text(label, rect.x + 12, rect.y + 7, .68, COLORS.muted)
  local value = focused and self.draft or (kind == "screen" and self:current_screen()[field] or self:current_action()[field])
  self:text(value, rect.x + 12, rect.y + 27, .88, focused and COLORS.gold or COLORS.text, rect.width - 24)
  if focused then self:text("|", rect.x + 13 + #value * 8, rect.y + 27, .88, COLORS.blue) end
  self.controls[#self.controls + 1] = { rect = rect, action = { type = "field", kind = kind, field = field }, cursor = "text" }
end

function Studio:native_field(rect, label, target, field, value_type)
  local focused = self.active and self.active.kind == "native_field" and self.active.target == target and self.active.field == field
  self:panel(rect, focused and { .08, .20, .29 } or COLORS.surface2, focused and COLORS.blue or COLORS.border)
  self:text(label, rect.x + 10, rect.y + 5, .58, COLORS.muted)
  local value = focused and self.draft or tostring(target[field] == nil and "" or target[field])
  self:text(value, rect.x + 10, rect.y + 21, .72, focused and COLORS.gold or COLORS.text, rect.width - 20)
  if focused then self:text("|", rect.x + 11 + #value * 7, rect.y + 21, .72, COLORS.blue) end
  self.controls[#self.controls + 1] = { rect = rect, action = { type = "native_field", target = target, field = field, value_type = value_type }, cursor = "text" }
end

function Studio:draw_header(view)
  color(COLORS.dark); love.graphics.rectangle("fill", 0, 0, view.width, view.header.height)
  color(COLORS.blue); love.graphics.rectangle("fill", 0, view.header.height - 2, view.width, 2)
  self:text("UNPOLISHED BEES", 20, 14, 2.1, COLORS.blue)
  self:text("DATA-DRIVEN 2D STUDIO", 20, 55, .76, COLORS.muted)
  local target = self.bridge.target
  self:text("TARGET  " .. target, view.width - 450, 20, .72, COLORS.muted, 300, "right")
  local unsaved = self.dirty or self.room_dirty or self.native_dirty
  self:text(unsaved and "UNSAVED" or "SYNCHRONIZED", view.width - 150, 20, .72, unsaved and COLORS.gold or COLORS.mint, 132, "right")
  self:button({ x = view.width - 252, y = 46, width = 112, height = 30 }, "RELOAD", { type = "reload" })
  self:button({ x = view.width - 128, y = 46, width = 112, height = 30 }, "PUBLISH", { type = "save" }, { selected = self.dirty })
end

function Studio:draw_nav(view)
  self:panel(view.nav)
  self:text("WORKSPACE", view.nav.x + 13, view.nav.y + 14, .72, COLORS.gold)
  local tabs = { { "home", "OVERVIEW" }, { "native", "NATIVE PROJECT" }, { "rooms", "ROAG ROOMS" }, { "art", "ART & SPRITES" }, { "scenes", "SCENES" }, { "flow", "TITLE FLOW" }, { "publish", "PUBLISH" } }
  for index, item in ipairs(tabs) do
    self:button({ x = view.nav.x + 10, y = view.nav.y + 48 + (index - 1) * 52, width = view.nav.width - 20, height = 42 }, item[2], { type = "tab", tab = item[1] }, { selected = self.tab == item[1] })
  end
  self:text("JSON ONLY", view.nav.x + 13, view.nav.y + view.nav.height - 92, .7, COLORS.mint)
  self:text("Native assets and declared ROAG JSON are editable. Lua, saves, and profiles are never opened for writing.", view.nav.x + 13, view.nav.y + view.nav.height - 70, .66, COLORS.muted, view.nav.width - 26)
end

function Studio:draw_home(view)
  self:panel(view.body)
  self:text("A focused authoring boundary", view.body.x + 24, view.body.y + 24, 1.5, COLORS.text)
  self:text("Edit ROAG’s presentation without loading, changing, or depending on a live run, account profile, fallen archive, route, or simulation system.", view.body.x + 24, view.body.y + 62, .86, COLORS.muted, view.body.width - 48)
  local cards = {
    { "NATIVE PROJECT", "Browse serializable scenes and flow assets, run the main scene, and inspect the data-first runtime preview.", "native", COLORS.mint },
    { "ROAG ROOMS", "Paint declared room-template geometry and preview deterministic connector-based room assembly.", "rooms", COLORS.gold },
    { "ART & SPRITES", "Choose the packaged visual language and map ROAG’s stable renderer roles to the original 49 × 22 sheet.", "art", COLORS.blue },
    { "SCENES", "Edit screen copy, layout token, accent token, and source ordering with a live presentation preview.", "scenes", COLORS.mint },
    { "TITLE FLOW", "Order the supported title actions and edit their labels/description. Gameplay targets stay validated and fixed.", "flow", COLORS.gold },
    { "PUBLISH", "Validate then atomically write only four allow-listed ROAG presentation files.", "publish", COLORS.red },
  }
  for index, card in ipairs(cards) do
    local column, row = (index - 1) % 2, math.floor((index - 1) / 2)
    local rect = { x = view.body.x + 24 + column * (view.body.width * .48), y = view.body.y + 132 + row * 180, width = view.body.width * .43, height = 148 }
    self:panel(rect, COLORS.surface2, card[4]); self:text(card[1], rect.x + 16, rect.y + 16, 1.05, card[4]); self:text(card[2], rect.x + 16, rect.y + 49, .76, COLORS.muted, rect.width - 32); self:button({ x = rect.x + 16, y = rect.y + 101, width = 140, height = 32 }, "OPEN", { type = "tab", tab = card[3] })
  end
end

function Studio:current_native_asset()
  return self.native_assets and self.native_assets[self.selected_asset]
end

function Studio:draw_native_scene_node(node, canvas)
  local properties = node.properties or {}
  local x, y = canvas.x + (properties.x or 0), canvas.y + (properties.y or 0)
  local width, height = properties.width or (node.type == "label" and 220 or 150), properties.height or (node.type == "label" and 28 or 42)
  local selected = self.native_selected_node == node
  if node.type == "scene" then
    -- Scene roots organize children but do not draw a visual box.
  elseif node.type == "panel" then
    local fill = properties.color or { .12, .19, .25, 1 }
    self:panel({ x = x, y = y, width = width, height = height }, fill, selected and COLORS.gold or COLORS.border)
  elseif node.type == "label" then
    self:text(properties.text or node.id, x, y + 4, .9, selected and COLORS.gold or COLORS.text, width)
  elseif node.type == "button" then
    self:panel({ x = x, y = y, width = width, height = height }, selected and { .12, .33, .36 } or COLORS.surface2, selected and COLORS.gold or COLORS.blue)
    self:text(properties.text or node.id, x + 8, y + math.floor(height / 2 - 8), .74, COLORS.text, width - 16, "center")
  else
    self:panel({ x = x, y = y, width = width, height = height }, COLORS.surface2, selected and COLORS.gold or COLORS.border)
    self:text(node.type:upper(), x + 7, y + 7, .58, COLORS.muted)
  end
  if node.type ~= "scene" then self.controls[#self.controls + 1] = { rect = { x = x, y = y, width = width, height = height }, action = { type = "native_node", node = node }, cursor = "action" } end
  for _, child in ipairs(node.children or {}) do self:draw_native_scene_node(child, canvas) end
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
    self:panel(rect, selected and { .10, .27, .34 } or COLORS.surface2, selected and COLORS.gold or COLORS.blue)
    self:text(node.type:upper(), rect.x + 7, rect.y + 8, .58, selected and COLORS.gold or COLORS.muted)
    self:text(node.id:gsub("^graph%.", ""), rect.x + 7, rect.y + 28, .68, COLORS.text, rect.width - 14)
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
  local ok, image = pcall(love.graphics.newImage, path)
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
  self:text((map.infinite and "INFINITE / SPARSE" or (map.width .. " × " .. map.height)) .. "  ·  " .. layer.id .. "  ·  " .. (image and "IMAGE TILESET" or "NO IMAGE / NUMBER PREVIEW"), canvas.x + 10, canvas.y + canvas.height - 22, .58, COLORS.mint, canvas.width - 20)
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
  self:text("" .. columns .. " × " .. rows .. " TILES  ·  CLICK A CELL TO MAKE IT THE MAP BRUSH", x, y + height + 12, .62, COLORS.mint, math.min(width, canvas.width - 32))
end

function Studio:current_room()
  local corpus = self.corpora and self.corpora[self.selected_corpus]
  return corpus and corpus.rooms[self.selected_room]
end

function Studio:draw_native(view)
  local list = { x = view.body.x, y = view.body.y, width = math.max(282, view.body.width * .27), height = view.body.height }
  local canvas = { x = list.x + list.width + 16, y = view.body.y, width = view.body.width - list.width - 16, height = view.body.height }
  self:panel(list); self:panel(canvas)
  self:text("NATIVE PROJECT", list.x + 14, list.y + 14, .74, COLORS.gold)
  if not self.project_manifest then
    self:text("Project manifest unavailable:\n" .. tostring(self.project_error), list.x + 14, list.y + 48, .78, COLORS.red, list.width - 28)
    return
  end
  self:text(self.project_manifest.name, list.x + 14, list.y + 36, .82, COLORS.text, list.width - 28)
  self:text("CREATE", list.x + 14, list.y + 67, .62, COLORS.muted)
  local creates = { { "SCENE", "scene" }, { "TILESET", "tileset" }, { "MAP", "tilemap" }, { "FLOW", "flow" }, { "ROOM", "room_template" }, { "GEN", "generator" } }
  for index, item in ipairs(creates) do
    local column, row = (index - 1) % 3, math.floor((index - 1) / 3)
    self:button({ x = list.x + 10 + column * (list.width - 26) / 3, y = list.y + 83 + row * 36, width = (list.width - 32) / 3, height = 32 }, "+ " .. item[1], { type = "create_native_asset", asset_type = item[2] })
  end
  self:text("DROP PNG / TILED JSON TO IMPORT", list.x + 14, list.y + 158, .56, COLORS.mint, list.width - 28)
  self:text("JSON ASSETS  ·  WHEEL TO SCROLL", list.x + 14, list.y + 178, .58, COLORS.muted)
  local asset_top, asset_bottom, row_height = list.y + 197, list.y + list.height - 214, 34
  local visible_rows = math.max(1, math.floor((asset_bottom - asset_top) / row_height))
  self.native_asset_scroll = clamp(self.native_asset_scroll or 0, 0, math.max(0, #self.native_assets - visible_rows))
  for index = self.native_asset_scroll + 1, math.min(#self.native_assets, self.native_asset_scroll + visible_rows) do
    local asset = self.native_assets[index]
    local selected = index == self.selected_asset
    local rect = { x = list.x + 9, y = asset_top + (index - self.native_asset_scroll - 1) * row_height, width = list.width - 18, height = 29 }
    self:panel(rect, selected and { .10, .27, .34 } or COLORS.surface2, selected and COLORS.blue or COLORS.border)
    self:text(asset.id, rect.x + 8, rect.y + 4, .68, selected and COLORS.gold or COLORS.text, rect.width - 16)
    self:text(asset.entry.type:upper(), rect.x + 8, rect.y + 18, .50, COLORS.muted, rect.width - 16)
    self.controls[#self.controls + 1] = { rect = rect, action = { type = "native_asset", index = index }, cursor = "action" }
  end
  self.native_asset_list_rect = { x = list.x + 6, y = asset_top, width = list.width - 12, height = math.max(0, asset_bottom - asset_top) }
  if self.native_asset_data and self.native_asset_data.type == "generator" then self:button({ x = list.x + 10, y = list.y + list.height - 202, width = list.width - 20, height = 36 }, "GENERATE PREVIEW", { type = "generate_native" }) end
  self:button({ x = list.x + 10, y = list.y + list.height - 160, width = (list.width - 28) / 2, height = 36 }, "UNDO", { type = "undo_native" }, { enabled = self.native_history and self.native_history:can_undo() })
  self:button({ x = list.x + list.width / 2 + 4, y = list.y + list.height - 160, width = (list.width - 28) / 2, height = 36 }, "REDO", { type = "redo_native" }, { enabled = self.native_history and self.native_history:can_redo() })
  self:button({ x = list.x + 10, y = list.y + list.height - 118, width = list.width - 20, height = 36 }, self.native_dirty and "SAVE ASSET" or "VALIDATE ASSET", { type = "save_native" }, { selected = self.native_dirty })
  self:button({ x = list.x + 10, y = list.y + list.height - 77, width = (list.width - 28) / 2, height = 36 }, "RUN PROJECT", { type = "run_project" }, { selected = self.runtime and self.runtime.scene ~= nil })
  self:button({ x = list.x + list.width / 2 + 4, y = list.y + list.height - 77, width = (list.width - 28) / 2, height = 36 }, "RUN MAIN", { type = "run_scene" })
  self:button({ x = list.x + 10, y = list.y + list.height - 36, width = list.width - 20, height = 30 }, "REMOVE FROM INDEX", { type = "remove_native_asset" }, { danger = true, enabled = self:current_native_asset() and self:current_native_asset().id ~= self.project_manifest.main_scene_id })
  self:text("PLAY PROJECT and MAIN remain distinct. Native assets are declared JSON only.", canvas.x + 16, canvas.y + 12, .62, COLORS.muted, canvas.width - 32)
  local selected = self:current_native_asset()
  local inspector_height = 168
  if selected then
    self:text("INSPECTOR  " .. selected.id:upper(), canvas.x + 16, canvas.y + 36, .84, COLORS.blue)
    self:text("TYPE " .. selected.entry.type:upper() .. "  ·  " .. selected.entry.path, canvas.x + 16, canvas.y + 58, .57, COLORS.muted, canvas.width - 32)
  end
  local info_y = canvas.y + 78
  if self.native_asset_data and self.native_asset_data.type == "scene" then
    local node, props = self.native_selected_node, self.native_selected_node and (self.native_selected_node.properties or {})
    if node then
      node.properties = props
      self:text(node.id .. "  ·  " .. node.type:upper(), canvas.x + 16, info_y, .67, COLORS.gold)
      self:native_field({ x = canvas.x + 16, y = info_y + 20, width = 78, height = 42 }, "X", props, "x", "number")
      self:native_field({ x = canvas.x + 100, y = info_y + 20, width = 78, height = 42 }, "Y", props, "y", "number")
      self:native_field({ x = canvas.x + 184, y = info_y + 20, width = 78, height = 42 }, "WIDTH", props, "width", "number")
      self:native_field({ x = canvas.x + 268, y = info_y + 20, width = 78, height = 42 }, "HEIGHT", props, "height", "number")
      if node.type == "label" or node.type == "button" then self:native_field({ x = canvas.x + 352, y = info_y + 20, width = math.max(140, canvas.width - 368), height = 42 }, "TEXT", props, "text", "text") end
      self:button({ x = canvas.x + 16, y = info_y + 70, width = 96, height = 32 }, "+ PANEL", { type = "add_native_node", node_type = "panel" })
      self:button({ x = canvas.x + 118, y = info_y + 70, width = 96, height = 32 }, "+ LABEL", { type = "add_native_node", node_type = "label" })
      self:button({ x = canvas.x + 220, y = info_y + 70, width = 96, height = 32 }, "+ BUTTON", { type = "add_native_node", node_type = "button" })
      self:button({ x = canvas.x + 322, y = info_y + 70, width = 112, height = 32 }, self.native_reparent_source and "CHOOSE PARENT" or "REPARENT", { type = "native_reparent_mode" }, { selected = self.native_reparent_source ~= nil, enabled = node ~= self.native_asset_data.root })
      self:button({ x = canvas.x + 440, y = info_y + 70, width = 92, height = 32 }, "DELETE", { type = "delete_native_node" }, { danger = true, enabled = node ~= self.native_asset_data.root })
      if selected.id ~= self.project_manifest.main_scene_id then self:button({ x = canvas.x + 538, y = info_y + 70, width = 118, height = 32 }, "SET MAIN", { type = "set_main_scene" }) end
    end
  elseif self.native_asset_data and self.native_asset_data.type == "tilemap" then
    local map, layer = self.native_asset_data, self:current_map_layer(self.native_asset_data)
    self:text("LAYERS  ·  brush " .. tostring(self.map_brush or 1) .. "  ·  WHEEL ZOOMS · RIGHT DRAG PANS", canvas.x + 16, info_y, .62, COLORS.gold, canvas.width - 32)
    for index, item in ipairs(map.layers) do
      self:button({ x = canvas.x + 16 + (index - 1) * 112, y = info_y + 22, width = 106, height = 31 }, item.id:gsub("^layer%.", ""), { type = "select_map_layer", index = index }, { selected = index == self.selected_map_layer })
    end
    self:button({ x = canvas.x + 16, y = info_y + 60, width = 110, height = 32 }, "+ LAYER", { type = "add_map_layer" })
    self:button({ x = canvas.x + 132, y = info_y + 60, width = 116, height = 32 }, "DELETE LAYER", { type = "remove_map_layer" }, { danger = true, enabled = #map.layers > 1 })
    if layer then self:native_field({ x = canvas.x + 254, y = info_y + 54, width = 210, height = 42 }, "TILESET ID", layer, "tileset_id", "text") end
    self:button({ x = canvas.x + 470, y = info_y + 60, width = 92, height = 32 }, "ERASE", { type = "native_map_brush", tile = 0 }, { selected = self.map_brush == 0 })
  elseif self.native_asset_data and self.native_asset_data.type == "tileset" then
    local data = self.native_asset_data
    self:native_field({ x = canvas.x + 16, y = info_y + 8, width = 184, height = 42 }, "PNG PATH", data.texture, "path", "text")
    self:native_field({ x = canvas.x + 206, y = info_y + 8, width = 100, height = 42 }, "TILE W", data, "tile_width", "number")
    self:native_field({ x = canvas.x + 312, y = info_y + 8, width = 100, height = 42 }, "TILE H", data, "tile_height", "number")
    self:text("Click a visible tile to select it for tilemap painting.", canvas.x + 16, info_y + 62, .62, COLORS.mint)
  elseif self.native_asset_data and self.native_asset_data.type == "flow" then
    local flow, node = self.native_asset_data, self.native_selected_flow_node
    self:button({ x = canvas.x + 16, y = info_y + 8, width = 100, height = 32 }, "+ EVENT", { type = "add_flow_node", node_type = "event" })
    self:button({ x = canvas.x + 122, y = info_y + 8, width = 118, height = 32 }, "+ TRANSITION", { type = "add_flow_node", node_type = "transition" })
    self:button({ x = canvas.x + 246, y = info_y + 8, width = 110, height = 32 }, "+ VARIABLE", { type = "add_flow_node", node_type = "set_variable" })
    if node then
      self:text(node.id .. "  ·  " .. node.type:upper(), canvas.x + 16, info_y + 48, .64, COLORS.gold)
      if node.event then self:native_field({ x = canvas.x + 16, y = info_y + 68, width = 160, height = 42 }, "EVENT", node, "event", "text") end
      if node.scene_id then self:native_field({ x = canvas.x + 182, y = info_y + 68, width = 160, height = 42 }, "SCENE ID", node, "scene_id", "text") end
      if node.variable then self:native_field({ x = canvas.x + 348, y = info_y + 68, width = 120, height = 42 }, "VARIABLE", node, "variable", "text") end
      self:button({ x = canvas.x + 474, y = info_y + 74, width = 118, height = 32 }, self.native_connect_from and "PICK DESTINATION" or "CONNECT FROM", { type = "start_flow_connection" }, { selected = self.native_connect_from ~= nil })
      self:button({ x = canvas.x + 598, y = info_y + 74, width = 88, height = 32 }, "DELETE", { type = "delete_flow_node" }, { danger = true })
    end
  elseif self.native_asset_data and self.native_asset_data.type == "generator" then
    local data, settings = self.native_asset_data, self.native_asset_data.settings
    self:native_field({ x = canvas.x + 16, y = info_y + 8, width = 110, height = 42 }, "WIDTH", settings, "width", "number")
    self:native_field({ x = canvas.x + 132, y = info_y + 8, width = 110, height = 42 }, "HEIGHT", settings, "height", "number")
    self:native_field({ x = canvas.x + 248, y = info_y + 8, width = 110, height = 42 }, "SEED", settings, "seed", "number")
    self:native_field({ x = canvas.x + 364, y = info_y + 8, width = 110, height = 42 }, "THRESHOLD", settings, "threshold", "number")
    self:text("" .. data.generator_type:upper() .. " is deterministic: same JSON settings, same generated map.", canvas.x + 16, info_y + 62, .62, COLORS.mint)
  elseif self.native_asset_data and self.native_asset_data.type == "room_template" then
    self:text("Room-template assets are serializable primitives. Use ROAG ROOMS for its live companion corpus and connector diagnostics.", canvas.x + 16, info_y + 12, .68, COLORS.muted, canvas.width - 32)
  end
  local preview = { x = canvas.x + 16, y = canvas.y + inspector_height, width = canvas.width - 32, height = canvas.height - inspector_height - 16 }
  self:panel(preview, COLORS.dark, COLORS.border)
  if self.native_asset_data and self.native_asset_data.type == "scene" then
    local tree = { x = preview.x + 8, y = preview.y + 8, width = math.min(178, math.max(128, preview.width * .24)), height = preview.height - 16 }
    local scene_canvas = { x = tree.x + tree.width + 10, y = preview.y + 1, width = preview.width - tree.width - 20, height = preview.height - 2 }
    self:panel(tree, COLORS.surface, COLORS.border)
    self:text(self.native_reparent_source and "PICK NEW PARENT" or "SCENE TREE", tree.x + 8, tree.y + 8, .58, self.native_reparent_source and COLORS.gold or COLORS.muted, tree.width - 16)
    local row = 0
    local function draw_tree(node, nesting)
      if row >= math.floor((tree.height - 44) / 28) then return end
      local selected_node = node == self.native_selected_node
      local rect = { x = tree.x + 6, y = tree.y + 27 + row * 28, width = tree.width - 12, height = 24 }
      self:panel(rect, selected_node and { .10, .27, .34 } or COLORS.surface2, selected_node and COLORS.gold or COLORS.border)
      self:text(string.rep("· ", nesting) .. node.id:gsub("^node%.", ""), rect.x + 5, rect.y + 5, .53, selected_node and COLORS.gold or COLORS.text, rect.width - 10)
      self.controls[#self.controls + 1] = { rect = rect, action = { type = self.native_reparent_source and "native_reparent_here" or "native_node", node = node }, cursor = "action" }
      row = row + 1
      for _, child in ipairs(node.children or {}) do draw_tree(child, nesting + 1) end
    end
    draw_tree(self.native_asset_data.root, 0)
    self:text("SELECT NODE · DRAG CANVAS", tree.x + 7, tree.y + tree.height - 18, .49, COLORS.muted, tree.width - 14, "center")
    love.graphics.setScissor(scene_canvas.x + 1, scene_canvas.y + 1, scene_canvas.width - 2, scene_canvas.height - 2)
    self:draw_native_scene_node(self.native_asset_data.root, scene_canvas)
    love.graphics.setScissor()
    local node = self.native_selected_node
    if node then
      self:text("SELECTED " .. node.id .. "  ·  DRAG TO MOVE", scene_canvas.x + 12, preview.y + preview.height - 22, .6, COLORS.mint)
    end
  elseif self.native_asset_data and self.native_asset_data.type == "tilemap" then
    self:draw_native_tilemap(self.native_asset_data, preview)
  elseif self.native_asset_data and self.native_asset_data.type == "generator" then
    if self.generated_preview and self.generated_preview.type == "tilemap" then
      self:draw_native_tilemap(self.generated_preview, preview)
    else
      self:text("GENERATOR: " .. tostring(self.native_asset_data.generator_type):upper() .. "\nGenerate a deterministic preview from its JSON settings.", preview.x + 24, preview.y + 28, .8, COLORS.muted, preview.width - 48)
    end
  elseif self.native_asset_data and self.native_asset_data.type == "flow" then
    self:draw_native_flow(self.native_asset_data, preview)
    self:text("FLOW GRAPH  ·  DRAG NODES TO ORGANIZE. Select CONNECT FROM then its destination to add a declared edge.", preview.x + 12, preview.y + preview.height - 24, .6, COLORS.mint)
  elseif self.runtime and self.runtime.scene then
    love.graphics.setScissor(preview.x + 1, preview.y + 1, preview.width - 2, preview.height - 2)
    love.graphics.push(); love.graphics.translate(preview.x, preview.y); self.runtime:draw(); love.graphics.pop(); love.graphics.setScissor()
    self:text("LIVE DATA-RUNTIME PREVIEW  " .. self.runtime.scene_id, preview.x + 12, preview.y + preview.height - 24, .62, COLORS.mint)
  else
    self:text("Select RUN PROJECT to load the flow entry scene, or RUN MAIN SCENE to preview the project’s configured root.", preview.x + 24, preview.y + 28, .8, COLORS.muted, preview.width - 48)
  end
end

function Studio:draw_rooms(view)
  local list = { x = view.body.x, y = view.body.y, width = math.max(264, view.body.width * .25), height = view.body.height }
  local editor = { x = list.x + list.width + 16, y = view.body.y, width = view.body.width - list.width - 16, height = view.body.height }
  self:panel(list); self:panel(editor)
  self:text("ROAG ROOM JSON", list.x + 14, list.y + 14, .74, COLORS.gold)
  for index, corpus_id in ipairs(Workspace.CORPORA) do
    self:button({ x = list.x + 10, y = list.y + 43 + (index - 1) * 43, width = list.width - 20, height = 34 }, corpus_id:upper(), { type = "corpus", id = corpus_id }, { selected = self.selected_corpus == corpus_id })
  end
  local corpus = self.corpora[self.selected_corpus]
  self:text("DECLARED TEMPLATES", list.x + 14, list.y + 142, .64, COLORS.muted)
  for index, room in ipairs(corpus.rooms) do
    local selected = index == self.selected_room
    local rect = { x = list.x + 8, y = list.y + 161 + (index - 1) * 34, width = list.width - 16, height = 28 }
    self:panel(rect, selected and { .10, .27, .34 } or COLORS.surface2, selected and COLORS.blue or COLORS.border)
    self:text(room.data.id:gsub("^room%." .. self.selected_corpus .. "%.", ""), rect.x + 7, rect.y + 6, .64, selected and COLORS.gold or COLORS.text, rect.width - 14)
    self.controls[#self.controls + 1] = { rect = rect, action = { type = "room", index = index }, cursor = "action" }
  end
  self:button({ x = list.x + 10, y = list.y + list.height - 205, width = (list.width - 28) / 2, height = 32 }, "+ ROOM", { type = "new_room" })
  self:button({ x = list.x + list.width / 2 + 4, y = list.y + list.height - 205, width = (list.width - 28) / 2, height = 32 }, "REMOVE", { type = "remove_room" }, { danger = true, enabled = #corpus.rooms > 1 })
  self:button({ x = list.x + 10, y = list.y + list.height - 167, width = list.width - 20, height = 32 }, "CORPUS DIAGNOSTICS", { type = "room_diagnostics" }, { selected = self.room_diagnostics ~= nil })
  self:button({ x = list.x + 10, y = list.y + list.height - 129, width = list.width - 20, height = 32 }, "PREVIEW 3 × 2", { type = "room_preview" })
  self:button({ x = list.x + 10, y = list.y + list.height - 91, width = (list.width - 28) / 2, height = 32 }, "UNDO", { type = "undo_room" }, { enabled = self.room_histories[self:room_history_key()] and self.room_histories[self:room_history_key()]:can_undo() })
  self:button({ x = list.x + list.width / 2 + 4, y = list.y + list.height - 91, width = (list.width - 28) / 2, height = 32 }, "REDO", { type = "redo_room" }, { enabled = self.room_histories[self:room_history_key()] and self.room_histories[self:room_history_key()]:can_redo() })
  self:button({ x = list.x + 10, y = list.y + list.height - 48, width = list.width - 20, height = 40 }, self.room_dirty and "SAVE ROOM" or "VALIDATE ROOM", { type = "save_room" }, { selected = self.room_dirty })
  local room = self:current_room()
  self:text("TEMPLATE: " .. room.data.id:upper(), editor.x + 16, editor.y + 16, .88, COLORS.blue)
  self:text("Click a cell to paint. The edit changes only this declared JSON template; Lua generation code is untouched.", editor.x + 16, editor.y + 42, .66, COLORS.muted, editor.width - 32)
  local grid = { x = editor.x + 18, y = editor.y + 82, width = math.min(editor.width * .48, editor.height - 154), height = math.min(editor.width * .48, editor.height - 154) }
  self:panel(grid, COLORS.dark, COLORS.border)
  local tile = math.floor(math.min((grid.width - 20) / room.data.width, (grid.height - 20) / room.data.height))
  local grid_width, grid_height = room.data.width * tile, room.data.height * tile
  local origin_x, origin_y = grid.x + (grid.width - grid_width) / 2, grid.y + (grid.height - grid_height) / 2
  for row = 1, room.data.height do
    for column = 1, room.data.width do
      local glyph = room.data.layout[row]:sub(column, column)
      local fill = glyph == "#" and { .28, .39, .48 } or { .08, .15, .19 }
      color(fill); love.graphics.rectangle("fill", origin_x + (column - 1) * tile, origin_y + (row - 1) * tile, tile - 1, tile - 1)
      self.controls[#self.controls + 1] = { rect = { x = origin_x + (column - 1) * tile, y = origin_y + (row - 1) * tile, width = tile, height = tile }, action = { type = "room_paint", row = row, column = column }, cursor = "picker" }
    end
  end
  local palette_x = grid.x + grid.width + 20
  self:text("PALETTE", palette_x, grid.y + 5, .68, COLORS.gold)
  local glyphs = {}; for glyph in pairs(room.data.legend or {}) do glyphs[#glyphs + 1] = glyph end; table.sort(glyphs)
  self.room_brush = self.room_brush or glyphs[1]
  for index, glyph in ipairs(glyphs) do self:button({ x = palette_x, y = grid.y + 30 + (index - 1) * 38, width = 130, height = 30 }, glyph .. "  " .. tostring(room.data.legend[glyph]):gsub("^material%.", ""), { type = "room_brush", glyph = glyph }, { selected = self.room_brush == glyph }) end
  local connector_text = {}; for _, connector in ipairs(room.data.connectors or {}) do connector_text[#connector_text + 1] = connector.side .. "@" .. connector.offset end
  self:text("CONNECTORS  " .. table.concat(connector_text, "  "), palette_x, grid.y + 30 + #glyphs * 42, .63, COLORS.muted, editor.x + editor.width - palette_x - 16)
  local valid, validation = Workspace.validate_room(room.data)
  local health_y = grid.y + 56 + #glyphs * 42
  self:text(valid and "CURRENT ROOM: VALID" or ("CURRENT ROOM: " .. validation.reason), palette_x, health_y, .61, valid and COLORS.mint or COLORS.red, editor.x + editor.width - palette_x - 16)
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
    self:text("DETERMINISTIC ROOM-GRAPH PREVIEW", editor.x + 18, preview_y, .7, COLORS.mint)
    for _, cell in ipairs(self.room_graph.cells) do
      local x, y = editor.x + 18 + cell.x * 116, preview_y + 24 + cell.y * 37
      self:panel({ x = x, y = y, width = 108, height = 30 }, COLORS.surface2, COLORS.border)
      self:text(cell.template_id:gsub("^room%." .. self.selected_corpus .. "%.", ""), x + 6, y + 8, .52, COLORS.text, 96)
    end
  end
end

function Studio:draw_art(view)
  local left = { x = view.body.x, y = view.body.y, width = math.max(290, view.body.width * .29), height = view.body.height }
  local middle = { x = left.x + left.width + 16, y = view.body.y, width = view.body.width - left.width - 16, height = view.body.height }
  self:panel(left); self:panel(middle)
  self:text("PRESENTATION PACK", left.x + 14, left.y + 14, .74, COLORS.gold)
  local packs = self.data.catalog.art_packs
  for index, pack in ipairs(packs) do
    local selected = pack.id == self.data.art_pack.art_pack_id
    self:button({ x = left.x + 10, y = left.y + 43 + (index - 1) * 49, width = left.width - 20, height = 42 }, pack.label, { type = "pack", index = index }, { selected = selected })
    self:text(pack.license .. " · " .. pack.credit, left.x + 18, left.y + 78 + (index - 1) * 49, .58, selected and COLORS.dark or COLORS.muted, left.width - 36)
  end
  local selected_pack
  for _, pack in ipairs(packs) do if pack.id == self.data.art_pack.art_pack_id then selected_pack = pack end end
  self:text("ROLE MAPPER", middle.x + 16, middle.y + 14, .74, COLORS.gold)
  self:text(selected_pack.editable_roles and "Original ROAG 1-bit mapping — changes below are live role assignments." or "This pack ships its own stable starter mapping. Choose ROAG 1-BIT to edit individual role tiles.", middle.x + 16, middle.y + 39, .74, selected_pack.editable_roles and COLORS.mint or COLORS.muted, middle.width - 32)
  if not selected_pack.editable_roles then return end
  local roles_rect = { x = middle.x + 14, y = middle.y + 78, width = 224, height = middle.height - 92 }
  local sheet_rect = { x = roles_rect.x + roles_rect.width + 16, y = roles_rect.y, width = middle.width - roles_rect.width - 44, height = roles_rect.height }
  self:panel(roles_rect, COLORS.surface2); self:panel(sheet_rect, COLORS.surface2)
  self:text("ROLES", roles_rect.x + 10, roles_rect.y + 9, .7, COLORS.muted)
  self:button({ x = roles_rect.x + 10, y = roles_rect.y + roles_rect.height - 42, width = roles_rect.width - 20, height = 30 }, "UNDO", { type = "undo" }, { enabled = #self.undo_stack > 0 })
  local visible, y = {}, roles_rect.y + 35
  for index, role in ipairs(ROLES) do
    if self.role_filter == "" or role[1]:find(self.role_filter:lower(), 1, true) or role[2]:lower():find(self.role_filter:lower(), 1, true) then visible[#visible + 1] = { source = index, role = role } end
  end
  local max_rows = math.floor((roles_rect.height - 88) / 31)
  self.scroll = clamp(self.scroll, 0, math.max(0, #visible - max_rows))
  for local_index = self.scroll + 1, math.min(#visible, self.scroll + max_rows) do
    local item = visible[local_index]; local role = item.role; local selected = item.source == self.selected_role
    local rect = { x = roles_rect.x + 7, y = y, width = roles_rect.width - 14, height = 27 }
    self:panel(rect, selected and { .1, .27, .34 } or COLORS.surface, selected and COLORS.blue or COLORS.border)
    self:text(role[2], rect.x + 7, rect.y + 5, .73, selected and COLORS.gold or COLORS.text, rect.width - 56)
    local map = self.data.sprites.sprites[role[1]]; self:text(map and (map.column .. "," .. map.row) or "—", rect.x + rect.width - 44, rect.y + 6, .62, COLORS.muted)
    self.controls[#self.controls + 1] = { rect = rect, action = { type = "role", index = item.source }, cursor = "action" }
    y = y + 31
  end
  self:text("F FILTER · WHEEL SCROLL", roles_rect.x + 10, roles_rect.y + roles_rect.height - 66, .58, COLORS.muted, roles_rect.width - 20)
  self:draw_sheet(sheet_rect)
end

function Studio:draw_sheet(rect)
  if not self.sheet then self:text("Could not load ROAG sprite sheet:\n" .. tostring(self.sheet_error), rect.x + 16, rect.y + 20, .78, COLORS.red, rect.width - 32); return end
  local base = math.min((rect.width - 24) / (49 * 16), (rect.height - 48) / (22 * 16))
  local size = base * self.sheet_zoom; local sheet_width, sheet_height = 49 * size, 22 * size
  local origin_x, origin_y = rect.x + (rect.width - sheet_width) / 2 + self.sheet_pan_x, rect.y + (rect.height - sheet_height) / 2 + self.sheet_pan_y
  love.graphics.setScissor(rect.x + 1, rect.y + 1, rect.width - 2, rect.height - 2)
  color({ 1, 1, 1 }); love.graphics.draw(self.sheet, origin_x, origin_y, 0, size / 16, size / 16)
  local role = self:current_role(); local tile = self.data.sprites.sprites[role[1]]
  if tile then color(COLORS.blue); love.graphics.setLineWidth(3); love.graphics.rectangle("line", origin_x + (tile.column - 1) * size, origin_y + (tile.row - 1) * size, size, size) end
  local mx, my = love.mouse.getPosition(); local column, row = math.floor((mx - origin_x) / size) + 1, math.floor((my - origin_y) / size) + 1
  if column >= 1 and column <= 49 and row >= 1 and row <= 22 and inside(mx, my, rect) then color(COLORS.gold); love.graphics.setLineWidth(2); love.graphics.rectangle("line", origin_x + (column - 1) * size, origin_y + (row - 1) * size, size, size); self.sheet_hover = { column = column, row = row } else self.sheet_hover = nil end
  love.graphics.setLineWidth(1); love.graphics.setScissor()
  self:text(self.sheet_hover and ("[" .. self.sheet_hover.column .. ", " .. self.sheet_hover.row .. "] CLICK TO ASSIGN") or "CLICK TO ASSIGN · WHEEL ZOOMS · RIGHT DRAG PANS", rect.x + 12, rect.y + rect.height - 25, .64, self.sheet_hover and COLORS.gold or COLORS.muted, rect.width - 24, "center")
  self.controls[#self.controls + 1] = { rect = rect, action = { type = "sheet" }, cursor = "picker" }
end

function Studio:draw_scenes(view)
  local list = { x = view.body.x, y = view.body.y, width = math.max(254, view.body.width * .26), height = view.body.height }
  local edit = { x = list.x + list.width + 16, y = view.body.y, width = view.body.width - list.width - 16, height = view.body.height }
  self:panel(list); self:panel(edit)
  self:text("SCENES", list.x + 14, list.y + 14, .74, COLORS.gold)
  for index, screen in ipairs(self.data.screens.screens) do
    local selected = index == self.selected_screen; local rect = { x = list.x + 10, y = list.y + 44 + (index - 1) * 47, width = list.width - 20, height = 39 }
    self:panel(rect, selected and { .1, .27, .34 } or COLORS.surface2, selected and COLORS.blue or COLORS.border)
    self:text(screen.title, rect.x + 8, rect.y + 6, .8, selected and COLORS.gold or COLORS.text, rect.width - 16); self:text(screen.id .. " · " .. screen.layout, rect.x + 8, rect.y + 23, .57, COLORS.muted, rect.width - 16)
    self.controls[#self.controls + 1] = { rect = rect, action = { type = "screen", index = index }, cursor = "action" }
  end
  self:button({ x = list.x + 10, y = list.y + list.height - 86, width = (list.width - 28) / 2, height = 32 }, "MOVE UP", { type = "screen_move", delta = -1 }, { enabled = self.selected_screen > 1 })
  self:button({ x = list.x + list.width / 2 + 4, y = list.y + list.height - 86, width = (list.width - 28) / 2, height = 32 }, "MOVE DOWN", { type = "screen_move", delta = 1 }, { enabled = self.selected_screen < #self.data.screens.screens })
  self:text("Ordering is editor/inspection order; ROAG’s safe runtime behavior stays in App.", list.x + 12, list.y + list.height - 46, .57, COLORS.muted, list.width - 24)
  local screen = self:current_screen(); self:text("SCENE: " .. screen.id:upper(), edit.x + 18, edit.y + 16, 1.05, COLORS.blue); self:text("Validated presentation copy and visual tokens", edit.x + 18, edit.y + 44, .73, COLORS.muted)
  self:field({ x = edit.x + 18, y = edit.y + 82, width = edit.width - 36, height = 60 }, "TITLE", "screen", "title")
  self:field({ x = edit.x + 18, y = edit.y + 151, width = edit.width - 36, height = 60 }, "SUBTITLE", "screen", "subtitle")
  self:field({ x = edit.x + 18, y = edit.y + 220, width = edit.width - 36, height = 60 }, "FOOTER", "screen", "footer")
  self:button({ x = edit.x + 18, y = edit.y + 303, width = 215, height = 36 }, "LAYOUT: " .. screen.layout:upper(), { type = "cycle_layout" })
  self:button({ x = edit.x + 245, y = edit.y + 303, width = 215, height = 36 }, "ACCENT: " .. screen.accent:upper(), { type = "cycle_accent" })
  local preview = { x = edit.x + 18, y = edit.y + 367, width = edit.width - 36, height = edit.height - 385 }; self:panel(preview, COLORS.dark, COLORS.border)
  self:text(screen.title, preview.x + 24, preview.y + 24, 1.5, COLORS[screen.accent] or COLORS.blue, preview.width - 48, "center"); self:text(screen.subtitle, preview.x + 24, preview.y + 66, .76, COLORS.muted, preview.width - 48, "center")
  self:panel({ x = preview.x + preview.width * .16, y = preview.y + 118, width = preview.width * .68, height = 44 }, COLORS.surface2, COLORS[screen.accent] or COLORS.blue); self:text("LIVE SCREEN PREVIEW", preview.x + 24, preview.y + 132, .8, COLORS.gold, preview.width - 48, "center")
  self:text(screen.footer, preview.x + 24, preview.y + preview.height - 33, .72, COLORS.muted, preview.width - 48, "center")
end

function Studio:draw_flow(view)
  local list = { x = view.body.x, y = view.body.y, width = math.max(310, view.body.width * .34), height = view.body.height }
  local edit = { x = list.x + list.width + 16, y = view.body.y, width = view.body.width - list.width - 16, height = view.body.height }
  self:panel(list); self:panel(edit)
  self:text("TITLE FLOW", list.x + 14, list.y + 14, .74, COLORS.gold); self:text("Order determines what the player sees. Targets are fixed safe actions.", list.x + 14, list.y + 36, .66, COLORS.muted, list.width - 28)
  for index, action in ipairs(self.data.flow.title_actions) do
    local selected = index == self.selected_action; local rect = { x = list.x + 10, y = list.y + 75 + (index - 1) * 64, width = list.width - 20, height = 55 }
    self:panel(rect, selected and { .1, .27, .34 } or COLORS.surface2, selected and COLORS.blue or COLORS.border)
    self:text((index .. ". ") .. action.label, rect.x + 10, rect.y + 7, .82, selected and COLORS.gold or COLORS.text, rect.width - 20); self:text("→ " .. action.target, rect.x + 10, rect.y + 29, .63, COLORS.muted, rect.width - 20)
    self.controls[#self.controls + 1] = { rect = rect, action = { type = "action", index = index }, cursor = "action" }
  end
  self:button({ x = list.x + 10, y = list.y + list.height - 44, width = (list.width - 28) / 2, height = 32 }, "MOVE UP", { type = "action_move", delta = -1 }, { enabled = self.selected_action > 1 })
  self:button({ x = list.x + list.width / 2 + 4, y = list.y + list.height - 44, width = (list.width - 28) / 2, height = 32 }, "MOVE DOWN", { type = "action_move", delta = 1 }, { enabled = self.selected_action < #self.data.flow.title_actions })
  local action = self:current_action(); self:text("ACTION: " .. action.id:upper(), edit.x + 18, edit.y + 18, 1.05, COLORS.blue); self:text("Declared target: " .. action.target .. " (game behavior is not scriptable here)", edit.x + 18, edit.y + 46, .74, COLORS.muted)
  self:field({ x = edit.x + 18, y = edit.y + 88, width = edit.width - 36, height = 60 }, "VISIBLE LABEL", "action", "label")
  self:field({ x = edit.x + 18, y = edit.y + 157, width = edit.width - 36, height = 60 }, "HELPER DESCRIPTION", "action", "description")
  local flow = { x = edit.x + 18, y = edit.y + 248, width = edit.width - 36, height = 175 }; self:panel(flow, COLORS.dark, COLORS.border); self:text("SAFE NAVIGATION", flow.x + 16, flow.y + 15, .72, COLORS.gold); self:text("TITLE", flow.x + 20, flow.y + 66, 1.1, COLORS.blue); self:text("→", flow.x + flow.width * .38, flow.y + 68, 1.15, COLORS.muted); self:text(action.target:upper(), flow.x + flow.width * .48, flow.y + 66, 1.1, COLORS.mint); self:text("The editor can change the display order and copy. It cannot fabricate a new gameplay transition or invoke Lua callbacks.", flow.x + 16, flow.y + 119, .67, COLORS.muted, flow.width - 32)
end

function Studio:draw_publish(view)
  self:panel(view.body); self:text("Validate, then publish", view.body.x + 24, view.body.y + 24, 1.5, COLORS.text); self:text("A publish operation validates every document before it writes. It uses verified atomic replacement on four explicit paths only.", view.body.x + 24, view.body.y + 63, .82, COLORS.muted, view.body.width - 48)
  local files = { "content/screens/legacy.json", "content/presentation/flow.json", "content/presentation/art_pack.json", "sprite_editor/mappings.json" }
  for index, path in ipairs(files) do local y = view.body.y + 125 + (index - 1) * 56; self:panel({ x = view.body.x + 24, y = y, width = view.body.width - 48, height = 42 }, COLORS.surface2, COLORS.border); color(COLORS.mint); love.graphics.draw(self.images.icon_check, view.body.x + 38, y + 10, 0, .55, .55); self:text(path, view.body.x + 68, y + 12, .8, COLORS.text) end
  self:button({ x = view.body.x + 24, y = view.body.y + 386, width = 228, height = 48 }, self.dirty and "PUBLISH CHANGES" or "VALIDATE & PUBLISH", { type = "save" }, { selected = self.dirty })
  self:text("Not writable: active_run.json, meta_profile.json, fallen_characters.json, simulation source, route content, boss content, or any world/persistence data.", view.body.x + 24, view.body.y + 456, .7, COLORS.muted, view.body.width - 48)
end

function Studio:draw()
  local view = self:layout(); self.controls = {}; love.graphics.clear(COLORS.backdrop)
  self:draw_header(view); self:draw_nav(view)
  if not self.data then
    self:panel(view.body); self:text("ROAG workspace unavailable", view.body.x + 24, view.body.y + 24, 1.5, COLORS.red); self:text(self.status, view.body.x + 24, view.body.y + 70, .82, COLORS.muted, view.body.width - 48)
  elseif self.tab == "native" then self:draw_native(view)
  elseif self.tab == "rooms" then self:draw_rooms(view)
  elseif self.tab == "art" then self:draw_art(view)
  elseif self.tab == "scenes" then self:draw_scenes(view)
  elseif self.tab == "flow" then self:draw_flow(view)
  elseif self.tab == "publish" then self:draw_publish(view)
  else self:draw_home(view) end
  self:panel(view.footer, COLORS.dark, COLORS.border); self:text(self.status, view.footer.x + 12, view.footer.y + 11, .68, COLORS.muted, view.footer.width - 24)
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
  if self:choice("Remove from project index", "The JSON file will be kept on disk for recovery. Remove " .. selected.id .. " from this project’s manifest?", { "Cancel", "Remove" }) ~= 2 then return end
  local ok, failure = self.project:remove_asset(selected.id)
  if not ok then
    local suffix = failure.references and (" Referenced by " .. table.concat((function() local ids = {}; for _, ref in ipairs(failure.references) do ids[#ids + 1] = ref.id end; return ids end)(), ", ") .. ".") or ""
    self.status = "Could not remove asset: " .. failure.reason .. suffix
    return
  end
  self:load_native_project(); self.status = "Removed " .. selected.id .. " from the manifest. Its JSON file remains recoverable on disk."
end

function Studio:filedropped(file)
  if not self.project_manifest or not file or not file.getFilename then return end
  if not self:resolve_native_before_change() then return end
  local path = file:getFilename()
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
  if kind == "tab" then self:commit_field(); self.tab = action.tab
  elseif kind == "native_asset" then
    if action.index ~= self.selected_asset and self:resolve_native_before_change() then self:select_native_asset(action.index) end
  elseif kind == "create_native_asset" then self:create_native_asset(action.asset_type)
  elseif kind == "remove_native_asset" then self:remove_native_asset()
  elseif kind == "native_node" then
    self.native_selected_node, self.native_drag = action.node, { scene_node = action.node }
    self.status = "Selected " .. action.node.id .. ". Drag to reposition; save writes its JSON asset."
  elseif kind == "native_reparent_here" then
    local source = self.native_reparent_source
    if not source or source == action.node then self.native_reparent_source = nil; self.status = "Choose a different destination parent."; return end
    self:record_native()
    local ok, reason = Scene.reparent(self.native_asset_data, source.id, action.node.id)
    if ok then self.native_reparent_source, self.status = nil, "Reparented " .. source.id .. " under " .. action.node.id .. "." else self:undo_native(); self.native_reparent_source, self.status = nil, "Could not reparent: " .. reason end
  elseif kind == "add_native_node" then
    local parent = self.native_selected_node or self.native_asset_data.root
    self:record_native()
    local node, reason = Scene.add(self.native_asset_data, parent.id, action.node_type)
    if node then self.native_selected_node, self.status = node, "Added " .. node.id .. "." else self:undo_native(); self.status = "Could not add node: " .. reason end
  elseif kind == "delete_native_node" then
    local node = self.native_selected_node
    if node then
      self:record_native(); local removed, reason = Scene.remove(self.native_asset_data, node.id)
      if removed then self.native_selected_node, self.status = self.native_asset_data.root, "Removed " .. removed.id .. " and its descendants." else self:undo_native(); self.status = "Could not remove node: " .. reason end
    end
  elseif kind == "native_reparent_mode" then
    local node = self.native_selected_node
    if node and node ~= self.native_asset_data.root then self.native_reparent_source = self.native_reparent_source and nil or node; self.status = self.native_reparent_source and "Choose a destination parent from the scene tree." or "Reparenting cancelled." end
  elseif kind == "set_main_scene" then
    local selected = self:current_native_asset()
    local ok, failure = selected and self.project:set_main_scene(selected.id)
    if ok then self.project_manifest = self.project.manifest; self.status = "Set " .. selected.id .. " as the project main scene." else self.status = "Could not set main scene: " .. failure.reason end
  elseif kind == "native_flow_node" then
    if self.native_connect_from and self.native_connect_from ~= action.node then
      self:record_native(); local ok, reason = Flow.connect(self.native_asset_data, self.native_connect_from.id, action.node.id)
      if ok then self.status = "Connected " .. self.native_connect_from.id .. " → " .. action.node.id else self:undo_native(); self.status = "Could not connect nodes: " .. reason end
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
  elseif kind == "save_native" then self:save_native()
  elseif kind == "run_project" then
    local flow_id
    for asset_id, entry in pairs(self.project_manifest.assets) do if entry.type == "flow" then flow_id = asset_id break end end
    local ok, failure = flow_id and self.runtime:start(flow_id) or self.runtime:load_scene(self.project_manifest.main_scene_id)
    self.status = ok and "Running native JSON project preview." or ("Could not run native project: " .. failure.reason)
  elseif kind == "run_scene" then
    local ok, failure = self.runtime:load_scene(self.project_manifest.main_scene_id)
    self.status = ok and "Running configured main scene preview." or ("Could not run main scene: " .. failure.reason)
  elseif kind == "corpus" then
    if self:resolve_room_before_change() then self.selected_corpus, self.selected_room, self.room_graph, self.room_brush, self.room_diagnostics = action.id, 1, nil, nil, nil end
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
  elseif kind == "reload" then if self:confirm_discard("Reload Studio", "Discard unsaved Studio changes and reload from disk?") then self:reload() end
  elseif kind == "undo" then self:commit_field(); self:undo()
  elseif kind == "undo_native" then self:undo_native()
  elseif kind == "redo_native" then self:redo_native()
  elseif kind == "undo_room" then self:undo_room()
  elseif kind == "redo_room" then self:redo_room()
  elseif kind == "pack" then self:commit_field(); self:record(); self.data.art_pack.art_pack_id = self.data.catalog.art_packs[action.index].id; self.status = "Selected pack. Publish to make ROAG use it on next focus/launch."
  elseif kind == "role" then self:commit_field(); self.selected_role = action.index
  elseif kind == "sheet" and self.sheet_hover then self:commit_field(); self:record(); local role = self:current_role(); self.data.sprites.sprites[role[1]] = { column = self.sheet_hover.column, row = self.sheet_hover.row }; self.status = role[2] .. " mapped to [" .. self.sheet_hover.column .. ", " .. self.sheet_hover.row .. "]."
  elseif kind == "screen" then self:commit_field(); self.selected_screen = action.index
  elseif kind == "screen_move" then self:commit_field(); self:move(self.data.screens.screens, self.selected_screen, action.delta); self.selected_screen = self.selected_screen + action.delta
  elseif kind == "action" then self:commit_field(); self.selected_action = action.index
  elseif kind == "action_move" then self:commit_field(); self:move(self.data.flow.title_actions, self.selected_action, action.delta); self.selected_action = self.selected_action + action.delta
  elseif kind == "cycle_layout" then self:cycle("layout", { "title_menu", "catalog", "list_detail", "route", "menu", "notice" })
  elseif kind == "cycle_accent" then self:cycle("accent", { "cyan", "amber", "mint", "coral", "violet" })
  elseif kind == "field" then self:begin_field(action.kind, action.field)
  elseif kind == "native_field" then self:begin_native_field(action.target, action.field, action.value_type) end
  self:play_click()
end

function Studio:update()
  local x, y = love.mouse.getPosition(); local cursor = "default"
  if self.sheet_panning or self.map_panning then cursor = "pan" else
    for _, control in ipairs(self.controls) do if control.enabled ~= false and inside(x, y, control.rect) then cursor = control.cursor or "action" end end
  end
  love.mouse.setCursor(self.cursors[cursor])
end

function Studio:mousepressed(x, y, button)
  if button == 2 and self.tab == "art" and self.sheet_hover then self.sheet_panning = true; return end
  if button == 2 and self.tab == "native" and self.map_viewport and inside(x, y, self.map_viewport) then self.map_panning = true; return end
  if button ~= 1 then return end
  for index = #self.controls, 1, -1 do local control = self.controls[index]; if control.enabled ~= false and inside(x, y, control.rect) then self:activate(control.action); return end end
  self:commit_field()
end

function Studio:mousereleased(_, _, button)
  if button == 2 then self.sheet_panning, self.map_panning = false, false end
  if button == 1 then self.native_drag = nil end
end

function Studio:mousemoved(_, _, dx, dy)
  if self.sheet_panning then self.sheet_pan_x, self.sheet_pan_y = self.sheet_pan_x + dx, self.sheet_pan_y + dy end
  if self.map_panning then self.map_pan_x, self.map_pan_y = self.map_pan_x + dx, self.map_pan_y + dy end
  if self.native_drag and self.tab == "native" then
    if not self.native_drag.recorded then self:record_native(); self.native_drag.recorded = true end
    if self.native_drag.flow_node then
      local point = self.native_drag.flow_node.editor or { x = 0, y = 0 }
      self.native_drag.flow_node.editor = point; point.x, point.y = point.x + dx, point.y + dy
    else
      local node = self.native_drag.scene_node
      local properties = node.properties or {}; node.properties = properties
      properties.x, properties.y = (properties.x or 0) + dx, (properties.y or 0) + dy
    end
    self.native_dirty = true
  end
end

function Studio:wheelmoved(_, dy)
  if self.tab == "art" then
    self.sheet_zoom = clamp(self.sheet_zoom * (1.14 ^ dy), .45, 6)
    self.scroll = clamp(self.scroll - dy, 0, math.max(0, #ROLES - 1))
  end
  if self.tab == "native" and self.native_asset_data and self.native_asset_data.type == "tilemap" then
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
  end
end

function Studio:textinput(value)
  if self.active then self.draft = self.draft .. value elseif self.role_filtering then self.role_filter, self.scroll = self.role_filter .. value, 0 end
end

function Studio:keypressed(key)
  local modifier = love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl") or love.keyboard.isDown("lgui") or love.keyboard.isDown("rgui")
  if modifier and key == "s" then
    if self.tab == "native" then self:save_native() elseif self.tab == "rooms" then self:save_room() else self:save() end
    return
  end
  if modifier and key == "z" then
    self:commit_field()
    if self.tab == "native" then self:undo_native() elseif self.tab == "rooms" then self:undo_room() else self:undo() end
    return
  end
  if modifier and (key == "y" or key == "r") then
    self:commit_field()
    if self.tab == "native" then self:redo_native() elseif self.tab == "rooms" then self:redo_room() else self:redo() end
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
  if key == "f" and self.tab == "art" then self.role_filtering = true; return end
  if key == "escape" then love.event.quit() end
end

return Studio
