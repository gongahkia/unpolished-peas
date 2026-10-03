-- Native Preview Mode is editor chrome around the UI-independent Runtime.
-- It deliberately does not reuse Scene editor drawing or hit controls: this
-- is a faithful visual runtime preview, not an editable alternate canvas.
local Theme = require("ui.theme")

local Preview = {}
local COLORS, clamp = Theme.colors, Theme.clamp

local function viewport_frame(runtime, viewport)
  local bounds = runtime:visual_bounds()
  if not bounds then return nil end
  local scale = clamp(math.min((viewport.width - 72) / bounds.width, (viewport.height - 72) / bounds.height), .35, 2.5)
  return {
    scale = scale,
    x = viewport.x + viewport.width / 2 - (bounds.x + bounds.width / 2) * scale,
    y = viewport.y + viewport.height / 2 - (bounds.y + bounds.height / 2) * scale,
  }
end

local function warning_text(preview)
  local warnings = preview.warnings or {}
  if #warnings == 0 then return nil end
  local first = warnings[1]
  local suffix = #warnings > 1 and (" · +" .. tostring(#warnings - 1) .. " more") or ""
  return "Preview warning: " .. first.reason .. suffix
end

function Preview.draw(studio, view)
  local preview, runtime = studio.native_preview, studio.native_preview.runtime
  local header = { x = view.body.x, y = view.body.y, width = view.body.width, height = 62 }
  local footer = { x = view.body.x, y = view.body.y + view.body.height - 30, width = view.body.width, height = 30 }
  local viewport = { x = view.body.x, y = header.y + header.height + 8, width = view.body.width, height = footer.y - header.y - header.height - 16 }

  studio:panel(header, COLORS.surface, COLORS.selected_border)
  studio:line("PREVIEW", header.x + 12, header.y + 10, .84, COLORS.mint, 112)
  studio:line("Visual project preview", header.x + 12, header.y + 34, .57, COLORS.muted, 178)
  local stop_width, restart_width = 78, 88
  studio:button({ x = header.x + header.width - stop_width - 10, y = header.y + 16, width = stop_width, height = 30 }, "STOP", { type = "stop_native_preview" }, { danger = true })
  studio:button({ x = header.x + header.width - stop_width - restart_width - 16, y = header.y + 16, width = restart_width, height = 30 }, "RESTART", { type = "restart_native_preview" })
  local identity_width = math.max(130, header.width - 314)
  studio:line("Scene: " .. tostring(runtime.scene_id or "none"), header.x + 205, header.y + 13, .62, COLORS.text, identity_width)
  studio:line("Flow: " .. tostring(preview.flow_id or "none"), header.x + 205, header.y + 34, .54, COLORS.muted, identity_width)

  studio:canvas_surface(viewport)
  if preview.error then
    studio:text("Preview stopped after a runtime error.\n\n" .. tostring(preview.error.reason or preview.error), viewport.x + 24, viewport.y + 28, .76, COLORS.red, viewport.width - 48)
  elseif not runtime.scene then
    studio:text("Preview has no active Scene.", viewport.x + 24, viewport.y + 28, .8, COLORS.red, viewport.width - 48)
  else
    local frame = viewport_frame(runtime, viewport)
    if not frame then
      studio:line("This Scene contains no visual nodes.", viewport.x + 18, viewport.y + math.floor(viewport.height / 2) - 10, .82, COLORS.text, viewport.width - 36, "center")
      studio:line("Add a Panel, Label, or Button in the Scene editor to begin.", viewport.x + 18, viewport.y + math.floor(viewport.height / 2) + 16, .61, COLORS.muted, viewport.width - 36, "center")
    else
      love.graphics.setScissor(viewport.x + 1, viewport.y + 1, viewport.width - 2, viewport.height - 2)
      love.graphics.push()
      love.graphics.translate(frame.x, frame.y)
      love.graphics.scale(frame.scale, frame.scale)
      runtime:draw()
      love.graphics.pop()
      love.graphics.setScissor()
    end
  end

  studio:panel(footer, COLORS.dark, COLORS.border)
  local warning = warning_text(preview)
  local message = warning and (warning .. " · Visual input only · Esc stops") or "Visual preview · runtime input is not simulated yet · Esc stops"
  studio:line(message, footer.x + 10, footer.y + 8, .57, warning and COLORS.gold or COLORS.mint, footer.width - 20)
end

return Preview
