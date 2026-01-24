--- Protocol module for lovewright
-- Handles JSON-RPC style message encoding/decoding between test runner and game runtime

local protocol = {}

protocol.PORT = 19840
protocol.VERSION = "1.0.0"

-- Message types
protocol.MessageType = {
  -- Requests (test runner -> game)
  PING = "ping",
  GET_OBJECTS = "get_objects",
  QUERY_OBJECT = "query_object",
  GET_PROPERTY = "get_property",
  SIMULATE_INPUT = "simulate_input",
  TAKE_SCREENSHOT = "take_screenshot",
  WAIT_FOR = "wait_for",
  SHUTDOWN = "shutdown",

  -- Responses (game -> test runner)
  PONG = "pong",
  RESULT = "result",
  ERROR = "error",

  -- Events (game -> test runner)
  READY = "ready",
  FRAME = "frame",
  OBJECT_ADDED = "object_added",
  OBJECT_REMOVED = "object_removed",
}

-- Simple JSON encoder (minimal implementation for Lua tables)
local function encode_value(v, depth)
  depth = depth or 0
  if depth > 50 then
    error("JSON encode: max depth exceeded")
  end

  local t = type(v)
  if t == "nil" then
    return "null"
  elseif t == "boolean" then
    return v and "true" or "false"
  elseif t == "number" then
    if v ~= v then -- NaN
      return "null"
    elseif v == math.huge then
      return "1e308"
    elseif v == -math.huge then
      return "-1e308"
    else
      return tostring(v)
    end
  elseif t == "string" then
    -- Escape special characters
    local escaped = v:gsub('[\\"\b\f\n\r\t]', {
      ["\\"] = "\\\\",
      ['"'] = '\\"',
      ["\b"] = "\\b",
      ["\f"] = "\\f",
      ["\n"] = "\\n",
      ["\r"] = "\\r",
      ["\t"] = "\\t",
    })
    -- Escape control characters
    escaped = escaped:gsub("[\x00-\x1f]", function(c)
      return string.format("\\u%04x", string.byte(c))
    end)
    return '"' .. escaped .. '"'
  elseif t == "table" then
    -- Check if array or object
    local is_array = true
    local max_index = 0
    local count = 0
    for k, _ in pairs(v) do
      count = count + 1
      if type(k) == "number" and k > 0 and math.floor(k) == k then
        max_index = math.max(max_index, k)
      else
        is_array = false
        break
      end
    end
    if is_array and max_index == count then
      -- Encode as array
      local parts = {}
      for i = 1, #v do
        parts[i] = encode_value(v[i], depth + 1)
      end
      return "[" .. table.concat(parts, ",") .. "]"
    else
      -- Encode as object
      local parts = {}
      for k, val in pairs(v) do
        if type(k) == "string" then
          table.insert(parts, encode_value(k) .. ":" .. encode_value(val, depth + 1))
        end
      end
      return "{" .. table.concat(parts, ",") .. "}"
    end
  else
    return "null"
  end
end

function protocol.encode(data)
  return encode_value(data)
end

-- Simple JSON decoder
local function skip_whitespace(str, pos)
  return str:match("^%s*()", pos)
end

local function decode_value(str, pos)
  pos = skip_whitespace(str, pos)
  local first = str:sub(pos, pos)

  if first == '"' then
    -- String
    local i = pos + 1
    local result = {}
    while i <= #str do
      local c = str:sub(i, i)
      if c == '"' then
        return table.concat(result), i + 1
      elseif c == "\\" then
        local next_c = str:sub(i + 1, i + 1)
        if next_c == "n" then
          table.insert(result, "\n")
        elseif next_c == "r" then
          table.insert(result, "\r")
        elseif next_c == "t" then
          table.insert(result, "\t")
        elseif next_c == "b" then
          table.insert(result, "\b")
        elseif next_c == "f" then
          table.insert(result, "\f")
        elseif next_c == "u" then
          local hex = str:sub(i + 2, i + 5)
          table.insert(result, string.char(tonumber(hex, 16)))
          i = i + 4
        else
          table.insert(result, next_c)
        end
        i = i + 2
      else
        table.insert(result, c)
        i = i + 1
      end
    end
    error("JSON decode: unterminated string")
  elseif first == "{" then
    -- Object
    local obj = {}
    pos = pos + 1
    pos = skip_whitespace(str, pos)
    if str:sub(pos, pos) == "}" then
      return obj, pos + 1
    end
    while true do
      pos = skip_whitespace(str, pos)
      local key
      key, pos = decode_value(str, pos)
      pos = skip_whitespace(str, pos)
      if str:sub(pos, pos) ~= ":" then
        error("JSON decode: expected ':' at position " .. pos)
      end
      pos = pos + 1
      local value
      value, pos = decode_value(str, pos)
      obj[key] = value
      pos = skip_whitespace(str, pos)
      local sep = str:sub(pos, pos)
      if sep == "}" then
        return obj, pos + 1
      elseif sep == "," then
        pos = pos + 1
      else
        error("JSON decode: expected ',' or '}' at position " .. pos)
      end
    end
  elseif first == "[" then
    -- Array
    local arr = {}
    pos = pos + 1
    pos = skip_whitespace(str, pos)
    if str:sub(pos, pos) == "]" then
      return arr, pos + 1
    end
    while true do
      local value
      value, pos = decode_value(str, pos)
      table.insert(arr, value)
      pos = skip_whitespace(str, pos)
      local sep = str:sub(pos, pos)
      if sep == "]" then
        return arr, pos + 1
      elseif sep == "," then
        pos = pos + 1
      else
        error("JSON decode: expected ',' or ']' at position " .. pos)
      end
    end
  elseif str:sub(pos, pos + 3) == "true" then
    return true, pos + 4
  elseif str:sub(pos, pos + 4) == "false" then
    return false, pos + 5
  elseif str:sub(pos, pos + 3) == "null" then
    return nil, pos + 4
  else
    -- Number
    local num_str = str:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
    if num_str then
      return tonumber(num_str), pos + #num_str
    end
    error("JSON decode: unexpected character at position " .. pos .. ": " .. first)
  end
end

function protocol.decode(str)
  if type(str) ~= "string" or str == "" then
    return nil, "empty or invalid input"
  end
  local ok, result, _ = pcall(decode_value, str, 1)
  if ok then
    return result
  else
    return nil, result
  end
end

-- Create a request message
function protocol.request(msg_type, id, params)
  return protocol.encode({
    type = msg_type,
    id = id,
    params = params or {},
    version = protocol.VERSION,
  })
end

-- Create a response message
function protocol.response(id, result)
  return protocol.encode({
    type = protocol.MessageType.RESULT,
    id = id,
    result = result,
  })
end

-- Create an error response
function protocol.error_response(id, message, code)
  return protocol.encode({
    type = protocol.MessageType.ERROR,
    id = id,
    error = {
      message = message,
      code = code or -1,
    },
  })
end

-- Create an event message
function protocol.event(event_type, data)
  return protocol.encode({
    type = event_type,
    data = data or {},
  })
end

-- Frame a message for transmission (length-prefixed)
function protocol.frame(message)
  return string.format("%08d", #message) .. message
end

-- Read a framed message
function protocol.unframe(data, offset)
  offset = offset or 1
  if #data - offset + 1 < 8 then
    return nil, nil, "incomplete header"
  end
  local length_str = data:sub(offset, offset + 7)
  local length = tonumber(length_str)
  if not length then
    return nil, nil, "invalid length header"
  end
  if #data - offset + 1 < 8 + length then
    return nil, nil, "incomplete message"
  end
  local message = data:sub(offset + 8, offset + 7 + length)
  return message, offset + 8 + length, nil
end

return protocol
