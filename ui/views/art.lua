-- ROAG art-pack inspection and original-sheet role mapping.
-- Import/publish actions remain in Studio, while this module owns rendering and
-- pointer-local view state for the art workspace.
local Sources = require("core.art_sources")
local Theme = require("ui.theme")
local COLORS = Theme.colors
local color, inside, clamp, dock_width = Theme.color, Theme.inside, Theme.clamp, Theme.dock_width

local Art = {}

function Art.draw_pack_sheet(studio, rect, sheet)
  local image, reason = studio:art_sheet_image(sheet)
  studio.pack_sheet_rect = rect
  if not image then
    studio:text("Could not load the declared source sheet:\n" .. tostring(reason), rect.x + 18, rect.y + 22, .78, COLORS.red, rect.width - 36)
    return
  end
  local image_width, image_height = image:getDimensions()
  local available_height = rect.height - 46
  local base = math.min((rect.width - 30) / image_width, (available_height - 24) / image_height)
  local scale = math.max(.05, base * studio.art_sheet_zoom)
  local width, height = image_width * scale, image_height * scale
  local origin_x = rect.x + (rect.width - width) / 2 + studio.art_sheet_pan_x
  local origin_y = rect.y + (available_height - height) / 2 + studio.art_sheet_pan_y
  local grid_width = ((sheet.columns * (sheet.tile_width + (sheet.spacing or 0))) - (sheet.spacing or 0)) * scale
  local grid_height = ((sheet.rows * (sheet.tile_height + (sheet.spacing or 0))) - (sheet.spacing or 0)) * scale
  local pitch_x, pitch_y = (sheet.tile_width + (sheet.spacing or 0)) * scale, (sheet.tile_height + (sheet.spacing or 0)) * scale
  love.graphics.setScissor(rect.x + 1, rect.y + 1, rect.width - 2, rect.height - 2)
  color({ 1, 1, 1 }); love.graphics.draw(image, origin_x, origin_y, 0, scale, scale)
  if math.min(pitch_x, pitch_y) >= 7 then
    color(COLORS.border, .65); love.graphics.setLineWidth(1)
    for column = 0, sheet.columns do
      local x = origin_x + math.min(column * pitch_x, grid_width)
      love.graphics.line(x, origin_y, x, origin_y + grid_height)
    end
    for row = 0, sheet.rows do
      local y = origin_y + math.min(row * pitch_y, grid_height)
      love.graphics.line(origin_x, y, origin_x + grid_width, y)
    end
  end
  love.graphics.setLineWidth(1); love.graphics.setScissor()
  local details = sheet.columns .. " × " .. sheet.rows .. " TILES  ·  " .. sheet.tile_width .. " × " .. sheet.tile_height .. " PX"
  studio:line(details .. "  ·  WHEEL ZOOMS  ·  RIGHT DRAG PANS", rect.x + 12, rect.y + rect.height - 25, .60, COLORS.muted, rect.width - 24, "center")
end

function Art.draw_pack_sources(studio, middle, pack)
  local sheets = studio:art_sheets(pack)
  local source_width = dock_width(middle.width, .20, 205, 250)
  local sources = { x = middle.x + 14, y = middle.y + 78, width = source_width, height = middle.height - 92 }
  local sheet_rect = { x = sources.x + sources.width + 16, y = sources.y, width = middle.width - sources.width - 44, height = sources.height }
  studio:panel(sources, COLORS.surface); studio:canvas_surface(sheet_rect); studio:dock_title(sources, "SOURCE SHEETS", tostring(#sheets))
  if #sheets == 0 then
    studio:text("This pack does not declare browsable PNG source sheets.", sources.x + 12, sources.y + 44, .72, COLORS.red, sources.width - 24)
    studio:text("The selected pack can still be used by ROAG, but there is no sheet to import into this native project.", sheet_rect.x + 18, sheet_rect.y + 20, .78, COLORS.muted, sheet_rect.width - 36)
    return
  end
  local selected_sheet, selected_index = studio:current_art_sheet(pack)
  local button_y = sources.y + sources.height - 48
  local list_rect = { x = sources.x + 1, y = sources.y + 35, width = sources.width - 2, height = math.max(0, button_y - sources.y - 41) }
  local row_height, max_rows = 31, math.max(1, math.floor(list_rect.height / 31))
  studio.art_source_list_rect, studio.art_source_visible_count, studio.art_source_max_rows = list_rect, #sheets, max_rows
  studio.art_source_scroll = clamp(studio.art_source_scroll or 0, 0, math.max(0, #sheets - max_rows))
  local y = list_rect.y + 3
  for index = studio.art_source_scroll + 1, math.min(#sheets, studio.art_source_scroll + max_rows) do
    local item = sheets[index]
    studio:button({ x = sources.x + 7, y = y, width = sources.width - 14, height = 27 }, item.label, { type = "pack_sheet_source", pack_id = pack.id, index = index }, { selected = index == selected_index })
    y = y + row_height
  end
  studio:button({ x = sources.x + 10, y = button_y, width = sources.width - 20, height = 32 }, "ADD SHEET TO PROJECT", { type = "import_pack_sheet", pack = pack, sheet = selected_sheet }, { enabled = studio.project_manifest ~= nil })
  studio:line("COPIES PNG AS A NATIVE TILESET", sources.x + 10, sources.y + sources.height - 68, .51, COLORS.muted, sources.width - 20, "center")
  studio:line(pack.label .. " / " .. selected_sheet.label, sheet_rect.x + 14, sheet_rect.y + 13, .66, COLORS.text, sheet_rect.width - 28)
  Art.draw_pack_sheet(studio, sheet_rect, selected_sheet)
end

function Art.draw_sheet(studio, rect)
  if not studio.sheet then studio:text("Could not load ROAG sprite sheet:\n" .. tostring(studio.sheet_error), rect.x + 16, rect.y + 20, .78, COLORS.red, rect.width - 32); return end
  local base = math.min((rect.width - 24) / (49 * 16), (rect.height - 48) / (22 * 16))
  local size = base * studio.sheet_zoom; local sheet_width, sheet_height = 49 * size, 22 * size
  local origin_x, origin_y = rect.x + (rect.width - sheet_width) / 2 + studio.sheet_pan_x, rect.y + (rect.height - sheet_height) / 2 + studio.sheet_pan_y
  love.graphics.setScissor(rect.x + 1, rect.y + 1, rect.width - 2, rect.height - 2)
  color({ 1, 1, 1 }); love.graphics.draw(studio.sheet, origin_x, origin_y, 0, size / 16, size / 16)
  local role = studio:current_role(); local tile = studio.data.sprites.sprites[role[1]]
  if tile then color(COLORS.blue); love.graphics.setLineWidth(3); love.graphics.rectangle("line", origin_x + (tile.column - 1) * size, origin_y + (tile.row - 1) * size, size, size) end
  local mx, my = love.mouse.getPosition(); local column, row = math.floor((mx - origin_x) / size) + 1, math.floor((my - origin_y) / size) + 1
  if column >= 1 and column <= 49 and row >= 1 and row <= 22 and inside(mx, my, rect) then
    color(COLORS.gold); love.graphics.setLineWidth(2); love.graphics.rectangle("line", origin_x + (column - 1) * size, origin_y + (row - 1) * size, size, size); studio.sheet_hover = { column = column, row = row }
  else studio.sheet_hover = nil end
  love.graphics.setLineWidth(1); love.graphics.setScissor()
  studio:line(studio.sheet_hover and ("[" .. studio.sheet_hover.column .. ", " .. studio.sheet_hover.row .. "] CLICK TO ASSIGN") or "CLICK TO ASSIGN · WHEEL ZOOMS · RIGHT DRAG PANS", rect.x + 12, rect.y + rect.height - 25, .64, studio.sheet_hover and COLORS.gold or COLORS.muted, rect.width - 24, "center")
  studio.controls[#studio.controls + 1] = { rect = rect, action = { type = "sheet" }, cursor = "picker" }
end

function Art.draw(studio, view)
  studio.role_list_rect, studio.sheet_rect, studio.pack_sheet_rect, studio.art_source_list_rect = nil, nil, nil, nil
  studio.role_visible_count, studio.role_max_rows, studio.art_source_visible_count, studio.art_source_max_rows = 0, 0, 0, 0
  local left = { x = view.body.x, y = view.body.y, width = dock_width(view.body.width, .26, 270, 350), height = view.body.height }
  local middle = { x = left.x + left.width + 16, y = view.body.y, width = view.body.width - left.width - 16, height = view.body.height }
  studio:panel(left); studio:canvas_surface(middle); studio:dock_title(left, "ART PACKS", "LICENSED")
  local packs = studio.data.catalog.art_packs
  for index, pack in ipairs(packs) do
    local selected = pack.id == studio.data.art_pack.art_pack_id
    local row_y = left.y + 43 + (index - 1) * 56
    studio:button({ x = left.x + 10, y = row_y, width = left.width - 20, height = 36 }, pack.label, { type = "pack", index = index }, { selected = selected })
    studio:line(pack.license .. " · " .. pack.credit, left.x + 18, row_y + 39, .54, COLORS.muted, left.width - 36)
  end
  local selected_pack
  for _, pack in ipairs(packs) do if pack.id == studio.data.art_pack.art_pack_id then selected_pack = pack end end
  studio:panel({ x = middle.x + 8, y = middle.y + 8, width = middle.width - 16, height = 58 }, COLORS.surface, COLORS.border)
  studio:line(selected_pack.editable_roles and "SPRITE MAPPING" or "ART SOURCES", middle.x + 18, middle.y + 18, .72, COLORS.text, middle.width - 36)
  studio:line(selected_pack.editable_roles and "ROAG 1-bit mapping — assignments are live." or "Browse this pack's declared source sheets, then add any sheet to the open native project as a tileset.", middle.x + 18, middle.y + 40, .60, selected_pack.editable_roles and COLORS.mint or COLORS.muted, middle.width - 36)
  if not selected_pack.editable_roles then Art.draw_pack_sources(studio, middle, selected_pack); return end
  local roles_rect = { x = middle.x + 14, y = middle.y + 78, width = 224, height = middle.height - 92 }
  local sheet_rect = { x = roles_rect.x + roles_rect.width + 16, y = roles_rect.y, width = middle.width - roles_rect.width - 44, height = roles_rect.height }
  studio:panel(roles_rect, COLORS.surface); studio:canvas_surface(sheet_rect); studio:dock_title(roles_rect, "ROLES", "MAP")
  studio:button({ x = roles_rect.x + 10, y = roles_rect.y + roles_rect.height - 42, width = roles_rect.width - 20, height = 30 }, "UNDO", { type = "undo" }, { enabled = #studio.undo_stack > 0 })
  local visible, y = {}, roles_rect.y + 35
  for index, role in ipairs(Sources.roles) do
    if studio.role_filter == "" or role[1]:find(studio.role_filter:lower(), 1, true) or role[2]:lower():find(studio.role_filter:lower(), 1, true) then visible[#visible + 1] = { source = index, role = role } end
  end
  local max_rows = math.floor((roles_rect.height - 88) / 31)
  studio.role_list_rect = { x = roles_rect.x + 1, y = roles_rect.y + 34, width = roles_rect.width - 2, height = math.max(0, roles_rect.height - 110) }
  studio.role_visible_count, studio.role_max_rows = #visible, max_rows
  studio.scroll = clamp(studio.scroll, 0, math.max(0, #visible - max_rows))
  for local_index = studio.scroll + 1, math.min(#visible, studio.scroll + max_rows) do
    local item = visible[local_index]; local role = item.role; local selected = item.source == studio.selected_role
    local rect = { x = roles_rect.x + 7, y = y, width = roles_rect.width - 14, height = 27 }
    studio:panel(rect, selected and COLORS.selected or COLORS.surface2, selected and COLORS.selected_border or COLORS.border)
    studio:line(role[2], rect.x + 7, rect.y + 5, .73, COLORS.text, rect.width - 56)
    local map = studio.data.sprites.sprites[role[1]]; studio:line(map and (map.column .. "," .. map.row) or "—", rect.x + rect.width - 44, rect.y + 6, .62, COLORS.muted, 36, "right")
    studio.controls[#studio.controls + 1] = { rect = rect, action = { type = "role", index = item.source }, cursor = "action" }
    y = y + 31
  end
  studio:line("F FILTER · WHEEL SCROLL", roles_rect.x + 10, roles_rect.y + roles_rect.height - 66, .58, COLORS.muted, roles_rect.width - 20)
  studio.sheet_rect = sheet_rect
  Art.draw_sheet(studio, sheet_rect)
end

return Art
