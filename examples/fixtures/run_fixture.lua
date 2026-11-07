--- Runs one fixture file through the real runner, in its own process, and
-- prints what happened as plain lines for examples/tests/setup_failure_test.lua.
-- A failed setup in a fixture is the point of the fixture: it has to stay out
-- of the results of the run that checks it, hence the second process.
--
--   lua examples/fixtures/run_fixture.lua examples/fixtures/<fixture>.lua
--
-- Calls the runner directly, without lovewright.run: no run lock of its own
-- (a run with --isolated already holds it, around this process).

package.path = "./?.lua;./?/init.lua;" .. package.path

local lovewright = require("lovewright")
local Game = require("lovewright.game")
local Reporter = require("lovewright.reporter")
local Runner = require("lovewright.runner")

local results = Runner.run({ files = { arg[1] }, report = false })

print(string.format("RESULT passed=%d failed=%d", results.passed, results.failed))
for _, f in ipairs(results.failures) do
  print(string.format("FAILURE suite=%s | test=%s | phase=%s | error=%s | afterAll=%s",
    f.suite, f.test, f.phase, f.error, tostring(f.after_all_error)))
end

-- What the HTML report shows for those failures
local report_path = "fixture-lovewright-report.html"
Reporter.generate_html(results, { output = report_path })
local file = io.open(report_path, "rb")
if file then
  local html = file:read("*a")
  file:close()
  os.remove(report_path)
  for _, f in ipairs(results.failures) do
    print(string.format("REPORT suite=%s | original=%s | afterAll=%s", f.suite,
      tostring(html:find(f.error, 1, true) ~= nil),
      tostring(f.after_all_error ~= nil and html:find("afterAll failed too", 1, true) ~= nil)))
  end
end

-- (a leaked game must not outlive this process: it would hold the pipe the
-- checking run reads this output from)
Game.close_all()
os.exit(0)
