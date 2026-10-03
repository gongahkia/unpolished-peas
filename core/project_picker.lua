-- Native project chooser without a third-party runtime dependency. Commands
-- are fixed strings: user-selected paths are read from stdout and never
-- interpolated into a shell command.
local Picker = {}

local function run(command)
  local handle, reason = io.popen(command, "r")
  if not handle then return nil, reason or "Could not start the system picker" end
  local value = handle:read("*a") or ""
  handle:close()
  value = value:gsub("[\r\n]+$", "")
  if value == "" then return nil, "cancelled" end
  return value
end

local function os_name()
  return love and love.system and love.system.getOS and love.system.getOS() or "Unknown"
end

function Picker.choose_folder(purpose)
  local creating = purpose == "new_project"
  local system = os_name()
  if system == "OS X" then
    return run(creating
      and [[osascript -e 'POSIX path of (choose folder with prompt "Choose the folder for the new Unpolished Bees project")']]
      or [[osascript -e 'POSIX path of (choose folder with prompt "Choose an Unpolished Bees project folder")']])
  elseif system == "Windows" then
    return run(creating
      and [[powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; $picker = New-Object System.Windows.Forms.FolderBrowserDialog; $picker.Description = 'Choose the folder for the new Unpolished Bees project'; if ($picker.ShowDialog() -eq 'OK') { [Console]::Write($picker.SelectedPath) }"]]
      or [[powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; $picker = New-Object System.Windows.Forms.FolderBrowserDialog; $picker.Description = 'Choose an Unpolished Bees project folder'; if ($picker.ShowDialog() -eq 'OK') { [Console]::Write($picker.SelectedPath) }"]])
  elseif system == "Linux" then
    local path = run(creating
      and [[zenity --file-selection --directory --title='Choose the folder for the new Unpolished Bees project' 2>/dev/null]]
      or [[zenity --file-selection --directory --title='Choose an Unpolished Bees project folder' 2>/dev/null]])
    if path then return path end
    return run([[kdialog --getexistingdirectory 2>/dev/null]])
  end
  return nil, "Native folder selection is unavailable on this platform; paste the project folder path instead."
end

function Picker.choose_manifest()
  local system = os_name()
  if system == "OS X" then
    return run([[osascript -e 'POSIX path of (choose file with prompt "Choose unpolished_bees.project.json" of type {"json"})']])
  elseif system == "Windows" then
    return run([[powershell -NoProfile -Command "Add-Type -AssemblyName System.Windows.Forms; $picker = New-Object System.Windows.Forms.OpenFileDialog; $picker.Title = 'Choose unpolished_bees.project.json'; $picker.Filter = 'Unpolished Bees project manifest|unpolished_bees.project.json|JSON files|*.json'; if ($picker.ShowDialog() -eq 'OK') { [Console]::Write($picker.FileName) }"]])
  elseif system == "Linux" then
    local path = run([[zenity --file-selection --title='Choose unpolished_bees.project.json' --file-filter='Unpolished Bees project manifest | unpolished_bees.project.json' 2>/dev/null]])
    if path then return path end
    return run([[kdialog --getopenfilename '*.project.json' 2>/dev/null]])
  end
  return nil, "Native manifest selection is unavailable on this platform; paste the manifest or project-folder path instead."
end

return Picker
