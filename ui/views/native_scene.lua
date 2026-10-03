-- Scene-specific rendering and viewport interaction for the shared native
-- workspace. It deliberately owns only presentation and transient geometry;
-- core.scene remains the authority for tree mutations and validity.
local Scene = require("core.scene")
local NativeWorkspace = require("ui.native_workspace")
local Theme = require("ui.theme")

local SceneView = {}
local COLORS, clamp = Theme.colors, Theme.clamp

local function number(value, fallback)
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge and value or fallback
end

function SceneView.is_movable(node)
  return node and (node.type == "panel" or node.type == "label" or node.type == "button")
end

function SceneView.is_resizable(node)
  return node and (node.type == "panel" or node.type == "button")
end

function SceneView.bounds(node)
  local properties = node.properties or {}
  local width = number(properties.width, node.type == "label" and 220 or 150)
  local height = number(properties.height, node.type == "label" and 28 or 42)
  return {
    x = number(properties.x, 0),
    y = number(properties.y, 0),
    width = width,
    height = height,
  }
end

local function content_bounds(scene)
  local left, top, right, bottom
  Scene.each(scene, function(node)
    if node.type ~= "scene" then
      local rect = SceneView.bounds(node)
      left = not left and rect.x or math.min(left, rect.x)
      top = not top and rect.y or math.min(top, rect.y)
      right = not right and rect.x + rect.width or math.max(right, rect.x + rect.width)
      bottom = not bottom and rect.y + rect.height or math.max(bottom, rect.y + rect.height)
    end
  end)
  return left and { x = left, y = top, width = math.max(1, right - left), height = math.max(1, bottom - top) } or nil
end

function SceneView.reset(studio)
  studio.scene_zoom, studio.scene_pan_x, studio.scene_pan_y = 1, 0, 0
  studio.scene_view_needs_frame = true
  studio.scene_viewport = nil
end

local function ensure_viewport(studio, canvas)
  if not studio.scene_view_needs_frame then return end
  local bounds = content_bounds(studio.native_asset_data)
  local zoom, pan_x, pan_y = 1, 0, 0
  if bounds then
    zoom = clamp(math.min((canvas.width - 64) / bounds.width, (canvas.height - 64) / bounds.height), .45, 1.5)
    pan_x = canvas.width / 2 - (bounds.x + bounds.width / 2) * zoom
    pan_y = canvas.height / 2 - (bounds.y + bounds.height / 2) * zoom
  else
    -- The empty state is centred independently, but keeping logical origin in
    -- view makes the first newly created node immediately visible.
    pan_x, pan_y = 40, 40
  end
  studio.scene_zoom, studio.scene_pan_x, studio.scene_pan_y = zoom, pan_x, pan_y
  studio.scene_view_needs_frame = false
end

local function screen_rect(studio, canvas, node)
  local bounds, zoom = SceneView.bounds(node), studio.scene_zoom or 1
  return {
    x = canvas.x + (studio.scene_pan_x or 0) + bounds.x * zoom,
    y = canvas.y + (studio.scene_pan_y or 0) + bounds.y * zoom,
    width = bounds.width * zoom,
    height = bounds.height * zoom,
  }
end

function SceneView.zoom_at(studio, x, y, amount)
  local canvas = studio.scene_viewport
  if not canvas or x < canvas.x or y < canvas.y or x > canvas.x + canvas.width or y > canvas.y + canvas.height then return false end
  local old_zoom = studio.scene_zoom or 1
  local world_x = (x - canvas.x - (studio.scene_pan_x or 0)) / old_zoom
  local world_y = (y - canvas.y - (studio.scene_pan_y or 0)) / old_zoom
  local zoom = clamp(old_zoom * (1.14 ^ amount), .35, 2.5)
  studio.scene_zoom = zoom
  studio.scene_pan_x = x - canvas.x - world_x * zoom
  studio.scene_pan_y = y - canvas.y - world_y * zoom
  return true
end

local function tree_row(studio, pane, node, depth, y, source)
  local available, reason = true, nil
  if source then available, reason = Scene.can_reparent(studio.native_asset_data, source.id, node.id) end
  local rect = { x = pane.x + 6, y = y, width = pane.width - 12, height = 23 }
  local selected = node == studio.native_selected_node
  local fill = selected and COLORS.selected or COLORS.surface2
  if source and not available then fill = COLORS.surface end
  studio:panel(rect, fill, selected and COLORS.selected_border or COLORS.border)
  local indent = math.min(depth * 10, math.max(0, rect.width - 66))
  local type_label = node.type == "scene" and "ROOT" or node.type:upper()
  studio:line(node.id:gsub("^node%.", ""), rect.x + 6 + indent, rect.y + 5, .55, source and not available and COLORS.muted or COLORS.text, rect.width - indent - 45)
  studio:line(type_label, rect.x + 5, rect.y + 6, .46, source and not available and COLORS.muted or COLORS.gold, rect.width - 10, "right")
  if available then
    studio.controls[#studio.controls + 1] = {
      rect = rect,
      action = { type = source and "native_reparent_here" or "native_node", node = node },
      cursor = "action",
    }
  elseif reason then
    studio.controls[#studio.controls + 1] = { rect = rect, action = { type = "scene_reparent_unavailable", reason = reason }, enabled = false }
  end
end

local function draw_tree(studio, panes, scene)
  local source = studio.native_reparent_source
  studio:dock_title(panes.left, source and "REPARENTING" or "SCENE TREE", source and "ACTIVE" or nil)
  local row, start_y = 0, panes.left.y + (source and 62 or 37)
  if source then
    studio:line(source.id:gsub("^node%.", ""), panes.left.x + 9, panes.left.y + 38, .52, COLORS.gold, panes.left.width - 18)
  end
  local maximum = math.floor((panes.left.y + panes.left.height - start_y - 5) / 27)
  local function visit(node, depth)
    if row >= maximum then return end
    tree_row(studio, panes.left, node, depth, start_y + row * 27, source)
    row = row + 1
    for _, child in ipairs(node.children or {}) do visit(child, depth + 1) end
  end
  visit(scene.root, 0)
end

local function draw_node(studio, canvas, node, controls)
  if node.type ~= "scene" then
    local rect, properties = screen_rect(studio, canvas, node), node.properties or {}
    if node.type == "panel" then
      studio:panel(rect, properties.color or { .12, .19, .25, 1 }, COLORS.border)
    elseif node.type == "label" then
      studio:text(properties.text or node.id, rect.x, rect.y + math.max(3, math.floor(4 * (studio.scene_zoom or 1))), .9, COLORS.text, rect.width)
    elseif node.type == "button" then
      studio:panel(rect, COLORS.surface2, COLORS.border)
      studio:line(properties.text or node.id, rect.x + 8, rect.y + math.floor(rect.height / 2 - 8), .74, COLORS.text, rect.width - 16, "center")
    else
      studio:panel(rect, COLORS.surface2, COLORS.border)
      studio:line(node.type:upper(), rect.x + 7, rect.y + 7, .58, COLORS.muted, rect.width - 14)
    end
    controls[#controls + 1] = { rect = rect, action = { type = "native_node", node = node, movable = SceneView.is_movable(node) }, cursor = "action" }
  end
  for _, child in ipairs(node.children or {}) do draw_node(studio, canvas, child, controls) end
end

local function draw_selected_outline(studio, canvas, node)
  if not node or node.type == "scene" then return end
  local rect = screen_rect(studio, canvas, node)
  Theme.color(COLORS.mint); love.graphics.setLineWidth(2)
  love.graphics.rectangle("line", rect.x + 1, rect.y + 1, math.max(0, rect.width - 2), math.max(0, rect.height - 2), 2, 2)
  if SceneView.is_resizable(node) then
    local handle = { x = rect.x + rect.width - 7, y = rect.y + rect.height - 7, width = 12, height = 12 }
    Theme.color(COLORS.mint); love.graphics.rectangle("fill", handle.x, handle.y, handle.width, handle.height, 2, 2)
    studio.controls[#studio.controls + 1] = { rect = handle, action = { type = "native_scene_resize", node = node }, cursor = "action" }
  end
  love.graphics.setLineWidth(1)
end

local function draw_canvas(studio, panes, scene)
  local canvas = panes.center
  studio:canvas_surface(canvas)
  ensure_viewport(studio, canvas)
  studio.scene_viewport = canvas
  local controls = {}
  love.graphics.setScissor(canvas.x + 1, canvas.y + 1, canvas.width - 2, canvas.height - 2)
  draw_node(studio, canvas, scene.root, controls)
  -- Later controls win the reverse hit-test in Studio, so register ordinary
  -- node selection before the selected-node resize handle.
  for _, control in ipairs(controls) do studio.controls[#studio.controls + 1] = control end
  draw_selected_outline(studio, canvas, studio.native_selected_node)
  if #(scene.root.children or {}) == 0 then
    studio:line("This scene is empty.", canvas.x + 18, canvas.y + math.floor(canvas.height / 2) - 18, .9, COLORS.text, canvas.width - 36, "center")
    studio:line("Add a Panel, Label, or Button to begin.", canvas.x + 18, canvas.y + math.floor(canvas.height / 2) + 8, .66, COLORS.muted, canvas.width - 36, "center")
  end
  love.graphics.setScissor()
end

local function section(studio, rect, y, label)
  studio:line(label, rect.x + 8, y, .51, COLORS.muted, rect.width - 16)
  return y + 14
end

local function inspector(studio, panes, scene)
  local rect, node = panes.right, studio.native_selected_node
  studio:panel(rect, COLORS.surface, COLORS.border)
  studio:dock_title(rect, "INSPECTOR", node and node.type:upper() or nil)
  if not node then
    studio:text("Select a scene node to inspect it.", rect.x + 10, rect.y + 44, .67, COLORS.muted, rect.width - 20)
    return
  end
  studio:line(node.id, rect.x + 9, rect.y + 39, .62, COLORS.gold, rect.width - 18)
  local x, width, y = rect.x + 8, rect.width - 16, rect.y + 59
  if node == scene.root then
    studio:line("SCENE ROOT", x, y, .57, COLORS.muted, width)
    studio:line("Contains " .. tostring(#(node.children or {})) .. " node" .. (#(node.children or {}) == 1 and "" or "s") .. ".", x, y + 22, .68, COLORS.text, width)
    if studio:current_native_asset().id ~= studio.project_manifest.main_scene_id then
      studio:button({ x = x, y = y + 54, width = width, height = 30 }, "SET AS MAIN", { type = "set_main_scene" })
    end
    return
  end
  node.properties = node.properties or {}
  local properties = node.properties
  if SceneView.is_movable(node) then
    y = section(studio, rect, y, "TRANSFORM")
    studio:native_field({ x = x, y = y, width = width, height = 30 }, "X", properties, "x", "number"); y = y + 34
    studio:native_field({ x = x, y = y, width = width, height = 30 }, "Y", properties, "y", "number"); y = y + 34
    if SceneView.is_resizable(node) then
      studio:native_field({ x = x, y = y, width = width, height = 30 }, "WIDTH", properties, "width", "number"); y = y + 34
      studio:native_field({ x = x, y = y, width = width, height = 30 }, "HEIGHT", properties, "height", "number"); y = y + 34
    end
  else
    studio:text("This schema-supported node is preserved read-only by the visual editor.", x, y + 4, .62, COLORS.muted, width)
    return
  end
  if node.type == "label" or node.type == "button" then
    y = section(studio, rect, y + 2, "CONTENT")
    studio:native_field({ x = x, y = y, width = width, height = 30 }, "TEXT", properties, "text", "text"); y = y + 36
  elseif node.type == "panel" and properties.color then
    y = section(studio, rect, y + 2, "APPEARANCE")
    local color = properties.color
    studio:line(string.format("Color  %.2f  %.2f  %.2f  %.2f", number(color[1], 0), number(color[2], 0), number(color[3], 0), number(color[4], 1)), x, y, .54, COLORS.muted, width)
    y = y + 19
  end
  local position = Scene.sibling_position(scene, node.id)
  if position then
    y = section(studio, rect, y + 2, "ARRANGE")
    local half = math.floor((width - 5) / 2)
    studio:button({ x = x, y = y, width = half, height = 28 }, "MOVE UP", { type = "move_scene_node", direction = -1 }, { enabled = position.index > 1 })
    studio:button({ x = x + half + 5, y = y, width = width - half - 5, height = 28 }, "MOVE DOWN", { type = "move_scene_node", direction = 1 }, { enabled = position.index < #(position.node.children or {}) })
    y = y + 34
  end
  studio:button({ x = x, y = y, width = width, height = 30 }, "DELETE NODE", { type = "delete_native_node" }, { danger = true })
end

function SceneView.draw(studio, workspace)
  local scene = studio.native_asset_data
  local panes = NativeWorkspace.three_columns(workspace.body)
  studio:panel(panes.left, COLORS.surface, COLORS.border)
  draw_tree(studio, panes, scene)
  draw_canvas(studio, panes, scene)
  inspector(studio, panes, scene)
  local source = studio.native_reparent_source
  local message = source and ('Reparenting "' .. source.id:gsub("^node%.", "") .. '" · select a new parent · Esc cancels') or "Select a node · drag visual nodes to move · wheel zooms · right-drag pans"
  studio:draw_native_footer(workspace, message, source and COLORS.gold or COLORS.mint)
end

return SceneView
