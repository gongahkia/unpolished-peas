-- LÖVE's virtual filesystem cannot open a sibling checkout by pathname.
-- This stays isolated so both native tilesets and ROAG source sheets use the
-- exact same external-image loading boundary.
local ImageLoader = {}

function ImageLoader.load(path)
  local handle, reason = io.open(path, "rb")
  if not handle then error(reason) end
  local payload = handle:read("*a"); handle:close()
  local name = path:match("([^/\\]+)$") or "image.png"
  return love.graphics.newImage(love.filesystem.newFileData(payload, name))
end

return ImageLoader
