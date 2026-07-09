--- Expect module for lovewright
-- Playwright-style assertion API

local Expect = {}

-- Assertion error class
local AssertionError = {}
AssertionError.__index = AssertionError

function AssertionError.new(message, expected, actual)
  local self = setmetatable({}, AssertionError)
  self.message = message
  self.expected = expected
  self.actual = actual
  return self
end

function AssertionError:__tostring()
  local msg = "AssertionError: " .. self.message
  if self.expected ~= nil then
    msg = msg .. "\n  Expected: " .. tostring(self.expected)
  end
  if self.actual ~= nil then
    msg = msg .. "\n  Actual: " .. tostring(self.actual)
  end
  return msg
end

-- Value wrapper for assertions
local ValueExpect = {}
ValueExpect.__index = ValueExpect

function ValueExpect.new(value, negated)
  local self = setmetatable({}, ValueExpect)
  self.value = value
  self.negated = negated or false
  return self
end

function ValueExpect:_assert(condition, message, expected, actual)
  if self.negated then
    condition = not condition
    message = "NOT " .. message
  end

  require("lovewright.trace").record(
    condition and "assert:pass" or "assert:fail",
    message,
    { expected = tostring(expected), actual = tostring(actual) }
  )

  if not condition then
    error(AssertionError.new(message, expected, actual))
  end
end

-- Negation
function ValueExpect.__index.never(self)
  return ValueExpect.new(self.value, true)
end

-- Basic matchers
function ValueExpect:toBe(expected)
  self:_assert(
    self.value == expected,
    "Expected value to be equal",
    expected,
    self.value
  )
end

function ValueExpect:toEqual(expected)
  local function deep_equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end

    for k, v in pairs(a) do
      if not deep_equal(v, b[k]) then return false end
    end
    for k, v in pairs(b) do
      if not deep_equal(v, a[k]) then return false end
    end
    return true
  end

  self:_assert(
    deep_equal(self.value, expected),
    "Expected values to be deeply equal",
    expected,
    self.value
  )
end

function ValueExpect:toBeTruthy()
  self:_assert(
    self.value,
    "Expected value to be truthy",
    "truthy",
    self.value
  )
end

function ValueExpect:toBeFalsy()
  self:_assert(
    not self.value,
    "Expected value to be falsy",
    "falsy",
    self.value
  )
end

function ValueExpect:toBeNil()
  self:_assert(
    self.value == nil,
    "Expected value to be nil",
    nil,
    self.value
  )
end

function ValueExpect:toBeDefined()
  self:_assert(
    self.value ~= nil,
    "Expected value to be defined",
    "not nil",
    self.value
  )
end

-- Number matchers
function ValueExpect:toBeGreaterThan(expected)
  self:_assert(
    type(self.value) == "number" and self.value > expected,
    "Expected value to be greater than",
    "> " .. tostring(expected),
    self.value
  )
end

function ValueExpect:toBeGreaterThanOrEqual(expected)
  self:_assert(
    type(self.value) == "number" and self.value >= expected,
    "Expected value to be greater than or equal to",
    ">= " .. tostring(expected),
    self.value
  )
end

function ValueExpect:toBeLessThan(expected)
  self:_assert(
    type(self.value) == "number" and self.value < expected,
    "Expected value to be less than",
    "< " .. tostring(expected),
    self.value
  )
end

function ValueExpect:toBeLessThanOrEqual(expected)
  self:_assert(
    type(self.value) == "number" and self.value <= expected,
    "Expected value to be less than or equal to",
    "<= " .. tostring(expected),
    self.value
  )
end

function ValueExpect:toBeCloseTo(expected, precision)
  precision = precision or 2
  local diff = math.abs(self.value - expected)
  local threshold = math.pow(10, -precision) / 2

  self:_assert(
    type(self.value) == "number" and diff < threshold,
    "Expected value to be close to",
    expected .. " (precision: " .. precision .. ")",
    self.value
  )
end

-- String matchers
function ValueExpect:toContain(substring)
  if type(self.value) == "string" then
    self:_assert(
      self.value:find(substring, 1, true) ~= nil,
      "Expected string to contain",
      substring,
      self.value
    )
  elseif type(self.value) == "table" then
    local found = false
    for _, v in pairs(self.value) do
      if v == substring then
        found = true
        break
      end
    end
    self:_assert(
      found,
      "Expected table to contain",
      substring,
      self.value
    )
  else
    error("toContain requires string or table")
  end
end

function ValueExpect:toMatch(pattern)
  self:_assert(
    type(self.value) == "string" and self.value:match(pattern) ~= nil,
    "Expected string to match pattern",
    pattern,
    self.value
  )
end

function ValueExpect:toStartWith(prefix)
  self:_assert(
    type(self.value) == "string" and self.value:sub(1, #prefix) == prefix,
    "Expected string to start with",
    prefix,
    self.value
  )
end

function ValueExpect:toEndWith(suffix)
  self:_assert(
    type(self.value) == "string" and self.value:sub(-#suffix) == suffix,
    "Expected string to end with",
    suffix,
    self.value
  )
end

-- Table matchers
function ValueExpect:toHaveLength(expected)
  local len = 0
  if type(self.value) == "table" then
    len = #self.value
  elseif type(self.value) == "string" then
    len = #self.value
  end

  self:_assert(
    len == expected,
    "Expected length to be",
    expected,
    len
  )
end

function ValueExpect:toHaveKey(key)
  self:_assert(
    type(self.value) == "table" and self.value[key] ~= nil,
    "Expected table to have key",
    key,
    "keys: " .. table.concat(self:_keys(), ", ")
  )
end

function ValueExpect:_keys()
  local keys = {}
  if type(self.value) == "table" then
    for k in pairs(self.value) do
      table.insert(keys, tostring(k))
    end
  end
  return keys
end

-- Type matchers
function ValueExpect:toBeType(expected_type)
  self:_assert(
    type(self.value) == expected_type,
    "Expected type to be",
    expected_type,
    type(self.value)
  )
end

function ValueExpect:toBeNumber()
  self:toBeType("number")
end

function ValueExpect:toBeString()
  self:toBeType("string")
end

function ValueExpect:toBeTable()
  self:toBeType("table")
end

function ValueExpect:toBeFunction()
  self:toBeType("function")
end

function ValueExpect:toBeBoolean()
  self:toBeType("boolean")
end

-- Locator-specific wrapper
local LocatorExpect = {}
LocatorExpect.__index = LocatorExpect

function LocatorExpect.new(locator, negated)
  local self = setmetatable({}, LocatorExpect)
  self.locator = locator
  self.negated = negated or false
  return self
end

function LocatorExpect:_assert(condition, message, expected, actual)
  if self.negated then
    condition = not condition
    message = "NOT " .. message
  end

  require("lovewright.trace").record(
    condition and "assert:pass" or "assert:fail",
    message .. " (" .. tostring(self.locator.query) .. ")",
    { expected = tostring(expected), actual = tostring(actual) }
  )

  if not condition then
    error(AssertionError.new(message, expected, actual))
  end
end

function LocatorExpect.__index.never(self)
  return LocatorExpect.new(self.locator, true)
end

function LocatorExpect:toExist()
  self:_assert(
    self.locator:exists(),
    "Expected object to exist",
    "exists",
    "not found"
  )
end

function LocatorExpect:toBeVisible()
  self:_assert(
    self.locator:exists() and self.locator:isVisible(),
    "Expected object to be visible",
    "visible",
    self.locator:exists() and "hidden" or "not found"
  )
end

function LocatorExpect:toBeHidden()
  self:_assert(
    not self.locator:exists() or not self.locator:isVisible(),
    "Expected object to be hidden",
    "hidden",
    "visible"
  )
end

function LocatorExpect:toBeActive()
  self:_assert(
    self.locator:exists() and self.locator:isActive(),
    "Expected object to be active",
    "active",
    self.locator:exists() and "inactive" or "not found"
  )
end

function LocatorExpect:toHaveProperty(property, expected)
  local actual = self.locator:get(property)

  if expected ~= nil then
    self:_assert(
      actual == expected,
      "Expected property '" .. property .. "' to equal",
      expected,
      actual
    )
  else
    self:_assert(
      actual ~= nil,
      "Expected object to have property",
      property,
      "undefined"
    )
  end
end

function LocatorExpect:toHavePosition(x, y, tolerance)
  tolerance = tolerance or 1
  local actual_x = self.locator:get("x")
  local actual_y = self.locator:get("y")

  local match = math.abs(actual_x - x) <= tolerance and math.abs(actual_y - y) <= tolerance

  self:_assert(
    match,
    "Expected object position to be",
    string.format("(%d, %d) ± %d", x, y, tolerance),
    string.format("(%s, %s)", tostring(actual_x), tostring(actual_y))
  )
end

function LocatorExpect:toHaveCount(expected)
  local actual = self.locator:count()
  self:_assert(
    actual == expected,
    "Expected object count to be",
    expected,
    actual
  )
end

-- Game-specific wrapper
local GameExpect = {}
GameExpect.__index = GameExpect

function GameExpect.new(game, negated)
  local self = setmetatable({}, GameExpect)
  self.game = game
  self.negated = negated or false
  return self
end

function GameExpect:_assert(condition, message, expected, actual)
  if self.negated then
    condition = not condition
    message = "NOT " .. message
  end

  require("lovewright.trace").record(
    condition and "assert:pass" or "assert:fail",
    message,
    { expected = tostring(expected), actual = tostring(actual) }
  )

  if not condition then
    error(AssertionError.new(message, expected, actual))
  end
end

function GameExpect.__index.never(self)
  return GameExpect.new(self.game, true)
end

function GameExpect:toHaveObject(name)
  local locator = self.game:locator(name)
  self:_assert(
    locator:exists(),
    "Expected game to have object",
    name,
    "not found"
  )
end

function GameExpect:toBeConnected()
  self:_assert(
    self.game.connected,
    "Expected game to be connected",
    "connected",
    "disconnected"
  )
end

-- Main expect function
local function expect(value)
  -- Check if it's a Locator
  local Locator = require("lovewright.locator")
  if getmetatable(value) == Locator then
    return LocatorExpect.new(value)
  end

  -- Check if it's a Game
  local Game = require("lovewright.game")
  if getmetatable(value) == Game then
    return GameExpect.new(value)
  end

  -- Regular value
  return ValueExpect.new(value)
end

-- Export
Expect.expect = expect
Expect.AssertionError = AssertionError

return Expect
