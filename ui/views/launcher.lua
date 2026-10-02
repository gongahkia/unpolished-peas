-- Welcome and project-launcher surfaces. Project switching itself remains in
-- Studio so the unsaved-change policy stays centralized.
local Theme = require("ui.theme")
local COLORS = Theme.colors

local Launcher = {}

function Launcher.draw_home(studio, view)
  studio:canvas_surface(view.body)
  studio:line("WORKSPACE OVERVIEW", view.body.x + 20, view.body.y + 20, 1.18, COLORS.text, view.body.width - 40)
  studio:text("Author the declared presentation layer without loading, changing, or depending on a live run, account profile, archive, route, or simulation.", view.body.x + 20, view.body.y + 49, .78, COLORS.muted, math.min(view.body.width - 40, 820))
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
    local gap, card_width = 14, math.min(390, (view.body.width - 54) / 2)
    local rect = { x = view.body.x + 20 + column * (card_width + gap), y = view.body.y + 112 + row * 146, width = card_width, height = 128 }
    studio:panel(rect, COLORS.surface, card[4]); studio:line(card[1], rect.x + 12, rect.y + 13, .82, COLORS.text, rect.width - 24)
    studio:text(card[2], rect.x + 12, rect.y + 39, .68, COLORS.muted, rect.width - 24)
    studio:button({ x = rect.x + 12, y = rect.y + 88, width = 90, height = 26 }, "OPEN", { type = "tab", tab = card[3] })
  end
end

function Launcher.draw_projects(studio, view)
  studio:canvas_surface(view.body)
  studio:line("PROJECT LAUNCHER", view.body.x + 20, view.body.y + 20, 1.18, COLORS.text, view.body.width - 40)
  studio:text("Open an Unpolished Bees project by folder or manifest. Recent projects are stored in this editor’s local settings, not in your game data.", view.body.x + 20, view.body.y + 49, .75, COLORS.muted, math.min(view.body.width - 40, 760))
  local current = { x = view.body.x + 20, y = view.body.y + 85, width = math.min(760, view.body.width - 40), height = 138 }
  studio:panel(current, COLORS.surface, COLORS.border)
  local name = studio.project_manifest and studio.project_manifest.name or "NO PROJECT OPEN"
  studio:line(name, current.x + 14, current.y + 14, .90, COLORS.text, current.width - 28)
  studio:line(studio.project_manifest and "CURRENT PROJECT" or "SELECT A PROJECT TO BEGIN", current.x + 14, current.y + 37, .58, studio.project_manifest and COLORS.mint or COLORS.gold, current.width - 28)
  studio:button({ x = current.x + 14, y = current.y + 61, width = 142, height = 34 }, "OPEN FOLDER", { type = "choose_project", kind = "folder" })
  studio:button({ x = current.x + 164, y = current.y + 61, width = 168, height = 34 }, "CHOOSE MANIFEST", { type = "choose_project", kind = "manifest" })
  studio:button({ x = current.x + 340, y = current.y + 61, width = 116, height = 34 }, "PASTE PATH", { type = "project_path" })
  studio:project_path_field({ x = current.x + 14, y = current.y + 102, width = current.width - 28, height = 30 })
  local recent_y = current.y + current.height + 24
  studio:line("RECENT PROJECTS", view.body.x + 20, recent_y, .72, COLORS.muted, view.body.width - 40)
  if #studio.recent_projects == 0 then
    studio:text("No recent projects yet. Choose a folder or manifest above.", view.body.x + 20, recent_y + 28, .72, COLORS.muted, view.body.width - 40)
    return
  end
  local columns = view.body.width >= 820 and 2 or 1
  local gap = 12
  local card_width = math.min(420, (view.body.width - 40 - gap * (columns - 1)) / columns)
  for index, entry in ipairs(studio.recent_projects) do
    local column, row = (index - 1) % columns, math.floor((index - 1) / columns)
    local rect = { x = view.body.x + 20 + column * (card_width + gap), y = recent_y + 27 + row * 62, width = card_width, height = 52 }
    local selected = entry.path == studio.project_root
    studio:panel(rect, selected and COLORS.selected or COLORS.surface, selected and COLORS.selected_border or COLORS.border)
    studio:line(entry.name, rect.x + 10, rect.y + 8, .76, COLORS.text, rect.width - 20)
    studio:line(entry.path, rect.x + 10, rect.y + 28, .56, COLORS.muted, rect.width - 20)
    studio.controls[#studio.controls + 1] = { rect = rect, action = { type = "open_recent_project", path = entry.path }, cursor = "action" }
  end
end

return Launcher
