--- Game launcher and controller for lovewright
-- Launches LÖVE2D games with runtime injection and provides control API

local protocol = require("lovewright.protocol")
local Trace = require("lovewright.trace")

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

-- List running love.exe PIDs (Windows). Uses tasklist because wmic is
-- removed on current Windows 11 builds.
local function get_love_pids()
  local pids = {}
  local handle = io.popen('tasklist /FI "IMAGENAME eq love.exe" /FO CSV /NH 2>nul')
  if handle then
    for line in handle:lines() do
      local pid = line:match('^"[^"]*","(%d+)"')
      if pid then pids[pid] = true end
    end
    handle:close()
  end
  return pids
end

-- Launch process and return info for later cleanup
local function launch_process(cmd, path, port, headless)
  if is_windows then
    local win_path = path:gsub("/", "\\")

    -- Get list of love.exe PIDs before launch
    local before_pids = get_love_pids()

    -- Launch the process (headless mode minimizes window via love.load)
    os.execute('start "" "' .. cmd .. '" "' .. win_path .. '"')

    -- Brief wait for process to start
    local socket = require("socket")
    socket.sleep(0.3)

    -- Find the new love.exe PID
    for pid in pairs(get_love_pids()) do
      if not before_pids[pid] then
        return { pid = pid, port = port }
      end
    end

    return { port = port }  -- Fallback without PID
  else
    -- Unix: run in background with &
    -- For true headless on Linux, use Xvfb: xvfb-run lua run_example_tests.lua --headless
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

-- Move (rename) a file, overwriting the destination; returns false if src missing
local function move_file(src, dst)
  local src_path = is_windows and src:gsub("/", "\\") or src
  local dst_path = is_windows and dst:gsub("/", "\\") or dst
  os.remove(dst_path)
  return os.rename(src_path, dst_path) and true or false
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

-- Copy game files into the wrapper root using native tools (fast for large games).
-- Copying to the root keeps the game's require() and asset paths working unchanged.
-- `exclude` is a list of directory/file names to skip (matched at any depth).
local function copy_game_files(game_path, wrapper_path, exclude)
  -- Always skip version control data
  local excludes = { ".git" }
  for _, name in ipairs(exclude or {}) do
    table.insert(excludes, name)
  end

  if is_windows then
    local win_src = game_path:gsub("/", "\\")
    local win_dst = wrapper_path:gsub("/", "\\")
    local names = ""
    for _, name in ipairs(excludes) do
      names = names .. ' "' .. name .. '"'
    end
    local cmd = 'robocopy "' .. win_src .. '" "' .. win_dst .. '" /E /NFL /NDL /NJH /NJS /NP'
      .. ' /XD' .. names .. ' /XF' .. names
    os.execute(cmd .. " >nul 2>nul")
  else
    os.execute('cp -R "' .. game_path .. '/." "' .. wrapper_path .. '/" 2>/dev/null')
    for _, name in ipairs(excludes) do
      os.execute('rm -rf "' .. wrapper_path .. '/' .. name .. '" 2>/dev/null')
    end
  end
end

-- Create wrapper conf.lua content (loaded by LÖVE2D before main.lua).
-- Chains the game's own conf.lua (renamed to _lovewright_game_conf.lua) so module
-- flags and other settings are preserved, then applies lovewright overrides.
local function create_conf(options)
  local headless_settings = ""
  if options.headless then
    -- For headless mode: minimize window and disable vsync for faster execution
    -- True headless (t.modules.window = false) breaks the game loop on most platforms
    headless_settings = [[
  t.window.minwidth = 1
  t.window.minheight = 1
  t.window.vsync = 0
]]
  end

  local identity_setting = ""
  if options.identity then
    -- Isolated save directory so tests don't touch (or depend on) real save data
    identity_setting = string.format("  t.identity = %q\n", options.identity)
  end

  local conf = string.format([[
-- Lovewright configuration
-- Load the game's own conf (if it had one) so module/other settings are preserved
pcall(require, "_lovewright_game_conf")
local game_conf = love.conf

function love.conf(t)
  if game_conf then pcall(game_conf, t) end
  t.window = t.window or {}
  t.window.width = %d
  t.window.height = %d
  t.window.title = "Lovewright Test"
  t.console = false
%s%s
end
]],
    options.width,
    options.height,
    identity_setting,
    headless_settings
  )
  return conf
end

-- Create wrapper main.lua content
local function create_wrapper(options, port)
  -- Create a wrapper that loads the runtime (runtime files will be copied alongside)
  -- Game files live in the wrapper root; the game's main.lua is renamed to
  -- _lovewright_game_main.lua so this wrapper can control startup
  local headless_init = options.headless and [[
  -- Headless mode: minimize window to reduce visual distraction
  if love.window and love.window.minimize then
    love.window.minimize()
  end
]] or ""

  local wrapper = string.format([[
-- Lovewright runtime wrapper

-- Load and initialize runtime (bundled in wrapper)
-- Expose as global so games can register objects
lovewright = {
  runtime = require("lovewright.runtime")
}

-- Initialize runtime early
function love.load(arg)
%s
  -- Load the actual game FIRST (before runtime.init hooks love.update)
  local chunk, err = love.filesystem.load("_lovewright_game_main.lua")
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
    headless_init,
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
  local conf = create_conf(options)
  local temp_dir = get_temp_dir()
  local wrapper_path = temp_dir .. "/wrapper_" .. os.time()
  mkdir(wrapper_path)

  -- Copy game files into the wrapper root (keeps require/asset paths intact)
  copy_game_files(options.path, wrapper_path, options.exclude)

  -- Set aside the game's own entry points so the wrapper can control startup
  move_file(wrapper_path .. "/main.lua", wrapper_path .. "/_lovewright_game_main.lua")
  move_file(wrapper_path .. "/conf.lua", wrapper_path .. "/_lovewright_game_conf.lua")

  -- Copy runtime files into wrapper directory (after game copy so ours win)
  copy_runtime_files(wrapper_path)

  -- Write conf.lua (loaded by LÖVE2D before main.lua)
  local conf_path = wrapper_path .. "/conf.lua"
  if is_windows then
    conf_path = conf_path:gsub("/", "\\")
  end
  local conf_file = io.open(conf_path, "w")
  conf_file:write(conf)
  conf_file:close()

  -- Write main.lua
  local main_path = wrapper_path .. "/main.lua"
  if is_windows then
    main_path = main_path:gsub("/", "\\")
  end
  local wrapper_file = io.open(main_path, "w")
  wrapper_file:write(wrapper)
  wrapper_file:close()

  self.wrapper_path = wrapper_path

  -- Launch process
  self.process_info = launch_process(options.love_path, wrapper_path, self.port, options.headless)

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
    client:close()
    socket.sleep(0.1)
  end

  if not self.connected then
    self:close()
    error("Failed to connect to game runtime on port " .. tostring(self.port) .. " (timeout)")
  end

  -- Wait for ready event. Uses the full connection timeout: the first visible
  -- frame can stall the game loop for several seconds on some GPUs (e.g.
  -- Vulkan pipeline compilation), delaying the runtime's first update tick.
  local ready = self:_wait_for_event(protocol.MessageType.READY, options.timeout)
  if not ready then
    self:close()
    error("Game runtime did not send ready event within " .. options.timeout .. "ms")
  end

  Trace.game_launched(self)
  Trace.record("game", "launch " .. tostring(options.path), {
    width = options.width,
    height = options.height,
    port = self.port,
  })

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

-- Capture the current frame; returns the PNG as a base64 string
function Game:screenshotBase64()
  local result = self:_request(protocol.MessageType.TAKE_SCREENSHOT, {}, 10000)
  return result and result.screenshot or nil
end

function Game:screenshot(filename)
  local b64 = self:screenshotBase64()
  if b64 then
    -- Embed the same capture in the active trace without a second request
    Trace.attach(b64, "screenshot: " .. tostring(filename))

    -- Decode base64 and save
    local base64 = require("lovewright.runtime.base64")
    local data = base64.decode(b64)
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
      Trace.record("wait", string.format("waitFor condition met in %.2fs", socket.gettime() - start_time))
      return true
    end
    self:_process_messages()
    socket.sleep(0.016)  -- ~60fps
  end

  Trace.record("wait", string.format("waitFor TIMEOUT after %.2fs", timeout_sec))
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
      Trace.record("wait", string.format("waitForObject %s found in %.2fs", name, socket.gettime() - start_time))
      return self:locator(name)
    end
    socket.sleep(0.016)
  end

  Trace.record("wait", string.format("waitForObject %s TIMEOUT after %.2fs", name, timeout_sec))
  error("waitForObject timeout: " .. name)
end

function Game:getObjects()
  return self:_request(protocol.MessageType.GET_OBJECTS)
end

function Game:close()
  Trace.record("game", "close")
  Trace.game_closed(self)

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
