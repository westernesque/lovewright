#!/usr/bin/env lua
--- Test runner script for lovewright examples
--
-- Usage:
--   lua examples/run_example_tests.lua [options]
--
-- Options:
--   --headless    Run tests without visible game windows (for CI)
--   --trace       Record a full trace (with screenshots) for every test;
--                 failing tests always get a trace
--   --path=PATH   Test directory path (default: examples/tests)

-- Add lovewright to path
package.path = "./?.lua;./?/init.lua;" .. package.path

local lovewright = require("lovewright")

-- Parse command line arguments
local path = "examples/tests"
local headless = false
local trace = "retain-on-failure"

for i = 1, #arg do
  if arg[i] == "--headless" then
    headless = true
  elseif arg[i] == "--trace" then
    trace = "on"
  elseif arg[i]:match("^--path=") then
    path = arg[i]:match("^--path=(.+)$")
  elseif not arg[i]:match("^%-") then
    path = arg[i]
  end
end

-- Configure lovewright
lovewright.config.headless = headless
lovewright.config.trace = trace

print("Lovewright Test Runner")
print("======================")
if headless then
  print("Mode: headless")
end
print("")

local results = lovewright.run({ path = path })

-- Exit with error code if tests failed
os.exit(results.failed > 0 and 1 or 0)
