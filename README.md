# lovewright

An automated test framework for LÖVE2D applications, inspired by [Playwright](https://playwright.dev/).

<img width="1657" height="1433" alt="Screenshot 2026-01-26 104338" src="https://github.com/user-attachments/assets/c7a3d98f-9502-4b9e-87c2-7ce81cbb6ca3" />

## Features

- **Playwright-style API** - Familiar `describe`/`it` blocks with `expect` assertions
- **Object locators** - Find game objects by name, type, or properties
- **Input simulation** - Keyboard, mouse, and gamepad input injection
- **Screenshots** - Capture game frames and compare against snapshots
- **Headless mode** - Run tests without a visible window for CI/CD
- **Auto-waiting** - Wait for objects or conditions before assertions

## Installation

1. Clone this repository into your project or LÖVE2D library path
2. Ensure [LuaSocket](https://lunarmodules.github.io/luasocket/) is available

```bash
# If using LuaRocks
luarocks install luasocket
```

## Quick Start

### 1. Register objects in your game

```lua
-- In your game's main.lua
function love.load()
  player = { x = 100, y = 100, health = 100 }

  -- Register for testing (safe to call even without lovewright)
  if lovewright and lovewright.runtime then
    lovewright.runtime.register(player, "Player")
  end
end
```

### 2. Write tests

```lua
-- tests/player_test.lua
local lovewright = require("lovewright")
local describe, it, expect = lovewright.describe, lovewright.it, lovewright.expect

describe("Player", function()
  local game

  lovewright.beforeEach(function()
    game = lovewright.launch({
      path = "path/to/your/game",
      width = 800,
      height = 600,
    })
  end)

  lovewright.afterEach(function()
    game:close()
  end)

  it("starts with full health", function()
    local player = game:locator("Player")
    expect(player):toHaveProperty("health", 100)
  end)

  it("moves right when arrow key pressed", function()
    local player = game:locator("Player")
    local startX = player:get("x")

    game:keyboard():hold("right", 0.5)

    expect(player:get("x")):toBeGreaterThan(startX)
  end)
end)
```

### 3. Run tests

```bash
lua -e "require('lovewright').run({ path = 'tests' })"
```

## Running the Examples

The `examples/` directory contains a simple game and test suite to demonstrate lovewright's capabilities.

```bash
# From the lovewright root directory
lua examples/run_example_tests.lua

# Run in headless mode (minimized window, faster execution)
lua examples/run_example_tests.lua --headless

# For true headless on Linux CI, use Xvfb:
xvfb-run lua examples/run_example_tests.lua --headless
```

**Note:** LÖVE2D requires a display context, so `--headless` minimizes the window rather than hiding it completely. For CI environments without a display, use Xvfb on Linux or a virtual display on Windows.

This will:
1. Launch the simple-game example with LÖVE2D
2. Run 17 tests covering player movement, coin collection, game state, and screenshots
3. Generate an HTML report at `lovewright-report.html`

The example tests demonstrate:
- Object locators (`game:locator("Player")`)
- Property assertions (`expect(player):toHaveProperty("health", 100)`)
- Input simulation (`game:keyboard():hold("right", 1.0)`)
- Waiting for conditions (`game:waitFor(...)`)
- Screenshot capture (`game:screenshot("test.png")`)
- **Skipped tests** - Two tests using `it.skip()` to show skip functionality
- **Intentional failures** - Three tests that purposely fail to show failure output

## API Reference

### Launching Games

```lua
local game = lovewright.launch({
  path = "path/to/game",     -- Required: game directory
  width = 800,               -- Window width (default: 800)
  height = 600,              -- Window height (default: 600)
  headless = false,          -- Run without window (default: false)
  love_path = "love",        -- Path to love executable
  timeout = 5000,            -- Connection timeout in ms
})
```

### Locators

```lua
-- Find by name
local player = game:locator("Player")

-- Find by properties
local enemies = game:locator({ type = "Enemy" })

-- Locator methods
player:exists()              -- Check if object exists
player:get("health")         -- Get property value
player:x(), player:y()       -- Shorthand for position
player:isVisible()           -- Check visibility
player:waitFor(timeout)      -- Wait for object to exist
player:click()               -- Click on object center
player:all()                 -- Get all matching objects
player:count()               -- Count matching objects
```

### Input Simulation

```lua
-- Keyboard
game:keyboard():press("space")
game:keyboard():release("space")
game:keyboard():hold("right", 0.5)  -- Hold for 0.5 seconds
game:keyboard():type("hello")        -- Type text

-- Mouse
game:mouse():move(100, 200)
game:mouse():click(100, 200)
game:mouse():click(100, 200, 2)      -- Right click
game:mouse():dblclick(100, 200)
game:mouse():drag(0, 0, 100, 100)

-- Gamepad
game:gamepad():press("a")
game:gamepad():leftStick(0.5, 0)     -- Half-right on left stick
```

### Assertions

```lua
-- Value assertions
expect(value):toBe(expected)
expect(value):toEqual(expected)          -- Deep equality
expect(value):toBeTruthy()
expect(value):toBeFalsy()
expect(value):toBeNil()
expect(value):toBeGreaterThan(n)
expect(value):toBeLessThan(n)
expect(value):toContain(item)
expect(value):toMatch(pattern)
expect(value):toHaveLength(n)

-- Locator assertions
expect(locator):toExist()
expect(locator):toBeVisible()
expect(locator):toBeHidden()
expect(locator):toHaveProperty("health", 100)
expect(locator):toHavePosition(x, y, tolerance)
expect(locator):toHaveCount(n)

-- Negation
expect(value).never:toBe(other)
expect(locator).never:toExist()
```

### Waiting

```lua
-- Wait for condition
game:waitFor(function()
  return player:get("x") > 100
end, 5000)

-- Wait for object
game:waitForObject("Victory", 5000)

-- Locator waiting
player:waitFor(5000)           -- Wait to exist
player:waitForDetached(5000)   -- Wait to not exist
```

### Screenshots

```lua
-- Capture screenshot
game:screenshot("screenshot.png")

-- Snapshot testing
local screenshot = require("lovewright.screenshot")
screenshot.assertSnapshot(game, "main-menu")  -- Compare to saved snapshot
```

### Test Structure

```lua
describe("Suite name", function()
  -- Runs before each test in this suite
  lovewright.beforeEach(function() end)

  -- Runs after each test in this suite
  lovewright.afterEach(function() end)

  -- Runs once before all tests in this suite
  lovewright.beforeAll(function() end)

  -- Runs once after all tests in this suite
  lovewright.afterAll(function() end)

  it("test name", function()
    -- Test code
  end)

  -- Skip a test
  it.skip("skipped test", function() end)

  -- Only run this test
  it.only("focused test", function() end)

  -- Nested suites
  describe("nested", function()
    it("inherits hooks from parent", function() end)
  end)
end)

-- Skip entire suite
describe.skip("skipped suite", function() end)

-- Only run this suite
describe.only("focused suite", function() end)
```

## Architecture

```
┌─────────────┐     TCP/JSON-RPC     ┌─────────────────┐
│ Test Runner │ ←──────────────────→ │ Game + Runtime  │
└─────────────┘    localhost:19840   └─────────────────┘
```

Lovewright works by:
1. Launching your game with an injected runtime
2. The runtime hooks into LÖVE2D callbacks and starts a TCP server
3. Your tests connect to the runtime and send commands
4. The runtime executes commands (query objects, simulate input, take screenshots)
5. Results are sent back to the test runner

## Requirements

- LÖVE2D 11.0+
- Lua 5.1+ or LuaJIT
- LuaSocket

## License

MIT
