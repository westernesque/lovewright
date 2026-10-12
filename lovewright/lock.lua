--- Cross-process run lock for lovewright (opt-in)
--
-- Lets several test runs on one machine coordinate: ordinary runs take the
-- lock SHARED (any number at once), timing-sensitive runs (benchmarks, a
-- slowed-down CI-speed pass) take it EXCLUSIVE - they wait until no other
-- holder is left, and block new shared holders while they wait or run.
--
-- The lock is a directory of small files (default: <TEMP>/lovewright/locks,
-- LOVEWRIGHT_LOCK_DIR overrides) guarded by an atomic mkdir "gate":
--   S-<token>            a shared holder
--   W-<ticket>-<token>   an exclusive waiter (lowest ticket goes first)
--   X-<token>            the exclusive holder
-- Each file names its holder (label, key) for the "waiting for ..." messages.
--
-- Stale holders (a runner killed mid-run) are detected without timeouts:
-- on Windows a holder keeps its file OPEN, and an open file cannot be
-- deleted - so a file that CAN be deleted belonged to a dead process. On
-- other platforms the file holds the runner's pid, checked with kill -0.
--
--   local Lock = require("lovewright.lock")
--   local held = Lock.acquire("exclusive", { label = "perf run" })
--   ...
--   held:release()

local Lock = {}

local is_windows = package.config:sub(1, 1) == "\\"

local function sleep(seconds)
  require("socket").sleep(seconds)
end

local function now()
  return require("socket").gettime()
end

local function native(path)
  return is_windows and (path:gsub("/", "\\")) or path
end

-- os.execute succeeded (Lua 5.1 returns the status code, 5.2+ true/nil)
local function exec_ok(cmd)
  local r = os.execute(cmd)
  return r == 0 or r == true
end

local function mkdir(path)
  if is_windows then
    return exec_ok('mkdir "' .. native(path) .. '" 2>nul')
  end
  return exec_ok('mkdir "' .. path .. '" 2>/dev/null')
end

local function mkdir_p(path)
  if is_windows then
    os.execute('mkdir "' .. native(path) .. '" 2>nul')
  else
    os.execute('mkdir -p "' .. path .. '" 2>/dev/null')
  end
end

local function rmdir(path)
  if is_windows then
    os.execute('rmdir "' .. native(path) .. '" 2>nul')
  else
    os.execute('rmdir "' .. path .. '" 2>/dev/null')
  end
end

local function list(dir)
  local cmd = is_windows and ('dir /b "' .. native(dir) .. '" 2>nul') or ('ls -1 "' .. dir .. '" 2>/dev/null')
  local names = {}
  local p = io.popen(cmd)
  if p then
    for line in p:lines() do
      line = line:gsub("\r$", "")
      if line ~= "" then names[#names + 1] = line end
    end
    p:close()
  end
  return names
end

local function read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- This process's pid (POSIX only: the popen shell's parent is us)
local my_pid
local function pid()
  if is_windows then return nil end
  if my_pid == nil then
    local p = io.popen("echo $PPID")
    my_pid = p and tonumber((p:read("*a") or ""):match("%d+")) or false
    if p then p:close() end
  end
  return my_pid or nil
end

function Lock.default_dir()
  local tmp = os.getenv("TEMP") or os.getenv("TMPDIR") or os.getenv("TMP") or "/tmp"
  return os.getenv("LOVEWRIGHT_LOCK_DIR") or (tmp:gsub("\\", "/") .. "/lovewright/locks")
end

-- A random-enough token: time, the address of a fresh table, a counter
local counter = 0
local function token()
  counter = counter + 1
  local addr = tostring({}):match("0x(%x+)") or tostring({}):match("(%x+)$") or ""
  return string.format("%x%s%x", math.floor(now() * 1000) % 0x100000000, addr:sub(-6), counter)
end

-- Open `path` as a held lock file describing its owner. Returns the handle.
local function hold(path, info)
  local f = assert(io.open(path, "wb"), "lovewright.lock: cannot create " .. path)
  f:write(string.format("label=%s\nkey=%s\npid=%s\nsince=%s\n",
    info.label or "", info.key or "", tostring(pid() or ""), os.date("%Y-%m-%d %H:%M:%S")))
  f:flush()
  return f
end

-- The holder recorded in a lock file: { label, key, pid }
local function describe(path)
  local s = (read(path) or ""):gsub("\r", "")
  return {
    label = s:match("label=([^\n]*)") or "",
    key = s:match("key=([^\n]*)") or "",
    pid = tonumber(s:match("pid=(%d+)") or ""),
  }
end

-- Remove `path` if its holder is gone. Returns true when it was stale.
local function reap(path)
  if is_windows then
    -- a live holder keeps the file open: the delete fails
    return os.remove(native(path)) and true or false
  end
  local who = describe(path)
  if who.pid and exec_ok("kill -0 " .. who.pid .. " 2>/dev/null") then
    return false
  end
  if not who.pid then
    -- (a file whose pid is not written yet is being created right now)
    local s = read(path)
    if s == nil or s == "" then return false end
  end
  os.remove(path)
  return true
end

-- The gate: an atomic mkdir, owned through a held file inside it
local function gate_enter(dir)
  local gate = dir .. "/gate"
  local owner = gate .. "/owner"
  local missing = 0
  while true do
    if mkdir(gate) then
      return gate, hold(owner, { label = "gate" })
    end
    -- someone holds the gate: wait, unless they died holding it
    if is_windows then
      local ok, _, errno = os.remove(native(owner))
      if ok then
        rmdir(gate)
      elseif errno == 2 then
        missing = missing + 1
      else
        missing = 0
      end
    else
      if read(owner) then
        missing = 0
        if reap(owner) then rmdir(gate) end
      else
        missing = missing + 1
      end
    end
    -- a gate without an owner file for ~2 s was left by a process that died
    -- between the mkdir and creating the file
    if missing >= 20 then
      rmdir(gate)
      missing = 0
    end
    sleep(0.1)
  end
end

local function gate_leave(gate, handle)
  handle:close()
  os.remove(native(gate .. "/owner"))
  rmdir(gate)
end

-- One look at the lock directory with the gate held: reap dead holders and
-- sort the rest. `mine` is a set of names this process holds.
local function scan(dir, mine)
  local s = { shared = {}, waiting = {}, exclusive = {} }
  for _, name in ipairs(list(dir)) do
    local kind = name:sub(1, 2)
    if (kind == "S-" or kind == "W-" or kind == "X-") then
      local path = dir .. "/" .. name
      if mine[name] or not reap(path) then
        local entry = describe(path)
        entry.name = name
        if kind == "S-" then
          table.insert(s.shared, entry)
        elseif kind == "X-" then
          table.insert(s.exclusive, entry)
        else
          entry.ticket = tonumber(name:match("^W%-(%d+)%-")) or 0
          table.insert(s.waiting, entry)
        end
      end
    end
  end
  table.sort(s.waiting, function(a, b) return a.ticket < b.ticket end)
  return s
end

local function names(entries, skip)
  local out = {}
  for _, e in ipairs(entries) do
    if e.name ~= skip then
      out[#out + 1] = (e.label ~= "" and e.label or e.name)
    end
  end
  return table.concat(out, ", ")
end

local Held = {}
Held.__index = Held

--- Release the lock (idempotent).
function Held:release()
  if self.handle then
    self.handle:close()
    self.handle = nil
    os.remove(native(self.path))
  end
end

--- Take the lock.
-- @param mode string "shared" | "exclusive"
-- @param opts table|nil
--   dir      lock directory (default Lock.default_dir())
--   label    who is asking, shown to the runs that wait on it
--   key      shared only: refuse to start next to a live holder with the
--            same key (one run per checkout, say); nil = no check
--   log      function(msg) for the waiting messages (default print)
--   timeout  seconds to wait before erroring (default: forever)
-- @return Held object with :release()
function Lock.acquire(mode, opts)
  opts = opts or {}
  assert(mode == "shared" or mode == "exclusive", "lovewright.lock: mode must be shared or exclusive")
  local dir = (opts.dir or Lock.default_dir()):gsub("\\", "/")
  local log = opts.log or print
  local info = { label = opts.label or mode, key = opts.key or "" }
  local tok = token()
  mkdir_p(dir)

  local mine = {}
  local wait_name, wait_handle
  local started = now()
  local last_note = nil

  while true do
    local gate, gate_handle = gate_enter(dir)
    local ok, result, why = pcall(function()
      local s = scan(dir, mine)
      if mode == "shared" then
        if info.key ~= "" then
          for _, e in ipairs(s.shared) do
            if e.key == info.key then
              error("lovewright.lock: another run with key '" .. info.key .. "' is already running ("
                .. (e.label ~= "" and e.label or e.name) .. ")", 0)
            end
          end
        end
        if #s.exclusive == 0 and #s.waiting == 0 then
          local name = "S-" .. tok
          return { name = name, handle = hold(dir .. "/" .. name, info) }
        end
        local busy = {}
        if #s.exclusive > 0 then busy[#busy + 1] = "exclusive: " .. names(s.exclusive) end
        if #s.waiting > 0 then busy[#busy + 1] = "exclusive queued: " .. names(s.waiting) end
        return nil, table.concat(busy, "; ")
      end
      -- exclusive: queue once, then wait to be first with nobody inside
      if not wait_name then
        local ticket = 1
        for _, w in ipairs(s.waiting) do ticket = math.max(ticket, w.ticket + 1) end
        wait_name = string.format("W-%010d-%s", ticket, tok)
        wait_handle = hold(dir .. "/" .. wait_name, info)
        mine[wait_name] = true
        s = scan(dir, mine)
      end
      local first = s.waiting[1] and s.waiting[1].name == wait_name
      if first and #s.exclusive == 0 and #s.shared == 0 then
        local name = "X-" .. tok
        local handle = hold(dir .. "/" .. name, info)
        wait_handle:close()
        os.remove(native(dir .. "/" .. wait_name))
        mine[wait_name] = nil
        wait_name, wait_handle = nil, nil
        return { name = name, handle = handle }
      end
      local busy = {}
      if #s.exclusive > 0 then busy[#busy + 1] = "exclusive: " .. names(s.exclusive) end
      if #s.shared > 0 then busy[#busy + 1] = "shared: " .. names(s.shared) end
      if not first then busy[#busy + 1] = "queued ahead: " .. names(s.waiting, wait_name) end
      return nil, table.concat(busy, "; ")
    end)
    gate_leave(gate, gate_handle)
    if not ok then
      if wait_handle then
        wait_handle:close()
        os.remove(native(dir .. "/" .. wait_name))
      end
      error(result, 0)
    end
    if type(result) == "table" then
      if last_note then
        log(string.format("[lovewright] lock: %s lock taken after %.0f s", mode, now() - started))
      end
      return setmetatable({ mode = mode, path = dir .. "/" .. result.name, handle = result.handle }, Held)
    end

    if last_note == nil or now() - last_note >= 60 then
      log(string.format("[lovewright] lock: waiting for the %s lock (%s)", mode, tostring(why or "busy")))
      last_note = now()
    end
    if opts.timeout and now() - started > opts.timeout then
      if wait_handle then
        wait_handle:close()
        os.remove(native(dir .. "/" .. wait_name))
      end
      error(string.format("lovewright.lock: no %s lock after %d s", mode, opts.timeout), 0)
    end
    sleep(1)
  end
end

--- Who holds or waits for the lock right now (for diagnostics)
-- @return table { shared = {...}, waiting = {...}, exclusive = {...} }
function Lock.status(dir)
  dir = (dir or Lock.default_dir()):gsub("\\", "/")
  mkdir_p(dir)
  local gate, handle = gate_enter(dir)
  local ok, s = pcall(scan, dir, {})
  gate_leave(gate, handle)
  if not ok then error(s, 0) end
  return s
end

return Lock
