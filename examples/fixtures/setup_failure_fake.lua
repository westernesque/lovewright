--- Fixture: failed setups, with fake games (no LÖVE, so it costs nothing to run).
-- Run by examples/tests/setup_failure_test.lua through run_fixture.lua.

local lovewright = require("lovewright")
local Game = require("lovewright.game")
local describe, it = lovewright.describe, lovewright.it

local function note(text)
  print("NOTE " .. text)
end

-- Registers like Game.launch does; closing is all the runner needs of it
local function launch(name)
  local game = {}
  function game:close()
    Game.live[self] = nil
    note("closed " .. name)
  end
  Game.live[game] = true
  note("launched " .. name)
  return game
end

describe("setup fails, its handle never reached the suite", function()
  local game

  lovewright.beforeAll(function()
    -- as a launch helper does: launches, waits, and only then returns
    local helper_local = launch("A")
    error("setup failed: A", 0)
    game = helper_local
  end)

  lovewright.afterAll(function()
    note("A first afterAll ran")
    game:close()    -- assumes the setup finished: game is nil here
  end)

  lovewright.afterAll(function()
    note("A second afterAll ran")
  end)

  it("never runs", function()
    note("A test ran")
  end)
end)

describe("the suite after a failed setup", function()
  it("runs", function()
    note("B test ran")
  end)
end)

describe("outer suite", function()
  local outer

  lovewright.beforeAll(function()
    outer = launch("outer")
  end)

  lovewright.afterAll(function()
    -- (nested suites run after this suite's tests: this is the moment to look)
    note("outer open=" .. tostring(Game.live[outer] == true))
    outer:close()
  end)

  describe("nested suite whose setup fails", function()
    lovewright.beforeAll(function()
      launch("inner")
      error("setup failed: inner", 0)
    end)

    lovewright.afterAll(function()
      note("inner afterAll ran")
    end)
  end)

  it("passes", function() end)
end)

describe("setup passes, the suite forgets a game", function()
  lovewright.beforeAll(function()
    launch("forgotten")
  end)

  it("passes", function()
    note("forgotten test ran")
  end)
end)

describe("afterAll fails after a good setup", function()
  lovewright.afterAll(function()
    error("cleanup failed: good setup", 0)
  end)

  it("passes", function() end)
end)

describe("the last suite", function()
  it("sees no game left open", function()
    local open = 0
    for _ in pairs(Game.live) do open = open + 1 end
    note("games open=" .. open)
  end)
end)
