-- Unpolished Bees is a sibling presentation authoring application.  It is not
-- mounted by ROAG and never constructs the game's application/session state.
package.path = "./?.lua;./?/init.lua;" .. package.path

local Studio = require("ui.studio")
local studio

function love.load(arguments)
  studio = Studio.new(arguments or arg or {})
end

function love.update(dt)
  studio:update(dt)
end

function love.draw()
  studio:draw()
end

function love.keypressed(...)
  studio:keypressed(...)
end

function love.textinput(...)
  studio:textinput(...)
end

function love.mousepressed(...)
  studio:mousepressed(...)
end

function love.mousereleased(...)
  studio:mousereleased(...)
end

function love.mousemoved(...)
  studio:mousemoved(...)
end

function love.wheelmoved(...)
  studio:wheelmoved(...)
end

function love.filedropped(...)
  studio:filedropped(...)
end

function love.quit()
  return studio:quit()
end
