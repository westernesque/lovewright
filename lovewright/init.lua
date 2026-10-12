--- Lovewright - Automated test framework for LÖVE2D applications
-- Inspired by Playwright
--
-- @module lovewright
-- @author lovewright contributors
-- @license MIT

local lovewright = {
  _VERSION = "0.1.0",
  _DESCRIPTION = "Automated test framework for LÖVE2D applications",

  -- Global configuration (can be set before running tests)
  config = {
    headless = false,           -- Run games without a visible window
    -- "hidden" | "offscreen" | "minimized" (fallback order); the
    -- LOVEWRIGHT_HEADLESS_MODE environment variable overrides the default
    headless_mode = os.getenv("LOVEWRIGHT_HEADLESS_MODE") or "hidden",
    trace = "off",              -- "off" | "on" | "retain-on-failure"
    trace_dir = "lovewright-traces",  -- Where trace HTML files are written
    -- Isolated run: several runs on one machine at once without sharing a
    -- save dir, wrapper copy, port or game process (lovewright/isolation.lua).
    -- LOVEWRIGHT_ISOLATED=1 turns it on
    isolated = os.getenv("LOVEWRIGHT_ISOLATED") == "1",
    -- Cross-process run lock taken by lovewright.run (lovewright/lock.lua):
    -- nil | "shared" | "exclusive". nil = "shared" in an isolated run, no
    -- lock otherwise. LOVEWRIGHT_LOCK=off disables it
    lock = nil,
    lock_dir = nil,             -- default <TEMP>/lovewright/locks (LOVEWRIGHT_LOCK_DIR)
    -- Hang watchdog (seconds): a game that answers nothing for this long
    -- while the runner waits on it is killed and the test fails.
    -- LOVEWRIGHT_HANG_TIMEOUT overrides; 0 = off
    hang_timeout = tonumber(os.getenv("LOVEWRIGHT_HANG_TIMEOUT") or "") or 300,
  },
}

-- Load submodules
local Game = require("lovewright.game")
local Runner = require("lovewright.runner")
local ExpectModule = require("lovewright.expect")
local Screenshot = require("lovewright.screenshot")
local Trace = require("lovewright.trace")
local Step = require("lovewright.step")
local Lock = require("lovewright.lock")
local Isolation = require("lovewright.isolation")

-- Traces read the shared config table (mode and output dir)
Trace.config = lovewright.config

--- Launch a LÖVE2D game for testing
-- @param options table Configuration options
-- @param options.path string Path to the game directory (required)
-- @param options.width number Window width (default: 800)
-- @param options.height number Window height (default: 600)
-- @param options.headless boolean Run without visible window (default: lovewright.config.headless)
-- @param options.headless_mode string "hidden" (default) | "offscreen" | "minimized"
-- @param options.love_path string Path to love executable (default: "love")
-- @param options.timeout number Connection timeout in ms (default: 5000)
-- @param options.identity string Override save-directory identity for test isolation
-- @param options.exclude table Dir/file names to skip when copying the game (".git" always skipped)
-- @param options.args table Extra command-line arguments for the game (read from LÖVE's `arg`)
-- @param options.isolated boolean Isolated run (default: lovewright.config.isolated)
-- @param options.hang_timeout number Hang watchdog seconds (default: lovewright.config.hang_timeout)
-- @return Game Game controller instance
function lovewright.launch(options)
  options = options or {}
  if options.isolated == nil then
    options.isolated = lovewright.config.isolated
  end
  -- Apply global config defaults
  if options.headless == nil then
    options.headless = lovewright.config.headless
  end
  if options.headless_mode == nil then
    options.headless_mode = lovewright.config.headless_mode
  end
  if options.hang_timeout == nil then
    options.hang_timeout = lovewright.config.hang_timeout
  end
  return Game.launch(options)
end

--- Define a test suite (callable table with .only and .skip modifiers)
lovewright.describe = setmetatable({
  only = Runner.describe_only,
  skip = Runner.describe_skip,
}, {
  __call = function(_, name, fn)
    return Runner.describe(name, fn)
  end,
})

--- Run fn as a named test step (Playwright's test.step) and return its
-- results. Steps nest; they group the trace timeline and the HTML report,
-- and a failing test names the innermost step its error came from. Errors
-- are rethrown unchanged.
-- @param name string Step name
-- @param fn function Step body
-- @return any Whatever fn returns
function lovewright.step(name, fn)
  return Step.run(name, fn)
end

--- Define a test case (callable table with .only, .skip and .step)
lovewright.it = setmetatable({
  only = Runner.it_only,
  skip = Runner.it_skip,
  step = lovewright.step,
}, {
  __call = function(_, name, fn)
    return Runner.it(name, fn)
  end,
})

--- Playwright-style alias: test("name", fn), test.step("name", fn)
lovewright.test = lovewright.it

--- Run before each test in the current suite
-- @param fn function Hook function
function lovewright.beforeEach(fn)
  return Runner.beforeEach(fn)
end

--- Run after each test in the current suite
-- @param fn function Hook function
function lovewright.afterEach(fn)
  return Runner.afterEach(fn)
end

--- Run once before all tests in the current suite
-- @param fn function Hook function
function lovewright.beforeAll(fn)
  return Runner.beforeAll(fn)
end

--- Run once after all tests in the current suite
-- @param fn function Hook function
function lovewright.afterAll(fn)
  return Runner.afterAll(fn)
end

--- Create an assertion on a value
-- @param value any Value to assert on
-- @return Expect Expect object with assertion methods
lovewright.expect = ExpectModule.expect

--- Screenshot utilities
lovewright.screenshot = Screenshot

--- Run tests
-- @param options table Runner options
-- @param options.path string Directory to search for tests
-- @param options.pattern string Lua pattern for test files
-- @param options.files table Explicit list of test files
-- @param options.lock string nil | "shared" | "exclusive" (default: lovewright.config.lock)
-- @param options.lock_label string Who holds the lock, shown to waiting runs
-- @return table Test results
function lovewright.run(options)
  options = options or {}
  local config = lovewright.config
  local mode = options.lock or config.lock
  if mode == nil and config.isolated then
    mode = "shared"
  end
  if os.getenv("LOVEWRIGHT_LOCK") == "off" then
    mode = nil
  end

  if config.isolated then
    print("Isolated run " .. Isolation.run_id() .. " (own save dir, wrapper, port and pids)")
  end
  local held
  if mode then
    held = Lock.acquire(mode, {
      dir = config.lock_dir,
      label = options.lock_label or ((config.isolated and Isolation.run_id() or Isolation.cwd()) .. " (" .. mode .. ")"),
      -- one isolated run per checkout: they would share its output files
      key = (mode == "shared" and config.isolated) and Isolation.run_id() or nil,
    })
  end
  Game.owner_lock = held and held.path or nil
  local ok, results = pcall(Runner.run, options)
  -- games a suite left open (or an error skipped closing) die with the run
  local left = Game.close_all()
  if left > 0 then
    print("[lovewright] closed " .. left .. " game(s) left open at the end of the run")
  end
  Game.owner_lock = nil
  if held then
    held:release()
  end
  if not ok then
    error(results, 0)
  end
  return results
end

--- Reset test state (useful for meta-testing)
function lovewright.reset()
  return Runner.reset()
end

return lovewright
