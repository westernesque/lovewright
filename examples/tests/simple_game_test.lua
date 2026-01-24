--- Tests for the simple-game example
-- Demonstrates lovewright test capabilities

-- Add package path for running from project root
package.path = "./?.lua;./?/init.lua;" .. package.path

local lovewright = require("lovewright")
local describe, it, expect = lovewright.describe, lovewright.it, lovewright.expect

describe("Simple Game", function()
  local game

  lovewright.beforeEach(function()
    game = lovewright.launch({
      path = "examples/simple-game",
      width = 800,
      height = 600,
    })
  end)

  lovewright.afterEach(function()
    if game then
      game:close()
    end
  end)

  describe("Player", function()
    it("exists at game start", function()
      local player = game:locator("Player")
      expect(player):toExist()
    end)

    it("starts at the center of the screen", function()
      local player = game:locator("Player")
      expect(player):toHavePosition(400, 300, 10)
    end)

    it("has 100 health at start", function()
      local player = game:locator("Player")
      expect(player):toHaveProperty("health", 100)
    end)

    it("has 0 score at start", function()
      local player = game:locator("Player")
      expect(player):toHaveProperty("score", 0)
    end)

    it("moves right when right arrow is pressed", function()
      local player = game:locator("Player")
      local startX = player:get("x")

      game:keyboard():hold("right", 0.3)

      local endX = player:get("x")
      expect(endX):toBeGreaterThan(startX)
    end)

    it("moves left when left arrow is pressed", function()
      local player = game:locator("Player")
      local startX = player:get("x")

      game:keyboard():hold("left", 0.3)

      local endX = player:get("x")
      expect(endX):toBeLessThan(startX)
    end)

    it("moves up when up arrow is pressed", function()
      local player = game:locator("Player")
      local startY = player:get("y")

      game:keyboard():hold("up", 0.3)

      local endY = player:get("y")
      expect(endY):toBeLessThan(startY)
    end)

    it("moves down when down arrow is pressed", function()
      local player = game:locator("Player")
      local startY = player:get("y")

      game:keyboard():hold("down", 0.3)

      local endY = player:get("y")
      expect(endY):toBeGreaterThan(startY)
    end)

    it("stays within screen bounds", function()
      local player = game:locator("Player")

      -- Try to move off the left edge
      game:keyboard():hold("left", 2.0)

      local x = player:get("x")
      expect(x):toBeGreaterThanOrEqual(0)
    end)
  end)

  describe("Coin", function()
    it("exists at game start", function()
      local coin = game:locator("Coin")
      expect(coin):toExist()
    end)

    it("is visible at game start", function()
      local coin = game:locator("Coin")
      expect(coin):toBeVisible()
    end)

    it("disappears when collected", function()
      local player = game:locator("Player")
      local coin = game:locator("Coin")

      -- Move player to coin (player at 400,300 -> coin at 600,200)
      -- Need to move 200 right (at 200px/s = 1.0s) and 100 up (0.5s)
      game:keyboard():hold("right", 1.2)
      game:keyboard():hold("up", 0.6)

      -- Give time for collision
      game:waitFor(function()
        return player:get("score") > 0
      end, 3000)

      expect(coin):toBeHidden()
    end)

    it("increases score when collected", function()
      local player = game:locator("Player")

      -- Move player to coin (player at 400,300 -> coin at 600,200)
      game:keyboard():hold("right", 1.5)
      game:keyboard():hold("up", 0.8)

      game:waitFor(function()
        return player:get("score") > 0
      end, 5000)

      expect(player:get("score")):toBe(100)
    end)
  end)

  describe("Game State", function()
    it("can be paused with P key", function()
      local state = game:locator("GameState")

      game:keyboard():press("p")

      expect(state):toHaveProperty("paused", true)
    end)

    it("can be unpaused with P key", function()
      local state = game:locator("GameState")

      game:keyboard():press("p")
      game:keyboard():press("p")

      expect(state):toHaveProperty("paused", false)
    end)

    it("can be reset with R key", function()
      local player = game:locator("Player")

      -- Move player
      game:keyboard():hold("right", 0.3)

      -- Reset
      game:keyboard():press("r")

      -- Player should be back at start
      expect(player):toHavePosition(400, 300, 10)
    end)
  end)

  describe("Screenshots", function()
    it("can capture the game screen", function()
      local success = game:screenshot("test_screenshot.png")
      expect(success):toBeTruthy()
    end)
  end)
end)
