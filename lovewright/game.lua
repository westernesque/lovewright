--- Game launcher and controller for lovewright
-- Launches LÖVE2D games with runtime injection and provides control API

local protocol = require("lovewright.protocol")

local Game = {}
Game.__index = Game

-- Default options
local defaults = {
  width = 800,
  height = 600,
  headless = false,
  love_path = "love",
  timeout = 5000,  -- Connection timeout in ms
}

-- Create wrapper files for runtime injection
local function create_wrapper(game_path, options)
  local lovewright_path = debug.getinfo(1, "S").source:match("@(.+)/game%.lua$")
  if not lovewright_path then
    lovewright_path = "."
  end

  -- Create a temporary wrapper that loads the runtime
  local wrapper = string.format([[
-- Lovewright runtime wrapper
package.path = %q .. "/?.lua;" .. %q .. "/runtime/?.lua;" .. package.path

-- Load and initialize runtime
local runtime = require("lovewright.runtime")

-- Store original game path
local game_path = %q

-- Override love.conf to inject runtime settings
local original_conf = love.conf
love.conf = function(t)
  if original_conf then
    original_conf(t)
  end
  t.window = t.window or {}
  t.window.width = %d
  t.window.height = %d
  %s
end

-- Initialize runtime early
function love.load(arg)
  runtime.init({ headless = %s })

  -- Load the actual game
  local chunk, err = love.filesystem.load(game_path .. "/main.lua")
  if chunk then
    chunk()
    if love.load then
      love.load(arg)
    end
  else
    error("Failed to load game: " .. tostring(err))
  end
end
]],
    lovewright_path,
    lovewright_path,
    game_path,
    options.width,
    options.height,
    options.headless and "t.modules.window = false" or "",
    options.headless and "true" or "false"
  )

  return wrapper
end

-- Find or create temp directory
local function get_temp_dir()
  local tmpdir = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
  local lw_tmp = tmpdir .. "/lovewright"
  os.execute("mkdir -p " .. lw_tmp .. " 2>/dev/null")
  return lw_tmp
end

-- Launch LÖVE2D with the game
function Game.launch(options)
  options = options or {}
  for k, v in pairs(defaults) do
    if options[k] == nil then
      options[k] = v
    end
  end

  if not options.path then
    error("Game path is required")
  end

  local self = setmetatable({}, Game)
  self.options = options
  self.process = nil
  self.socket = nil
  self.connected = false
  self.buffer = ""
  self.request_id = 0
  self.pending_requests = {}
  self.frame_count = 0

  -- Create wrapper
  local wrapper = create_wrapper(options.path, options)
  local temp_dir = get_temp_dir()
  local wrapper_path = temp_dir .. "/wrapper_" .. os.time()
  os.execute("mkdir -p " .. wrapper_path)

  local wrapper_file = io.open(wrapper_path .. "/main.lua", "w")
  wrapper_file:write(wrapper)
  wrapper_file:close()

  self.wrapper_path = wrapper_path

  -- Build command
  local cmd = string.format(
    '%s "%s" 2>&1 &',
    options.love_path,
    wrapper_path
  )

  -- Launch process
  os.execute(cmd)

  -- Connect to runtime
  local socket = require("socket")
  local start_time = socket.gettime()
  local timeout_sec = options.timeout / 1000

  while socket.gettime() - start_time < timeout_sec do
    local client = socket.tcp()
    client:settimeout(0.1)
    local ok, err = client:connect("127.0.0.1", protocol.PORT)
    if ok then
      self.socket = client
      self.socket:settimeout(0)
      self.connected = true
      break
    end
    socket.sleep(0.1)
  end

  if not self.connected then
    self:close()
    error("Failed to connect to game runtime (timeout)")
  end

  -- Wait for ready event
  local ready = self:_wait_for_event(protocol.MessageType.READY, 5000)
  if not ready then
    self:close()
    error("Game runtime did not send ready event")
  end

  return self
end

-- Send a request and wait for response
function Game:_request(msg_type, params, timeout)
  if not self.connected then
    error("Not connected to game")
  end

  timeout = timeout or 5000
  self.request_id = self.request_id + 1
  local id = self.request_id

  local msg = protocol.request(msg_type, id, params)
  self.socket:send(protocol.frame(msg))

  -- Wait for response
  local socket = require("socket")
  local start_time = socket.gettime()
  local timeout_sec = timeout / 1000

  while socket.gettime() - start_time < timeout_sec do
    self:_process_messages()

    if self.pending_requests[id] then
      local response = self.pending_requests[id]
      self.pending_requests[id] = nil
      if response.error then
        error(response.error.message)
      end
      return response.result
    end

    socket.sleep(0.01)
  end

  error("Request timeout: " .. msg_type)
end

-- Wait for a specific event
function Game:_wait_for_event(event_type, timeout)
  timeout = timeout or 5000
  local socket = require("socket")
  local start_time = socket.gettime()
  local timeout_sec = timeout / 1000

  while socket.gettime() - start_time < timeout_sec do
    self:_process_messages()

    if self._last_event and self._last_event.type == event_type then
      local event = self._last_event
      self._last_event = nil
      return event.data
    end

    socket.sleep(0.01)
  end

  return nil
end

-- Process incoming messages
function Game:_process_messages()
  if not self.socket then return end

  local data, err, partial = self.socket:receive("*a")
  if data then
    self.buffer = self.buffer .. data
  elseif partial and #partial > 0 then
    self.buffer = self.buffer .. partial
  elseif err == "closed" then
    self.connected = false
    return
  end

  -- Process complete messages
  local offset = 1
  while true do
    local msg, new_offset = protocol.unframe(self.buffer, offset)
    if msg then
      local decoded = protocol.decode(msg)
      if decoded then
        if decoded.type == protocol.MessageType.RESULT or decoded.type == protocol.MessageType.ERROR then
          self.pending_requests[decoded.id] = decoded
        else
          -- Event
          self._last_event = decoded
          if decoded.type == protocol.MessageType.FRAME then
            self.frame_count = decoded.data.frame or self.frame_count
          end
        end
      end
      offset = new_offset
    else
      break
    end
  end

  if offset > 1 then
    self.buffer = self.buffer:sub(offset)
  end
end

-- Public API

function Game:ping()
  local result = self:_request(protocol.MessageType.PING)
  return result and result.pong == true
end

function Game:locator(query)
  local Locator = require("lovewright.locator")
  return Locator.new(self, query)
end

function Game:keyboard()
  local Input = require("lovewright.input")
  return Input.keyboard(self)
end

function Game:mouse()
  local Input = require("lovewright.input")
  return Input.mouse(self)
end

function Game:screenshot(filename)
  local result = self:_request(protocol.MessageType.TAKE_SCREENSHOT, {}, 10000)
  if result and result.screenshot then
    -- Decode base64 and save
    local base64 = require("lovewright.runtime.base64")
    local data = base64.decode(result.screenshot)
    local file = io.open(filename, "wb")
    if file then
      file:write(data)
      file:close()
      return true
    end
  end
  return false
end

function Game:waitFor(condition, timeout)
  timeout = timeout or 5000
  local socket = require("socket")
  local start_time = socket.gettime()
  local timeout_sec = timeout / 1000

  while socket.gettime() - start_time < timeout_sec do
    if condition() then
      return true
    end
    self:_process_messages()
    socket.sleep(0.016)  -- ~60fps
  end

  error("waitFor timeout")
end

function Game:waitForObject(name, timeout)
  timeout = timeout or 5000
  local socket = require("socket")
  local start_time = socket.gettime()
  local timeout_sec = timeout / 1000

  while socket.gettime() - start_time < timeout_sec do
    local result = self:_request(protocol.MessageType.QUERY_OBJECT, { name = name })
    if result and #result > 0 then
      return self:locator(name)
    end
    socket.sleep(0.016)
  end

  error("waitForObject timeout: " .. name)
end

function Game:getObjects()
  return self:_request(protocol.MessageType.GET_OBJECTS)
end

function Game:close()
  if self.socket then
    pcall(function()
      self:_request(protocol.MessageType.SHUTDOWN, {}, 1000)
    end)
    self.socket:close()
    self.socket = nil
  end

  self.connected = false

  -- Clean up wrapper
  if self.wrapper_path then
    os.execute("rm -rf " .. self.wrapper_path .. " 2>/dev/null")
  end
end

return Game
