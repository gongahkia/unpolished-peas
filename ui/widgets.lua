-- Stateful drawing primitives installed on Studio. Keeping them together
-- prevents individual views from inventing subtly different controls.
local Theme = require("ui.theme")
local COLORS = Theme.colors

local Widgets = {}

function Widgets.install(Studio)
  function Studio:font(scale)
    if scale >= 2 then return self.fonts.title end
    if scale >= 1.25 then return self.fonts.large end
    if scale < .86 then return self.fonts.small end
    return self.fonts.normal
  end

  function Studio:text(value, x, y, scale, tint, width, align)
    love.graphics.setFont(self:font(scale or 1)); Theme.color(tint or COLORS.text)
    if width then love.graphics.printf(tostring(value), x, y, width, align or "left") else love.graphics.print(tostring(value), x, y) end
  end

  -- Labels inside compact controls are always single-line so they cannot
  -- visually escape their associated hit target.
  function Studio:line(value, x, y, scale, tint, width, align)
    local font = self:font(scale or 1)
    love.graphics.setFont(font); Theme.color(tint or COLORS.text)
    if width then love.graphics.printf(Theme.ellipsize(font, value, width), x, y, width, align or "left") else love.graphics.print(tostring(value), x, y) end
  end

  function Studio:panel(rect, fill, outline)
    Theme.color(fill or COLORS.surface); love.graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height, 3, 3)
    Theme.color(outline or COLORS.border); love.graphics.setLineWidth(1); love.graphics.rectangle("line", rect.x + .5, rect.y + .5, rect.width - 1, rect.height - 1, 3, 3)
  end

  function Studio:canvas_surface(rect)
    Theme.color(COLORS.canvas); love.graphics.rectangle("fill", rect.x, rect.y, rect.width, rect.height, 3, 3)
    love.graphics.setScissor(rect.x + 1, rect.y + 1, rect.width - 2, rect.height - 2)
    Theme.color({ .09, .093, .10 }, .55)
    for x = rect.x - (rect.x % 16), rect.x + rect.width, 16 do love.graphics.line(x, rect.y, x, rect.y + rect.height) end
    for y = rect.y - (rect.y % 16), rect.y + rect.height, 16 do love.graphics.line(rect.x, y, rect.x + rect.width, y) end
    love.graphics.setScissor()
    Theme.color(COLORS.border); love.graphics.rectangle("line", rect.x + .5, rect.y + .5, rect.width - 1, rect.height - 1, 3, 3)
  end

  function Studio:button(rect, label, action, options)
    options = options or {}; self.controls[#self.controls + 1] = { rect = rect, action = action, enabled = options.enabled ~= false, cursor = options.cursor or "action" }
    local selected = options.selected == true
    local enabled = options.enabled ~= false
    local fill, outline, tint = COLORS.surface2, COLORS.border, COLORS.text
    if options.danger then fill, outline, tint = COLORS.danger, COLORS.red, COLORS.text
    elseif selected then fill, outline, tint = COLORS.selected, COLORS.selected_border, COLORS.text end
    if not enabled then fill, outline, tint = COLORS.surface, COLORS.border, COLORS.muted end
    self:panel(rect, fill, outline)
    local font = self:font(.78)
    local text_y = rect.y + math.floor((rect.height - font:getHeight()) / 2) - 1
    self:line(label, rect.x + 8, text_y, .78, tint, rect.width - 16, "center")
  end

  function Studio:field(rect, label, kind, field)
    local focused = self.active and self.active.kind == kind and self.active.field == field
    self:panel(rect, focused and COLORS.selected or COLORS.surface2, focused and COLORS.selected_border or COLORS.border)
    self:line(label, rect.x + 12, rect.y + 7, .68, COLORS.muted, rect.width - 24)
    local value = focused and self.draft or (kind == "screen" and self:current_screen()[field] or self:current_action()[field])
    local font, visible = self:font(.88), Theme.ellipsize(self:font(.88), value, rect.width - 24)
    self:line(visible, rect.x + 12, rect.y + 27, .88, focused and COLORS.gold or COLORS.text, rect.width - 24)
    if focused then self:text("|", rect.x + 13 + math.min(font:getWidth(visible), rect.width - 30), rect.y + 27, .88, COLORS.blue) end
    self.controls[#self.controls + 1] = { rect = rect, action = { type = "field", kind = kind, field = field }, cursor = "text" }
  end

  function Studio:native_field(rect, label, target, field, value_type)
    local focused = self.active and self.active.kind == "native_field" and self.active.target == target and self.active.field == field
    self:panel(rect, focused and COLORS.selected or COLORS.surface2, focused and COLORS.selected_border or COLORS.border)
    self:line(label, rect.x + 10, rect.y + 5, .58, COLORS.muted, rect.width - 20)
    local value = focused and self.draft or tostring(target[field] == nil and "" or target[field])
    local font, visible = self:font(.72), Theme.ellipsize(self:font(.72), value, rect.width - 20)
    self:line(visible, rect.x + 10, rect.y + 21, .72, focused and COLORS.gold or COLORS.text, rect.width - 20)
    if focused then self:text("|", rect.x + 11 + math.min(font:getWidth(visible), rect.width - 26), rect.y + 21, .72, COLORS.blue) end
    self.controls[#self.controls + 1] = { rect = rect, action = { type = "native_field", target = target, field = field, value_type = value_type }, cursor = "text" }
  end

  function Studio:project_path_field(rect)
    local focused = self.active and self.active.kind == "project_path"
    self:panel(rect, focused and COLORS.selected or COLORS.surface2, focused and COLORS.selected_border or COLORS.border)
    self:line("PROJECT FOLDER OR MANIFEST PATH", rect.x + 10, rect.y + 3, .58, COLORS.muted, rect.width - 20)
    local value = focused and self.draft or self.project_root or ""
    if focused and value == "" then value = "Paste a folder or manifest path" end
    local font, visible = self:font(.72), Theme.ellipsize(self:font(.72), value, rect.width - 20)
    local value_tint = focused and (self.draft == "" and COLORS.muted or COLORS.gold) or COLORS.text
    self:line(visible, rect.x + 10, rect.y + 16, .72, value_tint, rect.width - 20)
    if focused then self:text("|", rect.x + 11 + math.min(font:getWidth(self.draft), rect.width - 26), rect.y + 16, .72, COLORS.blue) end
    self.controls[#self.controls + 1] = { rect = rect, action = { type = "project_path" }, cursor = "text" }
  end

  function Studio:dock_title(rect, title, detail)
    self:line(title, rect.x + 12, rect.y + 10, .64, COLORS.muted, rect.width - 24)
    if detail then self:line(detail, rect.x + 12, rect.y + 10, .56, COLORS.muted, rect.width - 24, "right") end
    Theme.color(COLORS.border); love.graphics.line(rect.x + 1, rect.y + 31.5, rect.x + rect.width - 1, rect.y + 31.5)
  end

  function Studio:status_mark(x, y, tint)
    Theme.color(tint or COLORS.mint); love.graphics.setLineWidth(2)
    love.graphics.line(x, y + 5, x + 4, y + 9, x + 11, y + 1)
    love.graphics.setLineWidth(1)
  end
end

return Widgets
