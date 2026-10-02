-- Tiny dependency-free test registry. The count is derived from executions so
-- adding a test cannot leave a stale hand-written success total behind.
local Harness = { passed = 0 }

function Harness.test(name, fn)
  local ok, reason = pcall(fn)
  assert(ok, name .. ": " .. tostring(reason))
  Harness.passed = Harness.passed + 1
  print("PASS " .. name)
end

function Harness.summary()
  print(Harness.passed .. " passed, 0 failed")
end

return Harness
