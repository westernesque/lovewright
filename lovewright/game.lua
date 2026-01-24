--- Game launcher and controller for lovewright
-- Launches LÖVE2D games with runtime injection and provides control API

local protocol = require("lovewright.protocol")

local Game = {}
Game.__index = Game

-- Platform detection
local is_windows = package.config:sub(1, 1) == "\\"

-- Cross-platform utilities
local function mkdir(path)
  if is_windows then
    local win_path = path:gsub("/", "\\")
    os.execute('mkdir "' .. win_path .. '" 2>nul')
  else
    os.execute("mkdir -p " .. path .. " 2>/dev/null")
  end
end

local function rmdir(path)
  if is_windows then
    local win_path = path:gsub("/", "\\")
    os.execute('rmdir /s /q "' .. win_path .. '" 2>nul')
  else
    os.execute("rm -rf " .. path .. " 2>/dev/null")
  end
end

-- Launch process and return info for later cleanup
local function launch_process(cmd, path, port)
  if is_windows then
    local win_path = path:gsub("/", "\\")

    -- Get list of love.exe PIDs before launch
    local before_pids = {}
    local handle = io.popen('wmic process where "name=\'love.exe\'" get processid 2>nul')
    if handle then
      for line in handle:lines() do
        local pid = line:match("(%d+)")
        if pid then before_pids[pid] = true end
      end
      handle:close()
    end

    -- Launch the process
    os.execute('start "" "' .. cmd .. '" "' .. win_path .. '"')

    -- Brief wait for process to start
    local socket = require("socket")
    socket.sleep(0.3)

    -- Find the new love.exe PID
    handle = io.popen('wmic process where "name=\'love.exe\'" get processid 2>nul')
    if handle then
      for line in handle:lines() do
        local pid = line:match("(%d+)")
        if pid and not before_pids[pid] then
          handle:close()
          return { pid = pid, port = port }
        end
      end
      handle:close()
    end

    return { port = port }  -- Fallback without PID
  else
    -- Unix: run in background with &
    os.execute(cmd .. ' "' .. path .. '" 2>&1 &')
    return nil
  end
end

-- Kill a launched process
local function kill_process(process_info)
  if not process_info then return end
  if is_windows then
    if process_info.pid then
      -- Kill by PID (most reliable)
      local cmd = 'taskkill /PID ' .. process_info.pid .. ' /T /F >nul 2>&1'
      os.execute(cmd)
    end
    -- Also kill by command line pattern as fallback
    os.execute('wmic process where "commandline like \'%%lovewright%%\'" delete >nul 2>&1')
  else
    -- Unix: could use pkill or similar
    os.execute('pkill -f "love.*lovewright" 2>/dev/null')
  end
end

-- Default options
local defaults = {
  width = 800,
  height = 600,
  headless = false,
  love_path = "love",
  timeout = 5000,  -- Connection timeout in ms
}

-- Get the directory containing lovewright
local function get_lovewright_path()
  local info = debug.getinfo(1, "S").source
  -- Handle both @/path/to/game.lua and @C:\path\to\game.lua
  local path = info:match("@(.+)[/\\]game%.lua$")
  if path then
    return path
  end
  -- Fallback: try to find relative to current working directory
  return "lovewright"
end

-- Read a file's contents
local function read_file(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

-- Copy a single file
local function copy_file(src, dst)
  local src_path = is_windows and src:gsub("/", "\\") or src
  local dst_path = is_windows and dst:gsub("/", "\\") or dst
  local content = read_file(src_path)
  if content then
    local out = io.open(dst_path, "wb")
    if out then
      out:write(content)
      out:close()
      return true
    end
  end
  return false
end

-- Recursively copy a directory
local function copy_dir(src_dir, dst_dir)
  mkdir(dst_dir)

  -- List files in source directory
  local cmd
  if is_windows then
    local win_src = src_dir:gsub("/", "\\")
    cmd = 'dir /b "' .. win_src .. '" 2>nul'
  else
    cmd = 'ls -1 "' .. src_dir .. '" 2>/dev/null'
  end

  local handle = io.popen(cmd)
  if handle then
    for name in handle:lines() do
      local src_path = src_dir .. "/" .. name
      local dst_path = dst_dir .. "/" .. name

      -- Check if it's a directory
      local check_cmd
      if is_windows then
        local win_path = src_path:gsub("/", "\\")
        check_cmd = 'if exist "' .. win_path .. '\\*" (echo dir) else (echo file)'
      else
        check_cmd = 'test -d "' .. src_path .. '" && echo dir || echo file'
      end

      local type_handle = io.popen(check_cmd)
      local file_type = type_handle:read("*l")
      type_handle:close()

      if file_type == "dir" then
        copy_dir(src_path, dst_path)
      else
        copy_file(src_path, dst_path)
      end
    end
    handle:close()
  end
end

-- Copy runtime files to wrapper directory
local function copy_runtime_files(wrapper_path)
  local lw_path = get_lovewright_path()

  -- Create lovewright subdirectory in wrapper
  mkdir(wrapper_path .. "/lovewright")
  mkdir(wrapper_path .. "/lovewright/runtime")

  -- Files to copy
  local files = {
    { src = lw_path .. "/protocol.lua", dst = wrapper_path .. "/lovewright/protocol.lua" },
    { src = lw_path .. "/runtime/init.lua", dst = wrapper_path .. "/lovewright/runtime/init.lua" },
    { src = lw_path .. "/runtime/base64.lua", dst = wrapper_path .. "/lovewright/runtime/base64.lua" },
  }

  for _, file in ipairs(files) do
    copy_file(file.src, file.dst)
  end
end

-- Copy game files to wrapper directory
local function copy_game_files(game_path, wrapper_path)
  local game_dst = wrapper_path .. "/game"
  copy_dir(game_path, game_dst)
end

-- Create wrapper main.lua content
local function create_wrapper(options, port)
  -- Create a wrapper that loads the runtime (runtime files will be copied alongside)
  -- Game files are copied to "game/" subdirectory
  local wrapper = string.format([[
-- Lovewright runtime wrapper

-- Load and initialize runtime (bundled in wrapper)
-- Expose as global so games can register objects
lovewright = {
  runtime = require("lovewright.runtime")
}

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
  -- Load the actual game FIRST (before runtime.init hooks love.update)
  local chunk, err = love.filesystem.load("game/main.lua")
  if chunk then
    local ok, game_err = pcall(chunk)
    if not ok then
      error("Failed to execute game: " .. tostring(game_err))
    end

    -- Now init runtime AFTER game defines its callbacks (so we can wrap them)
    lovewright.runtime.init({ headless = %s, port = %d })

    -- Call game's love.load if it exists
    if love.load and love.load ~= _G._lovewright_load then
      love.load(arg)
    end
  else
    error("Failed to load game: " .. tostring(err))
  end
end
_G._lovewright_load = love.load
]],
    options.width,
    options.height,
    options.headless and "t.modules.window = false" or "",
    options.headless and "true" or "false",
    port
  )

  return wrapper
end

-- Find or create temp directory
local function get_temp_dir()
  local tmpdir = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
  local lw_tmp = tmpdir .. "/lovewright"
  mkdir(lw_tmp)
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

  -- Get unique port for this instance
  self.port = protocol.get_port()

  -- Create wrapper
  local wrapper = create_wrapper(options, self.port)
  local temp_dir = get_temp_dir()
  local wrapper_path = temp_dir .. "/wrapper_" .. os.time()
  mkdir(wrapper_path)

  -- Copy runtime files into wrapper directory
  copy_runtime_files(wrapper_path)

  -- Copy game files into wrapper directory
  copy_game_files(options.path, wrapper_path)

  local main_path = wrapper_path .. "/main.lua"
  if is_windows then
    main_path = main_path:gsub("/", "\\")
  end
  local wrapper_file = io.open(main_path, "w")
  wrapper_file:write(wrapper)
  wrapper_file:close()

  self.wrapper_path = wrapper_path

  -- Launch process
  self.process_info = launch_process(options.love_path, wrapper_path, self.port)

  -- Connect to runtime
  local socket = require("socket")
  local start_time = socket.gettime()
  local timeout_sec = options.timeout / 1000

  while socket.gettime() - start_time < timeout_sec do
    local client = socket.tcp()
    client:settimeout(0.1)
    local ok, err = client:connect("127.0.0.1", self.port)
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
  -- Try graceful shutdown first
  if self.socket then
    pcall(function()
      self:_request(protocol.MessageType.SHUTDOWN, {}, 500)
    end)
    self.socket:close()
    self.socket = nil
  end

  self.connected = false

  -- Force kill the process
  if self.process_info then
    kill_process(self.process_info)
    self.process_info = nil
  end

  -- Brief wait for cleanup
  local socket = require("socket")
  socket.sleep(0.2)

  -- Don't release port immediately - OS may still have it in TIME_WAIT
  -- Ports will be reset between test runs by Runner.reset()
  self.port = nil

  -- Clean up wrapper directory
  if self.wrapper_path then
    rmdir(self.wrapper_path)
    self.wrapper_path = nil
  end
end

return Game
