--- Base64 encoding for lovewright runtime

local base64 = {}

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function base64.encode(data)
  local result = {}
  local padding = (3 - #data % 3) % 3

  -- Pad data to multiple of 3
  data = data .. string.rep("\0", padding)

  for i = 1, #data, 3 do
    local b1, b2, b3 = data:byte(i, i + 2)
    local n = b1 * 65536 + b2 * 256 + b3

    local c1 = math.floor(n / 262144) % 64
    local c2 = math.floor(n / 4096) % 64
    local c3 = math.floor(n / 64) % 64
    local c4 = n % 64

    table.insert(result, b64chars:sub(c1 + 1, c1 + 1))
    table.insert(result, b64chars:sub(c2 + 1, c2 + 1))
    table.insert(result, b64chars:sub(c3 + 1, c3 + 1))
    table.insert(result, b64chars:sub(c4 + 1, c4 + 1))
  end

  -- Replace padding chars with =
  for i = 1, padding do
    result[#result - i + 1] = "="
  end

  return table.concat(result)
end

local b64lookup = {}
for i = 1, 64 do
  b64lookup[b64chars:sub(i, i)] = i - 1
end

function base64.decode(data)
  -- Remove whitespace and padding
  data = data:gsub("%s", "")
  local padding = #data:match("=*$")
  data = data:gsub("=", "A")

  local result = {}
  for i = 1, #data, 4 do
    local c1 = b64lookup[data:sub(i, i)] or 0
    local c2 = b64lookup[data:sub(i + 1, i + 1)] or 0
    local c3 = b64lookup[data:sub(i + 2, i + 2)] or 0
    local c4 = b64lookup[data:sub(i + 3, i + 3)] or 0

    local n = c1 * 262144 + c2 * 4096 + c3 * 64 + c4

    table.insert(result, string.char(math.floor(n / 65536) % 256))
    table.insert(result, string.char(math.floor(n / 256) % 256))
    table.insert(result, string.char(n % 256))
  end

  -- Remove padding bytes
  return table.concat(result):sub(1, #result * 3 - padding)
end

return base64
