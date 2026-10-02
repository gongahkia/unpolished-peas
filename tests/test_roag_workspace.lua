package.path = "./?.lua;./?/init.lua;" .. package.path

local Workspace = require("core.roag_workspace")
local Fixture = require("tests.roag_fixture")
local Harness = require("tests.harness")

Harness.test("ROAG JSON workspace loads fixture presentation and both room corpora", function()
  local workspace = Workspace.new(Fixture.ROOT)
  local loaded, failure = workspace:load()
  assert(loaded, failure and failure.reason)
  assert(#loaded.corpora.dungeon.rooms == 1)
  assert(#loaded.corpora.reactor.rooms == 1)
  assert(not Workspace.validate_room({ format = "roag.room_template", version = 1, id = "room.bad", biome = "dungeon", width = 2, height = 2, layout = { ".." } }))
  assert(not Workspace.validate_room({ format = "roag.room_template", version = 1, id = "room.dungeon.open_edge", biome = "dungeon", tags = {}, weight = 1, allow_rotation = false, width = 2, height = 2, connectors = {}, legend = { ["."] = "material.terrain.air" }, layout = { "..", ".." } }))
end)
