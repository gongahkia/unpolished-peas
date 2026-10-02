local Bridge = require("core.roag_bridge")

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

local function path_arg(arguments)
  for index, value in ipairs(arguments or {}) do
    if value == "--roag" then return arguments[index + 1] end
    local path = value:match("^%-%-roag=(.+)$")
    if path then return path end
  end
end

function Studio.new(arguments)
  local target = path_arg(arguments) or Bridge.DEFAULT_TARGET
  local self = setmetatable({ bridge = Bridge.new(target), tab = "home", selected_screen = 1, selected_action = 1, selected_role = 1, role_filter = "", role_filtering = false, scroll = 0, sheet_zoom = 1, sheet_pan_x = 0, sheet_pan_y = 0, sheet_panning = false, dirty = false, undo_stack = {}, redo_stack = {}, active = nil, draft = "", controls = {}, status = "Loading ROAG presentation workspace…", fonts = {}, images = {}, cursors = {}, sounds = {} }, Studio)
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
  local data, failure = self.bridge:load()
  if not data then self.data, self.status = nil, "Could not open ROAG: " .. failure.reason; return nil, failure end
  self.data, self.dirty, self.undo_stack, self.redo_stack, self.active = data, false, {}, {}, nil
  self.selected_screen = clamp(self.selected_screen, 1, #data.screens.screens)
  self.selected_action = clamp(self.selected_action, 1, #data.flow.title_actions)
  self.status = "Loaded presentation data from " .. self.bridge.target
  self:load_sheet()
  return true
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

function Studio:commit_field()
  if not self.active then return end
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

function Studio:draw_header(view)
  color(COLORS.dark); love.graphics.rectangle("fill", 0, 0, view.width, view.header.height)
  color(COLORS.blue); love.graphics.rectangle("fill", 0, view.header.height - 2, view.width, 2)
  self:text("UNPOLISHED BEES", 20, 14, 2.1, COLORS.blue)
  self:text("ROAG PRESENTATION STUDIO", 20, 55, .76, COLORS.muted)
  local target = self.bridge.target
  self:text("TARGET  " .. target, view.width - 450, 20, .72, COLORS.muted, 300, "right")
  self:text(self.dirty and "UNPUBLISHED" or "SYNCHRONIZED", view.width - 150, 20, .72, self.dirty and COLORS.gold or COLORS.mint, 132, "right")
  self:button({ x = view.width - 252, y = 46, width = 112, height = 30 }, "RELOAD", { type = "reload" })
  self:button({ x = view.width - 128, y = 46, width = 112, height = 30 }, "PUBLISH", { type = "save" }, { selected = self.dirty })
end

function Studio:draw_nav(view)
  self:panel(view.nav)
  self:text("WORKSPACE", view.nav.x + 13, view.nav.y + 14, .72, COLORS.gold)
  local tabs = { { "home", "OVERVIEW" }, { "art", "ART & SPRITES" }, { "scenes", "SCENES" }, { "flow", "TITLE FLOW" }, { "publish", "PUBLISH" } }
  for index, item in ipairs(tabs) do
    self:button({ x = view.nav.x + 10, y = view.nav.y + 48 + (index - 1) * 52, width = view.nav.width - 20, height = 42 }, item[2], { type = "tab", tab = item[1] }, { selected = self.tab == item[1] })
  end
  self:text("SAFE BRIDGE", view.nav.x + 13, view.nav.y + view.nav.height - 92, .7, COLORS.mint)
  self:text("Only labels, declared UI flow, presentation pack selection and sprite mappings are writable.", view.nav.x + 13, view.nav.y + view.nav.height - 70, .66, COLORS.muted, view.nav.width - 26)
end

function Studio:draw_home(view)
  self:panel(view.body)
  self:text("A focused authoring boundary", view.body.x + 24, view.body.y + 24, 1.5, COLORS.text)
  self:text("Edit ROAG’s presentation without loading, changing, or depending on a live run, account profile, fallen archive, route, or simulation system.", view.body.x + 24, view.body.y + 62, .86, COLORS.muted, view.body.width - 48)
  local cards = {
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

function Studio:cycle(field, values)
  self:commit_field(); self:record(); local screen = self:current_screen(); local at = 1
  for index, value in ipairs(values) do if value == screen[field] then at = index break end end
  screen[field] = values[at % #values + 1]
end

function Studio:activate(action)
  if type(action) == "string" then return end
  local kind = action.type
  if kind == "tab" then self:commit_field(); self.tab = action.tab
  elseif kind == "save" then self:save()
  elseif kind == "reload" then self:reload()
  elseif kind == "undo" then self:commit_field(); self:undo()
  elseif kind == "pack" then self:commit_field(); self:record(); self.data.art_pack.art_pack_id = self.data.catalog.art_packs[action.index].id; self.status = "Selected pack. Publish to make ROAG use it on next focus/launch."
  elseif kind == "role" then self:commit_field(); self.selected_role = action.index
  elseif kind == "sheet" and self.sheet_hover then self:commit_field(); self:record(); local role = self:current_role(); self.data.sprites.sprites[role[1]] = { column = self.sheet_hover.column, row = self.sheet_hover.row }; self.status = role[2] .. " mapped to [" .. self.sheet_hover.column .. ", " .. self.sheet_hover.row .. "]."
  elseif kind == "screen" then self:commit_field(); self.selected_screen = action.index
  elseif kind == "screen_move" then self:commit_field(); self:move(self.data.screens.screens, self.selected_screen, action.delta); self.selected_screen = self.selected_screen + action.delta
  elseif kind == "action" then self:commit_field(); self.selected_action = action.index
  elseif kind == "action_move" then self:commit_field(); self:move(self.data.flow.title_actions, self.selected_action, action.delta); self.selected_action = self.selected_action + action.delta
  elseif kind == "cycle_layout" then self:cycle("layout", { "title_menu", "catalog", "list_detail", "route", "menu", "notice" })
  elseif kind == "cycle_accent" then self:cycle("accent", { "cyan", "amber", "mint", "coral", "violet" })
  elseif kind == "field" then self:begin_field(action.kind, action.field) end
  self:play_click()
end

function Studio:update()
  local x, y = love.mouse.getPosition(); local cursor = "default"
  if self.sheet_panning then cursor = "pan" else
    for _, control in ipairs(self.controls) do if control.enabled ~= false and inside(x, y, control.rect) then cursor = control.cursor or "action" end end
  end
  love.mouse.setCursor(self.cursors[cursor])
end

function Studio:mousepressed(x, y, button)
  if button == 2 and self.tab == "art" and self.sheet_hover then self.sheet_panning = true; return end
  if button ~= 1 then return end
  for index = #self.controls, 1, -1 do local control = self.controls[index]; if control.enabled ~= false and inside(x, y, control.rect) then self:activate(control.action); return end end
  self:commit_field()
end

function Studio:mousereleased(_, _, button)
  if button == 2 then self.sheet_panning = false end
end

function Studio:mousemoved(_, _, dx, dy)
  if self.sheet_panning then self.sheet_pan_x, self.sheet_pan_y = self.sheet_pan_x + dx, self.sheet_pan_y + dy end
end

function Studio:wheelmoved(_, dy)
  if self.tab == "art" then
    self.sheet_zoom = clamp(self.sheet_zoom * (1.14 ^ dy), .45, 6)
    self.scroll = clamp(self.scroll - dy, 0, math.max(0, #ROLES - 1))
  end
end

function Studio:textinput(value)
  if self.active then self.draft = self.draft .. value elseif self.role_filtering then self.role_filter, self.scroll = self.role_filter .. value, 0 end
end

function Studio:keypressed(key)
  local modifier = love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl") or love.keyboard.isDown("lgui") or love.keyboard.isDown("rgui")
  if modifier and key == "s" then self:save(); return end
  if modifier and key == "z" then self:commit_field(); self:undo(); return end
  if modifier and (key == "y" or key == "r") then self:commit_field(); self:redo(); return end
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
