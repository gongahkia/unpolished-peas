-- Small, dependency-free filesystem boundary shared by project and ROAG modes.
-- All public write APIs accept project-relative paths only.
local Fs = {}

function Fs.safe_relative(path)
  return type(path) == "string" and path ~= "" and not path:match("^[/\\]")
    and not path:match("^[A-Za-z]:") and not path:match("^%.%.[/\\]?")
    and not path:match("[/\\]%.%.[/\\]?") and not path:match("[/\\]%.?$")
end

function Fs.join(root, relative)
  assert(type(root) == "string" and root ~= "", "Filesystem root is required")
  assert(Fs.safe_relative(relative), "Unsafe relative path")
  return root:gsub("[/\\]+$", "") .. "/" .. relative
end

function Fs.read(path)
  local handle, reason = io.open(path, "rb")
  if not handle then return nil, reason end
  local payload = handle:read("*a")
  handle:close()
  return payload
end

function Fs.exists(path)
  local handle = io.open(path, "rb")
  if not handle then return false end
  handle:close()
  return true
end

function Fs.basename(path)
  return type(path) == "string" and path:match("([^/\\]+)$") or nil
end

function Fs.write_atomic(path, payload)
  if type(payload) ~= "string" then return nil, "Payload must be a string" end
  local temporary = path .. ".unpolished-bees.tmp"
  local handle, reason = io.open(temporary, "wb")
  if not handle then return nil, reason end
  local ok, write_reason = handle:write(payload)
  handle:close()
  if not ok then return nil, write_reason end
  local verified, verify_reason = Fs.read(temporary)
  if verified ~= payload then return nil, verify_reason or "Temporary write verification failed" end
  local renamed, rename_reason = os.rename(temporary, path)
  if not renamed then return nil, rename_reason end
  return true
end

function Fs.copy_atomic(source, destination)
  local payload, reason = Fs.read(source)
  if not payload then return nil, reason end
  return Fs.write_atomic(destination, payload)
end

return Fs
