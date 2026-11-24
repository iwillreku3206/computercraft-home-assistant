-- Widget script sent by a dimmer device to the pocket computer.
return function(ctx)
  local slider = ctx:addSlider()
    :setPosition(1, 1)
    :setSize(ctx.w, 1)
    :setMaxValue(15)
    :setBarType("horizontal")
  local stateLabel = ctx:addLabel()
    :setPosition(1, 2)
    :setSize(ctx.w, 1)
    :setText("")

  local syncing = false

  local function levelFromIndex(index)
    local size = slider:getWidth()
    if size <= 1 then
      return 0
    end
    return math.floor((index - 1) / (size - 1) * 15 + 0.5)
  end

  local function indexFromLevel(level)
    local size = slider:getWidth()
    if size <= 1 then
      return 1
    end
    return math.floor(level / 15 * (size - 1) + 0.5) + 1
  end

  slider:onChange(function()
    if syncing then
      return
    end
    local level = levelFromIndex(slider:getIndex())
    stateLabel:setText(string.format("%d%% (%d/15)", math.floor(level / 15 * 100 + 0.5), level))
    ctx:send("set", level)
  end)

  local function update(state, online)
    local level = tonumber(state) or 0
    syncing = true
    slider:setIndex(indexFromLevel(level))
    syncing = false
    local text = string.format("%d%% (%d/15)", math.floor(level / 15 * 100 + 0.5), level)
    if online then
      slider:enable()
      stateLabel:setText(text)
      stateLabel:setForeground(colors.lightGray)
    else
      slider:disable()
      stateLabel:setText("Offline - last " .. text)
      stateLabel:setForeground(colors.red)
    end
  end

  update(ctx.state, ctx.online)
  return update
end
