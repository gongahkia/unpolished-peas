package.path = "./?.lua;./?/init.lua;" .. package.path

local Bridge = require("core.roag_bridge")

local bridge = Bridge.new("../roag")
local data, failure = bridge:load()
assert(data, failure and failure.reason)
assert(#data.catalog.art_packs == 9)
assert(#data.flow.title_actions == 4)
assert(data.art_pack.art_pack_id == "art_pack.roag_kenney_1bit")
assert(Bridge.validate_sprite_data(data.sprites))
assert(not pcall(function() bridge:path("active_run") end))
print("PASS unpolished-bees bridge loads ROAG presentation-only workspace")
print("1 passed, 0 failed")
