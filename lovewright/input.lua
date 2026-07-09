--- Input simulation module for lovewright
-- Provides keyboard, mouse, and gamepad input simulation

local protocol = require("lovewright.protocol")
local Trace = require("lovewright.trace")

local Input = {}

-- Keyboard controller
local Keyboard = {}
Keyboard.__index = Keyboard

function Keyboard.new(game)
  local self = setmetatable({}, Keyboard)
  self.game = game
  return self
end

function Keyboard:press(key, scancode)
  self.game:_request(protocol.MessageType.SIMULATE_INPUT, {
    input_type = "keyboard",
    action = "press",
    key = key,
    scancode = scancode,
  })
  Trace.action(self.game, "keyboard:press", { key = key })
  return self
end

function Keyboard:release(key, scancode)
  self.game:_request(protocol.MessageType.SIMULATE_INPUT, {
    input_type = "keyboard",
    action = "release",
    key = key,
    scancode = scancode,
  })
  Trace.record("action", "keyboard:release", { key = key })
  return self
end

function Keyboard:hold(key, duration, scancode)
  duration = duration or 0.1
  self.game:_request(protocol.MessageType.SIMULATE_INPUT, {
    input_type = "keyboard",
    action = "hold",
    key = key,
    scancode = scancode,
    duration = duration,
  })

  -- Wait for hold duration plus a bit
  local socket = require("socket")
  socket.sleep(duration + 0.05)

  Trace.action(self.game, "keyboard:hold", { key = key, duration = duration })
  return self
end

function Keyboard:type(text, delay)
  delay = delay or 0.05
  local socket = require("socket")

  for i = 1, #text do
    local char = text:sub(i, i)
    local key = char:lower()

    -- Handle shift for uppercase and symbols
    local needs_shift = char:match("[A-Z]") or char:match('[~!@#$%%^&*()_+{}|:"<>?]')

    if needs_shift then
      self:press("lshift")
    end

    self:press(key)
    socket.sleep(delay / 2)
    self:release(key)

    if needs_shift then
      self:release("lshift")
    end

    socket.sleep(delay / 2)
  end

  return self
end

-- Mouse controller
local Mouse = {}
Mouse.__index = Mouse

function Mouse.new(game)
  local self = setmetatable({}, Mouse)
  self.game = game
  return self
end

function Mouse:move(x, y)
  self.game:_request(protocol.MessageType.SIMULATE_INPUT, {
    input_type = "mouse",
    action = "move",
    x = x,
    y = y,
  })
  -- record only (no snapshot): drags generate many moves
  Trace.record("action", "mouse:move", { x = x, y = y })
  return self
end

function Mouse:click(x, y, button)
  button = button or 1
  local params = {
    input_type = "mouse",
    action = "click",
    button = button,
  }
  if x then
    params.x = x
    params.y = y
  end
  self.game:_request(protocol.MessageType.SIMULATE_INPUT, params)

  -- Brief wait for click to process
  local socket = require("socket")
  socket.sleep(0.1)

  Trace.action(self.game, "mouse:click", { x = x, y = y, button = button })
  return self
end

function Mouse:dblclick(x, y, button)
  button = button or 1
  self:click(x, y, button)
  local socket = require("socket")
  socket.sleep(0.05)
  self:click(x, y, button)
  return self
end

function Mouse:press(button)
  button = button or 1
  self.game:_request(protocol.MessageType.SIMULATE_INPUT, {
    input_type = "mouse",
    action = "press",
    button = button,
  })
  return self
end

function Mouse:release(button)
  button = button or 1
  self.game:_request(protocol.MessageType.SIMULATE_INPUT, {
    input_type = "mouse",
    action = "release",
    button = button,
  })
  return self
end

function Mouse:drag(from_x, from_y, to_x, to_y, button, duration)
  button = button or 1
  duration = duration or 0.2
  local socket = require("socket")

  Trace.record("action", "mouse:drag", {
    from = from_x .. "," .. from_y,
    to = to_x .. "," .. to_y,
    button = button,
  })

  -- Move to start, press, move to end, release
  self:move(from_x, from_y)
  socket.sleep(0.05)
  self:press(button)
  socket.sleep(0.05)

  -- Interpolate movement
  local steps = math.max(1, math.floor(duration / 0.016))
  for i = 1, steps do
    local t = i / steps
    local x = from_x + (to_x - from_x) * t
    local y = from_y + (to_y - from_y) * t
    self:move(x, y)
    socket.sleep(duration / steps)
  end

  self:release(button)
  return self
end

function Mouse:wheel(dx, dy)
  -- Note: LÖVE2D wheel events are discrete
  -- This would require additional runtime support
  self.game:_request(protocol.MessageType.SIMULATE_INPUT, {
    input_type = "mouse",
    action = "wheel",
    dx = dx or 0,
    dy = dy or 0,
  })
  return self
end

-- Gamepad controller
local Gamepad = {}
Gamepad.__index = Gamepad

function Gamepad.new(game, index)
  local self = setmetatable({}, Gamepad)
  self.game = game
  self.index = index or 1
  return self
end

function Gamepad:press(button)
  self.game:_request(protocol.MessageType.SIMULATE_INPUT, {
    input_type = "gamepad",
    action = "press",
    button = button,
    index = self.index,
  })
  return self
end

function Gamepad:release(button)
  self.game:_request(protocol.MessageType.SIMULATE_INPUT, {
    input_type = "gamepad",
    action = "release",
    button = button,
    index = self.index,
  })
  return self
end

function Gamepad:axis(axis, value)
  self.game:_request(protocol.MessageType.SIMULATE_INPUT, {
    input_type = "gamepad",
    action = "axis",
    axis = axis,
    value = value,
    index = self.index,
  })
  return self
end

function Gamepad:leftStick(x, y)
  self:axis("leftx", x)
  self:axis("lefty", y)
  return self
end

function Gamepad:rightStick(x, y)
  self:axis("rightx", x)
  self:axis("righty", y)
  return self
end

-- Factory functions
function Input.keyboard(game)
  return Keyboard.new(game)
end

function Input.mouse(game)
  return Mouse.new(game)
end

function Input.gamepad(game, index)
  return Gamepad.new(game, index)
end

return Input
