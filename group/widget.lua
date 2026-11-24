-- Slider widget used by client-side groups of on/off switch devices.
-- value is 0..15; the shell translates it into how many members are on.
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
    ctx:send("set", level)
  end)

  local function update(state, online)
    local level = tonumber(state) or 0
    local group = ctx.group or { members = 0, on = 0, online = 0 }
    local members = group.members or 0
    local target = members > 0 and math.floor(level * members / 15 + 0.5) or 0
    syncing = true
    slider:setIndex(indexFromLevel(level))
    syncing = false
    local text = string.format("%d%% - %d/%d on", math.floor(level / 15 * 100 + 0.5), target, members)
    if group.online < members then
      text = text .. " (" .. group.online .. " online)"
    end
    stateLabel:setText(text)
    if online then
      slider:enable()
      stateLabel:setForeground(colors.lightGray)
    else
      slider:disable()
      stateLabel:setForeground(colors.red)
    end
  end

  update(ctx.state, ctx.online)
  return update
end
