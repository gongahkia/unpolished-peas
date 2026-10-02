package.path = "./?.lua;./?/init.lua;" .. package.path

local Bridge = require("core.roag_bridge")
local Fs = require("core.fs")
local Json = require("core.json")
local Fixture = require("tests.roag_fixture")
local Harness = require("tests.harness")

local test = Harness.test

test("baseline editable ROAG title actions load from the checked-in fixture", function()
  local root = Fixture.copy()
  local flow = Fixture.read_json(root, "content/presentation/flow.json")
  table.remove(flow.title_actions, #flow.title_actions)
  Fixture.write_json(root, "content/presentation/flow.json", flow)
  local data = assert(Bridge.new(root):load())
  assert(#data.flow.title_actions == 4)
  for _, action in ipairs(data.flow.title_actions) do assert(Bridge.is_title_action_editable(action)) end
end)

test("structurally safe unfamiliar ROAG title actions load as preserved read-only data", function()
  local data = assert(Bridge.new(Fixture.ROOT):load())
  local action = data.flow.title_actions[5]
  assert(action.id == "help" and action.target == "help")
  assert(not Bridge.is_title_action_editable(action))
end)

test("publishing unrelated presentation edits preserves unfamiliar ROAG action data and order", function()
  local root = Fixture.copy()
  local bridge = Bridge.new(root)
  local data = assert(bridge:load())
  local before = assert(Json.encode(data.flow.title_actions[5]))
  data.screens.screens[1].title = "UPDATED FIXTURE TITLE"
  assert(bridge:save(data))
  local reloaded = assert(Bridge.new(root):load())
  assert(reloaded.screens.screens[1].title == "UPDATED FIXTURE TITLE")
  assert(#reloaded.flow.title_actions == 5)
  assert(reloaded.flow.title_actions[5].id == "help")
  assert(Json.encode(reloaded.flow.title_actions[5]) == before)
end)

test("malformed ROAG title actions still fail validation", function()
  local root = Fixture.copy()
  local flow = Fixture.read_json(root, "content/presentation/flow.json")
  flow.title_actions[5].target = ""
  Fixture.write_json(root, "content/presentation/flow.json", flow)
  local data, failure = Bridge.new(root):load()
  assert(not data and failure.code == "invalid_flow")
end)

test("ROAG bridge publish writes only allow-listed presentation files", function()
  local root = Fixture.copy()
  local sentinel = root .. "/active_run.json"
  assert(Fs.write_atomic(sentinel, "do not touch\n"))
  local bridge = Bridge.new(root)
  local data = assert(bridge:load())
  data.screens.screens[1].subtitle = "UPDATED WITHOUT TOUCHING SAVES"
  assert(bridge:save(data))
  assert(Fs.read(sentinel) == "do not touch\n")
  assert(not pcall(function() bridge:path("active_run") end))
end)
