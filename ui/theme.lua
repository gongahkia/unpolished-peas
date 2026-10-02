-- Shared visual vocabulary and geometry helpers for every Studio workspace.
-- This module owns no editor state and can be used by focused view modules.
local Theme = {}

Theme.colors = {
  backdrop = { 0.075, 0.078, 0.085 }, canvas = { 0.055, 0.057, 0.062 }, surface = { 0.115, 0.12, 0.13 }, surface2 = { 0.16, 0.165, 0.18 },
  border = { 0.245, 0.25, 0.27 }, text = { 0.88, 0.885, 0.90 }, muted = { 0.57, 0.59, 0.63 },
  blue = { 0.43, 0.68, 0.73 }, mint = { 0.48, 0.73, 0.62 }, gold = { 0.80, 0.66, 0.38 }, red = { 0.75, 0.39, 0.36 }, dark = { 0.045, 0.047, 0.052 },
  selected = { 0.20, 0.30, 0.32 }, selected_border = { 0.45, 0.70, 0.66 }, danger = { 0.28, 0.125, 0.12 },
}

function Theme.color(value, alpha)
  love.graphics.setColor(value[1], value[2], value[3], alpha or value[4] or 1)
end

function Theme.inside(x, y, rect)
  return x >= rect.x and y >= rect.y and x <= rect.x + rect.width and y <= rect.y + rect.height
end

function Theme.clamp(value, minimum, maximum)
  return math.max(minimum, math.min(maximum, value))
end

function Theme.dock_width(available, fraction, minimum, maximum)
  return math.floor(Theme.clamp(available * fraction, minimum, maximum))
end

function Theme.ellipsize(font, value, width)
  value = tostring(value or ""):gsub("[\r\n]", " ")
  if font:getWidth(value) <= width then return value end
  local suffix = "..."
  while #value > 0 and font:getWidth(value .. suffix) > width do value = value:sub(1, -2) end
  return value .. suffix
end

return Theme
