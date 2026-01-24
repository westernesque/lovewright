--- HTML Reporter for lovewright
-- Generates Playwright-style HTML test reports

local Reporter = {}

-- Escape HTML special characters
local function escape_html(str)
  if type(str) ~= "string" then return tostring(str) end
  return str
    :gsub("&", "&amp;")
    :gsub("<", "&lt;")
    :gsub(">", "&gt;")
    :gsub('"', "&quot;")
    :gsub("\n", "<br>")
end

-- Format duration
local function format_duration(seconds)
  if seconds < 1 then
    return string.format("%.0fms", seconds * 1000)
  else
    return string.format("%.2fs", seconds)
  end
end

-- Generate HTML report
function Reporter.generate_html(results, options)
  options = options or {}
  local output_path = options.output or "lovewright-report.html"

  local passed = results.passed or 0
  local failed = results.failed or 0
  local skipped = results.skipped or 0
  local total = results.total or 0
  local duration = results.duration or 0
  local failures = results.failures or {}

  local pass_rate = total > 0 and math.floor((passed / total) * 100) or 0
  local status_color = failed > 0 and "#e74c3c" or "#2ecc71"

  local html = string.format([[
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Lovewright Test Report</title>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, sans-serif;
      background: #1a1a2e;
      color: #eee;
      line-height: 1.6;
    }
    .container { max-width: 1200px; margin: 0 auto; padding: 20px; }

    header {
      background: linear-gradient(135deg, #667eea 0%%, #764ba2 100%%);
      padding: 40px 20px;
      text-align: center;
      margin-bottom: 30px;
    }
    header h1 { font-size: 2.5em; margin-bottom: 10px; }
    header .subtitle { opacity: 0.9; font-size: 1.1em; }

    .summary {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
      gap: 20px;
      margin-bottom: 30px;
    }
    .stat-card {
      background: #16213e;
      border-radius: 12px;
      padding: 20px;
      text-align: center;
      border: 1px solid #0f3460;
    }
    .stat-card .number { font-size: 2.5em; font-weight: bold; }
    .stat-card .label { opacity: 0.7; text-transform: uppercase; font-size: 0.85em; letter-spacing: 1px; }
    .stat-card.passed .number { color: #2ecc71; }
    .stat-card.failed .number { color: #e74c3c; }
    .stat-card.skipped .number { color: #f39c12; }
    .stat-card.total .number { color: #3498db; }

    .progress-bar {
      background: #0f3460;
      border-radius: 10px;
      height: 20px;
      overflow: hidden;
      margin-bottom: 30px;
    }
    .progress-bar .fill {
      height: 100%%;
      background: linear-gradient(90deg, #2ecc71, #27ae60);
      transition: width 0.5s ease;
    }

    .section { margin-bottom: 30px; }
    .section h2 {
      font-size: 1.5em;
      margin-bottom: 15px;
      padding-bottom: 10px;
      border-bottom: 2px solid #0f3460;
    }

    .failure {
      background: #16213e;
      border-left: 4px solid #e74c3c;
      border-radius: 0 8px 8px 0;
      padding: 15px 20px;
      margin-bottom: 15px;
    }
    .failure .test-name {
      font-weight: bold;
      color: #e74c3c;
      margin-bottom: 5px;
    }
    .failure .suite-name {
      opacity: 0.7;
      font-size: 0.9em;
      margin-bottom: 10px;
    }
    .failure .error {
      background: #0d1b2a;
      padding: 15px;
      border-radius: 6px;
      font-family: 'Monaco', 'Menlo', 'Ubuntu Mono', monospace;
      font-size: 0.9em;
      overflow-x: auto;
      white-space: pre-wrap;
      word-break: break-word;
    }
    .failure .phase {
      display: inline-block;
      background: #e74c3c;
      color: white;
      padding: 2px 8px;
      border-radius: 4px;
      font-size: 0.8em;
      margin-left: 10px;
    }

    .no-failures {
      background: #16213e;
      border-left: 4px solid #2ecc71;
      border-radius: 0 8px 8px 0;
      padding: 20px;
      text-align: center;
      color: #2ecc71;
    }

    footer {
      text-align: center;
      padding: 30px;
      opacity: 0.6;
      font-size: 0.9em;
    }
    footer a { color: #667eea; text-decoration: none; }
    footer a:hover { text-decoration: underline; }
  </style>
</head>
<body>
  <header>
    <h1>🎮 Lovewright Test Report</h1>
    <div class="subtitle">Generated on %s</div>
  </header>

  <div class="container">
    <div class="summary">
      <div class="stat-card passed">
        <div class="number">%d</div>
        <div class="label">Passed</div>
      </div>
      <div class="stat-card failed">
        <div class="number">%d</div>
        <div class="label">Failed</div>
      </div>
      <div class="stat-card skipped">
        <div class="number">%d</div>
        <div class="label">Skipped</div>
      </div>
      <div class="stat-card total">
        <div class="number">%s</div>
        <div class="label">Duration</div>
      </div>
    </div>

    <div class="progress-bar">
      <div class="fill" style="width: %d%%;"></div>
    </div>
]],
    os.date("%Y-%m-%d %H:%M:%S"),
    passed,
    failed,
    skipped,
    format_duration(duration),
    pass_rate
  )

  -- Failures section
  html = html .. '    <div class="section">\n'
  html = html .. '      <h2>Test Results</h2>\n'

  if #failures > 0 then
    for i, failure in ipairs(failures) do
      local phase_badge = ""
      if failure.phase and failure.phase ~= "test" then
        phase_badge = string.format('<span class="phase">%s</span>', escape_html(failure.phase))
      end

      html = html .. string.format([[
      <div class="failure">
        <div class="test-name">%s%s</div>
        <div class="suite-name">%s</div>
        <div class="error">%s</div>
      </div>
]],
        escape_html(failure.test),
        phase_badge,
        escape_html(failure.suite),
        escape_html(failure.error)
      )
    end
  else
    html = html .. '      <div class="no-failures">✓ All tests passed!</div>\n'
  end

  html = html .. '    </div>\n'

  -- Footer
  html = html .. [[
  </div>

  <footer>
    Generated by <a href="https://github.com/lovewright/lovewright">Lovewright</a> -
    Automated testing for LÖVE2D
  </footer>
</body>
</html>
]]

  -- Write file
  local file = io.open(output_path, "w")
  if file then
    file:write(html)
    file:close()
    return output_path
  end

  return nil, "Failed to write report"
end

return Reporter
