-- Bounded JSON snapshots for editor-facing, serializable documents.
local Json = require("core.json")

local History = {}
History.__index = History

local function clone(value)
  local encoded, reason = Json.encode(value)
  assert(encoded, reason)
  local decoded, decode_reason = Json.decode(encoded)
  assert(decoded, decode_reason)
  return decoded
end

function History.new(limit)
  return setmetatable({ limit = limit or 100, undo_stack = {}, redo_stack = {} }, History)
end

function History:record(value)
  self.undo_stack[#self.undo_stack + 1] = clone(value)
  if #self.undo_stack > self.limit then table.remove(self.undo_stack, 1) end
  self.redo_stack = {}
end

function History:undo(value)
  local previous = self.undo_stack[#self.undo_stack]
  if not previous then return nil end
  self.redo_stack[#self.redo_stack + 1] = clone(value)
  table.remove(self.undo_stack)
  return clone(previous)
end

function History:redo(value)
  local following = self.redo_stack[#self.redo_stack]
  if not following then return nil end
  self.undo_stack[#self.undo_stack + 1] = clone(value)
  table.remove(self.redo_stack)
  return clone(following)
end

function History:can_undo()
  return #self.undo_stack > 0
end

function History:can_redo()
  return #self.redo_stack > 0
end

return History
