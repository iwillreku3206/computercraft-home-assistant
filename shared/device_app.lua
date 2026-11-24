--[[
  device_app.lua - generic Basalt application used by the switch and dimmer
  device programs.

  spec fields:
    kind             "switch" / "dimmer"
    title            display name for the window
    configPath       e.g. "/ha/switch.cfg"
    widgetPath       e.g. "/ha/widgets/switch.lua"
    defaultConfig()  returns a fresh config table
    defaultState     initial state
    sanitize(value)  returns a valid state or nil
    stateLabel(value) human readable state
    apply(side, value)  drives redstone
    clear(side)      turns a side off (used when the side changes)
    buildControl(parent, api) -> update(value)
]]

local ha = require("ha.lib.ha")
local updater = require("ha.lib.updater")
local basalt = ha.requireBasalt()

return function(spec)
  local cfg = ha.loadConfig(spec.configPath, spec.defaultConfig())
  cfg.id = os.getComputerID()
  cfg.kind = spec.kind
  cfg.paired = type(cfg.paired) == "table" and cfg.paired or {}
  cfg.name = ha.safeText(cfg.name, 24)
  if cfg.name == "" then
    cfg.name = spec.defaultName or (spec.title .. " " .. tostring(cfg.id))
  end
  cfg.network = ha.safeText(cfg.network, 24)
  if cfg.network == "" then
    cfg.network = ha.DEFAULT_NETWORK
  end
  cfg.channel = tonumber(cfg.channel) or ha.DEFAULT_CHANNEL
  if cfg.channel < 1 or cfg.channel > 65535 then
    cfg.channel = ha.DEFAULT_CHANNEL
  end
  cfg.pairingOpen = cfg.pairingOpen ~= false
  cfg.gps = cfg.gps ~= false
  cfg.updateUrl = ha.safeText(cfg.updateUrl or "", 200)
  if cfg.updateUrl == "" then
    cfg.updateUrl = updater.defaultUrl()
  end
  if not ha.validSide(cfg.side) then
    cfg.side = ha.sides()[1] or "top"
  end

  local state = spec.sanitize(cfg.state)
  if state == nil then
    state = spec.defaultState
  end

  local network = cfg.network
  local channel = cfg.channel
  local modem, modemSide, modemError
  local appliedSide
  local position
  local gpsLocator = ha.newGpsLocator()
  local dirty = false
  local lastWidgetSend = {}
  local widgetSource = ha.readFile(spec.widgetPath)
  local widgetHash = widgetSource and ha.hash(widgetSource) or nil
  local main
  local W, H
  local labels = {}
  local updateState = {
    checking = false,
    installing = false,
    available = nil,
    error = nil,
    doneVersion = nil,
  }
  local updateControl
  local updateButton
  local startUpdateInstall
  local updateMainUi
  local openConfig
  local configOverlay

  local function saveNow()
    cfg.state = state
    ha.saveConfig(spec.configPath, cfg)
    dirty = false
  end

  local function markDirty()
    dirty = true
  end

  local function applyState()
    if appliedSide and appliedSide ~= cfg.side then
      pcall(spec.clear, appliedSide)
      appliedSide = nil
    end
    local ok, err = pcall(spec.apply, cfg.side, state)
    if ok then
      appliedSide = cfg.side
      labels.applyError = nil
    else
      labels.applyError = tostring(err)
      ha.log("redstone apply failed:", err)
    end
  end

  local function pairedIds()
    local ids = {}
    for id, _ in pairs(cfg.paired) do
      ids[#ids + 1] = tonumber(id) or id
    end
    table.sort(ids, function(a, b)
      return tostring(a) < tostring(b)
    end)
    return ids
  end

  local function message(fields)
    return ha.newMessage(network, cfg.id, fields)
  end

  local function send(fields, to)
    if not modem then
      return false
    end
    if to ~= nil then
      fields.to = tonumber(to) or to
    end
    local ok = ha.transmit(modem, channel, message(fields))
    if not ok then
      modem = nil
      modemError = "modem detached"
      updateMainUi()
    end
    return ok
  end

  local function helloMessage(to)
    return message({
      t = "hello",
      to = to and (tonumber(to) or to) or nil,
      kind = spec.kind,
      name = cfg.name,
      side = cfg.side,
      value = state,
      pos = position,
      open = cfg.pairingOpen,
      paired = pairedIds(),
      widget = widgetHash and { hash = widgetHash, len = #widgetSource } or nil,
      appVersion = 1,
    })
  end

  local function sendHello(to)
    if not modem then
      return
    end
    local ok = ha.transmit(modem, channel, helloMessage(to))
    if not ok then
      modem = nil
      modemError = "modem detached"
      updateMainUi()
    end
  end

  local function sendState(to)
    send({
      t = "state",
      kind = spec.kind,
      value = state,
      pos = position,
    }, to)
  end

  local function sendWidget(client)
    if not widgetSource then
      send({ t = "widget_none" }, client)
      return
    end
    local total = math.max(1, math.ceil(#widgetSource / ha.WIDGET_CHUNK))
    for index = 1, total do
      local data = widgetSource:sub((index - 1) * ha.WIDGET_CHUNK + 1, index * ha.WIDGET_CHUNK)
      send({
        t = "widget",
        hash = widgetHash,
        i = index,
        n = total,
        data = data,
      }, client)
    end
    send({ t = "widget_end", hash = widgetHash, n = total }, client)
  end

  local function ensureModem()
    if modem then
      return true
    end
    local found, side, err = ha.openModem(channel)
    if found then
      modem, modemSide, modemError = found, side, nil
      ha.log("modem ready on", side, "channel", channel)
      updateMainUi()
      sendHello()
      return true
    end
    modemError = err or "no modem"
    updateMainUi()
    return false
  end

  local function closeModem()
    if modem then
      pcall(modem.close, channel)
    end
    modem = nil
  end

  local function setValue(value, options)
    local clean = spec.sanitize(value)
    if clean == nil then
      return false
    end
    options = options or {}
    if clean == state and not options.force then
      if options.reply then
        sendState(options.reply)
      end
      return true
    end
    state = clean
    cfg.state = clean
    applyState()
    markDirty()
    updateMainUi()
    sendState(options.reply)
    return true
  end

  local function forgetClient(id)
    id = tonumber(id) or id
    if cfg.paired[id] then
      cfg.paired[id] = nil
      saveNow()
      send({ t = "unpaired" }, id)
      sendHello()
      ha.log("forgot client", id)
    end
  end

  local function handleMessage(msg)
    if type(msg) ~= "table" then
      return
    end
    if not ha.isMessage(msg, network) then
      return
    end
    if msg.to ~= nil and tonumber(msg.to) ~= cfg.id then
      return
    end
    local from = tonumber(msg.from)
    if not from or from == cfg.id then
      return
    end

    local kind = msg.t
    if kind == "discover" then
      sendHello(from)
    elseif kind == "pair" then
      if cfg.pairingOpen or cfg.paired[from] then
        cfg.paired[from] = {
          name = ha.safeText(msg.name or ("Pocket " .. tostring(from)), 24),
          at = ha.now(),
        }
        saveNow()
        send({ t = "pair_ack" }, from)
        sendHello(from)
        ha.log("paired client", from)
      else
        send({ t = "pair_denied", reason = "pairing closed" }, from)
      end
    elseif kind == "unpair" then
      if cfg.paired[from] then
        cfg.paired[from] = nil
        saveNow()
        send({ t = "unpaired" }, from)
        sendHello()
        ha.log("client unpair", from)
      end
    elseif kind == "cmd" then
      if not cfg.paired[from] then
        return
      end
      if msg.action == "toggle" then
        setValue(not state, { reply = from })
      elseif msg.action == "set" then
        setValue(msg.value, { reply = from })
      end
    elseif kind == "widget_req" then
      if not cfg.paired[from] then
        return
      end
      local now = ha.now()
      if lastWidgetSend[from] and now - lastWidgetSend[from] < 3000 then
        return
      end
      lastWidgetSend[from] = now
      if msg.hash ~= nil and msg.hash ~= widgetHash then
        send({ t = "widget_none" }, from)
      else
        sendWidget(from)
      end
    end
  end

  function updateMainUi()
    if not main then
      return
    end
    labels.name:setText(ha.fit(cfg.name, W - 2))
    labels.kind:setText(string.format("%s | side: %s", spec.kind, cfg.side))
    labels.net:setText(string.format("%s / ch %d", cfg.network, cfg.channel))
    labels.pair:setText(string.format(
      "paired: %d | pairing %s",
      #pairedIds(),
      cfg.pairingOpen and "open" or "closed"
    ))
    labels.widget:setText("widget: " .. (widgetHash and widgetHash or "missing"))
    if modem then
      labels.modem:setText("modem " .. tostring(modemSide) .. ": ok")
      labels.modem:setForeground(colors.lime)
    else
      labels.modem:setText("NO MODEM: " .. ha.fit(modemError or "not found", W - 12))
      labels.modem:setForeground(colors.red)
    end
    labels.state:setText(spec.stateLabel(state))
    if labels.applyError then
      labels.error:setText("redstone error: " .. ha.fit(labels.applyError, W - 16))
      labels.error:show()
    else
      labels.error:hide()
    end
    if updateControl then
      local ok, err = pcall(updateControl, state)
      if not ok then
        ha.log("control update failed:", err)
      end
    end
  end

  local function applyGpsFix(found)
    if type(found) ~= "table" then
      return
    end
    local changed = not position
      or position.x ~= found.x
      or position.y ~= found.y
      or position.z ~= found.z
    if changed then
      position = found
      sendHello()
      updateMainUi()
    end
  end

  local function buildConfigOverlay()
    local overlay = main:addFrame()
      :setPosition(1, 1)
      :setSize(W, H)
      :setBackground(colors.black)
      :setForeground(colors.white)
      :setZIndex(100)
      :hide()

    local content = overlay
    content:addLabel():setPosition(1, 1):setSize(W - 2, 1):setText("Configure " .. spec.title)
    content:addButton():setPosition(W - 1, 1):setSize(1, 1):setText("X"):onClick(function()
      content:clearFocusedChild()
      overlay:hide()
    end)

    content:addLabel():setPosition(1, 3):setSize(W - 2, 1):setText("Name")
    local nameInput = content:addInput()
      :setPosition(1, 4)
      :setSize(W - 2, 1)
      :setInputLimit(24)
      :setValue(cfg.name)

    local pendingSide = cfg.side
    content:addLabel():setPosition(1, 5):setSize(W - 2, 1):setText("Redstone side")
    local sideButton = content:addButton()
      :setPosition(1, 6)
      :setSize(W - 2, 1)
      :setText("Side: " .. pendingSide)
    sideButton:onClick(function()
      pendingSide = ha.nextSide(pendingSide, 1)
      sideButton:setText("Side: " .. pendingSide)
    end)

    content:addLabel():setPosition(1, 7):setSize(W - 2, 1):setText("Network name")
    local netInput = content:addInput()
      :setPosition(1, 8)
      :setSize(W - 2, 1)
      :setInputLimit(24)
      :setValue(cfg.network)

    content:addLabel():setPosition(1, 9):setSize(W - 2, 1):setText("Radio channel")
    local channelInput = content:addInput()
      :setPosition(1, 10)
      :setSize(W - 2, 1)
      :setInputLimit(5)
      :setValue(tostring(cfg.channel))

    local pairingSwitch = content:addSwitch()
      :setPosition(W - 4, 11)
      :setSize(4, 1)
      :setValue(cfg.pairingOpen)
    content:addLabel():setPosition(1, 11):setSize(W - 6, 1):setText("Allow new pairing")

    local gpsSwitch = content:addSwitch()
      :setPosition(W - 4, 12)
      :setSize(4, 1)
      :setValue(cfg.gps)
    content:addLabel():setPosition(1, 12):setSize(W - 6, 1):setText("Use GPS")

    content:addButton():setPosition(1, 14):setSize(math.floor((W - 2) / 2), 1):setText("Save"):onClick(function()
      local name = ha.safeText(nameInput:getValue(), 24)
      if name ~= "" then
        cfg.name = name
      end
      local net = ha.safeText(netInput:getValue(), 24)
      if net ~= "" then
        cfg.network = net
      end
      local ch = tonumber(channelInput:getValue())
      if ch and ch >= 1 and ch <= 65535 then
        cfg.channel = math.floor(ch)
      end
      cfg.pairingOpen = pairingSwitch:getValue() and true or false
      cfg.gps = gpsSwitch:getValue() and true or false

      local channelChanged = cfg.channel ~= channel
      local sideChanged = cfg.side ~= pendingSide
      local networkChanged = cfg.network ~= network

      cfg.side = pendingSide
      network = cfg.network
      saveNow()
      if channelChanged then
        closeModem()
        channel = cfg.channel
        ensureModem()
      end
      if sideChanged then
        applyState()
      end
      if networkChanged or sideChanged or channelChanged then
        sendHello()
      end
      content:clearFocusedChild()
      overlay:hide()
      updateMainUi()
    end)

    content:addButton():setPosition(math.floor((W - 2) / 2) + 2, 14):setSize(math.ceil((W - 2) / 2), 1):setText("Cancel"):onClick(function()
      content:clearFocusedChild()
      overlay:hide()
    end)

    content:addLabel():setPosition(1, 16):setSize(W - 2, 1):setText("Paired pocket computers")
    local y = 17
    local clients = pairedIds()
    local shown = 0
    for _, id in ipairs(clients) do
      if y <= H - 1 then
        local entry = cfg.paired[id]
        content:addLabel():setPosition(1, y):setSize(W - 4, 1):setText(
          ha.fit(tostring(id) .. " " .. ha.safeText(entry and entry.name or "", 20), W - 4)
        )
        content:addButton():setPosition(W - 2, y):setSize(1, 1):setText("X"):onClick(function()
          forgetClient(id)
          content:clearFocusedChild()
          overlay:hide()
          basalt.schedule(function()
            os.sleep(0)
            openConfig()
          end)()
        end)
        shown = shown + 1
        y = y + 1
      end
    end
    if shown == 0 then
      content:addLabel():setPosition(1, y):setSize(W - 2, 1):setText("none")
    elseif shown < #clients then
      content:addLabel():setPosition(1, y):setSize(W - 2, 1):setText("+" .. (#clients - shown) .. " more")
    end

    return overlay
  end

  function openConfig()
    if configOverlay then
      configOverlay:remove()
      configOverlay = nil
    end
    configOverlay = buildConfigOverlay()
    configOverlay:show()
    updateMainUi()
  end

  ---------------------------------------------------------------------------
  -- UI
  ---------------------------------------------------------------------------

  main = basalt.createFrame()
  main:setTheme({
    BaseFrameBG = colors.black,
    BaseFrameText = colors.lightGray,
    FrameBG = colors.black,
    FrameText = colors.lightGray,
    ButtonBG = colors.gray,
    ButtonText = colors.white,
    InputBG = colors.gray,
    InputText = colors.white,
    SwitchBG = colors.gray,
    SwitchText = colors.white,
    LabelBG = false,
    LabelText = colors.lightGray,
    SliderBG = false,
    SliderText = colors.gray,
    SliderSymbolColor = colors.white,
  })
  W, H = main:getSize()

  labels.name = main:addLabel():setPosition(1, 1):setSize(W - 2, 1):setText(cfg.name)
  labels.kind = main:addLabel():setPosition(1, 2):setSize(W - 2, 1):setText("")
  labels.net = main:addLabel():setPosition(1, 3):setSize(W - 2, 1):setText("")
  labels.modem = main:addLabel():setPosition(1, 4):setSize(W - 2, 1):setText("")
  labels.state = main:addLabel():setPosition(1, 6):setSize(W - 2, 2):setText("")
  labels.pair = main:addLabel():setPosition(1, H - 2):setSize(W - 2, 1):setText("")
  labels.widget = main:addLabel():setPosition(1, H - 1):setSize(W - 2, 1):setText("")
  labels.error = main:addLabel():setPosition(1, H - 3):setSize(W - 2, 1):setText("")
  labels.error:hide()

  local controlFrame = main:addFrame()
    :setPosition(1, 8)
    :setSize(W, 3)
    :setBackground(colors.black)

  local api = {
    w = W - 2,
    h = 3,
    getValue = function()
      return state
    end,
    setValue = function(value)
      setValue(value)
    end,
    apply = function()
      applyState()
    end,
  }
  updateControl = spec.buildControl(controlFrame, api)

  main:addButton():setPosition(1, 12):setSize(W - 2, 1):setText("Configure"):onClick(function()
    openConfig()
  end)

  labels.update = main:addLabel()
    :setPosition(1, 13)
    :setSize(W - 2, 1)
    :setText("")
    :setForeground(colors.lime)
  labels.update:hide()

  updateButton = main:addButton()
    :setPosition(1, 14)
    :setSize(W - 2, 1)
    :setText("")
    :setBackground(colors.lime)
    :setForeground(colors.black)
    :hide()
  updateButton:onClick(function()
    if updateState.available then
      startUpdateInstall(updateState.available)
    end
  end)

  local function refreshUpdateUi()
    if updateState.available then
      labels.update:setText(ha.fit("Update " .. updateState.available.version .. " available", W - 2))
      labels.update:setForeground(colors.lime)
      labels.update:show()
      updateButton:setText(ha.fit("Install " .. updateState.available.version, W - 2))
      updateButton:show()
    elseif updateState.installing then
      labels.update:setText("Installing update...")
      labels.update:setForeground(colors.yellow)
      labels.update:show()
      updateButton:hide()
    elseif updateState.checking then
      labels.update:setText("Checking for updates...")
      labels.update:setForeground(colors.gray)
      labels.update:show()
      updateButton:hide()
    elseif updateState.doneVersion then
      labels.update:setText("Updated to " .. updateState.doneVersion .. ". Restart.")
      labels.update:setForeground(colors.lime)
      labels.update:show()
      updateButton:hide()
    else
      labels.update:hide()
      updateButton:hide()
    end
  end

  local function startUpdateCheck()
    if updateState.checking or updateState.installing or cfg.updateUrl == "" then
      return
    end
    updateState.checking = true
    updateState.doneVersion = nil
    updateState.error = nil
    refreshUpdateUi()
    basalt.schedule(function()
      local info, err = updater.check(cfg.updateUrl, spec.kind)
      updateState.checking = false
      if info then
        updateState.available = (info.newer and info.installer ~= "") and info or nil
        updateState.error = nil
      else
        updateState.available = nil
        updateState.error = err or "Update check failed"
        ha.log("update check failed:", updateState.error)
      end
      refreshUpdateUi()
    end)()
  end

  startUpdateInstall = function(info)
    if updateState.installing or not info or not info.installer or info.installer == "" then
      return
    end
    updateState.installing = true
    updateState.error = nil
    updateState.doneVersion = nil
    refreshUpdateUi()
    basalt.schedule(function()
      local path, err = updater.download(info.installer, spec.kind)
      if not path then
        updateState.installing = false
        updateState.error = err or "Download failed"
        ha.log("update download failed:", updateState.error)
        refreshUpdateUi()
        return
      end
      local ok, installErr = updater.installFile(path)
      updateState.installing = false
      if ok then
        updateState.available = nil
        updateState.doneVersion = info.version
        updateState.error = nil
        ha.log("updated to", info.version)
      else
        updateState.error = installErr or "Installer failed"
        ha.log("update install failed:", updateState.error)
      end
      refreshUpdateUi()
    end)()
  end

  ---------------------------------------------------------------------------
  -- runtime
  ---------------------------------------------------------------------------

  applyState()
  saveNow()
  ensureModem()

  local timer = os.startTimer(1)
  local ticks = 0

  local function tick()
    ticks = ticks + 1
    if dirty then
      saveNow()
    end
    if not modem and ticks % 10 == 0 then
      ensureModem()
    end
    if ticks % ha.HEARTBEAT_SECONDS == 0 then
      sendHello()
    end
    if cfg.gps and modem and ticks % 5 == 0 then
      gpsLocator:request(modem, modemSide, 1)
    end
  end

  basalt.onEvent(function(event, p1, p2, p3, p4, p5)
    if event == "modem_message" then
      local side, messageChannel, replyChannel, msg, distance = p1, p2, p3, p4, p5
      if messageChannel == ha.GPS_CHANNEL then
        local found = gpsLocator:handleModem(
          side,
          messageChannel,
          replyChannel,
          msg,
          distance
        )
        if found then
          applyGpsFix(found)
        end
      elseif messageChannel == channel and (not modemSide or side == modemSide) then
        local ok, err = pcall(handleMessage, msg)
        if not ok then
          ha.log("message error:", err)
        end
      end
      return
    elseif event == "timer" then
      local found = gpsLocator:handleTimer(p1)
      if found then
        applyGpsFix(found)
      end
      if p1 == timer then
        timer = os.startTimer(1)
        tick()
      end
      return
    elseif event == "terminate" then
      saveNow()
      return
    end
  end)

  updateMainUi()
  sendHello()
  if cfg.updateUrl ~= "" then
    startUpdateCheck()
  end
  basalt.autoUpdate()
end
