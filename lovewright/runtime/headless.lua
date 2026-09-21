--- Headless window control for the lovewright runtime (runs inside the game).
--
-- LÖVE cannot run without a window and still render: with the window and
-- graphics modules off there is no love.draw to screenshot, and SDL's
-- "dummy" video driver provides no GPU context. What it CAN do is keep
-- rendering into a window nobody sees. Measured on Windows (LÖVE 12, SDL3,
-- Vulkan) and unchanged from a visible window: love.draw keeps running,
-- love.graphics.captureScreenshot returns the real frame, canvas readbacks
-- work, and the loop runs faster because nothing is composited.
--
-- Modes, best first; each falls back to the next if it cannot be applied:
--   "hidden"     the SDL window is hidden (SDL_HideWindow through LuaJIT's
--                FFI; LÖVE has no Lua API for it). No window, no taskbar
--                entry, no focus change. The window is created off-screen
--                first (see game.lua's conf) so it never flashes.
--   "offscreen"  the window stays "shown" but parked far off-screen. For
--                setups where a hidden window stops presenting.
--   "minimized"  love.window.minimize(), the pre-0.2 behaviour. Works
--                everywhere, but shows in the taskbar and any game that
--                calls love.window.setMode at startup pops back up.
--
-- Games often re-create or re-show their window (love.window.setMode /
-- updateMode from saved settings, a fullscreen toggle): install() wraps
-- both to keep the window off-screen and windowed, and enforce() - called
-- from the runtime's update hook - re-applies the mode whenever the window
-- turns up visible again.

local headless = {}

local OFFSCREEN = -32000

local state = {
  mode = "off",        -- requested: off | hidden | offscreen | minimized
  applied = "none",    -- what actually took: hidden | offscreen | minimized | none
  sdl_tried = false,
  lib = nil,           -- FFI clib exposing the SDL symbols
  is_sdl3 = false,
  note = nil,          -- why a better mode was not available
}

-- Locate SDL inside the running love process. LÖVE 12 ships SDL3, 11.x SDL2
-- (a DLL on Windows, a shared lib or static link elsewhere: the default FFI
-- namespace covers those).
local function sdl()
  if state.sdl_tried then return state.lib end
  state.sdl_tried = true
  local ok, ffi = pcall(require, "ffi")
  if not ok then
    state.note = "LuaJIT FFI unavailable"
    return nil
  end
  pcall(ffi.cdef, [[
    typedef struct SDL_Window SDL_Window;
    SDL_Window** SDL_GetWindows(int *count);
    SDL_Window* SDL_GL_GetCurrentWindow(void);
    void SDL_HideWindow(SDL_Window *window);
    void SDL_free(void *mem);
  ]])
  local function usable(lib)
    return pcall(function() return lib.SDL_HideWindow end)
  end
  for _, name in ipairs({ "SDL3", "SDL2", "SDL2-2.0" }) do
    local okL, lib = pcall(ffi.load, name)
    if okL and usable(lib) then
      state.lib = lib
      state.is_sdl3 = (name == "SDL3")
      return lib
    end
  end
  if usable(ffi.C) then
    state.lib = ffi.C
    -- SDL_GetWindows only exists in SDL3
    state.is_sdl3 = pcall(function() return ffi.C.SDL_GetWindows end)
    return ffi.C
  end
  state.note = "SDL symbols not reachable through FFI"
  return nil
end

-- The game's SDL window, or nil
local function sdl_window(lib)
  local ffi = require("ffi")
  if state.is_sdl3 then
    local count = ffi.new("int[1]")
    local list = lib.SDL_GetWindows(count)
    if list ~= nil then
      local win = count[0] > 0 and list[0] or nil
      lib.SDL_free(list)
      if win ~= nil then return win end
    end
  end
  -- SDL2 (LÖVE 11 is OpenGL-only, so the GL window is the window)
  local ok, win = pcall(function() return lib.SDL_GL_GetCurrentWindow() end)
  if ok and win ~= nil then return win end
  return nil
end

local function hide_with_sdl()
  local lib = sdl()
  if not lib then return false end
  local ok, err = pcall(function()
    local win = sdl_window(lib)
    if win == nil then error("no SDL window") end
    lib.SDL_HideWindow(win)
  end)
  if not ok then state.note = tostring(err) end
  return ok
end

local function park_offscreen()
  if love.window and love.window.setPosition then
    return pcall(love.window.setPosition, OFFSCREEN, OFFSCREEN)
  end
  return false
end

-- Apply the requested mode now (falling back as needed). Returns the mode
-- that took effect.
function headless.apply()
  if state.mode == "off" or not (love.window and love.window.isOpen and love.window.isOpen()) then
    return state.applied
  end
  if state.mode == "hidden" and hide_with_sdl() then
    state.applied = "hidden"
  elseif (state.mode == "hidden" or state.mode == "offscreen") and park_offscreen() then
    state.applied = "offscreen"
  elseif love.window.minimize then
    love.window.minimize()
    state.applied = "minimized"
  end
  return state.applied
end

-- Wrap love.window.setMode / updateMode: a window (re)created mid-test must
-- come up off-screen and windowed, then be hidden again
local function guard(name)
  local original = love.window and love.window[name]
  if not original then return end
  love.window[name] = function(...)
    local args = { n = select("#", ...), ... }
    -- setMode(w, h, flags) / updateMode(w, h, flags)
    local flags = args[3]
    if state.mode == "hidden" or state.mode == "offscreen" then
      local patched = {}
      for k, v in pairs(type(flags) == "table" and flags or {}) do patched[k] = v end
      patched.x, patched.y = OFFSCREEN, OFFSCREEN
      patched.fullscreen = false
      args[3] = patched
      if args.n < 3 then args.n = 3 end
    end
    local results = { original(unpack(args, 1, args.n)) }
    headless.apply()
    return unpack(results)
  end
end

--- Turn headless handling on. `mode`: "hidden" (default) | "offscreen" |
-- "minimized". Call once, before the game's love.load runs.
function headless.install(mode)
  if mode ~= "offscreen" and mode ~= "minimized" then mode = "hidden" end
  state.mode = mode
  guard("setMode")
  guard("updateMode")
  return headless.apply()
end

--- Re-apply the mode if the window became visible again. Cheap enough to
-- call every frame.
function headless.enforce()
  if state.mode == "off" or not love.window then return end
  if state.applied == "hidden" then
    if love.window.isVisible and love.window.isVisible() then headless.apply() end
  elseif state.applied == "minimized" then
    if love.window.isMinimized and not love.window.isMinimized() then headless.apply() end
  end
end

--- What is in effect: { mode = requested, applied = actual, note = why-not }
function headless.status()
  return { mode = state.mode, applied = state.applied, note = state.note }
end

return headless
