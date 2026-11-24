-- Resolve /ha/... and /basalt.lua from the root regardless of shell.dir.
package.path = "/?.lua;" .. package.path

local ha = require("ha.lib.ha")
local run = require("ha.lib.device_app")

run({
  kind = "switch",
  title = "Switch",
  defaultName = "Switch " .. tostring(os.getComputerID()),
  configPath = "/ha/switch.cfg",
  widgetPath = "/ha/widgets/switch.lua",

  defaultConfig = function()
    return {
      version = 1,
      id = os.getComputerID(),
      kind = "switch",
      name = "Switch " .. tostring(os.getComputerID()),
      side = "top",
      network = ha.DEFAULT_NETWORK,
      channel = ha.DEFAULT_CHANNEL,
      pairingOpen = true,
      gps = true,
      state = false,
      paired = {},
    }
  end,

  defaultState = false,

  sanitize = function(value)
    if value == true or value == 1 or value == "on" or value == "true" then
      return true
    elseif value == false or value == 0 or value == "off" or value == "false" then
      return false
    end
    return nil
  end,

  stateLabel = function(value)
    return "Redstone output: " .. (value and "ON (15)" or "OFF (0)")
  end,

  apply = function(side, value)
    redstone.setOutput(side, value and true or false)
  end,

  clear = function(side)
    redstone.setOutput(side, false)
  end,

  buildControl = function(parent, api)
    local button = parent:addButton()
      :setPosition(1, 1)
      :setSize(api.w, 3)
      :setText("")
    button:onClick(function()
      api.setValue(not api.getValue())
    end)

    return function(value)
      local label = value and "ON - tap to turn off" or "OFF - tap to turn on"
      button:setText(ha.fit(label, api.w))
      button:setBackground(value and colors.green or colors.red)
      button:setForeground(colors.white)
    end
  end,
})
