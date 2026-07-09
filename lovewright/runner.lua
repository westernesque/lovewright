--- Test runner module for lovewright
-- Discovers and executes tests with describe/it blocks

local Runner = {}

-- Test state
local state = {
  suites = {},            -- All registered test suites
  current_suite = nil,    -- Currently defining suite
  before_each = {},       -- Global beforeEach hooks
  after_each = {},        -- Global afterEach hooks
  before_all = {},        -- Global beforeAll hooks
  after_all = {},         -- Global afterAll hooks
  only_mode = false,      -- If true, only run .only tests
  results = {
    passed = 0,
    failed = 0,
    skipped = 0,
    total = 0,
    failures = {},
    tests = {},           -- Every test in run order: {suite, test, status, duration, error?, phase?, trace?}
    duration = 0,
  },
}

-- Suite class
local Suite = {}
Suite.__index = Suite

function Suite.new(name, fn, options)
  local self = setmetatable({}, Suite)
  self.name = name
  self.fn = fn
  self.tests = {}
  self.before_each = {}
  self.after_each = {}
  self.before_all = {}
  self.after_all = {}
  self.only = options and options.only or false
  self.skip = options and options.skip or false
  self.nested = {}
  return self
end

-- Test class
local Test = {}
Test.__index = Test

function Test.new(name, fn, options)
  local self = setmetatable({}, Test)
  self.name = name
  self.fn = fn
  self.only = options and options.only or false
  self.skip = options and options.skip or false
  return self
end

-- describe function
function Runner.describe(name, fn)
  local suite = Suite.new(name, fn)
  local parent = state.current_suite

  state.current_suite = suite

  -- Execute the suite function to collect tests
  fn()

  state.current_suite = parent

  if parent then
    table.insert(parent.nested, suite)
  else
    table.insert(state.suites, suite)
  end

  return suite
end

-- describe.only - only run this suite
function Runner.describe_only(name, fn)
  state.only_mode = true
  local suite = Suite.new(name, fn, { only = true })
  local parent = state.current_suite

  state.current_suite = suite
  fn()
  state.current_suite = parent

  if parent then
    table.insert(parent.nested, suite)
  else
    table.insert(state.suites, suite)
  end

  return suite
end

-- describe.skip - skip this suite
function Runner.describe_skip(name, fn)
  local suite = Suite.new(name, fn, { skip = true })

  if state.current_suite then
    table.insert(state.current_suite.nested, suite)
  else
    table.insert(state.suites, suite)
  end

  return suite
end

-- it function
function Runner.it(name, fn)
  if not state.current_suite then
    error("it() must be called inside describe()")
  end

  local test = Test.new(name, fn)
  table.insert(state.current_suite.tests, test)
  return test
end

-- it.only - only run this test
function Runner.it_only(name, fn)
  state.only_mode = true
  if not state.current_suite then
    error("it.only() must be called inside describe()")
  end

  local test = Test.new(name, fn, { only = true })
  table.insert(state.current_suite.tests, test)
  return test
end

-- it.skip - skip this test
function Runner.it_skip(name, fn)
  if not state.current_suite then
    error("it.skip() must be called inside describe()")
  end

  local test = Test.new(name, fn, { skip = true })
  table.insert(state.current_suite.tests, test)
  return test
end

-- Hook functions
function Runner.beforeEach(fn)
  if state.current_suite then
    table.insert(state.current_suite.before_each, fn)
  else
    table.insert(state.before_each, fn)
  end
end

function Runner.afterEach(fn)
  if state.current_suite then
    table.insert(state.current_suite.after_each, fn)
  else
    table.insert(state.after_each, fn)
  end
end

function Runner.beforeAll(fn)
  if state.current_suite then
    table.insert(state.current_suite.before_all, fn)
  else
    table.insert(state.before_all, fn)
  end
end

function Runner.afterAll(fn)
  if state.current_suite then
    table.insert(state.current_suite.after_all, fn)
  else
    table.insert(state.after_all, fn)
  end
end

-- Run hooks
local function run_hooks(hooks)
  for _, hook in ipairs(hooks) do
    hook()
  end
end

-- Check if suite or test should run (considering .only)
local function should_run(item, parent_only)
  if item.skip then
    return false
  end
  if state.only_mode then
    return item.only or parent_only
  end
  return true
end

-- Check if suite has any .only items
local function has_only(suite)
  if suite.only then return true end
  for _, test in ipairs(suite.tests) do
    if test.only then return true end
  end
  for _, nested in ipairs(suite.nested) do
    if has_only(nested) then return true end
  end
  return false
end

-- Run a single test
local function run_test(test, suite_name, hooks)
  local Trace = require("lovewright.trace")

  state.results.total = state.results.total + 1

  -- Full per-test record (passed tests included), used by the HTML report
  local record = { suite = suite_name, test = test.name }
  table.insert(state.results.tests, record)

  if test.skip or (state.only_mode and not test.only) then
    state.results.skipped = state.results.skipped + 1
    record.status = "skipped"
    io.write("  - " .. test.name .. " (skipped)\n")
    return
  end

  io.write("  - " .. test.name .. " ")
  io.flush()

  local start_time = os.clock()

  Trace.begin(suite_name, test.name)

  -- Finish the trace, remember its path, and print it for failures
  local function finish_trace(failure, status, err)
    local trace_path = Trace.finish(status, err)
    if trace_path then
      record.trace = trace_path
      if failure then
        failure.trace = trace_path
        io.write("    Trace: " .. trace_path .. "\n")
      end
    end
  end

  local function record_failure(err, phase)
    state.results.failed = state.results.failed + 1
    record.status = "failed"
    record.error = tostring(err)
    record.phase = phase
    local failure = {
      suite = suite_name,
      test = test.name,
      error = tostring(err),
      phase = phase,
    }
    table.insert(state.results.failures, failure)
    return failure
  end

  -- Run beforeEach hooks
  local ok, err = pcall(function()
    for _, hook in ipairs(hooks.before_each) do
      hook()
    end
  end)

  if not ok then
    io.write("FAIL (beforeEach failed)\n")
    io.write("    Error: " .. tostring(err):gsub("\n", "\n    ") .. "\n")
    local failure = record_failure(err, "beforeEach")
    finish_trace(failure, "failed", err)
    return
  end

  -- Run the test
  ok, err = pcall(test.fn)

  local duration = os.clock() - start_time
  record.duration = duration

  if not ok then
    io.write("FAIL\n")
    local failure = record_failure(err, "test")
    -- Finish the trace now: the failure screenshot must be captured before
    -- afterEach hooks close the game
    finish_trace(failure, "failed", err)
  end

  -- Run afterEach hooks (even if the test failed)
  local after_ok, after_err = pcall(function()
    for _, hook in ipairs(hooks.after_each) do
      hook()
    end
  end)

  if ok then
    if after_ok then
      state.results.passed = state.results.passed + 1
      record.status = "passed"
      io.write(string.format("PASS (%.0fms)\n", duration * 1000))
      finish_trace(nil, "passed")
    else
      io.write("FAIL (afterEach failed)\n")
      local failure = record_failure(after_err, "afterEach")
      finish_trace(failure, "failed", after_err)
    end
  end
end

-- Run a suite
local function run_suite(suite, parent_name, parent_hooks)
  local full_name = parent_name and (parent_name .. " > " .. suite.name) or suite.name

  if suite.skip then
    io.write("\n" .. full_name .. " (skipped)\n")
    return
  end

  if state.only_mode and not suite.only and not has_only(suite) then
    return
  end

  io.write("\n" .. full_name .. "\n")

  -- Merge hooks
  local hooks = {
    before_each = {},
    after_each = {},
  }

  -- Add parent hooks
  if parent_hooks then
    for _, h in ipairs(parent_hooks.before_each) do
      table.insert(hooks.before_each, h)
    end
    for _, h in ipairs(parent_hooks.after_each) do
      table.insert(hooks.after_each, h)
    end
  end

  -- Add global hooks
  for _, h in ipairs(state.before_each) do
    table.insert(hooks.before_each, h)
  end
  for _, h in ipairs(state.after_each) do
    table.insert(hooks.after_each, h)
  end

  -- Add suite hooks
  for _, h in ipairs(suite.before_each) do
    table.insert(hooks.before_each, h)
  end
  for _, h in ipairs(suite.after_each) do
    table.insert(hooks.after_each, h)
  end

  -- Run beforeAll (traced so setup/launch failures are diagnosable)
  local Trace = require("lovewright.trace")
  Trace.begin(full_name, "(suite setup)")
  local ok, err = pcall(function()
    run_hooks(suite.before_all)
  end)

  if not ok then
    io.write("  beforeAll failed: " .. tostring(err) .. "\n")
    -- Count as a failure so runners exit non-zero
    state.results.failed = state.results.failed + 1
    local failure = {
      suite = full_name,
      test = "(suite setup)",
      error = tostring(err),
      phase = "beforeAll",
    }
    table.insert(state.results.failures, failure)
    local record = {
      suite = full_name,
      test = "(suite setup)",
      status = "failed",
      error = tostring(err),
      phase = "beforeAll",
    }
    table.insert(state.results.tests, record)
    local trace_path = Trace.finish("failed", err)
    if trace_path then
      failure.trace = trace_path
      record.trace = trace_path
      io.write("    Trace: " .. trace_path .. "\n")
    end
    return
  end
  Trace.finish("passed")

  -- Run tests
  for _, test in ipairs(suite.tests) do
    run_test(test, full_name, hooks)
  end

  -- Run nested suites
  for _, nested in ipairs(suite.nested) do
    run_suite(nested, full_name, hooks)
  end

  -- Run afterAll
  pcall(function()
    run_hooks(suite.after_all)
  end)
end

-- Check if running on Windows
local function is_windows()
  return package.config:sub(1, 1) == "\\"
end

-- Discover test files (cross-platform)
function Runner.discover(path, pattern)
  pattern = pattern or "_test%.lua$"
  local files = {}

  local cmd
  if is_windows() then
    -- Windows: use dir command
    -- Convert forward slashes to backslashes for Windows
    local win_path = path:gsub("/", "\\")
    cmd = 'dir /s /b "' .. win_path .. '\\*.lua" 2>nul'
  else
    -- Unix: use find command
    cmd = 'find "' .. path .. '" -name "*.lua" -type f 2>/dev/null'
  end

  local handle = io.popen(cmd)
  if handle then
    for file in handle:lines() do
      -- Normalize path separators
      local normalized = file:gsub("\\", "/")
      if normalized:match(pattern) or normalized:match("_spec%.lua$") then
        table.insert(files, file)
      end
    end
    handle:close()
  end

  return files
end

-- Load and run test files
function Runner.run(options)
  options = options or {}
  local path = options.path or "."
  local pattern = options.pattern
  local files = options.files

  -- Reset state
  state.suites = {}
  state.only_mode = false
  state.results = {
    passed = 0,
    failed = 0,
    skipped = 0,
    total = 0,
    failures = {},
    tests = {},
    duration = 0,
  }

  -- Discover files if not provided
  if not files then
    files = Runner.discover(path, pattern)
  end

  if #files == 0 then
    print("No test files found")
    return state.results
  end

  print("Found " .. #files .. " test file(s)\n")

  local start_time = os.clock()

  -- Run global beforeAll
  run_hooks(state.before_all)

  -- Load and execute each file
  for _, file in ipairs(files) do
    print("Loading: " .. file)
    local chunk, err = loadfile(file)
    if chunk then
      local ok, load_err = pcall(chunk)
      if not ok then
        print("Error loading " .. file .. ": " .. tostring(load_err))
      end
    else
      print("Error parsing " .. file .. ": " .. tostring(err))
    end
  end

  -- Run all suites
  for _, suite in ipairs(state.suites) do
    run_suite(suite)
  end

  -- Run global afterAll
  run_hooks(state.after_all)

  state.results.duration = os.clock() - start_time

  -- Print summary
  print("\n" .. string.rep("-", 50))
  print(string.format(
    "Results: %d passed, %d failed, %d skipped (%.2fs)",
    state.results.passed,
    state.results.failed,
    state.results.skipped,
    state.results.duration
  ))

  -- Print failures
  if #state.results.failures > 0 then
    print("\nFailures:")
    for i, failure in ipairs(state.results.failures) do
      print(string.format(
        "\n%d) %s > %s",
        i,
        failure.suite,
        failure.test
      ))
      if failure.phase ~= "test" then
        print("   (in " .. failure.phase .. ")")
      end
      print("   " .. failure.error:gsub("\n", "\n   "))
    end
  end

  -- Generate HTML report if requested
  if options.report ~= false then
    local Reporter = require("lovewright.reporter")
    local report_path = options.report_output or "lovewright-report.html"
    local ok, err = Reporter.generate_html(state.results, { output = report_path })
    if ok then
      print("\nHTML report: " .. report_path)
    end
  end

  -- On GitHub Actions, also write a job summary and failure annotations
  if os.getenv("GITHUB_ACTIONS") or os.getenv("GITHUB_STEP_SUMMARY") then
    local Reporter = require("lovewright.reporter")
    pcall(Reporter.github_actions, state.results)
  end

  return state.results
end

-- Reset state (for testing the runner itself)
function Runner.reset()
  -- Reset port counter
  local protocol = require("lovewright.protocol")
  protocol.reset_ports()

  state.suites = {}
  state.current_suite = nil
  state.before_each = {}
  state.after_each = {}
  state.before_all = {}
  state.after_all = {}
  state.only_mode = false
  state.results = {
    passed = 0,
    failed = 0,
    skipped = 0,
    total = 0,
    failures = {},
    tests = {},
    duration = 0,
  }
end

return Runner
