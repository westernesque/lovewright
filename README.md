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
- **Test steps** - `lovewright.step` (Playwright's `test.step`) groups a test into named phases in traces, reports and failure output

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

# Run in headless mode (no window at all, faster execution)
lua examples/run_example_tests.lua --headless

# On a machine with no display (Linux CI), give it a virtual one:
xvfb-run lua examples/run_example_tests.lua --headless
```

**Headless mode.** LÖVE cannot render without a window (turn the window module off and there is no `love.draw` to screenshot), so lovewright keeps the window and makes it invisible: it is created far off-screen, hidden through SDL (`SDL_HideWindow`, called via LuaJIT's FFI since LÖVE has no Lua API for it) before the game's `love.load` runs, never takes keyboard focus, and is hidden again if the game re-creates it (`love.window.setMode` / `updateMode` are forced windowed and off-screen while headless). Rendering is unaffected: `love.draw` keeps running, screenshots and canvas readbacks return real pixels, and the loop runs faster with nothing composited (measured on Windows with LÖVE 12 / SDL3 / Vulkan). If SDL cannot be reached the window is parked off-screen, and failing that minimized, which was the old behaviour; `headless_mode = "offscreen"` or `"minimized"` picks one of those on purpose, and `game:headlessStatus()` reports what took effect. A machine with no display at all still needs a virtual one (Xvfb).

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
- **Test steps** - `lovewright.step` grouping a test into named phases (`examples/tests/step_test.lua` checks the step API itself, no game needed)
- **Intentional failures** - Four tests that purposely fail to show failure output, one of them inside a nested step

## API Reference

### Launching Games

```lua
local game = lovewright.launch({
  path = "path/to/game",     -- Required: game directory
  width = 800,               -- Window width (default: 800)
  height = 600,              -- Window height (default: 600)
  headless = false,          -- Run without window (default: false)
  headless_mode = "hidden",  -- "hidden" | "offscreen" | "minimized" when headless
  love_path = "love",        -- Path to love executable
  timeout = 5000,            -- Connection timeout in ms
  identity = "my-game-test", -- Optional: override save directory for test isolation
  exclude = { "logs" },      -- Optional: dir/file names to skip when copying the game
  isolated = false,          -- Isolated run (default: lovewright.config.isolated), see below
})
```

The game is copied into a temporary wrapper directory before launch, with its own
`main.lua`/`conf.lua` set aside so lovewright can control startup. The game's conf
settings (modules, etc.) are preserved; window size, title, and `identity` are
overridden. `.git` is always excluded from the copy.

```lua
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
player:get("stats", 30000)   -- ...waiting up to 30s (lookup + read) for a slow getter or a game stuck in one long frame
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

### Steps

`lovewright.step(name, fn)` is lovewright's version of Playwright's
`test.step`: it runs `fn` as a named step of the current test and returns
whatever `fn` returns. Steps nest. They do not change what a test does;
they make it easier to read when it fails:

- the console names the innermost step the failure came from
  (`In step: open the menu > check the Start button`), as do the summary at
  the end of the run, the HTML report and GitHub Actions annotations
- the HTML report shows each test's step outline (open for failed tests)
- traces group the actions, waits, assertions and screenshots of a step
  under it: failed steps are expanded, passed steps collapsed

```lua
local lovewright = require("lovewright")
local it, expect, step = lovewright.it, lovewright.expect, lovewright.step

it("collects the coin", function()
  local player = game:locator("Player")

  local startScore = step("read the score", function()
    return player:get("score")          -- a step returns fn's results
  end)

  step("walk onto the coin", function()
    game:keyboard():hold("up", 0.6)
    step("cross to the right", function()  -- steps nest
      game:keyboard():hold("right", 1.2)
    end)
  end)

  step("the score went up", function()
    game:waitFor(function() return player:get("score") > startScore end, 5000)
  end)
end)
```

It is also available as `lovewright.it.step` and, with the Playwright-style
alias `lovewright.test` (= `lovewright.it`), as `test.step`. Errors pass
through a step unchanged (same value, same message), so a `pcall` around a
step sees exactly what `fn` raised. Steps work in hooks too (`beforeEach`,
`beforeAll`, ...): a failing hook reports its step the same way.

### Screenshots

```lua
-- Capture screenshot
game:screenshot("screenshot.png")

-- Capture as a base64 PNG string (no file written)
local b64 = game:screenshotBase64()

-- Snapshot testing
local screenshot = require("lovewright.screenshot")
screenshot.assertSnapshot(game, "main-menu")  -- Compare to saved snapshot
```

### Traces

Traces record a per-test timeline — launches, input actions, waits, and
assertions — with embedded screenshots, written as one self-contained HTML
file per test. Failing tests include a screenshot taken at the moment of
failure, and the HTML report links to each failure's trace.

```lua
lovewright.config.trace = "retain-on-failure"  -- "off" (default) | "on" | "retain-on-failure"
lovewright.config.trace_dir = "lovewright-traces"  -- output directory
```

- `"off"` — no tracing
- `"retain-on-failure"` — traces are recorded but only written for failing
  tests (recommended; negligible overhead on passing tests)
- `"on"` — a trace is written for every test, with a screenshot after every
  input action (slower, but a full visual replay)

Events recorded inside a [step](#steps) nest under it in the timeline, and
the trace header names the step a failing test failed in.

### Parallel runs and the run lock

By default a run assumes it has the machine to itself: games get ports
counted up from a time-based base, the wrapper copy is named after the
second it was made, the launcher finds the game's pid by diffing the
`love` process list, and `identity` names one shared save directory. Two
runs at once (two CI agents, two git worktrees) can then talk to, kill or
share state with each other's games. An **isolated** run avoids all of it:

```lua
lovewright.config.isolated = true   -- or LOVEWRIGHT_ISOLATED=1
```

- save directory: `identity` becomes `"<identity>-<run id>"`
- wrapper copy: `<TEMP>/lovewright/wrapper_<run id>_<token>`
- port: a free one drawn at random below the OS's ephemeral range
- the game: the wrapper writes the game's own pid next to itself before
  anything else runs (the launcher closes exactly that process, never one
  found by image name), and the runtime echoes a per-launch token in its
  ready event (a game from another run that answers on the port is
  dropped without being shut down)
- the runtime's debug log (`LOVEWRIGHT_DEBUG=1`) gets the run id in its name

The **run id** is the working directory's folder name plus a hash of its
path (`LOVEWRIGHT_RUN_ID` overrides): stable for a checkout, different for
checkouts side by side. Output paths you configure yourself (`trace_dir`,
`report_output`, screenshots) are relative to the working directory, so
give each concurrent run its own. `require("lovewright.isolation")` also
offers `free_port()` and `free_udp_pair()` for servers a suite starts
itself.

**Run lock.** `lovewright.run` can hold a cross-process lock while it runs
(`lovewright/lock.lua`, files under `<TEMP>/lovewright/locks`,
`LOVEWRIGHT_LOCK_DIR` overrides):

```lua
lovewright.config.lock = "shared"     -- default for isolated runs; nil = no lock otherwise
lovewright.config.lock = "exclusive"  -- timing-sensitive runs: benchmarks, slowed-down passes
lovewright.config.lock = false        -- never (e.g. when the caller holds it itself)
```

Any number of shared holders run together; an exclusive run waits until
none is left and blocks new shared ones while it waits and runs (queued
exclusive runs go first-come first-served). Waiting runs print who they
wait for once a minute. A runner that dies holding the lock does not block
the others: on Windows each holder keeps its lock file open and a file
that can be deleted belonged to a dead process; elsewhere the file holds
the runner's pid. An isolated shared run also refuses to start next to a
live run with the same run id (they would share output files).
`LOVEWRIGHT_LOCK=off` skips the lock. To hold it across several
`lovewright.run` calls, take it yourself and set `config.lock = false`:

```lua
local held = require("lovewright.lock").acquire("exclusive", { label = "benchmarks" })
-- ... lovewright.run(...) as often as needed ...
held:release()
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
