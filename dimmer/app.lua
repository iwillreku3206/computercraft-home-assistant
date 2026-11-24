-- Resolve /ha/... and /basalt.lua from the root regardless of shell.dir.
package.path = "/?.lua;" .. package.path

local ha = require("ha.lib.ha")
local run = require("ha.lib.device_app")

run({
  kind = "dimmer",
  title = "Dimmer",
  defaultName = "Dimmer " .. tostring(os.getComputerID()),
  configPath = "/ha/dimmer.cfg",
  widgetPath = "/ha/widgets/dimmer.lua",

  defaultConfig = function()
    return {
      version = 1,
      id = os.getComputerID(),
      kind = "dimmer",
      name = "",
      side = "top",
      network = ha.DEFAULT_NETWORK,
      channel = ha.DEFAULT_CHANNEL,
      pairingOpen = true,
      gps = true,
      state = 0,
      paired = {},
    }
  end,

  defaultState = 0,

  sanitize = function(value)
    local number = tonumber(value)
    if number == nil then
      return nil
    end
    return ha.round(ha.clamp(number, 0, 15))
  end,

  stateLabel = function(value)
    return string.format(
      "Redstone output: %d/15 (%d%%)",
      value,
      ha.pct(value)
    )
  end,

  apply = function(side, value)
    redstone.setAnalogOutput(side, value)
  end,

  clear = function(side)
    redstone.setAnalogOutput(side, 0)
  end,

  buildControl = function(parent, api)
    local slider = parent:addSlider()
      :setPosition(1, 1)
      :setSize(api.w, 1)
      :setMaxValue(15)
      :setBarType("horizontal")
    local label = parent:addLabel()
      :setPosition(1, 2)
      :setSize(api.w, 1)
      :setText("")

    local syncing = false

    local function levelFromIndex(index)
      local size = slider:getWidth()
      if size <= 1 then
        return 0
      end
      return ha.round((index - 1) / (size - 1) * 15)
    end

    local function indexFromLevel(level)
      local size = slider:getWidth()
      if size <= 1 then
        return 1
      end
      return ha.round(level / 15 * (size - 1)) + 1
    end

    slider:onChange(function()
      if syncing then
        return
      end
      local value = levelFromIndex(slider:getIndex())
      label:setText(string.format("Level %d/15 (%d%%)", value, ha.pct(value)))
      api.setValue(value)
    end)

    return function(value)
      syncing = true
      slider:setIndex(indexFromLevel(value))
      syncing = false
      label:setText(string.format("Level %d/15 (%d%%)", value, ha.pct(value)))
    end
  end,
})
