-- Small, dependency-free filesystem boundary shared by project and ROAG modes.
-- All public write APIs accept project-relative paths only.
local Fs = {}

-- Project roots are chosen outside LÖVE's save sandbox.  Use LuaJIT's native
-- FFI boundary for the small amount of directory work needed by project
-- creation instead of interpolating author-controlled paths into shell
-- commands.  File payload writes remain ordinary atomic writes below.
local ffi_ok, ffi = pcall(require, "ffi")
local platform = ffi_ok and ffi.os or nil

if platform == "OSX" then
  -- The exported Darwin readdir symbol uses the compact dirent layout.
  ffi.cdef[[
    typedef struct __dirstream DIR;
    struct ub_dirent { unsigned int d_ino; unsigned short d_reclen; unsigned char d_type; unsigned char d_namlen; char d_name[1024]; };
    DIR *opendir(const char *);
    struct ub_dirent *readdir(DIR *);
    int closedir(DIR *);
    int mkdir(const char *path, unsigned int mode);
  ]]
elseif platform == "Linux" or platform == "BSD" then
  ffi.cdef[[
    typedef struct __dirstream DIR;
    struct ub_dirent { unsigned long long d_ino; long long d_off; unsigned short d_reclen; unsigned char d_type; char d_name[256]; };
    DIR *opendir(const char *);
    struct ub_dirent *readdir(DIR *);
    int closedir(DIR *);
    int mkdir(const char *path, unsigned int mode);
  ]]
elseif platform == "Windows" then
  ffi.cdef[[
    typedef void *HANDLE;
    typedef unsigned long DWORD;
    typedef int BOOL;
    typedef struct {
      DWORD dwFileAttributes;
      DWORD ftCreationTime_dwLowDateTime; DWORD ftCreationTime_dwHighDateTime;
      DWORD ftLastAccessTime_dwLowDateTime; DWORD ftLastAccessTime_dwHighDateTime;
      DWORD ftLastWriteTime_dwLowDateTime; DWORD ftLastWriteTime_dwHighDateTime;
      DWORD nFileSizeHigh; DWORD nFileSizeLow; DWORD dwReserved0; DWORD dwReserved1;
      char cFileName[260]; char cAlternateFileName[14];
    } WIN32_FIND_DATAA;
    HANDLE FindFirstFileA(const char *path, WIN32_FIND_DATAA *data);
    BOOL FindNextFileA(HANDLE handle, WIN32_FIND_DATAA *data);
    BOOL FindClose(HANDLE handle);
    DWORD GetLastError(void);
    int _mkdir(const char *path);
  ]]
end

local function native_reason(operation, code)
  return operation .. " (system error " .. tostring(code or "unknown") .. ")"
end

local function posix_directory(path)
  local directory = ffi.C.opendir(path)
  if directory == nil then
    local code = ffi.errno()
    if code == 2 then return "missing" end -- ENOENT
    if code == 20 then return "file" end -- ENOTDIR
    return nil, native_reason("Could not inspect this project folder", code)
  end
  return "directory", directory
end

local function windows_directory(path)
  local data = ffi.new("WIN32_FIND_DATAA[1]")
  local handle = ffi.C.FindFirstFileA(path, data)
  if ffi.cast("intptr_t", handle) == -1 then
    local code = ffi.C.GetLastError()
    if code == 2 or code == 3 then return "missing" end -- file/path not found
    return nil, native_reason("Could not inspect this project folder", code)
  end
  ffi.C.FindClose(handle)
  if bit.band(data[0].dwFileAttributes, 0x10) == 0 then return "file" end -- FILE_ATTRIBUTE_DIRECTORY
  return "directory"
end

-- Return "missing", "file", or "directory".  The optional second value is
-- a human-readable OS inspection failure, not a filesystem mutation result.
function Fs.directory_state(path)
  if type(path) ~= "string" or path == "" then return nil, "Project folder is required" end
  if not ffi_ok or not platform then return nil, "Native project-folder inspection is unavailable on this platform" end
  if platform == "Windows" then return windows_directory(path) end
  if platform == "OSX" or platform == "Linux" or platform == "BSD" then
    local state, directory_or_reason = posix_directory(path)
    if state ~= "directory" then return state, directory_or_reason end
    ffi.C.closedir(directory_or_reason)
    return state
  end
  return nil, "Native project-folder inspection is unavailable on this platform"
end

function Fs.directory_entries(path)
  local state, reason = Fs.directory_state(path)
  if state ~= "directory" then return nil, reason or "Project folder is not a directory" end
  if platform == "Windows" then
    local pattern = path:gsub("[/\\]+$", "") .. "\\*"
    local data = ffi.new("WIN32_FIND_DATAA[1]")
    local handle = ffi.C.FindFirstFileA(pattern, data)
    if ffi.cast("intptr_t", handle) == -1 then return nil, native_reason("Could not inspect this project folder", ffi.C.GetLastError()) end
    local entries = {}
    repeat
      local name = ffi.string(data[0].cFileName)
      if name ~= "." and name ~= ".." then entries[#entries + 1] = name end
    until ffi.C.FindNextFileA(handle, data) == 0
    ffi.C.FindClose(handle)
    table.sort(entries)
    return entries
  end
  local directory = ffi.C.opendir(path)
  if directory == nil then return nil, native_reason("Could not inspect this project folder", ffi.errno()) end
  local entries = {}
  while true do
    local entry = ffi.C.readdir(directory)
    if entry == nil then break end
    local name = ffi.string(entry.d_name)
    if name ~= "." and name ~= ".." then entries[#entries + 1] = name end
  end
  ffi.C.closedir(directory)
  table.sort(entries)
  return entries
end

function Fs.directory_empty(path)
  local entries, reason = Fs.directory_entries(path)
  if not entries then return nil, reason end
  return #entries == 0
end

-- Create exactly one directory.  Callers must verify that its parent already
-- exists, which prevents a mistyped project path from creating an unexpected
-- tree of parent folders.
function Fs.create_directory(path)
  local state, reason = Fs.directory_state(path)
  if state == "directory" then return true end
  if state ~= "missing" then return nil, reason or "Project folder is not a directory" end
  local created
  if platform == "Windows" then created = ffi.C._mkdir(path) else created = ffi.C.mkdir(path, tonumber("755", 8)) end
  if created == 0 then return true end
  local code = ffi.errno()
  if code == 17 and Fs.directory_state(path) == "directory" then return true end -- EEXIST race
  return nil, native_reason("Could not create project folder", code)
end

function Fs.parent(path)
  if type(path) ~= "string" then return nil end
  local clean = path:gsub("[/\\]+$", "")
  if clean == "" then return nil end
  local parent = clean:match("^(.*)[/\\][^/\\]+$")
  if parent == "" and clean:match("^/") then return "/" end
  if parent and parent ~= "" then return parent end
  return nil
end

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
