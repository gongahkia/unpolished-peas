package.path = "./?.lua;./?/init.lua;" .. package.path

local Workspace = require("core.roag_workspace")

local workspace = Workspace.new("../roag")
local loaded, failure = workspace:load()
assert(loaded, failure and failure.reason)
assert(#loaded.corpora.dungeon.rooms == 10)
assert(#loaded.corpora.reactor.rooms == 10)
assert(not Workspace.validate_room({ format = "roag.room_template", version = 1, id = "room.bad", biome = "dungeon", width = 2, height = 2, layout = { ".." } }))
assert(not Workspace.validate_room({ format = "roag.room_template", version = 1, id = "room.dungeon.open_edge", biome = "dungeon", tags = {}, weight = 1, allow_rotation = false, width = 2, height = 2, connectors = {}, legend = { ["."] = "material.terrain.air" }, layout = { "..", ".." } }))
print("PASS ROAG JSON workspace loads presentation and both room corpora")
print("1 passed, 0 failed")
