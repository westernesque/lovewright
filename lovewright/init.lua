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
    headless = false,  -- Run games without a visible window
  },
}

-- Load submodules
local Game = require("lovewright.game")
local Runner = require("lovewright.runner")
local ExpectModule = require("lovewright.expect")
local Screenshot = require("lovewright.screenshot")

--- Launch a LÖVE2D game for testing
-- @param options table Configuration options
-- @param options.path string Path to the game directory (required)
-- @param options.width number Window width (default: 800)
-- @param options.height number Window height (default: 600)
-- @param options.headless boolean Run without visible window (default: lovewright.config.headless)
-- @param options.love_path string Path to love executable (default: "love")
-- @param options.timeout number Connection timeout in ms (default: 5000)
-- @return Game Game controller instance
function lovewright.launch(options)
  options = options or {}
  -- Apply global config defaults
  if options.headless == nil then
    options.headless = lovewright.config.headless
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

--- Define a test case (callable table with .only and .skip modifiers)
lovewright.it = setmetatable({
  only = Runner.it_only,
  skip = Runner.it_skip,
}, {
  __call = function(_, name, fn)
    return Runner.it(name, fn)
  end,
})

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
-- @return table Test results
function lovewright.run(options)
  return Runner.run(options)
end

--- Reset test state (useful for meta-testing)
function lovewright.reset()
  return Runner.reset()
end

return lovewright
