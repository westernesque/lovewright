--- Lovewright - Automated test framework for LÖVE2D applications
-- Inspired by Playwright
--
-- @module lovewright
-- @author lovewright contributors
-- @license MIT

local lovewright = {
  _VERSION = "0.1.0",
  _DESCRIPTION = "Automated test framework for LÖVE2D applications",
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
-- @param options.headless boolean Run without visible window (default: false)
-- @param options.love_path string Path to love executable (default: "love")
-- @param options.timeout number Connection timeout in ms (default: 5000)
-- @return Game Game controller instance
function lovewright.launch(options)
  return Game.launch(options)
end

--- Define a test suite
-- @param name string Name of the suite
-- @param fn function Suite definition function
function lovewright.describe(name, fn)
  return Runner.describe(name, fn)
end

--- Define a test case
-- @param name string Name of the test
-- @param fn function Test function
function lovewright.it(name, fn)
  return Runner.it(name, fn)
end

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

-- Attach describe/it modifiers
lovewright.describe.only = Runner.describe_only
lovewright.describe.skip = Runner.describe_skip
lovewright.it.only = Runner.it_only
lovewright.it.skip = Runner.it_skip

-- Make describe and it callable with modifiers
setmetatable(lovewright, {
  __index = function(t, k)
    return rawget(t, k)
  end,
})

return lovewright
