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
      -- First move up to y=200 (100px at 200px/s = 0.5s), then right to x=600
      game:keyboard():hold("up", 0.6)
      game:keyboard():hold("right", 1.2)

      -- Give time for collision
      game:waitFor(function()
        return player:get("score") > 0
      end, 5000)

      expect(coin):toBeHidden()
    end)

    it("increases score when collected", function()
      local player = game:locator("Player")

      -- Move player to coin (player at 400,300 -> coin at 600,200)
      -- First move up to y=200, then right to x=600
      game:keyboard():hold("up", 0.6)
      game:keyboard():hold("right", 1.2)

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

  -- These tests are SKIPPED to demonstrate the skip functionality
  describe("Example Skipped Tests", function()
    it.skip("is skipped because feature not implemented yet", function()
      -- This test would check for a feature that doesn't exist yet
      local powerup = game:locator("PowerUp")
      expect(powerup):toExist()
    end)

    it.skip("is skipped because it requires multiplayer", function()
      -- This test would require multiplayer which isn't implemented
      local player2 = game:locator("Player2")
      expect(player2):toExist()
    end)
  end)

  -- These tests are INTENTIONALLY failing to demonstrate failure output
  describe("Example Failures (these SHOULD fail)", function()
    it("demonstrates a failed equality assertion", function()
      local player = game:locator("Player")
      -- Player starts with 100 health, not 50
      expect(player):toHaveProperty("health", 50)
    end)

    it("demonstrates a failed existence check", function()
      -- There is no object named "Dragon" in the game
      local dragon = game:locator("Dragon")
      expect(dragon):toExist()
    end)

    it("demonstrates a failed comparison", function()
      local player = game:locator("Player")
      -- Player starts at x=400, which is not greater than 500
      expect(player:get("x")):toBeGreaterThan(500)
    end)
  end)
end)
