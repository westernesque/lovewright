--- Game launcher and controller for lovewright
-- Launches LÖVE2D games with runtime injection and provides control API

local protocol = require("lovewright.protocol")
local Trace = require("lovewright.trace")

local Game = {}
Game.__index = Game

-- Games launched by this process and not closed yet (Game.close_all)
Game.live = {}
-- The run lock file this runner holds (set by lovewright.run), recorded
-- with each isolated game so a later run can tell whether its runner died
Game.owner_lock = nil

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
-- Extra command-line arguments for the game, quoted for the shell. The game
-- reads them from LÖVE's global `arg` (Nano MD uses --scene=<name> to boot
-- straight into a scene for the visual-parity capture).
local function format_args(game_args)
  if not game_args or #game_args == 0 then return "" end
  local out = {}
  for _, a in ipairs(game_args) do
    table.insert(out, '"' .. tostring(a):gsub('"', '\\"') .. '"')
  end
  return " " .. table.concat(out, " ")
end

local function launch_process(cmd, path, port, headless, game_args, isolated)
  local extra = format_args(game_args)
  if is_windows then
    local win_path = path:gsub("/", "\\")

    -- Get list of love.exe PIDs before launch. Not in an isolated run:
    -- another run may be launching its own love.exe at the same moment, so
    -- the diff could name ITS game; the wrapper reports our pid instead
    local before_pids = isolated and {} or get_love_pids()

    -- Headless: the runtime hides the window (runtime/headless.lua); these
    -- SDL hints (SDL3 / SDL2 spelling) stop it taking keyboard focus in the
    -- instant between creation and hiding
    local env = ""
    if headless then
      env = 'set "SDL_WINDOW_ACTIVATE_WHEN_SHOWN=0"&& set "SDL_WINDOW_NO_ACTIVATION_WHEN_SHOWN=1"&& '
    end
    os.execute(env .. 'start "" "' .. cmd .. '" "' .. win_path .. '"' .. extra)

    if isolated then
      -- pid comes from the wrapper's _lovewright_pid file (read_pid)
      return { port = port, match = path }
    end

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
    -- Unix: run in background with &. Headless hides the window the same way
    -- (runtime/headless.lua); a machine with NO display at all still needs a
    -- virtual one: xvfb-run lua run_example_tests.lua --headless
    local env = headless
      and 'SDL_WINDOW_ACTIVATE_WHEN_SHOWN=0 SDL_WINDOW_NO_ACTIVATION_WHEN_SHOWN=1 ' or ''
    os.execute(env .. cmd .. ' "' .. path .. '"' .. extra .. ' 2>&1 &')
    if isolated then
      return { port = port, match = path }
    end
    return nil
  end
end

-- Kill a launched process
local function kill_process(process_info)
  if not process_info then return end
  if is_windows then
    local pids = { process_info.pid }
    if not process_info.pid and process_info.match then
      -- isolated run whose game never reported its pid: find it by the
      -- wrapper path on its command line (never by image name)
      pids = require("lovewright.isolation").find_pids(process_info.match:match("[^/\\]+$"))
    end
    for _, pid in ipairs(pids) do
      -- Kill by PID (most reliable)
      local cmd = 'taskkill /PID ' .. pid .. ' /T /F >nul 2>&1'
      os.execute(cmd)
    end
  elseif process_info.pid then
    os.execute('kill -9 ' .. process_info.pid .. ' 2>/dev/null')
  elseif process_info.match then
    -- isolated: only this run's game (its wrapper path is on the command line)
    os.execute('pkill -f "' .. process_info.match .. '" 2>/dev/null')
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
  headless_mode = "hidden",  -- "hidden" | "offscreen" | "minimized" (see runtime/headless.lua)
  love_path = "love",
  timeout = 5000,  -- Connection timeout in ms
  -- Hang watchdog: once the game has answered nothing for this many seconds
  -- while requests wait on it, it is killed and the request fails (and
  -- every later one at once, instead of each waiting out its timeout).
  -- 0 / false = off
  hang_timeout = 300,
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
    { src = lw_path .. "/runtime/headless.lua", dst = wrapper_path .. "/lovewright/runtime/headless.lua" },
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
    -- tar pipe honors excludes during the copy (cp would copy .git first)
    local tar_excludes = ""
    for _, name in ipairs(excludes) do
      tar_excludes = tar_excludes .. " --exclude='" .. name .. "'"
    end
    os.execute('tar cf - -C "' .. game_path .. '"' .. tar_excludes ..
      ' . | tar xf - -C "' .. wrapper_path .. '" 2>/dev/null')
  end
end

-- Create wrapper conf.lua content (loaded by LÖVE2D before main.lua).
-- Chains the game's own conf.lua (renamed to _lovewright_game_conf.lua) so module
-- flags and other settings are preserved, then applies lovewright overrides.
local function create_conf(options)
  local headless_settings = ""
  if options.headless then
    -- Headless: no vsync (nothing is presented to a screen anyone watches).
    -- LÖVE cannot render with the window module off, so the window exists
    -- and the runtime hides it (runtime/headless.lua); creating it far
    -- off-screen means it never flashes before that happens.
    headless_settings = [[
  t.window.minwidth = 1
  t.window.minheight = 1
  t.window.vsync = 0
]]
    if options.headless_mode ~= "minimized" then
      headless_settings = headless_settings .. [[
  t.window.x = -32000
  t.window.y = -32000
  t.window.fullscreen = false
]]
    end
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

-- Isolated runs: the wrapper writes the game's own pid next to itself
-- (_lovewright_pid) before anything else runs, so the launcher can close
-- exactly this game even if it never connects. (__asm__ renames keep the
-- declarations from clashing with any the game makes itself.)
local PID_SNIPPET = [[
do
  local okF, ffi = pcall(require, "ffi")
  if okF then
    if jit and jit.os == "Windows" then
      pcall(ffi.cdef, 'unsigned long lovewright_getpid(void) __asm__("GetCurrentProcessId");')
    else
      pcall(ffi.cdef, 'int lovewright_getpid(void) __asm__("getpid");')
    end
    local okP, pid = pcall(function() return tonumber(ffi.C.lovewright_getpid()) end)
    if okP and pid then
      local f = io.open(love.filesystem.getSource() .. "/_lovewright_pid", "w")
      if f then
        f:write(tostring(pid))
        f:close()
      end
    end
  end
end
]]

-- Create wrapper main.lua content
local function create_wrapper(options, port)
  -- Create a wrapper that loads the runtime (runtime files will be copied alongside)
  -- Game files live in the wrapper root; the game's main.lua is renamed to
  -- _lovewright_game_main.lua so this wrapper can control startup
  local headless_init = options.headless and string.format([[
  -- Headless mode: hide the window before the game touches it (and keep it
  -- hidden if the game re-creates it) - see lovewright/runtime/headless.lua
  require("lovewright.runtime.headless").install(%q)
]], options.headless_mode or "hidden") or ""

  local runtime_extra = ""
  if options.isolated then
    runtime_extra = string.format(", token = %q, debug_tag = %q", options.token, options.run_id or "")
  end

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
    lovewright.runtime.init({ headless = %s, port = %d%s })

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
    port,
    runtime_extra
  )

  if options.isolated then
    wrapper = "-- Lovewright isolated run " .. tostring(options.run_id) .. "\n" .. PID_SNIPPET .. wrapper
  end
  return wrapper
end

-- The pid in an isolated run's _lovewright_pid file (nil until the game started)
local function read_pid(pid_file)
  local s = read_file(is_windows and pid_file:gsub("/", "\\") or pid_file)
  return s and s:match("^%s*(%d+)") or nil
end

-- Find or create temp directory
local function get_temp_dir()
  local tmpdir = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
  local lw_tmp = tmpdir .. "/lovewright"
  mkdir(lw_tmp)
  return lw_tmp
end

-- Orphaned games. An isolated run records every game it launches in
-- <TEMP>/lovewright/runs/<run id>.games as "<pid>\t<wrapper>\t<lock file>",
-- the lock file being the run lock its runner holds. When a runner dies
-- without closing its games (killed, stopped), the game normally quits by
-- itself once it sees the connection drop (runtime: a claimed client that
-- disconnects) - but a game stuck inside one long frame cannot. So the
-- next isolated launch with the same run id kills each recorded game whose
-- runner is gone (its lock file is deletable / missing), that is still a
-- running love process and whose wrapper still names that pid: only games
-- this checkout's own runs started, never one found by image name.
local function games_file(run_id)
  local dir = get_temp_dir() .. "/runs"
  mkdir(dir)
  return dir .. "/" .. run_id .. ".games"
end

local function read_games(run_id)
  local list = {}
  local s = read_file(games_file(run_id))
  for line in (s or ""):gmatch("[^\r\n]+") do
    local pid, wrapper, lock = line:match("^(%d+)\t([^\t]*)\t?(.*)$")
    if pid then list[#list + 1] = { pid = pid, wrapper = wrapper, lock = lock or "" } end
  end
  return list
end

local function write_games(run_id, list)
  local out = {}
  for _, g in ipairs(list) do
    out[#out + 1] = g.pid .. "\t" .. g.wrapper .. "\t" .. (g.lock or "") .. "\n"
  end
  local f = io.open(games_file(run_id), "wb")
  if f then
    f:write(table.concat(out))
    f:close()
  end
end

-- `pid` is a running love process
local function love_alive(pid)
  if is_windows then
    local p = io.popen('tasklist /FI "PID eq ' .. pid .. '" /FO CSV /NH 2>nul')
    local alive = false
    if p then
      for line in p:lines() do
        if line:match('^"[Ll][Oo][Vv][Ee][^"]*","' .. pid .. '"') then alive = true end
      end
      p:close()
    end
    return alive
  end
  local r = os.execute("kill -0 " .. pid .. " 2>/dev/null")
  return r == 0 or r == true
end

local function reap_orphans(run_id)
  local list = read_games(run_id)
  if #list == 0 then return end
  local Lock = require("lovewright.lock")
  local keep = {}
  for _, g in ipairs(list) do
    local mine = false
    for live in pairs(Game.live) do
      if live.process_info and live.process_info.pid == g.pid then mine = true end
    end
    if mine or (g.lock ~= "" and g.lock == Game.owner_lock) then
      keep[#keep + 1] = g
    elseif love_alive(g.pid) then
      if g.lock == "" or Lock.holder_alive(g.lock) then
        keep[#keep + 1] = g          -- its runner may be alive: not ours to judge
      elseif read_pid(g.wrapper .. "/_lovewright_pid") == g.pid then
        print("[lovewright] killing orphaned game pid " .. g.pid .. " of a dead run " .. run_id)
        kill_process({ pid = g.pid })
        rmdir(g.wrapper)
      end
    elseif g.wrapper:find("wrapper_" .. run_id .. "_", 1, true) and read_pid(g.wrapper .. "/_lovewright_pid") == g.pid then
      rmdir(g.wrapper)                 -- a game that quit by itself: its copy is left
    end
  end
  write_games(run_id, keep)
end

local function record_game(game)
  local pid = game.process_info and game.process_info.pid
  local run_id = game.options.run_id
  if not (pid and run_id) then return end
  local list = read_games(run_id)
  list[#list + 1] = { pid = pid, wrapper = game.wrapper_path, lock = Game.owner_lock or "" }
  write_games(run_id, list)
  game.recorded_pid = pid
end

local function forget_game(game)
  if not game.recorded_pid then return end
  local keep = {}
  for _, g in ipairs(read_games(game.options.run_id)) do
    if g.pid ~= game.recorded_pid then keep[#keep + 1] = g end
  end
  write_games(game.options.run_id, keep)
  game.recorded_pid = nil
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

  -- Isolated run (lovewright.isolation): own save dir, wrapper copy, port,
  -- launch token and pid. Works on a copy so the caller's table is untouched
  if options.isolated then
    local Isolation = require("lovewright.isolation")
    local copy = {}
    for k, v in pairs(options) do copy[k] = v end
    options = copy
    options.run_id = Isolation.run_id()
    options.token = Isolation.token()
    options.identity = (options.identity or "lovewright") .. "-" .. options.run_id
    reap_orphans(options.run_id)
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
  self.hang_timeout = tonumber(options.hang_timeout) or 0
  self.quiet_since = nil   -- since when requests have waited on a silent game

  -- Get unique port for this instance (isolated: a free one at random,
  -- not BASE_PORT + the time, which another runner may be counting up from)
  if options.isolated then
    self.port = require("lovewright.isolation").free_port()
  else
    self.port = protocol.get_port()
  end

  -- Create wrapper
  local wrapper = create_wrapper(options, self.port)
  local conf = create_conf(options)
  local temp_dir = get_temp_dir()
  local wrapper_path = temp_dir .. "/wrapper_" .. os.time()
  if options.isolated then
    wrapper_path = temp_dir .. "/wrapper_" .. options.run_id .. "_" .. options.token
  end
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
  self.process_info = launch_process(options.love_path, wrapper_path, self.port, options.headless, options.args,
    options.isolated)

  -- Connect to runtime
  local socket = require("socket")
  local start_time = socket.gettime()
  local timeout_sec = options.timeout / 1000

  while socket.gettime() - start_time < timeout_sec do
    local client = socket.tcp()
    client:settimeout(0.1)
    local ok, err = client:connect("127.0.0.1", self.port)
    local _, local_port = client:getsockname()
    if ok and tonumber(local_port) == self.port then
      -- TCP self-connect: nobody listens yet and the OS gave this socket
      -- the very port it dials (Linux, port in the ephemeral range), so it
      -- reached itself. Drop it with an RST (linger 0) - a plain close sits
      -- in TIME_WAIT on the port and the game's bind fails - and retry
      client:setoption("linger", { on = true, timeout = 0 })
      ok = false
    end
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
  if options.isolated then
    if type(ready) ~= "table" or ready.token ~= options.token then
      -- another run's game answered on our port: drop the connection
      -- WITHOUT the shutdown request (that game is not ours to stop)
      self.socket:close()
      self.socket = nil
      self.connected = false
      self:close()
      error("Connected to a game from another run on port " .. tostring(self.port) .. " (launch token mismatch)")
    end
    self.process_info.pid = self.process_info.pid or read_pid(wrapper_path .. "/_lovewright_pid")
    -- claim the game: from now on it quits by itself when this runner's
    -- connection drops without a shutdown (the runner died or was stopped)
    pcall(self._request, self, protocol.MessageType.PING, { token = options.token }, options.timeout)
    record_game(self)
  end
  Game.live[self] = true
  -- How the window ended up when headless: "hidden" | "offscreen" |
  -- "minimized" | "none" (see Game:headlessStatus)
  self.headless_status = type(ready) == "table" and ready.headless or nil

  Trace.game_launched(self)
  Trace.record("game", "launch " .. tostring(options.path), {
    width = options.width,
    height = options.height,
    port = self.port,
    run = options.run_id,
    pid = self.process_info and self.process_info.pid or nil,
  })

  return self
end

-- Hang watchdog bookkeeping: a request or wait starts the silence clock
-- (unless it already runs: requests that time out one after another add
-- up), and any bytes from the game stop it
function Game:_expect()
  if not self.quiet_since then
    self.quiet_since = require("socket").gettime()
  end
end

-- Kill the game and fail when it has been silent for hang_timeout seconds
function Game:_watchdog()
  local limit = self.hang_timeout
  if not limit or limit <= 0 or not self.quiet_since then return end
  local quiet = require("socket").gettime() - self.quiet_since
  if quiet < limit then return end
  self.hung = string.format("the game sent nothing for %.0f s (hang watchdog, hang_timeout = %s s) and was killed",
    quiet, tostring(limit))
  Trace.record("game", "hang watchdog: " .. self.hung)
  if self.socket then
    self.socket:close()
    self.socket = nil
  end
  self.connected = false
  local info = self.process_info
  if info and (info.pid or info.match) then
    if info.match and not info.pid and self.wrapper_path then
      info.pid = read_pid(self.wrapper_path .. "/_lovewright_pid")
    end
    kill_process(info)
  end
  error("lovewright: " .. self.hung, 0)
end

-- Send a request and wait for response
function Game:_request(msg_type, params, timeout)
  if not self.connected then
    error("Not connected to game" .. (self.hung and (": " .. self.hung) or ""))
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
  self:_expect()

  while socket.gettime() - start_time < timeout_sec do
    self:_process_messages()
    self:_watchdog()

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
  self:_expect()

  while socket.gettime() - start_time < timeout_sec do
    self:_process_messages()
    self:_watchdog()

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
  if (data and #data > 0) or (partial and #partial > 0) then
    self.quiet_since = nil   -- the game is alive
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

    -- Create the parent directory first: io.open("wb") fails silently when it
    -- does not exist, which used to surface as a bare "screenshot returned
    -- false" with nothing to go on.
    local dir = filename:match("^(.*)[/\][^/\]+$")
    if dir and dir ~= "" then
      if is_windows then
        os.execute('mkdir "' .. dir:gsub("/", "\\") .. '" 2>nul')
      else
        os.execute('mkdir -p "' .. dir .. '" 2>/dev/null')
      end
    end

    local file, err = io.open(filename, "wb")
    if file then
      file:write(data)
      file:close()
      return true
    end
    return false, "cannot write " .. tostring(filename) .. ": " .. tostring(err)
  end
  return false, "no screenshot data from the game"
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

--- How headless mode took effect in the launched game, as reported at
-- connect time: { mode = requested, applied = "hidden" | "offscreen" |
-- "minimized" | "none", note = reason a better mode was unavailable }.
-- nil when the game was not launched headless.
function Game:headlessStatus()
  return self.headless_status
end

function Game:close()
  Game.live[self] = nil
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
    if self.process_info.match and not self.process_info.pid and self.wrapper_path then
      self.process_info.pid = read_pid(self.wrapper_path .. "/_lovewright_pid")
    end
    kill_process(self.process_info)
    self.process_info = nil
  end
  forget_game(self)

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

--- Close every game this process launched and has not closed (lovewright.run
-- calls it when the run ends, also when it ends in an error)
function Game.close_all()
  local open = {}
  for g in pairs(Game.live) do open[#open + 1] = g end
  for _, g in ipairs(open) do
    pcall(g.close, g)
  end
  return #open
end

return Game
