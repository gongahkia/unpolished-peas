-- Checked-in ROAG fixture helpers. Normal tests never read a sibling checkout.
local Fs = require("core.fs")
local Json = require("core.json")

local Fixture = { ROOT = "tests/fixtures/roag" }

local function command_succeeded(result)
  return result == true or result == 0
end

function Fixture.copy()
  local root = os.tmpname()
  os.remove(root)
  local copied = os.execute("cp -R " .. string.format("%q", Fixture.ROOT) .. " " .. string.format("%q", root))
  assert(command_succeeded(copied), "Could not create temporary ROAG fixture copy")
  return root
end

function Fixture.read_json(root, relative)
  local payload, reason = Fs.read(root .. "/" .. relative)
  assert(payload, reason)
  local data, decode_reason = Json.decode(payload)
  assert(data, decode_reason)
  return data
end

function Fixture.write_json(root, relative, data)
  local payload, reason = Json.encode(data)
  assert(payload, reason)
  assert(Fs.write_atomic(root .. "/" .. relative, payload .. "\n"))
end

return Fixture
