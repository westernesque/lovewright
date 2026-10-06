--- Trace recording for lovewright (Playwright-style)
-- Records a per-test timeline of actions, waits, and assertions, with
-- embedded screenshots, and writes a self-contained HTML trace file per test.
--
-- Modes (lovewright.config.trace):
--   "off"               - no tracing (default)
--   "retain-on-failure" - record events; write a trace (plus a screenshot
--                         taken at the moment of failure) only for failing tests
--   "on"                - record events, snapshot after every input action,
--                         and write a trace for every test
--
-- Output directory: lovewright.config.trace_dir (default "lovewright-traces")

local Trace = {}

-- Shared config table; lovewright/init.lua points this at lovewright.config
Trace.config = { trace = "off" }

-- Currently recording trace (nil when not recording)
local current = nil

-- Games launched during the current test (most recent last), used to grab
-- a screenshot at the moment of failure
local active_games = {}

local counter = 0

local function mode()
  return Trace.config.trace or "off"
end

local function now()
  return require("socket").gettime()
end

local is_windows = package.config:sub(1, 1) == "\\"

local function mkdir(path)
  if is_windows then
    os.execute('mkdir "' .. path:gsub("/", "\\") .. '" 2>nul')
  else
    os.execute('mkdir -p "' .. path .. '" 2>/dev/null')
  end
end

-- Whether a trace is currently being recorded
function Trace.enabled()
  return current ~= nil
end

--- Start recording a trace for a test.
-- Note: active_games persists across tests — games launched in beforeAll
-- stay available for failure screenshots until they are closed.
function Trace.begin(suite_name, test_name)
  if mode() == "off" then
    current = nil
    return
  end
  counter = counter + 1
  current = {
    suite = suite_name,
    test = test_name,
    start = now(),
    events = {},
    steps = {},   -- open step groups, innermost last (see Trace.step_begin)
    index = counter,
  }
end

-- Append an event to the innermost open step, or the top-level timeline
local function push(event)
  local open = current.steps[#current.steps]
  table.insert(open and open.children or current.events, event)
end

--- Record a timeline event. details is an optional table of key -> scalar.
function Trace.record(event_type, label, details)
  if not current then return end
  push({
    t = now() - current.start,
    type = event_type,
    label = label,
    details = details,
  })
end

--- Attach an already-encoded base64 PNG to the timeline
function Trace.attach(b64_png, label)
  if not current or not b64_png then return end
  push({
    t = now() - current.start,
    type = "screenshot",
    label = label or "screenshot",
    image = b64_png,
  })
end

--- Capture a screenshot from a game and attach it to the timeline
function Trace.snapshot(game, label)
  if not current then return end
  local ok, b64 = pcall(function()
    return game:screenshotBase64()
  end)
  if ok and b64 then
    Trace.attach(b64, label)
  end
end

--- Record an input action; in "on" mode also snapshot the game afterwards
function Trace.action(game, label, details)
  if not current then return end
  Trace.record("action", label, details)
  if mode() == "on" and game then
    Trace.snapshot(game, "after " .. label)
  end
end

--- Open a step group: events recorded until the matching step_end nest
-- under it (lovewright.step drives these)
function Trace.step_begin(name)
  if not current then return end
  local group = {
    t = now() - current.start,
    type = "step",
    label = name,
    children = {},
  }
  push(group)
  table.insert(current.steps, group)
end

--- Close the innermost step group. err is the error text when the step
-- failed and the error started there (not in a nested step)
function Trace.step_end(status, err)
  if not current then return end
  local group = table.remove(current.steps)
  if not group then return end
  group.duration = now() - current.start - group.t
  group.status = status
  group.error = err
end

-- Game registry hooks (called from Game.launch/close)
function Trace.game_launched(game)
  table.insert(active_games, game)
end

function Trace.game_closed(game)
  for i = #active_games, 1, -1 do
    if active_games[i] == game then
      table.remove(active_games, i)
    end
  end
end

-- HTML helpers -------------------------------------------------------------

local function escape_html(str)
  if type(str) ~= "string" then return tostring(str) end
  return str
    :gsub("&", "&amp;")
    :gsub("<", "&lt;")
    :gsub(">", "&gt;")
    :gsub('"', "&quot;")
end

local function slugify(str)
  local slug = tostring(str):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  return slug:sub(1, 60)
end

local function details_string(details)
  if not details then return "" end
  local parts = {}
  for k, v in pairs(details) do
    table.insert(parts, tostring(k) .. "=" .. tostring(v))
  end
  table.sort(parts)
  return table.concat(parts, "  ")
end

-- Number of events in a timeline, counting those nested in steps
local function count_events(events)
  local n = 0
  for _, event in ipairs(events) do
    n = n + 1
    if event.children then
      n = n + count_events(event.children)
    end
  end
  return n
end

-- Write the trace as a self-contained HTML file; returns the file path
function Trace.write_html(trace)
  local dir = Trace.config.trace_dir or "lovewright-traces"
  mkdir(dir)

  local filename = string.format("%s/trace-%03d-%s.html", dir, trace.index, slugify(trace.test))

  local status_color = trace.status == "passed" and "#2ecc71" or "#e74c3c"

  local parts = {}
  table.insert(parts, string.format([[
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Trace: %s</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, 'Segoe UI', Roboto, sans-serif; background: #1a1a2e; color: #eee; line-height: 1.5; }
    .container { max-width: 1100px; margin: 0 auto; padding: 20px; }
    header { padding: 25px 20px; background: #16213e; border-bottom: 3px solid %s; margin-bottom: 20px; }
    header h1 { font-size: 1.4em; }
    header .suite { opacity: 0.7; font-size: 0.95em; }
    header .meta { margin-top: 8px; font-size: 0.9em; }
    .status { display: inline-block; padding: 2px 10px; border-radius: 4px; background: %s; color: #fff; font-weight: bold; }
    .error { background: #0d1b2a; border-left: 4px solid #e74c3c; padding: 12px 15px; margin: 15px 0;
             font-family: monospace; font-size: 0.9em; white-space: pre-wrap; word-break: break-word; }
    table { width: 100%%; border-collapse: collapse; }
    td { padding: 6px 10px; border-bottom: 1px solid #0f3460; vertical-align: top; font-size: 0.92em; }
    td.time { color: #f39c12; font-family: monospace; white-space: nowrap; width: 80px; }
    td.type { width: 110px; }
    .badge { display: inline-block; padding: 1px 8px; border-radius: 4px; font-size: 0.8em; background: #0f3460; }
    .badge.action { background: #2980b9; }
    .badge.assert-pass { background: #27ae60; }
    .badge.assert-fail { background: #c0392b; }
    .badge.wait { background: #8e44ad; }
    .badge.screenshot { background: #d35400; }
    .badge.game { background: #16a085; }
    .badge.step { background: #34495e; }
    td.step-cell { padding: 4px 0 4px 10px; }
    td td { font-size: 1em; }
    details.step > summary { cursor: pointer; padding: 2px 0; }
    details.step > summary .time { color: #f39c12; font-family: monospace; display: inline-block; width: 70px; }
    details.step.passed > summary .mark { color: #2ecc71; }
    details.step.failed > summary .mark { color: #e74c3c; }
    details.step.failed > summary { color: #ff8a80; }
    details.step > table { margin-left: 18px; width: calc(100%% - 18px); border-left: 2px solid #0f3460; }
    details.step > .error { margin: 6px 0 6px 18px; }
    .detail { opacity: 0.7; font-family: monospace; font-size: 0.85em; }
    .shot img { max-width: 100%%; border: 1px solid #0f3460; border-radius: 6px; margin-top: 6px; }
    footer { text-align: center; padding: 25px; opacity: 0.6; font-size: 0.9em; }
  </style>
</head>
<body>
  <header>
    <h1>%s</h1>
    <div class="suite">%s</div>
    <div class="meta"><span class="status">%s</span> &nbsp; %.2fs &nbsp; %d events%s</div>
  </header>
  <div class="container">
]],
    escape_html(trace.test),
    status_color, status_color,
    escape_html(trace.test),
    escape_html(trace.suite),
    escape_html(string.upper(trace.status)),
    trace.duration or 0,
    count_events(trace.events),
    trace.step and (' &nbsp; failed in step <b>' .. escape_html(trace.step) .. '</b>') or ""
  ))

  if trace.error then
    table.insert(parts, '    <div class="error">' .. escape_html(trace.error) .. "</div>\n")
  end

  -- One timeline row per event; steps become collapsible groups holding
  -- their own rows (failed steps start open, passed ones collapsed)
  local function render(events, indent)
    if #events == 0 then return end
    table.insert(parts, indent .. "<table>\n")
    for _, event in ipairs(events) do
      local badge_class = event.type
      if event.type == "assert:pass" then badge_class = "assert-pass" end
      if event.type == "assert:fail" then badge_class = "assert-fail" end

      if event.type == "step" then
        local failed = event.status == "failed"
        local mark = failed and "&#10007;" or (event.status == "passed" and "&#10003;" or "&hellip;")
        table.insert(parts, string.format(
          '%s  <tr><td colspan="3" class="step-cell"><details class="step %s"%s><summary>' ..
          '<span class="time">+%.2fs</span> <span class="badge step">step</span> ' ..
          '<span class="mark">%s</span> %s <span class="detail">%s</span></summary>\n',
          indent, failed and "failed" or "passed", failed and " open" or "",
          event.t, mark, escape_html(event.label),
          event.duration and string.format("%.2fs", event.duration) or "unfinished"
        ))
        if event.error then
          table.insert(parts, indent .. '    <div class="error">' .. escape_html(event.error) .. "</div>\n")
        end
        render(event.children, indent .. "    ")
        table.insert(parts, indent .. "  </details></td></tr>\n")
      elseif event.image then
        table.insert(parts, string.format(
          '%s  <tr><td class="time">+%.2fs</td><td class="type"><span class="badge screenshot">screenshot</span></td>' ..
          '<td class="shot">%s<br><img src="data:image/png;base64,%s" loading="lazy"></td></tr>\n',
          indent, event.t, escape_html(event.label), event.image
        ))
      else
        table.insert(parts, string.format(
          '%s  <tr><td class="time">+%.2fs</td><td class="type"><span class="badge %s">%s</span></td>' ..
          '<td>%s <span class="detail">%s</span></td></tr>\n',
          indent, event.t, badge_class, escape_html(event.type), escape_html(event.label),
          escape_html(details_string(event.details))
        ))
      end
    end
    table.insert(parts, indent .. "</table>\n")
  end
  render(trace.events, "    ")

  table.insert(parts, [[
  </div>
  <footer>Generated by Lovewright trace</footer>
</body>
</html>
]])

  local file = io.open(filename, "w")
  if not file then
    return nil
  end
  file:write(table.concat(parts))
  file:close()
  return filename
end

--- Finish the current trace; returns the written file path (or nil).
-- step is the "outer > inner" path of the step the failure came from
function Trace.finish(status, err, step)
  local trace = current
  if not trace then
    current = nil
    return nil
  end

  local write = (mode() == "on") or (mode() == "retain-on-failure" and status == "failed")
  if not write then
    current = nil
    return nil
  end

  -- Steps still open (none, unless a step body never returned) end here;
  -- the failure screenshot below then lands on the top-level timeline
  trace.steps = {}

  -- On failure, grab a final screenshot from the most recently launched game
  if status == "failed" then
    local game = active_games[#active_games]
    if game and game.connected then
      Trace.snapshot(game, "at failure")
    end
  end

  current = nil
  trace.duration = now() - trace.start
  trace.status = status
  trace.error = err and tostring(err) or nil
  trace.step = step

  return Trace.write_html(trace)
end

return Trace
