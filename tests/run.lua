package.path = "./?.lua;./?/init.lua;" .. package.path

local Bridge = require("core.roag_bridge")
local Fixture = require("tests.roag_fixture")
local Harness = require("tests.harness")

local bridge = Bridge.new(Fixture.ROOT)
local data, failure = bridge:load()
assert(data, failure and failure.reason)
assert(#data.catalog.art_packs == 1)
assert(#data.flow.title_actions == 5)
assert(data.art_pack.art_pack_id == "art_pack.roag_kenney_1bit")
assert(Bridge.validate_sprite_data(data.sprites))
assert(not pcall(function() bridge:path("active_run") end))
print("PASS unpolished-bees bridge loads checked-in ROAG presentation fixture")

assert(loadfile("tests/test_engine.lua"))()
assert(loadfile("tests/test_roag_bridge.lua"))()
assert(loadfile("tests/test_roag_workspace.lua"))()
Harness.summary()
print("PASS complete suite")
