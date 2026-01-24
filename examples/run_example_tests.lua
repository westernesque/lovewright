#!/usr/bin/env lua
--- Simple test runner script for lovewright

-- Add lovewright to path
package.path = "./?.lua;./?/init.lua;" .. package.path

local lovewright = require("lovewright")

-- Get test path from args or use default
local path = arg[1] or "examples/tests"

print("Lovewright Test Runner")
print("======================\n")

local results = lovewright.run({ path = path })

-- Exit with error code if tests failed
os.exit(results.failed > 0 and 1 or 0)
