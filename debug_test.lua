-- Simple debug test to see what's happening
package.path = "./?.lua;./?/init.lua;" .. package.path

local lovewright = require("lovewright")

print("Starting debug test...")
print("Launching game...")

local ok, err = pcall(function()
  local game = lovewright.launch({
    path = "examples/simple-game",
    timeout = 10000,  -- 10 second timeout
  })

  print("Game launched successfully!")
  print("Connected: " .. tostring(game.connected))

  -- Try to get objects
  print("Getting objects...")
  local objects = game:getObjects()
  print("Objects found: " .. #objects)
  for _, obj in ipairs(objects) do
    print("  - " .. obj.name .. " (id: " .. obj.id .. ")")
  end

  print("Closing game...")
  game:close()
  print("Done!")
end)

if not ok then
  print("ERROR: " .. tostring(err))
end
