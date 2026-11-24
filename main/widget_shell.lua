--[[
  widget_shell.lua - the "shell" part of the pocket computer application.

  A device advertises a Lua script. The client caches and compiles that script
  in a restricted environment and gives it a small context API. The shell
  itself only draws the card title/status and hosts whatever controls the
  device script creates.
]]

local ha = require("ha.lib.ha")

local shell = {}

local function genericWidget(ctx)
  local label = ctx:addLabel()
    :setPosition(1, 1)
    :setSize(ctx.w, 1)
    :setText("Widget script unavailable")
  local value = ctx:addLabel()
    :setPosition(1, 2)
    :setSize(ctx.w, 1)
    :setText("")

  return function(state, online)
    label:setForeground(online and colors.lightGray or colors.red)
    value:setText(tostring(state) .. (online and "" or " (offline)"))
  end
end

local function addMethods(ctx, content)
  for _, name in ipairs({
    "Button", "Label", "Frame", "Switch", "Slider", "Input",
    "Checkbox", "Progressbar", "List", "Dropdown",
  }) do
    local method = "add" .. name
    ctx[method] = function(_, ...)
      return content[method](content, ...)
    end
  end
end

function shell.buildCard(parent, spec)
  local card = parent:addFrame()
    :setPosition(spec.x, spec.y)
    :setSize(spec.w, spec.h)
    :setBackground(colors.gray)
    :setForeground(colors.white)
    :setZIndex(10)

  local titleLabel = card:addLabel()
    :setPosition(1, 1)
    :setSize(spec.w - 7, 1)
    :setForeground(colors.white)
    :setText(ha.fit(spec.title or "", spec.w - 7))

  local statusLabel = card:addLabel()
    :setPosition(spec.w - 5, 1)
    :setSize(6, 1)
    :setForeground(colors.lightGray)
    :setTextAlign("right")
    :setText(spec.statusText or "")

  if spec.onTitleClick then
    titleLabel:onClick(spec.onTitleClick)
  end

  local content = card:addFrame()
    :setPosition(1, 2)
    :setSize(spec.w, spec.h - 1)
    :setBackground(colors.gray)

  local ctx = {
    w = spec.w,
    h = spec.h - 1,
    state = spec.state,
    online = spec.online and true or false,
    group = spec.group,
    key = spec.key,
    kind = spec.kind,
    name = spec.name,
    device = spec.device,
  }

  function ctx:send(action, value)
    if spec.send then
      return spec.send(action, value)
    end
    return false
  end

  function ctx:setTitle(text)
    titleLabel:setText(ha.fit(text or "", spec.w - 7))
  end

  function ctx:setStatus(text, color)
    statusLabel:setText(ha.fit(text or "", 6))
    statusLabel:setForeground(color or colors.lightGray)
  end

  function ctx:log(...)
    ha.log("widget", spec.key, ...)
  end

  addMethods(ctx, content)

  local renderer
  local sourceUsed
  local function trySource(source, name)
    if not source then
      return nil, "no source"
    end
    local env = ha.widgetEnv()
    local chunk, err = ha.compile(source, "=ha-widget-" .. tostring(name), env)
    if not chunk then
      return nil, err
    end
    local ok, result = pcall(chunk)
    if not ok then
      return nil, result
    end
    if type(result) ~= "function" then
      return nil, "widget script must return a function"
    end
    return result
  end

  local errors = {}
  renderer, sourceUsed = trySource(spec.source, spec.sourceHash or spec.key)
  if not renderer then
    errors[#errors + 1] = tostring(sourceUsed)
    content:removeChildren()
    renderer, sourceUsed = trySource(spec.fallbackSource, "fallback-" .. spec.key)
    if not renderer then
      errors[#errors + 1] = tostring(sourceUsed)
      content:removeChildren()
      renderer = genericWidget
      sourceUsed = nil
    end
  end

  local updater
  local buildOk, buildErr = pcall(function()
    updater = renderer(ctx)
    if updater ~= nil and type(updater) ~= "function" then
      error("widget renderer must return an update function or nil")
    end
  end)
  if not buildOk then
    errors[#errors + 1] = tostring(buildErr)
    ha.log("widget build failed for", spec.key, buildErr)
    content:removeChildren()
    updater = genericWidget(ctx)
  end

  local cardState = {
    key = spec.key,
    frame = card,
    height = spec.h,
    broken = false,
  }

  function cardState:update(state, online, statusText, statusColor, group)
    ctx.state = state
    ctx.online = online and true or false
    ctx.group = group
    statusLabel:setText(ha.fit(statusText or "", 6))
    statusLabel:setForeground(statusColor or colors.lightGray)
    if updater then
      local ok, err = pcall(updater, state, ctx.online, group)
      if not ok and not self.broken then
        self.broken = true
        ha.log("widget update failed for", spec.key, err)
        statusLabel:setText("ERR")
        statusLabel:setForeground(colors.red)
      end
    end
  end

  function cardState:setTitle(text)
    titleLabel:setText(ha.fit(text or "", spec.w - 7))
  end

  function cardState:setStatus(text, color)
    statusLabel:setText(ha.fit(text or "", 6))
    statusLabel:setForeground(color or colors.lightGray)
  end

  function cardState:destroy()
    card:remove()
  end

  if #errors > 0 then
    ha.log("widget problems for", spec.key, table.concat(errors, " | "))
  end

  cardState:update(
    spec.state,
    spec.online,
    spec.statusText,
    spec.statusColor,
    spec.group
  )
  return cardState
end

return shell
