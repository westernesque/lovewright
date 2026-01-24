--- Locator module for lovewright
-- Playwright-style locators for finding game objects

local protocol = require("lovewright.protocol")

local Locator = {}
Locator.__index = Locator

function Locator.new(game, query)
  local self = setmetatable({}, Locator)
  self.game = game
  self.query = query
  self._cached_id = nil
  self._cached_time = 0
  return self
end

-- Resolve the locator to an object ID
function Locator:_resolve()
  local now = os.time()

  -- Cache for 100ms
  if self._cached_id and now - self._cached_time < 0.1 then
    return self._cached_id
  end

  local query_params = {}

  if type(self.query) == "string" then
    query_params.name = self.query
  elseif type(self.query) == "table" then
    query_params = self.query
  end

  local result = self.game:_request(protocol.MessageType.QUERY_OBJECT, query_params)

  if result and #result > 0 then
    self._cached_id = result[1].id
    self._cached_time = now
    return self._cached_id
  end

  return nil
end

-- Get a property from the object
function Locator:get(property)
  local object_id = self:_resolve()
  if not object_id then
    error("Object not found: " .. tostring(self.query))
  end

  local result = self.game:_request(protocol.MessageType.GET_PROPERTY, {
    object_id = object_id,
    property = property,
  })

  return result and result.value
end

-- Check if object exists
function Locator:exists()
  return self:_resolve() ~= nil
end

-- Get the object ID
function Locator:id()
  return self:_resolve()
end

-- Get all matching objects (for plural locators)
function Locator:all()
  local query_params = {}

  if type(self.query) == "string" then
    query_params.name = self.query
  elseif type(self.query) == "table" then
    query_params = self.query
  end

  local result = self.game:_request(protocol.MessageType.QUERY_OBJECT, query_params)
  local locators = {}

  if result then
    for _, obj in ipairs(result) do
      local loc = Locator.new(self.game, { id = obj.id })
      loc._cached_id = obj.id
      loc._cached_time = os.time()
      table.insert(locators, loc)
    end
  end

  return locators
end

-- Count matching objects
function Locator:count()
  return #self:all()
end

-- Get first matching object
function Locator:first()
  local all = self:all()
  return all[1]
end

-- Get nth matching object (1-indexed)
function Locator:nth(n)
  local all = self:all()
  return all[n]
end

-- Filter locator
function Locator:filter(predicate)
  local all = self:all()
  local filtered = {}

  for _, loc in ipairs(all) do
    if predicate(loc) then
      table.insert(filtered, loc)
    end
  end

  return filtered
end

-- Chain locators - find objects near this one
function Locator:near(distance)
  distance = distance or 100
  local x = self:get("x")
  local y = self:get("y")

  if not x or not y then
    error("Object does not have position")
  end

  return {
    x = x,
    y = y,
    distance = distance,
    _is_near_query = true,
  }
end

-- Wait for object to exist
function Locator:waitFor(timeout)
  timeout = timeout or 5000
  local socket = require("socket")
  local start_time = socket.gettime()
  local timeout_sec = timeout / 1000

  while socket.gettime() - start_time < timeout_sec do
    if self:exists() then
      return self
    end
    self.game:_process_messages()
    socket.sleep(0.016)
  end

  error("Locator waitFor timeout: " .. tostring(self.query))
end

-- Wait for object to not exist
function Locator:waitForDetached(timeout)
  timeout = timeout or 5000
  local socket = require("socket")
  local start_time = socket.gettime()
  local timeout_sec = timeout / 1000

  while socket.gettime() - start_time < timeout_sec do
    if not self:exists() then
      return true
    end
    self.game:_process_messages()
    socket.sleep(0.016)
  end

  error("Locator waitForDetached timeout: " .. tostring(self.query))
end

-- Convenience methods for common properties
function Locator:x()
  return self:get("x")
end

function Locator:y()
  return self:get("y")
end

function Locator:width()
  return self:get("width")
end

function Locator:height()
  return self:get("height")
end

function Locator:isVisible()
  local visible = self:get("visible")
  return visible ~= false  -- Default to true if not set
end

function Locator:isActive()
  local active = self:get("active")
  return active ~= false  -- Default to true if not set
end

-- Get bounding box
function Locator:boundingBox()
  return {
    x = self:get("x") or 0,
    y = self:get("y") or 0,
    width = self:get("width") or 0,
    height = self:get("height") or 0,
  }
end

-- Click on the object
function Locator:click()
  local box = self:boundingBox()
  local cx = box.x + box.width / 2
  local cy = box.y + box.height / 2

  self.game:mouse():click(cx, cy)
  return self
end

-- String representation
function Locator:__tostring()
  if type(self.query) == "string" then
    return "Locator(" .. self.query .. ")"
  else
    return "Locator(" .. tostring(self.query) .. ")"
  end
end

return Locator
