--- Simple example game for lovewright testing
-- A basic game with a player that can move around

local player = {
  x = 400,
  y = 300,
  width = 32,
  height = 32,
  speed = 200,
  health = 100,
  score = 0,
  visible = true,
  active = true,
}

local coin = {
  x = 600,
  y = 200,
  width = 16,
  height = 16,
  visible = true,
  active = true,
  collected = false,
}

local gameState = {
  started = false,
  paused = false,
  won = false,
}

function love.load()
  love.window.setTitle("Simple Game - Lovewright Example")

  -- Register objects with lovewright if runtime is present
  if lovewright and lovewright.runtime then
    lovewright.runtime.register(player, "Player")
    lovewright.runtime.register(coin, "Coin")
    lovewright.runtime.register(gameState, "GameState")
  end
end

function love.update(dt)
  if gameState.paused or gameState.won then
    return
  end

  -- Handle player movement
  if love.keyboard.isDown("left") or love.keyboard.isDown("a") then
    player.x = player.x - player.speed * dt
  end
  if love.keyboard.isDown("right") or love.keyboard.isDown("d") then
    player.x = player.x + player.speed * dt
  end
  if love.keyboard.isDown("up") or love.keyboard.isDown("w") then
    player.y = player.y - player.speed * dt
  end
  if love.keyboard.isDown("down") or love.keyboard.isDown("s") then
    player.y = player.y + player.speed * dt
  end

  -- Keep player in bounds
  player.x = math.max(0, math.min(player.x, love.graphics.getWidth() - player.width))
  player.y = math.max(0, math.min(player.y, love.graphics.getHeight() - player.height))

  -- Check coin collision
  if not coin.collected and coin.active then
    if player.x < coin.x + coin.width and
       player.x + player.width > coin.x and
       player.y < coin.y + coin.height and
       player.y + player.height > coin.y then
      coin.collected = true
      coin.visible = false
      coin.active = false
      player.score = player.score + 100
      gameState.won = true
    end
  end
end

function love.draw()
  -- Draw background
  love.graphics.setBackgroundColor(0.2, 0.2, 0.3)

  -- Draw player
  if player.visible then
    love.graphics.setColor(0.2, 0.6, 1)
    love.graphics.rectangle("fill", player.x, player.y, player.width, player.height)
  end

  -- Draw coin
  if coin.visible and not coin.collected then
    love.graphics.setColor(1, 0.8, 0)
    love.graphics.rectangle("fill", coin.x, coin.y, coin.width, coin.height)
  end

  -- Draw UI
  love.graphics.setColor(1, 1, 1)
  love.graphics.print("Score: " .. player.score, 10, 10)
  love.graphics.print("Health: " .. player.health, 10, 30)

  if gameState.won then
    love.graphics.setColor(0, 1, 0)
    love.graphics.printf("You Win!", 0, 250, love.graphics.getWidth(), "center")
  end

  if gameState.paused then
    love.graphics.setColor(1, 1, 0)
    love.graphics.printf("PAUSED", 0, 250, love.graphics.getWidth(), "center")
  end
end

function love.keypressed(key)
  if key == "escape" then
    love.event.quit()
  elseif key == "p" then
    gameState.paused = not gameState.paused
  elseif key == "r" then
    -- Reset game
    player.x = 400
    player.y = 300
    player.score = 0
    coin.collected = false
    coin.visible = true
    coin.active = true
    gameState.won = false
  elseif key == "space" then
    gameState.started = true
  end
end
