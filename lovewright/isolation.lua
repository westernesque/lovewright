--- Isolated runs: several lovewright runs on one machine at once
--
-- Opt-in (lovewright.config.isolated, LOVEWRIGHT_ISOLATED=1). An isolated run
-- gets its own identity for everything another run could share:
--   * save directory   identity "<identity>-<run id>"
--   * wrapper copy     <TEMP>/lovewright/wrapper_<run id>_<token>
--   * runner port      a free random port (not BASE_PORT + time)
--   * the game         a launch token the game echoes in its ready event,
--                      and the game's own pid (written by the wrapper), so
--                      the launcher never talks to, or kills, another run's game
-- The run id names the checkout the runner was started from (its
-- directory's name plus a hash of its path): stable across runs of one
-- checkout, different between checkouts (e.g. git worktrees side by side).
-- LOVEWRIGHT_RUN_ID overrides it.

local Isolation = {}

local is_windows = package.config:sub(1, 1) == "\\"

--- 32-bit djb2 hash of a string, as 8 hex digits
function Isolation.hash(s)
  local h = 5381
  for i = 1, #s do
    h = (h * 33 + s:byte(i)) % 4294967296
  end
  return string.format("%08x", h)
end

--- A path in a form that is the same however it was spelled (case, slashes)
function Isolation.normalize(path)
  path = path:gsub("\\", "/"):lower()
  path = path:gsub("/+$", "")
  return path
end

local cached_cwd
--- The runner's working directory (absolute)
function Isolation.cwd()
  if cached_cwd == nil then
    local p = io.popen(is_windows and "cd" or "pwd")
    cached_cwd = p and (p:read("*l") or ""):gsub("\r$", "") or ""
    if p then p:close() end
  end
  return cached_cwd
end

local function sanitize(s)
  return (s:gsub("[^%w%-]", "-"):sub(1, 40))
end

--- Run id for a directory: "<dir name>-<last 6 hex of the hash of its normalized path>"
function Isolation.run_id_for(dir)
  local name = dir:gsub("[/\\]+$", ""):match("([^/\\]+)$") or "run"
  return sanitize(name) .. "-" .. Isolation.hash(Isolation.normalize(dir)):sub(-6)
end

local cached_id
--- This run's id (LOVEWRIGHT_RUN_ID, else derived from the working directory)
function Isolation.run_id()
  if cached_id == nil then
    local env = os.getenv("LOVEWRIGHT_RUN_ID")
    if env and env ~= "" then
      cached_id = sanitize(env)
    else
      cached_id = Isolation.run_id_for(Isolation.cwd())
    end
  end
  return cached_id
end

-- Seed once from the clock and an address so two runners started in the
-- same second still draw different tokens
local seeded = false
--- A short random token (wrapper names, launch tokens)
function Isolation.token()
  if not seeded then
    local addr = tonumber((tostring({}):match("(%x+)$")) or "0", 16) or 0
    math.randomseed((require("socket").gettime() * 1000 + addr) % 2147483647)
    math.random(); math.random()
    seeded = true
  end
  return string.format("%06x%06x", math.random(0, 0xffffff), math.random(0, 0xffffff))
end

-- Ports are drawn at random BELOW the ephemeral range (Windows hands out
-- 49152+, Linux 32768+), never asked of the OS with port 0: an ephemeral
-- port is the next one the OS gives to any client socket, so a server put
-- on p + 1 of an OS-picked p receives the replies meant for the very next
-- socket opened (the private relay's control port did exactly that).
local PORT_LOW, PORT_HIGH = 20000, 32000

local function bindable(kind, port)
  local socket = require("socket")
  local s = assert(kind == "udp" and socket.udp() or socket.tcp())
  local ok
  if kind == "udp" then
    ok = s:setsockname("127.0.0.1", port)
  else
    ok = s:bind("127.0.0.1", port)
  end
  s:close()
  return ok and true or false
end

-- `count` consecutive free ports of `kind`, the first one returned
local function free_run(kind, count)
  Isolation.token()   -- (seeds math.random)
  for _ = 1, 200 do
    local port = math.random(PORT_LOW, PORT_HIGH - count)
    local ok = true
    for i = 0, count - 1 do
      if not bindable(kind, port + i) then ok = false break end
    end
    if ok then return port end
  end
  error("lovewright.isolation: no free " .. kind .. " port")
end

--- A TCP port on 127.0.0.1 nobody is listening on (the runner<->game port)
function Isolation.free_port()
  return free_run("tcp", 1)
end

--- A free UDP port p on 127.0.0.1 whose neighbour p + 1 is free too (a
-- server plus its control port, say)
function Isolation.free_udp_pair()
  return free_run("udp", 2)
end

--- The pids of love processes whose command line contains `fragment`
-- (Windows; a fallback for a game that never reported its own pid)
function Isolation.find_pids(fragment)
  local pids = {}
  if not is_windows then return pids end
  local cmd = "powershell -NoProfile -NonInteractive -Command \"Get-CimInstance Win32_Process"
    .. " | Where-Object { $_.Name -like 'love*' -and $_.CommandLine -like '*" .. fragment:gsub("'", "") .. "*' }"
    .. " | ForEach-Object { $_.ProcessId }\" 2>nul"
  local p = io.popen(cmd)
  if p then
    for line in p:lines() do
      local pid = line:match("^%s*(%d+)%s*$")
      if pid then pids[#pids + 1] = pid end
    end
    p:close()
  end
  return pids
end

return Isolation
