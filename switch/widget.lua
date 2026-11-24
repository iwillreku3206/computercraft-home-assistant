-- Widget script sent by a switch device to the pocket computer.
-- The client shell loads this in a sandbox and calls the returned function.
return function(ctx)
  local button = ctx:addButton()
    :setPosition(1, 1)
    :setSize(ctx.w, 1)
    :setText("")

  local stateLabel = ctx:addLabel()
    :setPosition(1, 2)
    :setSize(ctx.w, 1)
    :setText("")

  local function update(state, online)
    local on = state == true
    button:setText(on and "Turn off" or "Turn on")
    button:setBackground(on and colors.green or colors.gray)
    button:setForeground(colors.white)
    if online then
      button:enable()
      stateLabel:setText(on and "State: ON" or "State: OFF")
      stateLabel:setForeground(colors.lightGray)
    else
      button:disable()
      stateLabel:setText((on and "Last state: ON" or "Last state: OFF") .. " (offline)")
      stateLabel:setForeground(colors.red)
    end
  end

  button:onClick(function()
    if ctx.online then
      ctx:send("toggle")
    end
  end)

  update(ctx.state, ctx.online)
  return update
end
