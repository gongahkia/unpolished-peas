-- Global Studio chrome: menus, header status, and workspace navigation.
-- Views provide their own content; this module owns the controls shared by all.
local Theme = require("ui.theme")
local COLORS = Theme.colors

local Chrome = {}

-- The shell owns these destinations so that navigation describes the product
-- hierarchy rather than exposing the implementation's individual modes.
function Chrome.navigation(studio)
  local project_open = studio:has_project()
  local roag_available = studio:is_roag_available()
  return {
    {
      label = "PROJECT",
      items = {
        { tab = "home", label = "Overview", enabled = true },
        { tab = "native", label = "Native Assets", enabled = project_open },
      },
    },
    {
      label = "ROAG",
      detail = roag_available and "CONNECTED" or "UNAVAILABLE",
      detail_tint = roag_available and COLORS.mint or COLORS.gold,
      items = {
        { tab = "rooms", label = "Rooms", enabled = roag_available },
        { tab = "art", label = "Art & Sprites", enabled = roag_available },
        { tab = "scenes", label = "Scenes", enabled = roag_available },
        { tab = "flow", label = "Title Flow", enabled = roag_available },
        { tab = "publish", label = "Publish", enabled = roag_available },
      },
    },
  }
end

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
  local unsaved = studio.dirty or studio.room_dirty or studio.native_dirty
  studio:line(unsaved and "UNSAVED" or "SAVED", view.width - 116, 7, .62, unsaved and COLORS.gold or COLORS.mint, 108, "right")
  local previewing = studio.native_preview ~= nil
  local save_width = previewing and 112 or 86
  local breadcrumb = { x = 8, y = 27, width = view.width - save_width - 24, height = 30 }
  studio:panel(breadcrumb, COLORS.surface, COLORS.border)
  studio:line(studio:workspace_breadcrumb(), breadcrumb.x + 10, breadcrumb.y + 8, .70, COLORS.text, breadcrumb.width - 20)
  studio:button({ x = view.width - save_width - 8, y = 29, width = save_width, height = 26 }, previewing and "STOP PREVIEW" or "SAVE", { type = previewing and "stop_native_preview" or "save_current" }, { selected = previewing or unsaved, enabled = studio.tab ~= "projects" })
end

function Chrome.draw_nav(studio, view)
  studio:panel(view.nav)
  local y = view.nav.y + 10
  for group_index, group in ipairs(Chrome.navigation(studio)) do
    studio:line(group.label, view.nav.x + 10, y, .56, COLORS.muted, view.nav.width - 20)
    y = y + 20
    if group.detail then
      studio:line(group.detail, view.nav.x + 10, y - 3, .50, group.detail_tint, view.nav.width - 20)
      y = y + 14
    end
    for _, item in ipairs(group.items) do
      studio:button({ x = view.nav.x + 8, y = y, width = view.nav.width - 16, height = 34 }, item.label, { type = "tab", tab = item.tab }, { selected = studio.tab == item.tab, enabled = item.enabled })
      y = y + 40
    end
    if group_index < #Chrome.navigation(studio) then
      Theme.color(COLORS.border); love.graphics.line(view.nav.x + 8, y - 4.5, view.nav.x + view.nav.width - 8, y - 4.5)
      y = y + 8
    end
  end
end

function Chrome.draw_menu(studio)
  local menu = studio.header_menu
  if not menu then return end
  local definitions = {
    file = { x = 8, width = 184, items = {
      { "NEW PROJECT…", { type = "new_project" } }, { "OPEN PROJECT…", { type = "choose_project", kind = "folder" } }, { "PROJECT LAUNCHER", { type = "tab", tab = "projects" } },
      { "SAVE CURRENT", { type = "save_current" } }, { "QUIT", { type = "quit_app" }, danger = true },
    } },
    edit = { x = 59, width = 168, items = {
      { "UNDO", { type = "undo_current" }, enabled = studio:can_undo_current() }, { "REDO", { type = "redo_current" }, enabled = studio:can_redo_current() },
    } },
    view = { x = 112, width = 184, items = {
      { "OVERVIEW", { type = "tab", tab = "home" } }, { "NATIVE ASSETS", { type = "tab", tab = "native" }, enabled = studio:has_project() },
      { "ROAG — ROOMS", { type = "tab", tab = "rooms" }, enabled = studio:is_roag_available() }, { "ROAG — ART & SPRITES", { type = "tab", tab = "art" }, enabled = studio:is_roag_available() },
      { "ROAG — SCENES", { type = "tab", tab = "scenes" }, enabled = studio:is_roag_available() }, { "ROAG — TITLE FLOW", { type = "tab", tab = "flow" }, enabled = studio:is_roag_available() },
      { "ROAG — PUBLISH", { type = "tab", tab = "publish" }, enabled = studio:is_roag_available() },
    } },
    project = { x = 167, width = 192, items = {
      { "PROJECT LAUNCHER", { type = "tab", tab = "projects" } }, { "OPEN PROJECT FOLDER…", { type = "choose_project", kind = "folder" } },
      { "NATIVE ASSETS", { type = "tab", tab = "native" }, enabled = studio:has_project() }, { "RELOAD ROAG", { type = "reload" } },
      { studio.native_preview and "STOP PREVIEW" or "PREVIEW PROJECT", { type = studio.native_preview and "stop_native_preview" or "run_project" }, enabled = studio:has_project() },
      { "PREVIEW MAIN SCENE", { type = "run_scene" }, enabled = studio:has_project() and not studio.native_preview },
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
