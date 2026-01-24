--- Screenshot module for lovewright
-- Capture and compare game screenshots

local Screenshot = {}

-- Platform detection
local is_windows = package.config:sub(1, 1) == "\\"

local function mkdir(path)
  if is_windows then
    local win_path = path:gsub("/", "\\")
    os.execute('mkdir "' .. win_path .. '" 2>nul')
  else
    os.execute("mkdir -p " .. path .. " 2>/dev/null")
  end
end

-- Capture a screenshot from the game
function Screenshot.capture(game, filename)
  return game:screenshot(filename)
end

-- Compare two screenshot files
-- Returns true if they match within threshold
function Screenshot.compare(file1, file2, options)
  options = options or {}
  local threshold = options.threshold or 0.01  -- 1% difference allowed

  local f1 = io.open(file1, "rb")
  local f2 = io.open(file2, "rb")

  if not f1 then
    return false, "Cannot open file: " .. file1
  end
  if not f2 then
    f1:close()
    return false, "Cannot open file: " .. file2
  end

  local data1 = f1:read("*a")
  local data2 = f2:read("*a")
  f1:close()
  f2:close()

  -- Simple byte comparison for now
  -- A more sophisticated implementation would decode PNGs and compare pixels
  if data1 == data2 then
    return true
  end

  -- If files are different sizes, definitely different
  if #data1 ~= #data2 then
    return false, "File sizes differ"
  end

  -- Count different bytes
  local diff_count = 0
  for i = 1, #data1 do
    if data1:byte(i) ~= data2:byte(i) then
      diff_count = diff_count + 1
    end
  end

  local diff_ratio = diff_count / #data1
  if diff_ratio <= threshold then
    return true
  end

  return false, string.format("%.2f%% different (threshold: %.2f%%)", diff_ratio * 100, threshold * 100)
end

-- Create a snapshot test
function Screenshot.snapshot(game, name, options)
  options = options or {}
  local snapshot_dir = options.snapshot_dir or ".lovewright/snapshots"
  local update = options.update or false

  -- Ensure directory exists
  mkdir(snapshot_dir)

  local snapshot_path = snapshot_dir .. "/" .. name .. ".png"
  local actual_path = snapshot_dir .. "/" .. name .. ".actual.png"

  -- Capture current screenshot
  game:screenshot(actual_path)

  -- Check if snapshot exists
  local f = io.open(snapshot_path, "r")
  if not f then
    if update then
      -- Create new snapshot
      os.rename(actual_path, snapshot_path)
      return true, "Snapshot created"
    else
      return false, "Snapshot does not exist: " .. snapshot_path
    end
  end
  f:close()

  -- Compare
  local match, err = Screenshot.compare(snapshot_path, actual_path, options)

  if match then
    -- Clean up actual file
    os.remove(actual_path)
    return true
  end

  if update then
    -- Update snapshot
    os.rename(actual_path, snapshot_path)
    return true, "Snapshot updated"
  end

  -- Keep actual file for debugging
  return false, err
end

-- Assert screenshot matches snapshot
function Screenshot.assertSnapshot(game, name, options)
  local match, err = Screenshot.snapshot(game, name, options)
  if not match then
    local ExpectModule = require("lovewright.expect")
    error(ExpectModule.AssertionError.new(
      "Screenshot does not match snapshot: " .. name,
      "match",
      err
    ))
  end
end

return Screenshot
