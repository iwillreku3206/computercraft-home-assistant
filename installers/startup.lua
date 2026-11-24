-- Shared startup configuration for generated installers.
-- This file is embedded into every generated installer. Edit it here, then run
-- `make build`; do not duplicate these choices in individual installers.

local STARTUP_MARKER_START = "-- >>> computercraft-home-assistant >>>"
local STARTUP_MARKER_END = "-- <<< computercraft-home-assistant <<<"

local STARTUP_CHOICES = {
  { id = "1", command = "ha", label = "Home Assistant client", path = "/ha.lua" },
  { id = "2", command = "switch", label = "Switch device", path = "/switch.lua" },
  { id = "3", command = "dimmer", label = "Dimmer device", path = "/dimmer.lua" },
}

local function startupRemoveBlock(text)
  local start = text:find(STARTUP_MARKER_START, 1, true)
  if not start then
    return text
  end
  local finish = text:find(STARTUP_MARKER_END, start, true)
  if not finish then
    return text:sub(1, start - 1)
  end
  finish = finish + #STARTUP_MARKER_END
  if text:sub(finish, finish) == "\n" then
    finish = finish + 1
  end
  return text:sub(1, start - 1) .. text:sub(finish)
end

local function startupWrite(command)
  local existing = readFile("/startup.lua") or ""
  existing = startupRemoveBlock(existing)
  local block = STARTUP_MARKER_START
    .. "\n"
    .. string.format("shell.run(%q)\n", command)
    .. STARTUP_MARKER_END
    .. "\n"
  if existing ~= "" then
    block = block .. "\n" .. existing
  end
  return writeFile("/startup.lua", block)
end

local function startupLabel()
  local current = os.getComputerLabel() or ""
  print("")
  if current ~= "" then
    print("Computer label [" .. current .. "]:")
  else
    print("Computer label (blank leaves it unchanged):")
  end
  local ok, input = pcall(read)
  if not ok or input == nil then
    return
  end
  input = tostring(input):match("^%s*(.-)%s*$")
  if input == "" then
    print("Computer label unchanged.")
    return
  end
  local setOk, err = pcall(os.setComputerLabel, input)
  if setOk then
    print("Computer label set to " .. input .. ".")
  else
    print("Could not set computer label: " .. tostring(err))
  end
end

local function startupConfigure()
  local available = {}
  local byId = {}
  for _, choice in ipairs(STARTUP_CHOICES) do
    if files[choice.path] then
      available[#available + 1] = choice
      byId[choice.id] = choice
    end
  end
  if #available == 0 then
    return
  end

  print("")
  print("Startup program:")
  for _, choice in ipairs(available) do
    print("  " .. choice.id .. ") " .. choice.label .. " (" .. choice.command .. ")")
  end
  print("  0) Do not change /startup.lua")

  while true do
    print("Select a startup program [0]:")
    local ok, input = pcall(read)
    if not ok or input == nil then
      print("Startup unchanged (no input).")
      return
    end
    input = tostring(input):match("^%s*(.-)%s*$")
    if input == "" then
      input = "0"
    end
    if input == "0" then
      print("Startup unchanged.")
      return
    end
    local choice = byId[input]
    if choice then
      if startupWrite(choice.command) then
        print(string.format("Updated /startup.lua: shell.run(%q)", choice.command))
        print("Startup changed; restarting computer...")
        local rebooted = pcall(function()
          os.sleep(1)
          os.reboot()
        end)
        if not rebooted then
          print("Could not restart automatically; reboot manually.")
        end
      else
        print("Could not update /startup.lua.")
      end
      return
    end
    print("Invalid selection.")
  end
end

if not HA_AUTO_UPDATE then
  startupLabel()
  startupConfigure()
end
