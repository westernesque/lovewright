--- A failed beforeAll costs one suite: afterAll still runs, the games the suite
-- launched are closed, the report keeps the original error and the next suite
-- runs. The failing suites live in examples/fixtures and run in a process of
-- their own (run_fixture.lua), so their failures stay out of this run's results.

package.path = "./?.lua;./?/init.lua;" .. package.path

local lovewright = require("lovewright")
local describe, it, expect = lovewright.describe, lovewright.it, lovewright.expect

local is_windows = package.config:sub(1, 1) == "\\"

-- The interpreter running this file: the lowest index of the global arg
local function lua_exe()
  if not arg then return "lua" end
  local i = -1
  while arg[i - 1] do i = i - 1 end
  return arg[i] or "lua"
end

local function run_fixture(name)
  local cmd = string.format('"%s" examples/fixtures/run_fixture.lua examples/fixtures/%s.lua 2>&1', lua_exe(), name)
  -- (cmd.exe strips one pair of quotes around the whole line)
  if is_windows then cmd = '"' .. cmd .. '"' end
  local p = assert(io.popen(cmd))
  local out = p:read("*a")
  p:close()
  return out
end

local function has(out, text)
  return out:find(text, 1, true) ~= nil
end

-- `first` was printed before `second`. The run closes what is left when it ends,
-- so "closed" alone proves nothing: it has to happen before the next suite
local function in_order(out, first, second)
  local a, b = out:find(first, 1, true), out:find(second, 1, true)
  return a ~= nil and b ~= nil and a < b
end

-- The line of `out` starting with `prefix` and naming `suite`
local function line_for(out, prefix, suite)
  for line in out:gmatch("[^\r\n]+") do
    if line:sub(1, #prefix) == prefix and line:find("suite=" .. suite, 1, true) then
      return line
    end
  end
  error("no " .. prefix .. " line for '" .. suite .. "' in:\n" .. out, 0)
end

describe("A failed setup, fake games", function()
  local out

  lovewright.beforeAll(function()
    out = run_fixture("setup_failure_fake")
  end)

  it("runs every afterAll, also past one that errors on a nil handle", function()
    expect(has(out, "NOTE A first afterAll ran")):toBe(true)
    expect(has(out, "NOTE A second afterAll ran")):toBe(true)
  end)

  it("skips the suite's tests", function()
    expect(has(out, "NOTE A test ran")):toBe(false)
  end)

  it("closes the game whose handle never reached the suite", function()
    expect(in_order(out, "NOTE closed A", "NOTE B test ran")):toBe(true)
  end)

  it("keeps the original error, with afterAll's beside it", function()
    local line = line_for(out, "FAILURE", "setup fails, its handle never reached the suite")
    expect(has(line, "phase=beforeAll")):toBe(true)
    expect(has(line, "error=setup failed: A |")):toBe(true)
    expect(has(line, "afterAll=") and not has(line, "afterAll=nil")):toBe(true)
  end)

  it("shows both in the HTML report", function()
    local line = line_for(out, "REPORT", "setup fails, its handle never reached the suite")
    expect(has(line, "original=true")):toBe(true)
    expect(has(line, "afterAll=true")):toBe(true)
  end)

  it("runs the next suite", function()
    expect(has(out, "NOTE B test ran")):toBe(true)
  end)

  it("a nested setup failure closes its own game, not the outer suite's", function()
    expect(has(out, "NOTE inner afterAll ran")):toBe(true)
    expect(in_order(out, "NOTE closed inner", "NOTE outer open=true")):toBe(true)
    expect(in_order(out, "NOTE outer open=true", "NOTE closed outer")):toBe(true)
  end)

  it("closes a game the suite forgot, when that suite ends", function()
    expect(in_order(out, "NOTE closed forgotten", "NOTE games open=")):toBe(true)
    expect(has(out, "NOTE games open=0")):toBe(true)
  end)

  it("an afterAll error after a good setup is logged and fails nothing", function()
    expect(has(out, "afterAll failed: cleanup failed: good setup")):toBe(true)
    expect(has(out, "RESULT passed=5 failed=2")):toBe(true)
  end)
end)

describe("A failed setup, a real game", function()
  local out

  lovewright.beforeAll(function()
    out = run_fixture("setup_failure_game")
    for note in out:gmatch("NOTE [^\r\n]*") do
      print("  " .. note)
    end
  end)

  it("leaves no game running", function()
    expect(has(out, "NOTE leak pid_alive=false port_open=false others_open=0")):toBe(true)
  end)

  it("the next suite boots", function()
    expect(has(out, "NOTE next suite pong=true")):toBe(true)
    expect(has(out, "RESULT passed=2 failed=2")):toBe(true)
  end)

  it("closing a game twice is fine", function()
    expect(has(out, "NOTE second close survived")):toBe(true)
  end)
end)
