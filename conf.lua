function love.conf(t)
  t.identity = "unpolished-bees"
  t.window.title = "Unpolished Bees — ROAG Presentation Studio"
  t.window.width, t.window.height = 1360, 840
  t.window.minwidth, t.window.minheight = 960, 640
  t.window.resizable = true
  t.console = false
  -- Keep the editor’s baseline lean; the data/runtime core does not need
  -- these LÖVE subsystems and can opt into new capabilities deliberately.
  t.modules.joystick = false
  t.modules.physics = false
  t.modules.thread = false
  t.modules.touch = false
  t.modules.video = false
end
