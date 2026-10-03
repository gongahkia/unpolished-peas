-- Shared, deliberately small geometry vocabulary for native asset editors.
-- It owns rectangles only; Studio and the domain modules continue to own all
-- controls, mutations, and persistence behavior.
local NativeWorkspace = {}

local GAP = 8

local function rectangle(x, y, width, height)
  return { x = x, y = y, width = math.max(0, width), height = math.max(0, height) }
end

function NativeWorkspace.layout(bounds)
  local header_height, toolbar_height, footer_height = 56, 76, 28
  local header = rectangle(bounds.x, bounds.y, bounds.width, header_height)
  local toolbar = rectangle(bounds.x, header.y + header.height + GAP, bounds.width, toolbar_height)
  local footer_y = bounds.y + bounds.height - footer_height
  local footer = rectangle(bounds.x, footer_y, bounds.width, footer_height)
  local body_y = toolbar.y + toolbar.height + GAP
  return {
    bounds = bounds,
    header = header,
    toolbar = toolbar,
    body = rectangle(bounds.x, body_y, bounds.width, footer.y - GAP - body_y),
    footer = footer,
  }
end

-- Three-pane editors keep a useful central workspace at the declared minimum
-- window size by reducing secondary panes before constraining the canvas.
function NativeWorkspace.three_columns(body)
  local left = math.max(118, math.min(190, math.floor(body.width * .205)))
  local right = math.max(158, math.min(260, math.floor(body.width * .285)))
  local center = body.width - left - right - GAP * 2
  if center < 180 then
    local shortage = 180 - center
    local right_reduction = math.min(shortage, math.max(0, right - 146))
    right, shortage = right - right_reduction, shortage - right_reduction
    left = left - math.min(shortage, math.max(0, left - 108))
  end
  center = body.width - left - right - GAP * 2
  local left_rect = rectangle(body.x, body.y, left, body.height)
  local center_rect = rectangle(left_rect.x + left_rect.width + GAP, body.y, center, body.height)
  return {
    left = left_rect,
    center = center_rect,
    right = rectangle(center_rect.x + center_rect.width + GAP, body.y, right, body.height),
  }
end

function NativeWorkspace.editor_with_inspector(body)
  local right = math.max(158, math.min(260, math.floor(body.width * .285)))
  local center = body.width - right - GAP
  if center < 220 then right, center = math.max(146, body.width - GAP - 220), 220 end
  local center_rect = rectangle(body.x, body.y, center, body.height)
  return {
    center = center_rect,
    right = rectangle(center_rect.x + center_rect.width + GAP, body.y, right, body.height),
  }
end

function NativeWorkspace.settings_and_editor(body)
  local left = math.max(170, math.min(260, math.floor(body.width * .30)))
  local center = body.width - left - GAP
  if center < 200 then left, center = math.max(146, body.width - GAP - 200), 200 end
  local left_rect = rectangle(body.x, body.y, left, body.height)
  return {
    left = left_rect,
    center = rectangle(left_rect.x + left_rect.width + GAP, body.y, center, body.height),
  }
end

return NativeWorkspace
