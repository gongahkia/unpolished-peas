-- Small persistence boundary for the editor's project launcher. This lives in
-- LÖVE's application save directory, never in an opened project.
local Json = require("core.json")

local RecentProjects = {
  FILE = "recent_projects.json",
  VERSION = 1,
  LIMIT = 8,
}

local function filesystem()
  return love and love.filesystem or nil
end

local function clean_entry(entry)
  if type(entry) ~= "table" or type(entry.path) ~= "string" or entry.path == "" then return nil end
  return {
    path = entry.path,
    name = type(entry.name) == "string" and entry.name or "Untitled Project",
    opened_at = type(entry.opened_at) == "number" and entry.opened_at or 0,
  }
end

function RecentProjects.load()
  local fs = filesystem()
  if not fs then return {} end
  local payload = fs.read(RecentProjects.FILE)
  if not payload then return {} end
  local data = Json.decode(payload)
  if type(data) ~= "table" or data.version ~= RecentProjects.VERSION or type(data.projects) ~= "table" then return {} end
  local entries, seen = {}, {}
  for _, entry in ipairs(data.projects) do
    local value = clean_entry(entry)
    if value and not seen[value.path] and #entries < RecentProjects.LIMIT then
      entries[#entries + 1], seen[value.path] = value, true
    end
  end
  return entries
end

function RecentProjects.save(entries)
  local fs = filesystem()
  if not fs then return true end
  local payload = Json.encode({ version = RecentProjects.VERSION, projects = entries or {} })
  if not payload then return nil, "Could not encode recent projects" end
  local ok, reason = fs.write(RecentProjects.FILE, payload .. "\n")
  return ok or nil, reason
end

function RecentProjects.remember(entries, path, name, opened_at)
  local updated = {
    { path = path, name = name or "Untitled Project", opened_at = opened_at or os.time() },
  }
  for _, entry in ipairs(entries or {}) do
    local value = clean_entry(entry)
    if value and value.path ~= path and #updated < RecentProjects.LIMIT then updated[#updated + 1] = value end
  end
  return updated
end

return RecentProjects
