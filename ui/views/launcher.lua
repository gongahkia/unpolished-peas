-- Welcome and project-launcher surfaces. Project switching itself remains in
-- Studio so the unsaved-change policy stays centralized.
local Theme = require("ui.theme")
local COLORS = Theme.colors

local Launcher = {}

local function draw_new_project(studio, view)
  studio:canvas_surface(view.body)
  studio:line("NEW PROJECT", view.body.x + 20, view.body.y + 20, 1.18, COLORS.text, view.body.width - 40)
  studio:text("Create a small, valid native project. The selected folder becomes the project root.", view.body.x + 20, view.body.y + 49, .75, COLORS.muted, math.min(view.body.width - 40, 760))
  local width = math.min(760, view.body.width - 40)
  local form = { x = view.body.x + 20, y = view.body.y + 84, width = width, height = 258 }
  studio:panel(form, COLORS.surface, COLORS.border)
  studio:new_project_field({ x = form.x + 14, y = form.y + 18, width = form.width - 28, height = 48 }, "PROJECT NAME", "name", "My Game")
  local browse_width = 116
  studio:new_project_field({ x = form.x + 14, y = form.y + 82, width = form.width - browse_width - 36, height = 48 }, "PROJECT FOLDER", "folder", "/path/to/my-game")
  studio:button({ x = form.x + form.width - browse_width - 14, y = form.y + 82, width = browse_width, height = 48 }, "BROWSE", { type = "choose_new_project_folder" })
  local creation = studio.new_project or {}
  local error = creation.error
  if error then studio:text(error, form.x + 14, form.y + 146, .70, COLORS.red, form.width - 28) end
  local button_y = form.y + form.height - 48
  studio:button({ x = form.x + form.width - 260, y = button_y, width = 110, height = 34 }, "CANCEL", { type = "cancel_new_project" })
  if creation.collision_path then
    studio:button({ x = form.x + form.width - 142, y = button_y, width = 128, height = 34 }, "OPEN EXISTING", { type = "open_new_project_collision" }, { selected = true })
  else
    studio:button({ x = form.x + form.width - 142, y = button_y, width = 128, height = 34 }, "CREATE PROJECT", { type = "create_new_project" }, { selected = true })
  end
end

function Launcher.draw_home(studio, view)
  studio:canvas_surface(view.body)
  studio:line("WORKSPACE OVERVIEW", view.body.x + 20, view.body.y + 20, 1.18, COLORS.text, view.body.width - 40)
  studio:text("One current project, with native authoring tools and an optional ROAG integration.", view.body.x + 20, view.body.y + 49, .78, COLORS.muted, math.min(view.body.width - 40, 820))
  local width = math.min(820, view.body.width - 40)
  local project = { x = view.body.x + 20, y = view.body.y + 82, width = width, height = 116 }
  studio:panel(project, COLORS.surface, COLORS.border)
  studio:line("PROJECT", project.x + 14, project.y + 13, .58, COLORS.muted, project.width - 28)
  if studio:has_project() then
    studio:line(studio.project_manifest.name, project.x + 14, project.y + 32, .90, COLORS.text, project.width - 28)
    studio:line(studio.project_root, project.x + 14, project.y + 56, .60, COLORS.muted, project.width - 28)
    studio:text("Native content: scenes, tilemaps, flows, generators, and room templates.", project.x + 14, project.y + 78, .66, COLORS.muted, project.width - 160)
    studio:button({ x = project.x + project.width - 142, y = project.y + 71, width = 128, height = 30 }, "NATIVE ASSETS", { type = "tab", tab = "native" })
  else
    studio:line("NO PROJECT OPEN", project.x + 14, project.y + 33, .84, COLORS.gold, project.width - 28)
    studio:text("Choose a project folder or manifest before editing native content.", project.x + 14, project.y + 57, .68, COLORS.muted, project.width - 180)
    studio:button({ x = project.x + project.width - 142, y = project.y + 68, width = 128, height = 30 }, "OPEN PROJECT", { type = "tab", tab = "projects" })
  end
  local integration = { x = view.body.x + 20, y = project.y + project.height + 18, width = width, height = 142 }
  local roag_available = studio:is_roag_available()
  studio:panel(integration, COLORS.surface, roag_available and COLORS.border or COLORS.gold)
  studio:line("ROAG INTEGRATION", integration.x + 14, integration.y + 13, .58, COLORS.muted, integration.width - 28)
  studio:line(roag_available and "CONNECTED" or "UNAVAILABLE", integration.x + 14, integration.y + 33, .82, roag_available and COLORS.mint or COLORS.gold, integration.width - 28)
  studio:line(studio.bridge.target, integration.x + 14, integration.y + 56, .60, COLORS.muted, integration.width - 28)
  if roag_available then
    studio:text("ROAG tools: Rooms, Art & Sprites, Scenes, Title Flow, and Publish.", integration.x + 14, integration.y + 79, .68, COLORS.muted, integration.width - 166)
    studio:button({ x = integration.x + integration.width - 142, y = integration.y + 94, width = 128, height = 30 }, "OPEN ROOMS", { type = "tab", tab = "rooms" })
  else
    local reason = studio.roag_error and studio.roag_error.reason or "ROAG workspace could not be loaded."
    studio:text("Native Assets remain available. ROAG reason: " .. reason, integration.x + 14, integration.y + 79, .68, COLORS.muted, integration.width - 28)
  end
end

function Launcher.draw_projects(studio, view)
  if studio.new_project then return draw_new_project(studio, view) end
  studio:canvas_surface(view.body)
  studio:line("PROJECT LAUNCHER", view.body.x + 20, view.body.y + 20, 1.18, COLORS.text, view.body.width - 40)
  studio:text("Create a new project or open one by folder or manifest. Recent projects are stored in this editor’s local settings, not in your game data.", view.body.x + 20, view.body.y + 49, .75, COLORS.muted, math.min(view.body.width - 40, 760))
  local current = { x = view.body.x + 20, y = view.body.y + 85, width = math.min(760, view.body.width - 40), height = 138 }
  studio:panel(current, COLORS.surface, COLORS.border)
  local name = studio.project_manifest and studio.project_manifest.name or "NO PROJECT OPEN"
  studio:line(name, current.x + 14, current.y + 14, .90, COLORS.text, current.width - 28)
  studio:line(studio.project_manifest and "CURRENT PROJECT" or "SELECT A PROJECT TO BEGIN", current.x + 14, current.y + 37, .58, studio.project_manifest and COLORS.mint or COLORS.gold, current.width - 28)
  studio:button({ x = current.x + 14, y = current.y + 61, width = 142, height = 34 }, "NEW PROJECT", { type = "new_project" }, { selected = not studio.project_manifest })
  studio:button({ x = current.x + 164, y = current.y + 61, width = 142, height = 34 }, "OPEN PROJECT", { type = "choose_project", kind = "folder" })
  studio:button({ x = current.x + 314, y = current.y + 61, width = 164, height = 34 }, "CHOOSE MANIFEST", { type = "choose_project", kind = "manifest" })
  studio:button({ x = current.x + 486, y = current.y + 61, width = 116, height = 34 }, "PASTE PATH", { type = "project_path" })
  studio:project_path_field({ x = current.x + 14, y = current.y + 102, width = current.width - 28, height = 30 })
  local recent_y = current.y + current.height + 24
  studio:line("RECENT PROJECTS", view.body.x + 20, recent_y, .72, COLORS.muted, view.body.width - 40)
  if #studio.recent_projects == 0 then
    studio:text("No recent projects yet. Create a new project or open an existing one.", view.body.x + 20, recent_y + 28, .72, COLORS.muted, view.body.width - 40)
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
