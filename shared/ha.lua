--[[
  ha.lua - shared support for the ComputerCraft Home Assistant.

  Installed on every computer as /ha/lib/ha.lua. It deliberately only depends
  on the standard CraftOS APIs so the same file can be syntax-checked with
  ordinary Lua.
]]

local ha = {}

ha.PROTO = "omp-ha"
ha.VERSION = 1
ha.DEFAULT_CHANNEL = 48721
ha.DEFAULT_NETWORK = "home"
ha.HEARTBEAT_SECONDS = 5
ha.DISCOVER_SECONDS = 30
ha.OFFLINE_MS = 15000
ha.WIDGET_CHUNK = 4096

local unpack = unpack or table.unpack

---------------------------------------------------------------------------
-- basics
---------------------------------------------------------------------------

local function fallbackClock()
  return os.clock() * 1000
end

function ha.now()
  if os.epoch then
    local ok, value = pcall(os.epoch, "utc")
    if ok and type(value) == "number" then
      return value
    end
  end
  return fallbackClock()
end

function ha.clamp(value, low, high)
  value = tonumber(value) or low
  if value < low then
    return low
  elseif value > high then
    return high
  end
  return value
end

function ha.round(value)
  value = tonumber(value) or 0
  if value < 0 then
    return math.ceil(value - 0.5)
  end
  return math.floor(value + 0.5)
end

function ha.deepcopy(value, seen)
  if type(value) ~= "table" then
    return value
  end
  seen = seen or {}
  if seen[value] then
    return seen[value]
  end
  local copy = {}
  seen[value] = copy
  for k, v in pairs(value) do
    copy[ha.deepcopy(k, seen)] = ha.deepcopy(v, seen)
  end
  return copy
end

function ha.merge(dst, src)
  dst = dst or {}
  for k, v in pairs(src or {}) do
    if type(v) == "table" and type(dst[k]) == "table" then
      ha.merge(dst[k], v)
    else
      dst[k] = ha.deepcopy(v)
    end
  end
  return dst
end

function ha.trim(value)
  value = tostring(value or "")
  return value:match("^%s*(.-)%s*$") or ""
end

function ha.safeText(value, limit)
  local text = tostring(value or "")
  text = text:gsub("[%c]", " ")
  text = text:gsub("%s+", " ")
  text = ha.trim(text)
  if limit and #text > limit then
    text = text:sub(1, limit)
  end
  return text
end

function ha.fit(value, width)
  local text = tostring(value or "")
  width = tonumber(width) or 0
  if width <= 0 then
    return ""
  elseif #text <= width then
    return text
  elseif width <= 2 then
    return text:sub(1, width)
  end
  return text:sub(1, width - 2) .. ".."
end

function ha.normLabel(value)
  local text = ha.safeText(value, 20):lower()
  if text == "" then
    return nil
  end
  return text
end

function ha.hash(source)
  local h = 5381
  for i = 1, #source do
    h = (h * 33 + source:byte(i)) % 2147483647
  end
  return string.format("%08x", h)
end

function ha.pct(level)
  return ha.round(ha.clamp(level, 0, 15) / 15 * 100)
end

function ha.levelFromPct(percent)
  return ha.round(ha.clamp(percent, 0, 100) / 100 * 15)
end

function ha.distance(a, b)
  if type(a) ~= "table" or type(b) ~= "table" then
    return nil
  end
  if type(a.x) ~= "number" or type(a.y) ~= "number" or type(a.z) ~= "number" then
    return nil
  end
  if type(b.x) ~= "number" or type(b.y) ~= "number" or type(b.z) ~= "number" then
    return nil
  end
  local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
  return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function ha.distanceText(distance)
  if type(distance) ~= "number" then
    return "?"
  end
  if distance < 1000 then
    return tostring(ha.round(distance)) .. "m"
  end
  return string.format("%.1fk", distance / 1000)
end

function ha.humanAge(timestamp)
  if type(timestamp) ~= "number" then
    return "never"
  end
  local seconds = math.max(0, (ha.now() - timestamp) / 1000)
  if seconds < 60 then
    return tostring(math.floor(seconds)) .. "s"
  elseif seconds < 3600 then
    return tostring(math.floor(seconds / 60)) .. "m"
  end
  return tostring(math.floor(seconds / 3600)) .. "h"
end

function ha.listFromSet(set)
  local result = {}
  for key, value in pairs(set or {}) do
    if value then
      result[#result + 1] = key
    end
  end
  table.sort(result, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return result
end

function ha.listContains(list, needle)
  for _, value in ipairs(list or {}) do
    if value == needle then
      return true
    end
  end
  return false
end

---------------------------------------------------------------------------
-- filesystem / persistence
---------------------------------------------------------------------------

function ha.ensureDir(path)
  if not fs or not path or path == "" then
    return false
  end
  if fs.exists(path) then
    return true
  end
  local prefix = path:sub(1, 1) == "/" and "/" or ""
  local current = prefix
  for part in path:gmatch("[^/]+") do
    if current == "/" then
      current = "/" .. part
    elseif current == "" then
      current = part
    else
      current = current .. "/" .. part
    end
    if not fs.exists(current) then
      local ok = pcall(fs.makeDir, current)
      if not ok then
        return false
      end
    end
  end
  return fs.exists(path)
end

function ha.readFile(path)
  if not fs or not fs.exists(path) then
    return nil
  end
  local handle = fs.open(path, "r")
  if not handle then
    return nil
  end
  local ok, data = pcall(handle.readAll)
  handle.close()
  if ok then
    return data
  end
  return nil
end

function ha.writeFile(path, data)
  ha.ensureDir(path:match("^(.*)/[^/]+$") or "")
  local handle = fs.open(path, "w")
  if not handle then
    return false
  end
  local ok = pcall(handle.write, data)
  handle.close()
  return ok
end

local function mergeDefaults(dst, loaded)
  if type(loaded) ~= "table" then
    return dst
  end
  for key, value in pairs(loaded) do
    if type(value) == "table" and type(dst[key]) == "table" then
      dst[key] = mergeDefaults(dst[key], value)
    else
      dst[key] = ha.deepcopy(value)
    end
  end
  return dst
end

function ha.loadConfig(path, defaults)
  local config = ha.deepcopy(defaults or {})
  local raw = ha.readFile(path)
  if raw and textutils and textutils.unserialize then
    local ok, decoded = pcall(textutils.unserialize, raw)
    if ok and type(decoded) == "table" then
      config = mergeDefaults(config, decoded)
    end
  end
  return config
end

function ha.saveConfig(path, config)
  if not textutils or not textutils.serialize then
    return false
  end
  local ok, payload = pcall(textutils.serialize, config)
  if not ok then
    return false
  end
  return ha.writeFile(path, payload)
end

function ha.log(...)
  if not fs then
    return
  end
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring(select(i, ...))
  end
  local line = string.format("[%s] %s\n", tostring(ha.now()), table.concat(parts, " "))
  ha.ensureDir("/ha")
  local handle = fs.open("/ha/debug.log", "a")
  if handle then
    pcall(handle.write, line)
    handle.close()
  end
end

---------------------------------------------------------------------------
-- time
---------------------------------------------------------------------------

function ha.clockText()
  local day = 0
  if os.day then
    local ok, value = pcall(os.day)
    if ok and value then
      day = value
    end
  end
  local game = "??:??"
  if os.time and textutils and textutils.formatTime then
    local ok, value = pcall(textutils.formatTime, os.time(), true)
    if ok and value then
      game = value
    end
  end
  local real = "??:??"
  if os.date and os.epoch then
    local ok, value = pcall(os.date, "%H:%M", os.epoch("local") / 1000)
    if ok and value then
      real = value
    end
  elseif os.date then
    local ok, value = pcall(os.date, "%H:%M")
    if ok and value then
      real = value
    end
  end
  return string.format("D%s %s | %s", tostring(day), game, real)
end

---------------------------------------------------------------------------
-- modem / protocol
---------------------------------------------------------------------------

function ha.newMessage(network, from, fields)
  fields = fields or {}
  fields.p = ha.PROTO
  fields.v = ha.VERSION
  fields.net = network
  fields.from = from
  fields.ts = fields.ts or ha.now()
  return fields
end

function ha.isMessage(message, network)
  return type(message) == "table"
    and message.p == ha.PROTO
    and message.v == ha.VERSION
    and message.net == network
end

local function eachPeripheralType(name, wanted)
  if peripheral.hasType then
    local ok, has = pcall(peripheral.hasType, name, wanted)
    return ok and has
  end
  local ok, kind = pcall(peripheral.getType, name)
  if not ok then
    return false
  end
  if type(kind) == "table" then
    for _, value in ipairs(kind) do
      if value == wanted then
        return true
      end
    end
  end
  return kind == wanted
end

function ha.findModem()
  if not peripheral then
    return nil, nil, "peripheral API unavailable"
  end
  local names = {}
  local ok, result = pcall(peripheral.getNames)
  if ok and type(result) == "table" then
    names = result
  end
  for _, name in ipairs(names) do
    if eachPeripheralType(name, "modem") then
      local modem = peripheral.wrap(name)
      if modem then
        local wirelessOk, wireless = pcall(modem.isWireless, modem)
        if wirelessOk and wireless then
          return modem, name
        end
      end
    end
  end
  -- Some pocket computer upgrades are not exposed by getNames in older
  -- versions; peripheral.find handles those.
  if peripheral.find then
    local findOk, modem, name = pcall(peripheral.find, "modem")
    if findOk and modem then
      local wirelessOk, wireless = pcall(modem.isWireless, modem)
      if wirelessOk and wireless then
        return modem, name
      end
    end
  end
  return nil, nil, "no wireless/ender modem found"
end

function ha.openModem(channel)
  local modem, side, err = ha.findModem()
  if not modem then
    return nil, nil, err
  end
  local ok, openErr = pcall(modem.open, channel)
  if not ok then
    return nil, side, tostring(openErr)
  end
  return modem, side
end

function ha.reopenModem(modem, oldChannel, newChannel)
  if modem and oldChannel then
    pcall(modem.close, oldChannel)
  end
  return ha.openModem(newChannel)
end

function ha.transmit(modem, channel, message)
  if not modem then
    return false
  end
  local ok = pcall(modem.transmit, channel, channel, message)
  return ok
end

ha.GPS_CHANNEL = 65534

local function gpsRound(value)
  return math.floor(value * 100 + 0.5) / 100
end

local function gpsSub(a, b)
  return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
end

local function gpsAdd(a, b)
  return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }
end

local function gpsScale(a, value)
  return { x = a.x * value, y = a.y * value, z = a.z * value }
end

local function gpsDot(a, b)
  return a.x * b.x + a.y * b.y + a.z * b.z
end

local function gpsCross(a, b)
  return {
    x = a.y * b.z - a.z * b.y,
    y = a.z * b.x - a.x * b.z,
    z = a.x * b.y - a.y * b.x,
  }
end

local function gpsLength(a)
  return math.sqrt(gpsDot(a, a))
end

local function gpsDistance(a, b)
  return gpsLength(gpsSub(a, b))
end

-- Solves three sphere equations. Returns one or two candidate positions.
local function gpsSolveTriple(a, b, c)
  local a2b = gpsSub(b.pos, a.pos)
  local a2c = gpsSub(c.pos, a.pos)
  local distance = gpsLength(a2b)
  if distance < 1e-9 then
    return nil
  end
  local ex = gpsScale(a2b, 1 / distance)
  local i = gpsDot(ex, a2c)
  local ey = gpsSub(a2c, gpsScale(ex, i))
  local eyLength = gpsLength(ey)
  if eyLength < 1e-9 then
    return nil
  end
  ey = gpsScale(ey, 1 / eyLength)
  local j = gpsDot(ey, a2c)
  if math.abs(j) < 1e-9 then
    return nil
  end
  local ez = gpsCross(ex, ey)
  local r1, r2, r3 = a.distance, b.distance, c.distance
  local x = (r1 * r1 - r2 * r2 + distance * distance) / (2 * distance)
  local y = (r1 * r1 - r3 * r3 - x * x + (x - i) * (x - i) + j * j) / (2 * j)
  local base = gpsAdd(a.pos, gpsAdd(gpsScale(ex, x), gpsScale(ey, y)))
  local zSquared = r1 * r1 - x * x - y * y
  if zSquared < -0.5 then
    return nil
  end
  if zSquared < 0 then
    zSquared = 0
  end
  local z = math.sqrt(zSquared)
  return gpsAdd(base, gpsScale(ez, z)), gpsSub(base, gpsScale(ez, z))
end

-- Turns GPS host responses into a position. Each fix is
-- { pos = {x,y,z}, distance = number }.
function ha.trilaterate(fixes)
  if type(fixes) ~= "table" or #fixes < 3 then
    return nil
  end

  local candidates, seen = {}, {}
  local function addCandidate(position)
    if not position then
      return
    end
    local key = string.format("%.2f,%.2f,%.2f", position.x, position.y, position.z)
    if not seen[key] then
      seen[key] = true
      candidates[#candidates + 1] = {
        x = position.x,
        y = position.y,
        z = position.z,
      }
    end
  end

  for i = 1, #fixes - 2 do
    for j = i + 1, #fixes - 1 do
      for k = j + 1, #fixes do
        local p1, p2 = gpsSolveTriple(fixes[i], fixes[j], fixes[k])
        addCandidate(p1)
        addCandidate(p2)
      end
    end
  end

  if #candidates == 0 then
    return nil
  end

  for _, candidate in ipairs(candidates) do
    local error = 0
    for _, fix in ipairs(fixes) do
      error = error + math.abs(gpsDistance(candidate, fix.pos) - fix.distance)
    end
    candidate.error = error
  end
  table.sort(candidates, function(a, b)
    return a.error < b.error
  end)

  local best = candidates[1]
  if #candidates > 1 then
    local second = candidates[2]
    if math.abs(second.error - best.error) < 0.01
      and gpsDistance(best, second) > 1 then
      -- The mirror candidate fits equally well; the fix is ambiguous.
      return nil
    end
  end

  return { x = gpsRound(best.x), y = gpsRound(best.y), z = gpsRound(best.z) }
end

-- Asynchronous GPS client. Basalt's schedule resumption drops the modem
-- distance parameter from gps responses, so gps.locate cannot be used from a
-- Basalt schedule. This locator is driven from the Basalt event callback.
function ha.newGpsLocator()
  local locator = {
    fixes = {},
    pending = false,
    timerId = nil,
    modemSide = nil,
  }

  local function finish(self, position)
    self.pending = false
    if self.timerId then
      pcall(os.cancelTimer, self.timerId)
      self.timerId = nil
    end
    self.fixes = {}
    return position
  end

  function locator:request(modem, modemSide, timeout)
    if self.pending or not modem then
      return false
    end

    self.pending = true
    self.modemSide = modemSide
    self.fixes = {}

    local okOpen, isOpen = pcall(modem.isOpen, ha.GPS_CHANNEL)
    if not (okOpen and isOpen) then
      local opened = pcall(modem.open, ha.GPS_CHANNEL)
      if not opened then
        self.pending = false
        return false
      end
    end

    local sent = pcall(modem.transmit, ha.GPS_CHANNEL, ha.GPS_CHANNEL, "PING")
    if not sent then
      self.pending = false
      return false
    end

    self.timerId = os.startTimer(timeout or 0.75)
    return true
  end

  function locator:handleModem(side, channel, reply, message, distance)
    if not self.pending then
      return nil
    end
    if channel ~= ha.GPS_CHANNEL or reply ~= ha.GPS_CHANNEL then
      return nil
    end
    if self.modemSide and side ~= self.modemSide then
      return nil
    end
    if type(message) ~= "table" or #message ~= 3 then
      return nil
    end

    local x = tonumber(message[1])
    local y = tonumber(message[2])
    local z = tonumber(message[3])
    distance = tonumber(distance)
    if not x or not y or not z or not distance then
      return nil
    end

    if distance == 0 then
      return finish(self, { x = x, y = y, z = z })
    end

    self.fixes[#self.fixes + 1] = {
      pos = { x = x, y = y, z = z },
      distance = distance,
    }

    -- Wait for a fourth fix when possible: three spheres can produce a
    -- mirrored candidate that only another host resolves.
    if #self.fixes >= 4 then
      local position = ha.trilaterate(self.fixes)
      if position then
        return finish(self, position)
      end
    end
    return nil
  end

  function locator:handleTimer(id)
    if not self.pending or id ~= self.timerId then
      return nil
    end
    self.timerId = nil
    return finish(self, ha.trilaterate(self.fixes))
  end

  function locator:isBusy()
    return self.pending
  end

  return locator
end

---------------------------------------------------------------------------
-- redstone sides
---------------------------------------------------------------------------

ha.FALLBACK_SIDES = { "top", "bottom", "left", "right", "front", "back" }

function ha.sides()
  if redstone and redstone.getSides then
    local ok, sides = pcall(redstone.getSides)
    if ok and type(sides) == "table" and #sides > 0 then
      return sides
    end
  end
  return ha.FALLBACK_SIDES
end

function ha.validSide(side)
  for _, value in ipairs(ha.sides()) do
    if value == side then
      return true
    end
  end
  return false
end

function ha.nextSide(side, direction)
  local sides = ha.sides()
  local current = 1
  for index, value in ipairs(sides) do
    if value == side then
      current = index
      break
    end
  end
  current = current + (direction or 1)
  if current < 1 then
    current = #sides
  elseif current > #sides then
    current = 1
  end
  return sides[current]
end

---------------------------------------------------------------------------
-- widget source sandbox
---------------------------------------------------------------------------

local SAFE_GLOBALS = {
  "assert", "error", "ipairs", "next", "pairs", "pcall", "select",
  "tonumber", "tostring", "type", "unpack", "xpcall", "rawequal",
  "rawget", "rawset", "setmetatable", "getmetatable",
}

local SAFE_LIBRARIES = {
  "math", "string", "table", "coroutine",
}

function ha.widgetEnv(extra)
  local env = {}
  for _, name in ipairs(SAFE_GLOBALS) do
    env[name] = _G[name]
  end
  for _, name in ipairs(SAFE_LIBRARIES) do
    env[name] = _G[name]
  end
  env.unpack = unpack
  env.colors = colors or _G.colors
  env.textutils = textutils
  env.bit32 = _G.bit32
  env.os = {
    time = os.time,
    day = os.day,
    date = os.date,
    epoch = os.epoch,
    clock = os.clock,
  }
  for key, value in pairs(extra or {}) do
    env[key] = value
  end
  return env
end

-- Compiles source into the supplied environment. Works on CC's Lua 5.1
-- (loadstring/setfenv) and on a modern host Lua used by the test harness.
function ha.requireBasalt()
  local ok, basalt = pcall(require, "basalt-ha")
  if ok and basalt then
    return basalt
  end
  return require("basalt")
end

function ha.compile(source, chunkName, env)
  if type(source) ~= "string" then
    return nil, "widget source is not a string"
  end
  if loadstring then
    local fn, err = loadstring(source, chunkName)
    if not fn then
      return nil, err
    end
    if setfenv then
      setfenv(fn, env)
    end
    return fn
  end
  return load(source, chunkName, "t", env)
end

return ha
