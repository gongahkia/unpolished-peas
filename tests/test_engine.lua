package.path = "./?.lua;./?/init.lua;" .. package.path

local Json = require("core.json")
local Fs = require("core.fs")
local Generator = require("core.generator")
local Flow = require("core.flow")
local History = require("core.history")
local Project = require("core.project")
local RecentProjects = require("core.recent_projects")
local RoomGraph = require("core.room_graph")
local Runtime = require("core.runtime")
local Scene = require("core.scene")
local Tilemap = require("core.tilemap")
local Tiled = require("core.tiled_import")
local Studio = require("ui.studio")
local Chrome = require("ui.chrome")
local NativeWorkspace = require("ui.native_workspace")
local Workspace = require("core.roag_workspace")
local Fixture = require("tests.roag_fixture")
local Harness = require("tests.harness")

local test = Harness.test

local function temporary_root()
  local root = os.tmpname()
  os.remove(root)
  return root
end

local function remove_new_project(root)
  os.remove(root .. "/assets/main.scene.json")
  os.remove(root .. "/unpolished_bees.project.json")
  os.remove(root .. "/assets")
  os.remove(root)
end

test("native workspace geometry keeps common regions and a usable center at minimum width", function()
  local workspace = NativeWorkspace.layout({ x = 10, y = 20, width = 536, height = 530 })
  assert(workspace.header.y == 20 and workspace.toolbar.y > workspace.header.y)
  assert(workspace.body.y > workspace.toolbar.y and workspace.footer.y > workspace.body.y)
  assert(workspace.footer.y + workspace.footer.height == 550)
  local scene = NativeWorkspace.three_columns(workspace.body)
  assert(scene.left.width >= 108 and scene.center.width >= 180 and scene.right.width >= 146)
  assert(scene.left.x + scene.left.width < scene.center.x and scene.center.x + scene.center.width < scene.right.x)
  local flow = NativeWorkspace.editor_with_inspector(workspace.body)
  assert(flow.center.width >= 220 and flow.right.width >= 146)
  local generator = NativeWorkspace.settings_and_editor(workspace.body)
  assert(generator.left.width >= 146 and generator.center.width >= 200)
end)

test("native project assets validate and round-trip through the starter fixture", function()
  local project = Project.new("examples/starter")
  local manifest = assert(project:load())
  assert(manifest.name == "Unpolished Bees Starter")
  local scene = assert(project:load_asset("scene.main"))
  assert(scene.root.children[1].type == "panel")
  local encoded = assert(Json.encode(scene))
  assert(Project.validate_asset(assert(Json.decode(encoded)), "scene"))
end)

test("runtime executes declarative scene transitions", function()
  local runtime = Runtime.new(Project.new("examples/starter"))
  assert(runtime:start("flow.main"))
  assert(runtime.scene_id == "scene.main")
  runtime:emit("open_shop")
  runtime:update()
  assert(runtime.scene_id == "scene.shop")
  assert(runtime.variables.credits == 0)
end)

test("schema rejects unsafe asset references and embedded lua", function()
  local project = Project.empty("Unsafe")
  project.assets["scene.main"] = { type = "scene", path = "../escape.json" }
  assert(not Project.validate_manifest(project))
  project.assets["scene.main"] = { type = "tilemap", path = "assets/not-a-scene.json" }
  assert(not Project.validate_manifest(project))
  local flow = {
    format = "unpolished_bees.flow", version = 1, type = "flow", id = "flow.test", entry_scene_id = "scene.main",
    nodes = { { id = "graph.start", type = "hook", hook = "function() end" } }, edges = {}, variables = {},
  }
  assert(not Project.validate_asset(flow, "flow"))
end)

test("tiled finite JSON imports to a validated sparse native tilemap", function()
  local source = [[{"type":"map","orientation":"orthogonal","width":40,"height":1,"tilewidth":16,"tileheight":16,"layers":[{"id":4,"name":"Ground","type":"tilelayer","data":[1,0,2,3,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,4]}]}]]
  local map = assert(Tiled.import_map(source, { id = "tilemap.fixture", tileset_id = "tileset.fixture", chunk_width = 32 }))
  assert(map.layers[1].chunks[1].cells[2].x == 2 and map.layers[1].chunks[1].cells[2].y == 0)
  assert(#map.layers[1].chunks == 2 and Tilemap.get(map, "layer.tiled_4", 39, 0) == 4)
  assert(Project.validate_asset(map, "tilemap"))
end)

test("room graph assembly is deterministic for matching connector corpora", function()
  local template = {
    id = "room.empty", connectors = {}, width = 1, height = 1, layout = { "." },
  }
  local first = assert(RoomGraph.assemble({ template }, 1, 1, 123))
  local second = assert(RoomGraph.assemble({ template }, 1, 1, 123))
  assert(first.cells[1].template_id == "room.empty")
  assert(Json.encode(first) == Json.encode(second))
end)

test("sparse tilemap painting creates, updates, and erases chunks deterministically", function()
  local map = {
    format = "unpolished_bees.tilemap", version = 1, type = "tilemap", id = "tilemap.paint", infinite = true,
    tile_width = 16, tile_height = 16, chunk_width = 4, chunk_height = 4,
    layers = { { id = "layer.ground", tileset_id = "tileset.fixture", chunks = {} } },
  }
  assert(Tilemap.set(map, "layer.ground", 5, 2, 7))
  assert(Tilemap.get(map, "layer.ground", 5, 2) == 7)
  assert(Tilemap.set(map, "layer.ground", 5, 2, 3))
  assert(Tilemap.get(map, "layer.ground", 5, 2) == 3)
  assert(Tilemap.set(map, "layer.ground", 5, 2, 0))
  assert(Tilemap.get(map, "layer.ground", 5, 2) == nil)
  assert(not Tilemap.set(map, "layer.ground", -1, 2, 1))
  assert(Project.validate_asset(map, "tilemap"))
end)

test("noise and WFC generators produce deterministic ordinary tilemaps", function()
  local noise = { format = "unpolished_bees.generator", version = 1, type = "generator", id = "generator.noise", generator_type = "noise", settings = { width = 4, height = 3, seed = 7, threshold = .4 } }
  assert(Project.validate_asset(noise, "generator"))
  local first, second = assert(Generator.generate(noise)), assert(Generator.generate(noise))
  assert(Json.encode(first) == Json.encode(second))
  local wfc = { format = "unpolished_bees.generator", version = 1, type = "generator", id = "generator.wfc", generator_type = "wfc", settings = { width = 2, height = 2, seed = 12, tiles = { "floor" }, rules = { floor = { north = { "floor" }, east = { "floor" }, south = { "floor" }, west = { "floor" } } } } }
  local map = assert(Generator.generate(wfc))
  assert(#map.layers[1].chunks[1].cells == 4)
  local alternating = { format = "unpolished_bees.generator", version = 1, type = "generator", id = "generator.alternating", generator_type = "wfc", settings = { width = 3, height = 2, seed = 4, tiles = { "a", "b" }, rules = { a = { north = { "b" }, east = { "b" }, south = { "b" }, west = { "b" } }, b = { north = { "a" }, east = { "a" }, south = { "a" }, west = { "a" } } } } }
  assert(Generator.generate(alternating))
end)

test("editor histories and primitive tree/flow/layer mutations remain serializable", function()
  local history = History.new(2)
  local value = { value = 1 }; history:record(value); value.value = 2
  local undone = assert(history:undo(value)); assert(undone.value == 1)
  local redone = assert(history:redo(undone)); assert(redone.value == 2)

  local scene = assert(Project.asset_template("scene", "scene.editor"))
  local panel = assert(Scene.add(scene, scene.root.id, "panel"))
  local label = assert(Scene.add(scene, panel.id, "label"))
  assert(Scene.reparent(scene, label.id, scene.root.id))
  assert(Scene.remove(scene, panel.id))
  assert(Scene.find(scene, label.id))
  assert(Project.validate_asset(scene, "scene"))

  local flow = assert(Project.asset_template("flow", "flow.editor", { entry_scene_id = "scene.editor" }))
  local event, transition = Flow.add_node(flow, "event"), Flow.add_node(flow, "transition")
  assert(Flow.connect(flow, flow.nodes[1].id, event.id))
  assert(Flow.connect(flow, event.id, transition.id))
  assert(Flow.remove_node(flow, event.id))
  assert(#flow.edges == 0 and Project.validate_asset(flow, "flow"))

  local map = assert(Project.asset_template("tilemap", "tilemap.editor", { tileset_id = "tileset.editor" }))
  local extra = Tilemap.add_layer(map, "tileset.editor", "detail")
  assert(Tilemap.set(map, extra.id, 0, 0, 1))
  assert(Tilemap.remove_layer(map, extra.id))
  assert(Project.validate_asset(map, "tilemap"))
end)

test("Scene tree helpers protect the root, prevent cycles, and preserve sibling order", function()
  local scene = assert(Project.asset_template("scene", "scene.tree"))
  local panel = assert(Scene.add(scene, scene.root.id, "panel"))
  local label = assert(Scene.add(scene, panel.id, "label"))
  local button = assert(Scene.add(scene, scene.root.id, "button"))
  assert(scene.root.children[1] == panel and scene.root.children[2] == button)
  assert(Scene.move_sibling(scene, button.id, -1))
  assert(scene.root.children[1] == button and scene.root.children[2] == panel)
  assert(not Scene.move_sibling(scene, scene.root.id, -1))
  assert(not Scene.move_sibling(scene, button.id, -1))
  assert(not Scene.reparent(scene, label.id, panel.id))
  assert(Scene.parent_of(scene, label.id).node == panel)
  local allowed, reason = Scene.can_reparent(scene, panel.id, label.id)
  assert(not allowed and reason:match("cannot become"))
  assert(not Scene.reparent(scene, panel.id, label.id))
  assert(Scene.parent_of(scene, label.id).node == panel)
  assert(not Scene.reparent(scene, scene.root.id, button.id))
  assert(not Scene.remove(scene, scene.root.id))
  assert(Project.validate_asset(scene, "scene"))
end)

test("Studio Scene editing synchronizes selection, history, and persistence", function()
  local root = temporary_root()
  assert(Project.create(root, "Scene Editor Fixture"))
  local studio = setmetatable({
    project_root = root, tab = "native", selected_asset = 1, selected_map_layer = 1,
    native_images = {}, native_quads = {}, sounds = {}, status = "", recent_projects = {},
  }, Studio)
  studio:load_native_project()
  local scene = studio.native_asset_data
  assert(scene.type == "scene" and studio.native_selected_node == scene.root)

  studio:activate({ type = "add_native_node", node_type = "panel" })
  local panel = studio.native_selected_node
  assert(panel.type == "panel" and Scene.parent_of(scene, panel.id).node == scene.root)
  studio:activate({ type = "add_native_node", node_type = "label" })
  local label = studio.native_selected_node
  assert(label.type == "label" and Scene.parent_of(scene, label.id).node == panel)
  studio:activate({ type = "add_native_node", node_type = "button" })
  local button = studio.native_selected_node
  assert(button.type == "button" and Scene.parent_of(scene, button.id).node == panel)
  assert(label.id ~= button.id)

  studio:activate({ type = "move_scene_node", direction = -1 })
  assert(panel.children[1] == button and panel.children[2] == label)
  studio:activate({ type = "undo_native" })
  panel = Scene.find(studio.native_asset_data, panel.id)
  label, button = Scene.find(studio.native_asset_data, label.id), Scene.find(studio.native_asset_data, button.id)
  assert(panel.children[1] == label and panel.children[2] == button)
  studio:activate({ type = "redo_native" })
  panel = Scene.find(studio.native_asset_data, panel.id)
  assert(panel.children[1].id == button.id)

  studio:select_scene_node(button.id)
  studio:begin_native_field(studio.native_selected_node.properties, "text", "text")
  studio.draft = ""
  studio:commit_field()
  assert(studio.native_selected_node.properties.text == "")
  local original_x = panel.properties.x
  studio:begin_native_field(panel.properties, "x", "number")
  studio.draft = "not a number"
  studio:commit_field()
  assert(panel.properties.x == original_x and studio.status:match("valid number"))

  studio:select_scene_node(panel.id)
  studio:activate({ type = "native_node", node = studio.native_selected_node })
  studio:mousemoved(0, 0, 9, 7); studio:mousereleased(0, 0, 1)
  panel = Scene.find(studio.native_asset_data, panel.id)
  assert(panel.properties.x == original_x + 9 and panel.properties.y == 47)
  studio:activate({ type = "undo_native" })
  panel = Scene.find(studio.native_asset_data, panel.id)
  assert(panel.properties.x == original_x and panel.properties.y == 40)
  studio:activate({ type = "redo_native" })
  panel = Scene.find(studio.native_asset_data, panel.id)
  assert(panel.properties.x == original_x + 9)

  local original_width, original_height = panel.properties.width, panel.properties.height
  studio:activate({ type = "native_scene_resize", node = panel })
  studio:mousemoved(0, 0, 12, 8); studio:mousereleased(0, 0, 1)
  panel = Scene.find(studio.native_asset_data, panel.id)
  assert(panel.properties.width == original_width + 12 and panel.properties.height == original_height + 8)
  studio:activate({ type = "undo_native" })
  panel = Scene.find(studio.native_asset_data, panel.id)
  assert(panel.properties.width == original_width and panel.properties.height == original_height)
  studio:activate({ type = "redo_native" })
  panel = Scene.find(studio.native_asset_data, panel.id)
  assert(panel.properties.width == original_width + 12)

  studio:select_scene_node(button.id)
  studio:activate({ type = "native_reparent_mode" })
  assert(studio.native_reparent_source.id == button.id)
  studio:activate({ type = "native_reparent_here", node = studio.native_asset_data.root })
  button = Scene.find(studio.native_asset_data, button.id)
  assert(Scene.parent_of(studio.native_asset_data, button.id).node == studio.native_asset_data.root and not studio.native_reparent_source)
  studio:activate({ type = "undo_native" })
  button = Scene.find(studio.native_asset_data, button.id)
  assert(Scene.parent_of(studio.native_asset_data, button.id).node.id == panel.id)
  studio:activate({ type = "redo_native" })
  button = Scene.find(studio.native_asset_data, button.id)
  assert(Scene.parent_of(studio.native_asset_data, button.id).node == studio.native_asset_data.root)

  studio:select_scene_node(panel.id)
  studio:activate({ type = "delete_native_node" })
  assert(studio.native_selected_node == studio.native_asset_data.root)
  studio:activate({ type = "undo_native" })
  assert(Scene.find(studio.native_asset_data, panel.id))
  studio:select_scene_node(button.id)
  studio:activate({ type = "move_scene_node", direction = -1 })
  assert(studio.native_asset_data.root.children[1].id == button.id)
  assert(studio:save_native())
  local reopened = assert(Project.new(root):load_asset("scene.main"))
  local reopened_panel, reopened_button = Scene.find(reopened, panel.id), Scene.find(reopened, button.id)
  assert(reopened_panel.properties.x == original_x + 9 and reopened_panel.properties.width == original_width + 12)
  assert(reopened_button and Scene.parent_of(reopened, reopened_button.id).node == reopened.root)
  assert(reopened.root.children[1].id == reopened_button.id)
  remove_new_project(root)
end)

test("project creation, recoverable index removal, and reference protection work", function()
  local root = os.tmpname(); os.remove(root)
  local made = os.execute("mkdir -p " .. string.format("%q", root .. "/assets"))
  assert(made == true or made == 0)
  local project = assert(Project.create(root, "Editor Fixture"))
  assert(project:load())
  local imported = assert(project:import_tileset("assets/kenney/cursor_pack/Preview.png", "cursor_preview"))
  assert(project:load_asset(imported.id).texture.mode == "imported")
  local tileset = assert(project:create_asset("tileset", "terrain", { texture_path = "assets/terrain.png" }))
  local map = assert(project:create_asset("tilemap", "level", { tileset_id = tileset.id }))
  local removed, failure = project:remove_asset(tileset.id)
  assert(not removed and failure.code == "asset_still_referenced" and failure.references[1].id == map.id)
  assert(project:remove_asset(map.id))
  assert(project:remove_asset(tileset.id))
  assert(project:load())
end)

test("new projects create a valid minimal scene scaffold and reopen cleanly", function()
  local root = temporary_root()
  local project = assert(Project.create(root, "  My First Game  "))
  local manifest = assert(project:load())
  assert(manifest.name == "My First Game" and manifest.main_scene_id == "scene.main")
  assert(manifest.assets["scene.main"].path == "assets/main.scene.json")
  assert(Fs.exists(root .. "/assets/main.scene.json") and Fs.exists(root .. "/" .. Project.MANIFEST))
  assert(Project.validate_asset(assert(project:load_asset("scene.main")), "scene"))
  local reopened = Project.new(root)
  assert(reopened:load().name == "My First Game")
  assert(reopened:load_asset("scene.main").root.id == "node.root")
  remove_new_project(root)

  local existing_empty_root = temporary_root()
  assert(Fs.create_directory(existing_empty_root))
  local existing_empty = assert(Project.create(existing_empty_root, "Existing Empty Folder"))
  assert(existing_empty:load().name == "Existing Empty Folder")
  remove_new_project(existing_empty_root)
end)

test("new project creation rejects unsafe destinations without modifying them", function()
  local empty_name_root = temporary_root()
  local missing, empty_name_failure = Project.create(empty_name_root, "   ")
  assert(not missing and empty_name_failure.code == "project_name_required")
  assert(Fs.directory_state(empty_name_root) == "missing")

  local existing_root = temporary_root()
  assert(Project.create(existing_root, "Original Project"))
  local original_manifest = assert(Fs.read(existing_root .. "/" .. Project.MANIFEST))
  local collision, collision_failure = Project.create(existing_root, "Replacement Project")
  assert(not collision and collision_failure.code == "project_exists")
  assert(Fs.read(existing_root .. "/" .. Project.MANIFEST) == original_manifest)
  remove_new_project(existing_root)

  local unrelated_root = temporary_root()
  assert(Fs.create_directory(unrelated_root))
  local note = assert(io.open(unrelated_root .. "/notes.txt", "wb")); assert(note:write("keep this")); note:close()
  local adopted, adopted_failure = Project.create(unrelated_root, "Should Not Adopt")
  assert(not adopted and adopted_failure.code == "project_folder_not_empty")
  assert(Fs.read(unrelated_root .. "/notes.txt") == "keep this")
  assert(not Fs.exists(unrelated_root .. "/" .. Project.MANIFEST))
  os.remove(unrelated_root .. "/notes.txt")
  assert(os.remove(unrelated_root))
end)

test("Studio imports ROAG-style source sheets as reusable native tilesets", function()
  local root = os.tmpname(); os.remove(root)
  local made = os.execute("mkdir -p " .. string.format("%q", root .. "/assets"))
  assert(made == true or made == 0)
  assert(Project.create(root, "Art Source Fixture"))
  local studio = setmetatable({
    project_root = root, selected_asset = 1, selected_map_layer = 1,
    native_images = {}, native_quads = {}, sounds = {}, status = "", recent_projects = {},
    art_sheet_selection = {}, bridge = { target = "." },
  }, Studio)
  studio:load_native_project()
  local pack = { id = "art_pack.fixture", label = "Fixture Art" }
  local sheet = { id = "main", label = "Fixture Cursor", path = "assets/kenney/cursor_pack/PNG/Basic/Default/pointer_scifi_a.png", tile_width = 16, tile_height = 16 }
  local added, tileset = studio:import_art_sheet(pack, sheet)
  assert(added and tileset.tile_width == 16 and tileset.tile_height == 16)
  assert(studio.project:load_asset(tileset.id).texture.path == "assets/fixture_art_main.png")
  local second_added, second_tileset = studio:import_art_sheet(pack, sheet)
  assert(second_added and second_tileset.id == tileset.id)
end)

test("Studio header menus expose contextual commands instead of decorative labels", function()
  local root = os.tmpname(); os.remove(root)
  local made = os.execute("mkdir -p " .. string.format("%q", root .. "/assets"))
  assert(made == true or made == 0)
  assert(Project.create(root, "Header Menu Fixture"))
  local studio = setmetatable({
    project_root = root, tab = "native", selected_asset = 1, selected_map_layer = 1,
    native_images = {}, native_quads = {}, sounds = {}, status = "", recent_projects = {},
    undo_stack = {}, redo_stack = {}, room_histories = {},
  }, Studio)
  studio:load_native_project()
  studio:activate({ type = "header_menu", menu = "file" })
  assert(studio.header_menu == "file")
  studio:activate({ type = "header_menu", menu = "file" })
  assert(studio.header_menu == nil)
  studio:activate({ type = "show_help", topic = "shortcuts" })
  assert(studio.status == "Keyboard shortcuts shown.")
  studio:activate({ type = "add_native_node", node_type = "panel" })
  assert(studio.native_dirty and studio:can_undo_current())
  studio:activate({ type = "save_current" })
  assert(not studio.native_dirty)
end)

test("Studio shell groups project and ROAG destinations without command tabs", function()
  local studio = setmetatable({ project_manifest = { name = "Shell Fixture" }, data = {}, tab = "home", sounds = {} }, Studio)
  local groups = Chrome.navigation(studio)
  assert(#groups == 2 and groups[1].label == "PROJECT" and groups[2].label == "ROAG")
  assert(groups[1].items[1].label == "Overview" and groups[1].items[2].label == "Native Assets")
  assert(groups[2].items[2].label == "Art & Sprites" and groups[2].items[4].label == "Title Flow")
  for _, group in ipairs(groups) do
    for _, item in ipairs(group.items) do assert(item.tab ~= "projects" and item.tab ~= "save") end
  end
  assert(studio:workspace_breadcrumb() == "Shell Fixture  /  Overview")
  studio.data = nil
  assert(not Chrome.navigation(studio)[2].items[1].enabled)
  studio:activate({ type = "tab", tab = "native" })
  assert(studio.tab == "native" and studio:workspace_breadcrumb() == "Shell Fixture  /  Native Assets")
end)

test("Studio native actions compose validated assets without a graphical runtime", function()
  local root = os.tmpname(); os.remove(root)
  local made = os.execute("mkdir -p " .. string.format("%q", root .. "/assets"))
  assert(made == true or made == 0)
  assert(Project.create(root, "Studio Action Fixture"))
  local studio = setmetatable({ project_root = root, tab = "native", selected_asset = 1, selected_map_layer = 1, native_images = {}, sounds = {}, status = "" }, Studio)
  studio:load_native_project()
  studio:activate({ type = "add_native_node", node_type = "panel" })
  assert(studio.native_dirty and #studio.native_asset_data.root.children == 1)
  local panel = studio.native_asset_data.root.children[1]
  local panel_x, panel_y = panel.properties.x, panel.properties.y
  studio:activate({ type = "native_node", node = panel })
  studio:mousemoved(0, 0, 9, 7); studio:mousereleased(0, 0, 1)
  assert(studio.native_asset_data.root.children[1].properties.x == panel_x + 9)
  assert(studio.native_asset_data.root.children[1].properties.y == panel_y + 7)
  studio:activate({ type = "undo_native" })
  assert(#studio.native_asset_data.root.children == 1 and studio.native_asset_data.root.children[1].properties.x == panel_x)
  studio:activate({ type = "undo_native" })
  assert(#studio.native_asset_data.root.children == 0)
  assert(studio:save_native())
  studio:activate({ type = "create_native_asset", asset_type = "tilemap" })
  assert(studio.native_asset_data.type == "tilemap")
  assert(studio.project_manifest.assets[studio.native_asset_data.layers[1].tileset_id])
  studio:activate({ type = "add_map_layer" })
  local layer = studio.native_asset_data.layers[2]
  assert(Tilemap.set(studio.native_asset_data, layer.id, 1, 1, 1))
  assert(studio:save_native())
  studio:activate({ type = "create_native_asset", asset_type = "flow" })
  studio:activate({ type = "add_flow_node", node_type = "event" })
  local event = studio.native_selected_flow_node
  local event_x, event_y = event.editor.x, event.editor.y
  studio:activate({ type = "native_flow_node", node = event })
  studio:mousemoved(0, 0, 11, 5); studio:mousereleased(0, 0, 1)
  assert(event.editor.x == event_x + 11 and event.editor.y == event_y + 5)
  studio:activate({ type = "undo_native" })
  event = studio.native_asset_data.nodes[#studio.native_asset_data.nodes]
  assert(event.editor.x == event_x and event.editor.y == event_y)
  studio:activate({ type = "native_flow_node", node = event })
  studio:activate({ type = "start_flow_connection" })
  studio:activate({ type = "native_flow_node", node = studio.native_asset_data.nodes[1] })
  assert(#studio.native_asset_data.edges == 1 and event.id ~= studio.native_asset_data.nodes[1].id)
  assert(studio:save_native())
  studio:activate({ type = "create_native_asset", asset_type = "generator" })
  studio:activate({ type = "generate_native" })
  assert(studio.generated_preview and studio.generated_preview.type == "tilemap")
end)

test("Studio switches validated project folders or manifests and retains recents", function()
  local first_root, second_root = os.tmpname(), os.tmpname()
  os.remove(first_root); os.remove(second_root)
  local first_made = os.execute("mkdir -p " .. string.format("%q", first_root .. "/assets"))
  local second_made = os.execute("mkdir -p " .. string.format("%q", second_root .. "/assets"))
  assert((first_made == true or first_made == 0) and (second_made == true or second_made == 0))
  assert(Project.create(first_root, "First Project"))
  assert(Project.create(second_root, "Second Project"))
  local studio = setmetatable({ project_root = first_root, selected_asset = 1, selected_map_layer = 1, native_images = {}, native_quads = {}, sounds = {}, status = "", recent_projects = {} }, Studio)
  assert(studio:open_project(first_root))
  assert(studio.project_manifest.name == "First Project")
  assert(studio:open_project(second_root .. "/" .. Project.MANIFEST))
  assert(studio.project_root == second_root and studio.project_manifest.name == "Second Project")
  local active_root = studio.project_root
  assert(not studio:open_project(second_root .. "/not-a-project"))
  assert(studio.project_root == active_root)
  assert(not studio:request_project_open(second_root .. "/not-a-project"))
  assert(studio.project_root == active_root)
  local recents = RecentProjects.remember(studio.recent_projects, "/another-project", "Another", 1)
  assert(recents[1].path == "/another-project" and #recents <= RecentProjects.LIMIT)
end)

test("Studio new-project lifecycle is cancellable, guarded, recent, and ROAG-independent", function()
  local first_root, created_root, blocked_root = temporary_root(), temporary_root(), temporary_root()
  assert(Project.create(first_root, "Existing Project"))
  local roag_data = { marker = "unchanged" }
  local studio = setmetatable({
    project_root = first_root, selected_asset = 1, selected_map_layer = 1,
    native_images = {}, native_quads = {}, sounds = {}, status = "", recent_projects = {},
    bridge = { target = "fixture-roag-target" }, data = roag_data,
  }, Studio)
  assert(studio:open_project(first_root))
  local recents_before = #studio.recent_projects
  studio:begin_new_project()
  assert(studio.new_project and studio.project_root == first_root)
  studio:cancel_new_project()
  assert(not studio.new_project and studio.project_root == first_root and #studio.recent_projects == recents_before)

  studio:begin_new_project()
  studio.new_project.name, studio.new_project.folder = "Created Through Studio", created_root
  assert(studio:create_new_project())
  assert(studio.project_root == created_root and studio.project_manifest.name == "Created Through Studio")
  assert(studio.tab == "native" and not studio.native_dirty and studio.data == roag_data and studio.bridge.target == "fixture-roag-target")
  local created_entries = 0
  for _, entry in ipairs(studio.recent_projects) do if entry.path == created_root then created_entries = created_entries + 1 end end
  assert(created_entries == 1)
  studio:activate({ type = "open_recent_project", path = first_root })
  assert(studio.project_root == first_root)
  studio:activate({ type = "open_recent_project", path = created_root })
  assert(studio.project_root == created_root)
  local reopened_entries = 0
  for _, entry in ipairs(studio.recent_projects) do if entry.path == created_root then reopened_entries = reopened_entries + 1 end end
  assert(reopened_entries == 1)

  studio.native_dirty = true
  studio.choice = function() return 1 end -- Cancel the shared dirty-project switch guard.
  studio:begin_new_project()
  studio.new_project.name, studio.new_project.folder = "Blocked Create", blocked_root
  local created, failure = studio:create_new_project()
  assert(not created and failure.reason == "Project switch cancelled")
  assert(studio.project_root == created_root and Fs.directory_state(blocked_root) == "missing")
  assert(studio.data == roag_data and studio.bridge.target == "fixture-roag-target")
  for _, entry in ipairs(studio.recent_projects) do assert(entry.path ~= blocked_root) end
  assert(not studio:request_project_open(first_root))
  assert(studio.project_root == created_root)

  remove_new_project(first_root)
  remove_new_project(created_root)
end)

test("ROAG corpus diagnostics and recoverable manifest room lifecycle work in a scratch target", function()
  local root = Fixture.copy()
  local workspace = Workspace.new(root)
  assert(workspace:load())
  local room = assert(workspace:create_room("dungeon", "editor_fixture"))
  assert(#workspace.corpora.dungeon.rooms == 2)
  assert(workspace:remove_room("dungeon", room.filename))
  assert(#workspace.corpora.dungeon.rooms == 1)
end)
