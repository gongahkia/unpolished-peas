-- Global Studio chrome: menus, header status, and workspace navigation.
-- Views provide their own content; this module owns the controls shared by all.
local Theme = require("ui.theme")
local COLORS = Theme.colors

local Chrome = {}

local function menu_label(studio, rect, label, menu)
  local selected = studio.header_menu == menu
  if selected then studio:panel(rect, COLORS.surface2, COLORS.selected_border) end
  studio:line(label, rect.x + 7, rect.y + 6, .64, selected and COLORS.text or COLORS.muted, rect.width - 14, "center")
  studio.controls[#studio.controls + 1] = { rect = rect, action = { type = "header_menu", menu = menu }, cursor = "action" }
end

local function menu_item(studio, rect, label, action, options)
  options = options or {}
  studio:button(rect, label, action, { enabled = options.enabled ~= false, danger = options.danger })
end

function Chrome.draw_header(studio, view)
  Theme.color(COLORS.dark); love.graphics.rectangle("fill", 0, 0, view.width, view.header.height)
  local menus = { { "FILE", "file", 8, 45 }, { "EDIT", "edit", 59, 47 }, { "VIEW", "view", 112, 49 }, { "PROJECT", "project", 167, 79 }, { "HELP", "help", 252, 47 } }
  for _, item in ipairs(menus) do menu_label(studio, { x = item[3], y = 1, width = item[4], height = 25 }, item[1], item[2]) end
  local tabs = { home = "OVERVIEW", projects = "PROJECTS", native = "PROJECT", rooms = "ROOMS", art = "SPRITES", scenes = "SCENES", flow = "FLOW", publish = "EXPORT" }
  local title = tabs[studio.tab] or "PROJECT"
  studio:panel({ x = 8, y = 27, width = 232, height = 30 }, COLORS.surface, COLORS.border)
  studio:line("UNPOLISHED BEES  /  " .. title, 18, 35, .70, COLORS.text, 212)
  local unsaved = studio.dirty or studio.room_dirty or studio.native_dirty
  studio:line(unsaved and "UNSAVED" or "SAVED", view.width - 302, 7, .62, unsaved and COLORS.gold or COLORS.mint, 82, "right")
  studio:line("TARGET " .. studio.bridge.target, view.width - 220, 7, .58, COLORS.muted, 210, "right")
  studio:button({ x = view.width - 262, y = 29, width = 78, height = 26 }, "OPEN", { type = "tab", tab = "projects" })
  studio:button({ x = view.width - 176, y = 29, width = 78, height = 26 }, "RELOAD", { type = "reload" })
  studio:button({ x = view.width - 90, y = 29, width = 82, height = 26 }, "PUBLISH", { type = "save_current" }, { selected = studio.dirty })
end

function Chrome.draw_nav(studio, view)
  studio:panel(view.nav)
  studio:line("TOOLS", view.nav.x + 5, view.nav.y + 8, .52, COLORS.muted, view.nav.width - 10, "center")
  local tabs = { { "home", "HOME" }, { "projects", "OPEN" }, { "native", "ASSET" }, { "rooms", "ROOM" }, { "art", "ART" }, { "scenes", "SCENE" }, { "flow", "FLOW" }, { "publish", "SAVE" } }
  for index, item in ipairs(tabs) do
    studio:button({ x = view.nav.x + 7, y = view.nav.y + 30 + (index - 1) * 46, width = view.nav.width - 14, height = 38 }, item[2], { type = "tab", tab = item[1] }, { selected = studio.tab == item[1] })
  end
end

function Chrome.draw_menu(studio)
  local menu = studio.header_menu
  if not menu then return end
  local definitions = {
    file = { x = 8, width = 184, items = {
      { "OPEN PROJECT…", { type = "choose_project", kind = "folder" } }, { "SAVE CURRENT", { type = "save_current" } },
      { "RELOAD ROAG", { type = "reload" } }, { "QUIT", { type = "quit_app" }, danger = true },
    } },
    edit = { x = 59, width = 168, items = {
      { "UNDO", { type = "undo_current" }, enabled = studio:can_undo_current() }, { "REDO", { type = "redo_current" }, enabled = studio:can_redo_current() },
    } },
    view = { x = 112, width = 184, items = {
      { "OVERVIEW", { type = "tab", tab = "home" } }, { "NATIVE PROJECT", { type = "tab", tab = "native" } }, { "ROAG ROOMS", { type = "tab", tab = "rooms" } },
      { "ART & SPRITES", { type = "tab", tab = "art" } }, { "SCENES", { type = "tab", tab = "scenes" } }, { "TITLE FLOW", { type = "tab", tab = "flow" } }, { "PUBLISH", { type = "tab", tab = "publish" } },
    } },
    project = { x = 167, width = 192, items = {
      { "PROJECT LAUNCHER", { type = "tab", tab = "projects" } }, { "OPEN PROJECT FOLDER…", { type = "choose_project", kind = "folder" } },
      { "NATIVE ASSETS", { type = "tab", tab = "native" }, enabled = studio.project_manifest ~= nil }, { "RUN PROJECT PREVIEW", { type = "run_project" }, enabled = studio.project_manifest ~= nil },
    } },
    help = { x = 252, width = 208, items = {
      { "KEYBOARD SHORTCUTS", { type = "show_help", topic = "shortcuts" } }, { "ABOUT UNPOLISHED BEES", { type = "show_help", topic = "about" } },
    } },
  }
  local definition = definitions[menu]
  if not definition then return end
  local rect = { x = definition.x, y = 27, width = definition.width, height = #definition.items * 32 + 10 }
  studio:panel(rect, COLORS.surface, COLORS.selected_border)
  for index, item in ipairs(definition.items) do
    menu_item(studio, { x = rect.x + 5, y = rect.y + 5 + (index - 1) * 32, width = rect.width - 10, height = 28 }, item[1], item[2], { enabled = item.enabled, danger = item.danger })
  end
end

return Chrome
