-- ROAG presentation editing views. They render only declared presentation
-- data; Studio retains validation, history, and publishing actions.
local Theme = require("ui.theme")
local COLORS = Theme.colors
local dock_width = Theme.dock_width

local Presentation = {}

function Presentation.draw_scenes(studio, view)
  local list = { x = view.body.x, y = view.body.y, width = dock_width(view.body.width, .23, 246, 320), height = view.body.height }
  local edit = { x = list.x + list.width + 16, y = view.body.y, width = view.body.width - list.width - 16, height = view.body.height }
  studio:panel(list); studio:canvas_surface(edit); studio:dock_title(list, "SCENES", "ORDER")
  for index, screen in ipairs(studio.data.screens.screens) do
    local selected = index == studio.selected_screen; local rect = { x = list.x + 10, y = list.y + 44 + (index - 1) * 47, width = list.width - 20, height = 39 }
    studio:panel(rect, selected and COLORS.selected or COLORS.surface2, selected and COLORS.selected_border or COLORS.border)
    studio:line(screen.title, rect.x + 8, rect.y + 6, .8, COLORS.text, rect.width - 16); studio:line(screen.id .. " · " .. screen.layout, rect.x + 8, rect.y + 23, .57, COLORS.muted, rect.width - 16)
    studio.controls[#studio.controls + 1] = { rect = rect, action = { type = "screen", index = index }, cursor = "action" }
  end
  studio:button({ x = list.x + 10, y = list.y + list.height - 86, width = (list.width - 28) / 2, height = 32 }, "MOVE UP", { type = "screen_move", delta = -1 }, { enabled = studio.selected_screen > 1 })
  studio:button({ x = list.x + list.width / 2 + 4, y = list.y + list.height - 86, width = (list.width - 28) / 2, height = 32 }, "MOVE DOWN", { type = "screen_move", delta = 1 }, { enabled = studio.selected_screen < #studio.data.screens.screens })
  studio:text("Ordering is editor/inspection order; ROAG’s safe runtime behavior stays in App.", list.x + 12, list.y + list.height - 46, .57, COLORS.muted, list.width - 24)
  local screen = studio:current_screen(); studio:panel({ x = edit.x + 8, y = edit.y + 8, width = edit.width - 16, height = 62 }, COLORS.surface, COLORS.border)
  studio:line(screen.id:upper(), edit.x + 18, edit.y + 19, .84, COLORS.text, edit.width - 36); studio:line("Validated presentation copy and visual tokens", edit.x + 18, edit.y + 44, .60, COLORS.muted, edit.width - 36)
  studio:field({ x = edit.x + 18, y = edit.y + 82, width = edit.width - 36, height = 60 }, "TITLE", "screen", "title")
  studio:field({ x = edit.x + 18, y = edit.y + 151, width = edit.width - 36, height = 60 }, "SUBTITLE", "screen", "subtitle")
  studio:field({ x = edit.x + 18, y = edit.y + 220, width = edit.width - 36, height = 60 }, "FOOTER", "screen", "footer")
  studio:button({ x = edit.x + 18, y = edit.y + 303, width = 215, height = 36 }, "LAYOUT: " .. screen.layout:upper(), { type = "cycle_layout" })
  studio:button({ x = edit.x + 245, y = edit.y + 303, width = 215, height = 36 }, "ACCENT: " .. screen.accent:upper(), { type = "cycle_accent" })
  local preview = { x = edit.x + 18, y = edit.y + 367, width = edit.width - 36, height = edit.height - 385 }; studio:canvas_surface(preview)
  studio:text(screen.title, preview.x + 24, preview.y + 24, 1.5, COLORS[screen.accent] or COLORS.blue, preview.width - 48, "center")
  studio:text(screen.subtitle, preview.x + 24, preview.y + 66, .76, COLORS.muted, preview.width - 48, "center")
  studio:panel({ x = preview.x + preview.width * .16, y = preview.y + 118, width = preview.width * .68, height = 44 }, COLORS.surface2, COLORS[screen.accent] or COLORS.blue)
  studio:text("LIVE SCREEN PREVIEW", preview.x + 24, preview.y + 132, .8, COLORS.gold, preview.width - 48, "center")
  studio:text(screen.footer, preview.x + 24, preview.y + preview.height - 33, .72, COLORS.muted, preview.width - 48, "center")
end

function Presentation.draw_flow(studio, view)
  local list = { x = view.body.x, y = view.body.y, width = dock_width(view.body.width, .28, 280, 370), height = view.body.height }
  local edit = { x = list.x + list.width + 16, y = view.body.y, width = view.body.width - list.width - 16, height = view.body.height }
  studio:panel(list); studio:canvas_surface(edit); studio:dock_title(list, "TITLE FLOW", "SAFE")
  studio:text("Order determines what the player sees. Targets are fixed safe actions.", list.x + 14, list.y + 39, .66, COLORS.muted, list.width - 28)
  for index, action in ipairs(studio.data.flow.title_actions) do
    local selected = index == studio.selected_action; local rect = { x = list.x + 10, y = list.y + 75 + (index - 1) * 64, width = list.width - 20, height = 55 }
    studio:panel(rect, selected and COLORS.selected or COLORS.surface2, selected and COLORS.selected_border or COLORS.border)
    studio:line((index .. ". ") .. action.label, rect.x + 10, rect.y + 7, .82, COLORS.text, rect.width - 20); studio:line("> " .. action.target, rect.x + 10, rect.y + 29, .63, COLORS.muted, rect.width - 20)
    studio.controls[#studio.controls + 1] = { rect = rect, action = { type = "action", index = index }, cursor = "action" }
  end
  studio:button({ x = list.x + 10, y = list.y + list.height - 44, width = (list.width - 28) / 2, height = 32 }, "MOVE UP", { type = "action_move", delta = -1 }, { enabled = studio.selected_action > 1 })
  studio:button({ x = list.x + list.width / 2 + 4, y = list.y + list.height - 44, width = (list.width - 28) / 2, height = 32 }, "MOVE DOWN", { type = "action_move", delta = 1 }, { enabled = studio.selected_action < #studio.data.flow.title_actions })
  local action = studio:current_action(); studio:panel({ x = edit.x + 8, y = edit.y + 8, width = edit.width - 16, height = 62 }, COLORS.surface, COLORS.border)
  studio:line(action.id:upper(), edit.x + 18, edit.y + 19, .84, COLORS.text, edit.width - 36); studio:line("Declared target: " .. action.target .. " (game behavior is not scriptable here)", edit.x + 18, edit.y + 44, .60, COLORS.muted, edit.width - 36)
  studio:field({ x = edit.x + 18, y = edit.y + 88, width = edit.width - 36, height = 60 }, "VISIBLE LABEL", "action", "label")
  studio:field({ x = edit.x + 18, y = edit.y + 157, width = edit.width - 36, height = 60 }, "HELPER DESCRIPTION", "action", "description")
  local flow = { x = edit.x + 18, y = edit.y + 248, width = edit.width - 36, height = 175 }; studio:canvas_surface(flow)
  studio:line("SAFE NAVIGATION", flow.x + 16, flow.y + 15, .62, COLORS.muted, flow.width - 32); studio:line("TITLE", flow.x + 20, flow.y + 66, 1.0, COLORS.text, flow.width * .30)
  studio:line(">", flow.x + flow.width * .38, flow.y + 68, 1.0, COLORS.muted); studio:line(action.target:upper(), flow.x + flow.width * .48, flow.y + 66, 1.0, COLORS.mint, flow.width * .42)
  studio:text("The editor can change the display order and copy. It cannot fabricate a new gameplay transition or invoke Lua callbacks.", flow.x + 16, flow.y + 119, .67, COLORS.muted, flow.width - 32)
end

function Presentation.draw_publish(studio, view)
  studio:canvas_surface(view.body); studio:line("VALIDATE, THEN PUBLISH", view.body.x + 20, view.body.y + 20, 1.18, COLORS.text, view.body.width - 40)
  studio:text("A publish operation validates every document before it writes. It uses verified atomic replacement on four explicit paths only.", view.body.x + 20, view.body.y + 49, .75, COLORS.muted, math.min(view.body.width - 40, 760))
  local files = { "content/screens/legacy.json", "content/presentation/flow.json", "content/presentation/art_pack.json", "sprite_editor/mappings.json" }
  for index, path in ipairs(files) do
    local y = view.body.y + 125 + (index - 1) * 56
    studio:panel({ x = view.body.x + 24, y = y, width = view.body.width - 48, height = 42 }, COLORS.surface2, COLORS.border)
    studio:status_mark(view.body.x + 38, y + 13); studio:line(path, view.body.x + 68, y + 12, .8, COLORS.text, view.body.width - 104)
  end
  studio:button({ x = view.body.x + 24, y = view.body.y + 386, width = 228, height = 48 }, studio.dirty and "PUBLISH CHANGES" or "VALIDATE & PUBLISH", { type = "save" }, { selected = studio.dirty })
  studio:text("Not writable: active_run.json, meta_profile.json, fallen_characters.json, simulation source, route content, boss content, or any world/persistence data.", view.body.x + 24, view.body.y + 456, .7, COLORS.muted, view.body.width - 48)
end

return Presentation
