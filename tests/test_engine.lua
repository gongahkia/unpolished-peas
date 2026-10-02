package.path = "./?.lua;./?/init.lua;" .. package.path

local Json = require("core.json")
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
local Workspace = require("core.roag_workspace")
local Fixture = require("tests.roag_fixture")
local Harness = require("tests.harness")

local test = Harness.test

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

test("Studio native actions compose validated assets without a graphical runtime", function()
  local root = os.tmpname(); os.remove(root)
  local made = os.execute("mkdir -p " .. string.format("%q", root .. "/assets"))
  assert(made == true or made == 0)
  assert(Project.create(root, "Studio Action Fixture"))
  local studio = setmetatable({ project_root = root, selected_asset = 1, selected_map_layer = 1, native_images = {}, sounds = {}, status = "" }, Studio)
  studio:load_native_project()
  studio:activate({ type = "add_native_node", node_type = "panel" })
  assert(studio.native_dirty and #studio.native_asset_data.root.children == 1)
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
  studio:activate({ type = "start_flow_connection" })
  studio:activate({ type = "native_flow_node", node = studio.native_asset_data.nodes[1] })
  assert(#studio.native_asset_data.edges == 1 and event.id ~= studio.native_asset_data.nodes[1].id)
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
  local recents = RecentProjects.remember(studio.recent_projects, "/another-project", "Another", 1)
  assert(recents[1].path == "/another-project" and #recents <= RecentProjects.LIMIT)
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
