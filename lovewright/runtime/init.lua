--- Lovewright Runtime
-- Injected into the LÖVE2D game to enable testing

local runtime = {}

-- Load protocol (relative to lovewright install path)
local protocol

-- Runtime state
local state = {
  server = nil,
  client = nil,
  buffer = "",
  request_id = 0,
  connected = false,
  objects = {},          -- Registered objects: { id = { obj = table, name = string } }
  object_counter = 0,
  synthetic_keys = {},   -- Keys being held synthetically
  synthetic_mouse = {    -- Synthetic mouse state
    x = 0,
    y = 0,
    buttons = {},
  },
  pending_actions = {},  -- Timed actions (e.g., hold key for duration)
  frame_count = 0,
  headless = false,
  screenshot_requested = false,
  screenshot_callback = nil,
}

-- Store original LÖVE2D functions
local original = {
  load = nil,
  update = nil,
  draw = nil,
  keypressed = nil,
  keyreleased = nil,
  mousepressed = nil,
  mousereleased = nil,
  mousemoved = nil,
  quit = nil,
}

-- Original input functions
local original_input = {
  keyboard_isDown = nil,
  mouse_isDown = nil,
  mouse_getPosition = nil,
  mouse_getX = nil,
  mouse_getY = nil,
}

-- Initialize protocol module
local function init_protocol()
  -- Try to load from package path
  local ok, proto = pcall(require, "lovewright.protocol")
  if ok then
    protocol = proto
    return true
  end

  -- Try relative path from runtime
  ok, proto = pcall(function()
    local path = debug.getinfo(1, "S").source:match("@(.+)/runtime/init%.lua$")
    if path then
      package.path = path .. "/?.lua;" .. package.path
      return require("protocol")
    end
    return nil
  end)
  if ok and proto then
    protocol = proto
    return true
  end

  return false
end

-- Socket handling
local socket

local function init_socket()
  local ok, sock = pcall(require, "socket")
  if ok then
    socket = sock
    return true
  end
  return false
end

local function start_server()
  if not socket then return false end

  state.server = socket.tcp()
  state.server:setoption("reuseaddr", true)
  local ok, err = state.server:bind("127.0.0.1", protocol.PORT)
  if not ok then
    print("[lovewright] Failed to bind server: " .. tostring(err))
    return false
  end

  state.server:listen(1)
  state.server:settimeout(0) -- Non-blocking
  print("[lovewright] Server listening on port " .. protocol.PORT)
  return true
end

local function accept_client()
  if not state.server then return end
  if state.client then return end

  local client = state.server:accept()
  if client then
    client:settimeout(0)
    state.client = client
    state.connected = true
    state.buffer = ""
    print("[lovewright] Client connected")

    -- Send ready event
    local msg = protocol.event(protocol.MessageType.READY, {
      version = protocol.VERSION,
      frame = state.frame_count,
    })
    client:send(protocol.frame(msg))
  end
end

local function send_response(response)
  if state.client then
    state.client:send(protocol.frame(response))
  end
end

-- Object registry
function runtime.register(obj, name)
  state.object_counter = state.object_counter + 1
  local id = "obj_" .. state.object_counter
  state.objects[id] = {
    obj = obj,
    name = name,
    id = id,
  }
  return id
end

function runtime.unregister(obj_or_id)
  if type(obj_or_id) == "string" then
    state.objects[obj_or_id] = nil
  else
    for id, entry in pairs(state.objects) do
      if entry.obj == obj_or_id then
        state.objects[id] = nil
        break
      end
    end
  end
end

local function get_objects()
  local result = {}
  for id, entry in pairs(state.objects) do
    local obj = entry.obj
    local info = {
      id = id,
      name = entry.name,
      properties = {},
    }
    -- Extract common properties
    for _, prop in ipairs({ "x", "y", "width", "height", "visible", "active", "health", "score" }) do
      if obj[prop] ~= nil then
        info.properties[prop] = obj[prop]
      end
    end
    table.insert(result, info)
  end
  return result
end

local function query_objects(query)
  local results = {}
  for id, entry in pairs(state.objects) do
    local match = true
    local obj = entry.obj

    if query.name and entry.name ~= query.name then
      match = false
    end

    if query.type and obj.type ~= query.type then
      match = false
    end

    if query.properties then
      for k, v in pairs(query.properties) do
        if obj[k] ~= v then
          match = false
          break
        end
      end
    end

    if match then
      table.insert(results, {
        id = id,
        name = entry.name,
      })
    end
  end
  return results
end

local function get_object_property(object_id, property)
  local entry = state.objects[object_id]
  if not entry then
    return nil, "object not found"
  end
  return entry.obj[property]
end

-- Input simulation
local function simulate_input(input_type, action, params)
  if input_type == "keyboard" then
    if action == "press" then
      state.synthetic_keys[params.key] = true
      if love.keypressed then
        love.keypressed(params.key, params.scancode or params.key, false)
      end
    elseif action == "release" then
      state.synthetic_keys[params.key] = nil
      if love.keyreleased then
        love.keyreleased(params.key, params.scancode or params.key)
      end
    elseif action == "hold" then
      state.synthetic_keys[params.key] = true
      if love.keypressed then
        love.keypressed(params.key, params.scancode or params.key, false)
      end
      -- Schedule release
      table.insert(state.pending_actions, {
        time = love.timer.getTime() + (params.duration or 0.1),
        action = function()
          state.synthetic_keys[params.key] = nil
          if love.keyreleased then
            love.keyreleased(params.key, params.scancode or params.key)
          end
        end,
      })
    end
  elseif input_type == "mouse" then
    if action == "move" then
      state.synthetic_mouse.x = params.x
      state.synthetic_mouse.y = params.y
      if love.mousemoved then
        love.mousemoved(params.x, params.y, params.dx or 0, params.dy or 0, false)
      end
    elseif action == "click" then
      local button = params.button or 1
      if params.x then
        state.synthetic_mouse.x = params.x
        state.synthetic_mouse.y = params.y
      end
      state.synthetic_mouse.buttons[button] = true
      if love.mousepressed then
        love.mousepressed(state.synthetic_mouse.x, state.synthetic_mouse.y, button, false, 1)
      end
      -- Release after short delay
      table.insert(state.pending_actions, {
        time = love.timer.getTime() + 0.05,
        action = function()
          state.synthetic_mouse.buttons[button] = nil
          if love.mousereleased then
            love.mousereleased(state.synthetic_mouse.x, state.synthetic_mouse.y, button, false, 1)
          end
        end,
      })
    elseif action == "press" then
      local button = params.button or 1
      state.synthetic_mouse.buttons[button] = true
      if love.mousepressed then
        love.mousepressed(state.synthetic_mouse.x, state.synthetic_mouse.y, button, false, 1)
      end
    elseif action == "release" then
      local button = params.button or 1
      state.synthetic_mouse.buttons[button] = nil
      if love.mousereleased then
        love.mousereleased(state.synthetic_mouse.x, state.synthetic_mouse.y, button, false, 1)
      end
    end
  end
  return true
end

-- Monkey-patch input functions
local function patch_input()
  -- Keyboard
  original_input.keyboard_isDown = love.keyboard.isDown
  love.keyboard.isDown = function(...)
    -- Check synthetic keys first
    for i = 1, select("#", ...) do
      local key = select(i, ...)
      if state.synthetic_keys[key] then
        return true
      end
    end
    return original_input.keyboard_isDown(...)
  end

  -- Mouse position
  original_input.mouse_getPosition = love.mouse.getPosition
  love.mouse.getPosition = function()
    if state.synthetic_mouse.x ~= 0 or state.synthetic_mouse.y ~= 0 then
      return state.synthetic_mouse.x, state.synthetic_mouse.y
    end
    return original_input.mouse_getPosition()
  end

  original_input.mouse_getX = love.mouse.getX
  love.mouse.getX = function()
    if state.synthetic_mouse.x ~= 0 then
      return state.synthetic_mouse.x
    end
    return original_input.mouse_getX()
  end

  original_input.mouse_getY = love.mouse.getY
  love.mouse.getY = function()
    if state.synthetic_mouse.y ~= 0 then
      return state.synthetic_mouse.y
    end
    return original_input.mouse_getY()
  end

  -- Mouse buttons
  original_input.mouse_isDown = love.mouse.isDown
  love.mouse.isDown = function(...)
    for i = 1, select("#", ...) do
      local button = select(i, ...)
      if state.synthetic_mouse.buttons[button] then
        return true
      end
    end
    return original_input.mouse_isDown(...)
  end
end

-- Screenshot handling
local function take_screenshot()
  if love.graphics then
    local screenshot = love.graphics.newScreenshot()
    local data = screenshot:encode("png")
    return data:getString()
  end
  return nil
end

-- Message handling
local function handle_message(msg)
  local data = protocol.decode(msg)
  if not data then
    return protocol.error_response(nil, "Invalid message format")
  end

  local msg_type = data.type
  local id = data.id
  local params = data.params or {}

  if msg_type == protocol.MessageType.PING then
    return protocol.response(id, { pong = true, frame = state.frame_count })

  elseif msg_type == protocol.MessageType.GET_OBJECTS then
    return protocol.response(id, get_objects())

  elseif msg_type == protocol.MessageType.QUERY_OBJECT then
    local results = query_objects(params)
    return protocol.response(id, results)

  elseif msg_type == protocol.MessageType.GET_PROPERTY then
    local value, err = get_object_property(params.object_id, params.property)
    if err then
      return protocol.error_response(id, err)
    end
    return protocol.response(id, { value = value })

  elseif msg_type == protocol.MessageType.SIMULATE_INPUT then
    local ok = simulate_input(params.input_type, params.action, params)
    return protocol.response(id, { success = ok })

  elseif msg_type == protocol.MessageType.TAKE_SCREENSHOT then
    state.screenshot_requested = true
    state.screenshot_callback = function(data)
      -- Encode as base64
      local b64 = require("lovewright.runtime.base64")
      local encoded = b64.encode(data)
      send_response(protocol.response(id, { screenshot = encoded }))
    end
    return nil -- Response sent later

  elseif msg_type == protocol.MessageType.SHUTDOWN then
    love.event.quit()
    return protocol.response(id, { success = true })

  else
    return protocol.error_response(id, "Unknown message type: " .. tostring(msg_type))
  end
end

local function process_messages()
  if not state.client then return end

  -- Read available data
  local data, err, partial = state.client:receive("*a")
  if data then
    state.buffer = state.buffer .. data
  elseif partial and #partial > 0 then
    state.buffer = state.buffer .. partial
  elseif err == "closed" then
    print("[lovewright] Client disconnected")
    state.client = nil
    state.connected = false
    state.buffer = ""
    return
  end

  -- Process complete messages
  local offset = 1
  while true do
    local msg, new_offset, unframe_err = protocol.unframe(state.buffer, offset)
    if msg then
      local response = handle_message(msg)
      if response then
        send_response(response)
      end
      offset = new_offset
    else
      break
    end
  end

  -- Remove processed data
  if offset > 1 then
    state.buffer = state.buffer:sub(offset)
  end
end

local function process_pending_actions(dt)
  local current_time = love.timer.getTime()
  local i = 1
  while i <= #state.pending_actions do
    local action = state.pending_actions[i]
    if current_time >= action.time then
      action.action()
      table.remove(state.pending_actions, i)
    else
      i = i + 1
    end
  end
end

-- Hook LÖVE2D callbacks
function runtime.init(options)
  options = options or {}
  state.headless = options.headless or false

  if not init_protocol() then
    error("[lovewright] Failed to load protocol module")
  end

  if not init_socket() then
    error("[lovewright] Failed to load socket library")
  end

  if not start_server() then
    error("[lovewright] Failed to start server")
  end

  patch_input()

  -- Hook love.update
  original.update = love.update
  love.update = function(dt)
    accept_client()
    process_messages()
    process_pending_actions(dt)

    if original.update then
      original.update(dt)
    end

    state.frame_count = state.frame_count + 1
  end

  -- Hook love.draw for screenshots
  original.draw = love.draw
  love.draw = function()
    if original.draw then
      original.draw()
    end

    if state.screenshot_requested and state.screenshot_callback then
      local data = take_screenshot()
      if data then
        state.screenshot_callback(data)
      end
      state.screenshot_requested = false
      state.screenshot_callback = nil
    end
  end

  -- Hook love.quit
  original.quit = love.quit
  love.quit = function()
    if state.client then
      state.client:close()
    end
    if state.server then
      state.server:close()
    end
    if original.quit then
      return original.quit()
    end
  end

  print("[lovewright] Runtime initialized")
end

-- Expose for games to register objects
runtime.state = state

return runtime
