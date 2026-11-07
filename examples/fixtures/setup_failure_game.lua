--- Fixture: a failed setup with a real game, then a suite that has to boot its
-- own. Run by examples/tests/setup_failure_test.lua through run_fixture.lua.

local lovewright = require("lovewright")
local Game = require("lovewright.game")
local describe, it = lovewright.describe, lovewright.it
local socket = require("socket")

local is_windows = package.config:sub(1, 1) == "\\"

local function launch()
  return lovewright.launch({
    path = "examples/simple-game",
    width = 800,
    height = 600,
    timeout = 60000,
    headless = true,
  })
end

local function pid_alive(pid)
  if not (pid and is_windows) then return false end
  local p = io.popen('tasklist /FI "PID eq ' .. pid .. '" /FO CSV /NH 2>nul')
  local out = p and p:read("*a") or ""
  if p then p:close() end
  return out:find('"' .. pid .. '"', 1, true) ~= nil
end

-- The runtime listens on the game's port for as long as the game runs (the
-- way to tell on Linux, where a plain launch has no pid)
local function port_open(port)
  local client = socket.tcp()
  client:settimeout(1)
  local ok = client:connect("127.0.0.1", port)
  client:close()
  return ok and true or false
end

local leaked = {}

describe("setup launches a game, then fails", function()
  local game

  lovewright.beforeAll(function()
    -- as a launch helper does: the game stays in a local until the wait
    -- that comes after the launch has passed
    local helper_local = launch()
    helper_local:ping()
    leaked.pid = helper_local.process_info and helper_local.process_info.pid
    leaked.port = helper_local.port
    print("NOTE leak candidate pid=" .. tostring(leaked.pid))
    error("setup failed: the game never got there", 0)
    game = helper_local
  end)

  lovewright.afterAll(function()
    if game then game:close() end
  end)

  it("never runs", function() end)
end)

describe("setup closes its game itself, afterAll closes it again", function()
  local game

  lovewright.beforeAll(function()
    game = launch()
    game:close()
    error("setup failed: cleaned up by hand", 0)
  end)

  lovewright.afterAll(function()
    if game then game:close() end
    print("NOTE second close survived")
  end)
end)

describe("the suite after the failed setups", function()
  local game

  lovewright.beforeAll(function()
    game = launch()
  end)

  lovewright.afterAll(function()
    if game then game:close() end
  end)

  it("no longer has the game of the failed setup", function()
    local open = 0
    for g in pairs(Game.live) do
      if g ~= game then open = open + 1 end
    end
    print(string.format("NOTE leak pid_alive=%s port_open=%s others_open=%d",
      tostring(pid_alive(leaked.pid)), tostring(port_open(leaked.port)), open))
  end)

  it("boots its own", function()
    print("NOTE next suite pong=" .. tostring(game:ping() ~= nil))
  end)
end)
