-- Explicit read-only smoke check for a real ROAG checkout. This is separate
-- from the deterministic fixture-backed suite in tests/run.lua.
package.path = "./?.lua;./?/init.lua;" .. package.path

local Bridge = require("core.roag_bridge")
local Workspace = require("core.roag_workspace")

local target = arg[1]
assert(target and target ~= "", "Usage: luajit tests/test_live_roag.lua /path/to/roag")
local bridge = Bridge.new(target)
local data, failure = bridge:load()
assert(data, failure and failure.reason)

local workspace, workspace_failure = Workspace.new(target):load()
assert(workspace, workspace_failure and workspace_failure.reason)

local preserved = 0
for _, action in ipairs(data.flow.title_actions) do
  if not Bridge.is_title_action_editable(action) then preserved = preserved + 1 end
end

print("PASS live ROAG workspace loads read-only from " .. target)
print(#data.flow.title_actions .. " title actions; " .. preserved .. " preserved read-only action(s)")
