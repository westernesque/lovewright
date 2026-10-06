--- Test steps for lovewright (Playwright's test.step)
-- Groups the actions, waits and assertions of a test under a name. Steps
-- nest; each one shows up as a collapsible group in the test's trace and
-- as an outline in the HTML report, and when a test fails the runner names
-- the innermost step the error escaped from ("In step: open menu > click
-- Start").
--
--   lovewright.step("open the settings", function()
--     game:locator("SettingsButton"):click()
--     game:waitFor(function() ... end)
--   end)
--
-- step(name, fn) calls fn() and returns whatever it returns. An error
-- raised inside it is rethrown unchanged (same value, same message), so
-- pcall around a step sees exactly what fn raised.

local Trace = require("lovewright.trace")

local Step = {}

local stack = {}     -- open steps, outermost first
local roots = {}     -- top-level steps of the current test, in run order
local failure = nil  -- { err = <error value>, node = <innermost step it escaped from> }

local unpack = unpack or table.unpack

local function pack(...)
  return { n = select("#", ...), ... }
end

local function now()
  return require("socket").gettime()
end

local function path_of(node)
  local names = {}
  while node do
    table.insert(names, 1, node.name)
    node = node.parent
  end
  return table.concat(names, " > ")
end

-- true if `node` is `ancestor` or nested somewhere inside it
local function within(node, ancestor)
  while node do
    if node == ancestor then return true end
    node = node.parent
  end
  return false
end

--- Forget the steps of the previous test (the runner calls this per test)
function Step.reset()
  stack = {}
  roots = {}
  failure = nil
end

--- Run fn as a named step; returns fn's results, rethrows its error
function Step.run(name, fn)
  if type(fn) ~= "function" then
    error("step(name, fn): fn must be a function, got " .. type(fn), 2)
  end
  name = tostring(name)

  -- A new step starting means any earlier step failure was caught by the
  -- test, so it is no longer the reason the test might fail
  failure = nil

  local parent = stack[#stack]
  local node = { name = name, parent = parent, children = {}, start = now() }
  table.insert(parent and parent.children or roots, node)
  table.insert(stack, node)
  Trace.step_begin(name)

  local results = pack(pcall(fn))

  stack[#stack] = nil
  node.duration = now() - node.start

  if results[1] then
    node.status = "passed"
    Trace.step_end("passed")
    return unpack(results, 2, results.n)
  end

  local err = results[2]
  node.status = "failed"
  -- Keep the innermost failing step: an inner step already claimed this
  -- error on its way out unless the error is new
  if not (failure and failure.err == err and within(failure.node, node)) then
    failure = { err = err, node = node }
    node.error = tostring(err)
  end
  Trace.step_end("failed", node.error)
  error(err, 0)
end

--- The "outer > inner" path of the step `err` escaped from, or nil when it
-- was not raised inside a step (or the test caught that step's error)
function Step.failed_in(err)
  if failure and failure.err == err then
    return path_of(failure.node)
  end
  return nil
end

--- Path of the step currently running ("" outside any step)
function Step.current()
  return path_of(stack[#stack])
end

--- Plain copy of the current test's step tree, for reports:
-- { { name, status, duration, error?, children = {...} }, ... }
function Step.tree()
  local function copy(list)
    local out = {}
    for _, node in ipairs(list) do
      table.insert(out, {
        name = node.name,
        status = node.status or "running",
        duration = node.duration,
        error = node.error,
        children = copy(node.children),
      })
    end
    return out
  end
  return copy(roots)
end

return Step
