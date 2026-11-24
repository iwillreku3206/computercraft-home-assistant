--[[
  Home Assistant client for an advanced pocket computer.

  Run as /ha.lua (installed by the client installer). The client is a shell:
  each paired device advertises a widget script, which is cached and executed
  in a small sandbox. Devices, groups, labels, favorites and filters live in
  /ha/client.cfg so every pocket computer keeps its own layout.
]]

-- Resolve /ha/... and /basalt.lua from the root regardless of shell.dir.
package.path = "/?.lua;" .. package.path

local ha = require("ha.lib.ha")
local shell = require("ha.main.widget_shell")
local updater = require("ha.lib.updater")
local basalt = ha.requireBasalt()

local CONFIG_PATH = "/ha/client.cfg"
local CACHE_DIR = "/ha/cache/widgets"
local BUILTIN_DIR = "/ha/widgets"
local clientId = os.getComputerID()

local function defaultConfig()
  return {
    version = 1,
    name = (os.getComputerLabel and os.getComputerLabel()) or ("Pocket " .. tostring(clientId)),
    network = ha.DEFAULT_NETWORK,
    channel = ha.DEFAULT_CHANNEL,
    sort = "name",
    gps = true,
    updateChannel = updater.defaultChannel(),
    favorites = {},
    labels = {},
    filters = {
      favoritesOnly = false,
      labels = {},
      showOffline = true,
    },
    devices = {},
    groups = {},
    pos = nil,
  }
end

local cfg = ha.loadConfig(CONFIG_PATH, defaultConfig())

local function normalizeConfig()
  cfg.name = ha.safeText(cfg.name, 24)
  if cfg.name == "" then
    cfg.name = "Pocket " .. tostring(clientId)
  end
  cfg.network = ha.safeText(cfg.network, 24)
  if cfg.network == "" then
    cfg.network = ha.DEFAULT_NETWORK
  end
  cfg.channel = tonumber(cfg.channel) or ha.DEFAULT_CHANNEL
  if cfg.channel < 1 or cfg.channel > 65535 then
    cfg.channel = ha.DEFAULT_CHANNEL
  end
  if cfg.sort ~= "distance" then
    cfg.sort = "name"
  end
  cfg.gps = cfg.gps ~= false
  if cfg.updateChannel ~= "stable" and cfg.updateChannel ~= "nightly" then
    cfg.updateChannel = updater.defaultChannel()
  end

  cfg.favorites = type(cfg.favorites) == "table" and cfg.favorites or {}
  cfg.filters = type(cfg.filters) == "table" and cfg.filters or {}
  cfg.filters.favoritesOnly = cfg.filters.favoritesOnly == true
  cfg.filters.showOffline = cfg.filters.showOffline ~= false
  cfg.filters.labels = type(cfg.filters.labels) == "table" and cfg.filters.labels or {}
  for label, enabled in pairs(cfg.filters.labels) do
    if not enabled then
      cfg.filters.labels[label] = nil
    end
  end

  local devices = {}
  for key, device in pairs(cfg.devices or {}) do
    local id = tonumber(key)
    if id and type(device) == "table" then
      device.id = id
      device.name = ha.safeText(device.name, 24)
      if device.name == "" then
        device.name = "Device " .. tostring(id)
      end
      device.kind = device.kind or "switch"
      device.side = device.side or "?"
      device.lastSeen = tonumber(device.lastSeen) or 0
      devices[id] = device
    end
  end
  cfg.devices = devices

  local groups = {}
  for key, group in pairs(cfg.groups or {}) do
    if type(group) == "table" then
      local gid = tostring(group.id or key)
      group.id = gid
      group.name = ha.safeText(group.name, 24)
      if group.name == "" then
        group.name = "Group"
      end
      group.value = ha.round(ha.clamp(group.value or 0, 0, 15))
      local members, seen = {}, {}
      for _, raw in ipairs(group.members or {}) do
        local id = tonumber(raw)
        if id and cfg.devices[id] and not seen[id] then
          seen[id] = true
          members[#members + 1] = id
        end
      end
      group.members = members
      groups[gid] = group
    end
  end
  cfg.groups = groups

  local labels = {}
  for key, list in pairs(cfg.labels or {}) do
    if type(list) == "table" then
      local clean, seen = {}, {}
      for _, raw in ipairs(list) do
        local label = ha.normLabel(raw)
        if label and not seen[label] then
          seen[label] = true
          clean[#clean + 1] = label
        end
      end
      if #clean > 0 then
        table.sort(clean)
        labels[key] = clean
      end
    end
  end
  cfg.labels = labels

  if type(cfg.pos) ~= "table" then
    cfg.pos = nil
  end
end

normalizeConfig()

local ownPos = cfg.pos
local modem, modemSide, modemError
local gpsLocator = ha.newGpsLocator()
local updateState = {
  checking = false,
  installing = false,
  available = nil,
  latest = nil,
  error = nil,
  doneVersion = nil,
  message = nil,
}
local discovered = {}
local widgetSources = {}
local widgetRx = {}
local lastWidgetReq = {}
local pendingPairs = {}
local pendingUnpairs = {}
local pendingUnpairAt = {}
local outbox = {}
local lastSent = {}
local lastSentAt = {}
local cards = {}
local listContentHeight = 0
local lastOrderSig = ""

local dirty = false
local stateDirty = false
local lastSave = ha.now()
local tickCount = 0
local flushTimer
local lastPairMessage = nil

local main, W, H
local clockLabel, modemLabel, sortButton, summaryLabel, updateButton
local list
local overlay
local overlayTitle, overlayBack, overlayClose
local overlayScreen, overlayArg, overlayParent
local overlayVisible = false
local overlayRenderQueued = false
local activeScroll
local activeScrollHeight = 0
local rebuildQueued = false

local function requestGpsFix()
  if cfg.gps and modem then
    gpsLocator:request(modem, modemSide, 0.75)
  end
end

local rebuildHome, scheduleRebuild, refreshAllCards, refreshCard
local renderOverlay, openScreen, closeOverlay, overlayBack
local sendRaw, sendDiscover, openModem, closeModem
local pairDevice, unpairDevice, adoptDevice, removeDevice
local ensureWidget, requestWidget, saveWidgetSource
local setGroupValue, applyGroupTarget, reconcileGroups, flushOutbox
local queueCommand, toggleDevice, setDimmerValue
local handleMessage, tick
local buildMenuScreen, buildPairScreen, buildGroupsScreen, buildGroupEditScreen
local buildFiltersScreen, buildNetworkScreen, buildDeviceScreen, buildUpdatesScreen
local startUpdateCheck, startUpdateInstall, refreshUpdateUi

local function markDirty()
  dirty = true
end

local function markStateDirty()
  stateDirty = true
end

local function saveNow()
  cfg.pos = ownPos
  ha.saveConfig(CONFIG_PATH, cfg)
  dirty = false
  stateDirty = false
  lastSave = ha.now()
end

local function defer(fn)
  basalt.schedule(function()
    os.sleep(0)
    fn()
  end)()
end

local function isOnline(device)
  return type(device) == "table"
    and type(device.lastSeen) == "number"
    and (ha.now() - device.lastSeen) < ha.OFFLINE_MS
end

local function groupOfDevice(id)
  for gid, group in pairs(cfg.groups) do
    for _, member in ipairs(group.members) do
      if member == id then
        return gid, group
      end
    end
  end
  return nil
end

local function groupStats(group)
  local online, on = 0, 0
  for _, id in ipairs(group.members) do
    local device = cfg.devices[id]
    if device then
      if isOnline(device) then
        online = online + 1
      end
      if device.value == true then
        on = on + 1
      end
    end
  end
  return online, on
end

local function groupDistance(group)
  local total, count = 0, 0
  for _, id in ipairs(group.members) do
    local distance = ha.distance(ownPos, cfg.devices[id] and cfg.devices[id].pos)
    if distance then
      total = total + distance
      count = count + 1
    end
  end
  if count == 0 then
    return nil
  end
  return total / count
end

local function deviceDistance(id)
  local device = cfg.devices[id]
  if not device then
    return nil
  end
  return ha.distance(ownPos, device.pos)
end

local function valueForCount(onCount, memberCount)
  if memberCount <= 0 then
    return 0
  end
  for value = 0, 15 do
    if ha.round(value * memberCount / 15) == onCount then
      return value
    end
  end
  return ha.round(onCount / memberCount * 15)
end

local function statusFor(item)
  -- The right-hand column is the distance; the colour carries the online
  -- state. Group distances are the average of their members.
  if item.isGroup then
    local text = item.distance and ("~" .. ha.distanceText(item.distance)) or "~?"
    local color = colors.red
    if item.onlineCount == item.members then
      color = colors.lime
    elseif item.onlineCount > 0 then
      color = colors.yellow
    end
    return ha.fit(text, 6), color
  end
  local text = ha.distanceText(item.distance)
  return ha.fit(text, 6), item.online and colors.lime or colors.red
end

local function buildItemForKey(key)
  if key:sub(1, 1) == "g" then
    local gid = key:sub(2)
    local group = cfg.groups[gid]
    if not group then
      return nil
    end
    local online, on = groupStats(group)
    local favorite = cfg.favorites[key] == true
    local item = {
      key = key,
      isGroup = true,
      groupId = gid,
      group = group,
      kind = "group_slider",
      name = group.name,
      title = (favorite and "* " or "") .. group.name,
      state = group.value,
      members = #group.members,
      onlineCount = online,
      onCount = on,
      online = online > 0,
      distance = groupDistance(group),
      groupInfo = { members = #group.members, on = on, online = online },
      labels = cfg.labels[key] or {},
    }
    item.statusText, item.statusColor = statusFor(item)
    return item
  end

  local id = tonumber(key:sub(2))
  local device = id and cfg.devices[id] or nil
  if not device then
    return nil
  end
  local favorite = cfg.favorites[key] == true
  local item = {
    key = key,
    deviceId = id,
    device = device,
    kind = device.kind,
    name = device.name,
    title = (favorite and "* " or "") .. device.name,
    state = device.value,
    online = isOnline(device),
    distance = deviceDistance(id),
    labels = cfg.labels[key] or {},
  }
  item.statusText, item.statusColor = statusFor(item)
  return item
end

local function collectItems()
  local memberOf = {}
  for gid, group in pairs(cfg.groups) do
    for _, id in ipairs(group.members) do
      memberOf[id] = gid
    end
  end

  local selectedLabels = ha.listFromSet(cfg.filters.labels)
  local items, total = {}, 0

  local function consider(key)
    local item = buildItemForKey(key)
    if not item then
      return
    end
    total = total + 1
    if not cfg.filters.showOffline and not item.online then
      return
    end
    if cfg.filters.favoritesOnly and cfg.favorites[key] ~= true then
      return
    end
    if #selectedLabels > 0 then
      local matched = false
      for _, label in ipairs(item.labels) do
        if cfg.filters.labels[label] then
          matched = true
          break
        end
      end
      if not matched then
        return
      end
    end
    items[#items + 1] = item
  end

  for id in pairs(cfg.devices) do
    if not memberOf[id] then
      consider("d" .. tostring(id))
    end
  end
  for gid in pairs(cfg.groups) do
    consider("g" .. gid)
  end

  table.sort(items, function(a, b)
    if cfg.sort == "distance" then
      if a.distance and not b.distance then
        return true
      elseif b.distance and not a.distance then
        return false
      elseif a.distance and b.distance and a.distance ~= b.distance then
        return a.distance < b.distance
      end
    end
    local an, bn = a.name:lower(), b.name:lower()
    if an == bn then
      return a.key < b.key
    end
    return an < bn
  end)

  return items, total, memberOf, selectedLabels
end

local function itemSignature(items)
  local parts = {}
  for _, item in ipairs(items) do
    parts[#parts + 1] = item.key
  end
  return table.concat(parts, "|")
end

local function builtinSource(kind)
  return ha.readFile(BUILTIN_DIR .. "/" .. tostring(kind) .. ".lua")
end

local function widgetForItem(item)
  local fallbackKind = item.isGroup and "group_slider" or item.kind
  local fallback = fallbackKind and builtinSource(fallbackKind) or nil
  if item.isGroup then
    return fallback, nil, fallback
  end
  local hash = item.device and item.device.widgetHash
  if hash then
    local source = widgetSources[hash]
    if not source then
      source = ha.readFile(CACHE_DIR .. "/" .. hash .. ".lua")
      if source then
        widgetSources[hash] = source
      end
    end
    if source then
      return source, hash, fallback
    end
  end
  return fallback, nil, fallback
end

local function cardHeight(item)
  if item.kind == "switch" then
    return 3
  end
  return 4
end

rebuildHome = function(keepOffset)
  if not list then
    return
  end
  local oldOffset = 0
  if keepOffset then
    oldOffset = select(2, list:getOffset()) or 0
  end

  list:removeChildren()
  cards = {}

  local items, total, _, selectedLabels = collectItems()
  local y = 1
  for _, item in ipairs(items) do
    local height = cardHeight(item)
    local source, sourceHash, fallback = widgetForItem(item)
    local card = shell.buildCard(list, {
      x = 1,
      y = y,
      w = W - 1,
      h = height,
      key = item.key,
      kind = item.kind,
      name = item.name,
      title = item.title,
      state = item.state,
      online = item.online,
      statusText = item.statusText,
      statusColor = item.statusColor,
      group = item.groupInfo,
      source = source,
      sourceHash = sourceHash,
      fallbackSource = fallback,
      send = function(action, value)
        local key = item.key
        if key:sub(1, 1) == "g" then
          if action == "set" then
            return setGroupValue(key:sub(2), value)
          end
        else
          local id = tonumber(key:sub(2))
          if action == "toggle" then
            return toggleDevice(id)
          elseif action == "set" then
            return setDimmerValue(id, value)
          end
        end
        return false
      end,
      onTitleClick = function()
        openScreen("device", item.key, nil)
      end,
    })
    cards[item.key] = card
    y = y + height + 1
  end

  listContentHeight = math.max(0, y - 1)
  if #items == 0 then
    list:addLabel()
      :setPosition(1, 1)
      :setSize(W - 2, 4)
      :setText("No widgets shown.\nOpen Setup to pair devices or change filters.")
    listContentHeight = 4
  end

  local maxOffset = math.max(0, listContentHeight - list:getHeight())
  if keepOffset then
    list:setOffset(0, ha.clamp(oldOffset, 0, maxOffset))
  else
    list:setOffset(0, 0)
  end

  summaryLabel:setText(ha.fit(string.format(
    "%d/%d shown%s%s",
    #items,
    total,
    cfg.filters.favoritesOnly and " *" or "",
    #selectedLabels > 0 and (" #" .. tostring(#selectedLabels)) or ""
  ), W - 2))
  sortButton:setText(cfg.sort == "distance" and "Sort:Dist" or "Sort:Name")
  lastOrderSig = itemSignature(items)
end

scheduleRebuild = function(keepOffset)
  if not basalt or rebuildQueued then
    return
  end
  rebuildQueued = true
  defer(function()
    rebuildQueued = false
    rebuildHome(keepOffset)
  end)
end

refreshCard = function(key)
  local card = cards[key]
  if not card then
    return
  end
  local item = buildItemForKey(key)
  if not item then
    return
  end
  local statusText, statusColor = statusFor(item)
  card:update(item.state, item.online, statusText, statusColor, item.groupInfo)
  card:setTitle(item.title)
end

refreshAllCards = function()
  -- Re-evaluate filters and sort order every tick. GPS moves the pocket, so
  -- distance order and distance labels can change between device hellos.
  local items = collectItems()
  if itemSignature(items) ~= lastOrderSig then
    scheduleRebuild(true)
    return
  end
  for key in pairs(cards) do
    refreshCard(key)
  end
end

local function setOwnPosition(found)
  if type(found) ~= "table" then
    return
  end
  local changed = not ownPos
    or ownPos.x ~= found.x
    or ownPos.y ~= found.y
    or ownPos.z ~= found.z
  if changed then
    ownPos = found
    markStateDirty()
    refreshAllCards()
  end
end

refreshUpdateUi = function()
  if not updateButton then
    return
  end
  local info = updateState.available
  if info then
    updateButton:setText(ha.fit("v" .. tostring(info.version), 8))
    updateButton:setBackground(colors.lime)
    updateButton:setForeground(colors.black)
    updateButton:show()
  elseif updateState.checking or updateState.installing then
    updateButton:setText("UPD...")
    updateButton:setBackground(colors.gray)
    updateButton:setForeground(colors.white)
    updateButton:show()
  else
    updateButton:hide()
  end
end

startUpdateCheck = function(manual)
  if updateState.checking or updateState.installing then
    return false
  end

  updateState.checking = true
  updateState.error = nil
  updateState.doneVersion = nil
  updateState.message = nil
  updateState.latest = nil
  updateState.available = nil
  refreshUpdateUi()
  if overlayScreen == "updates" or overlayScreen == "menu" then
    defer(renderOverlay)
  end

  basalt.schedule(function()
    local info, err = updater.check(cfg.updateChannel, "client")
    updateState.checking = false
    if info then
      updateState.latest = info
      updateState.available = (
        info.installer ~= "" and (info.newer or info.switching)
      ) and info or nil
      updateState.error = nil
    else
      updateState.latest = nil
      updateState.available = nil
      updateState.error = err or "Update check failed"
    end
    refreshUpdateUi()
    if overlayScreen == "updates" or overlayScreen == "menu" then
      defer(renderOverlay)
    end
  end)()
  return true
end

startUpdateInstall = function(info)
  if updateState.installing or not info or not info.installer or info.installer == "" then
    updateState.error = "No installer URL in the update manifest"
    refreshUpdateUi()
    defer(renderOverlay)
    return false
  end

  updateState.installing = true
  updateState.error = nil
  updateState.doneVersion = nil
  updateState.message = "Downloading update..."
  refreshUpdateUi()
  defer(renderOverlay)

  basalt.schedule(function()
    local path, err = updater.download(info.installer, "client")
    if not path then
      updateState.installing = false
      updateState.message = nil
      updateState.error = err or "Download failed"
      refreshUpdateUi()
      if overlayScreen == "updates" then
        defer(renderOverlay)
      end
      return
    end

    updateState.message = "Installing update..."
    if overlayScreen == "updates" then
      defer(renderOverlay)
    end
    local ok, installErr = updater.installFile(path)
    updateState.installing = false
    updateState.message = nil
    if ok then
      updateState.doneVersion = info.version
      updateState.available = nil
      updateState.latest = nil
      updateState.error = nil
      if info.channel then
        cfg.updateChannel = info.channel
        markDirty()
        saveNow()
      end
      ha.log("updated to", info.version)
    else
      updateState.error = installErr or "Installer failed"
      ha.log("update failed", installErr)
    end
    refreshUpdateUi()
    if overlayScreen == "updates" then
      defer(renderOverlay)
    end
  end)()
  return true
end

local function refreshDeviceCards(id)
  refreshCard("d" .. tostring(id))
  for gid, group in pairs(cfg.groups) do
    for _, member in ipairs(group.members) do
      if member == id then
        refreshCard("g" .. gid)
        break
      end
    end
  end
end

---------------------------------------------------------------------------
-- network
---------------------------------------------------------------------------

sendRaw = function(fields, to)
  if not modem then
    return false
  end
  local message = ha.newMessage(cfg.network, clientId, fields)
  if to ~= nil then
    message.to = tonumber(to) or to
  end
  local ok = ha.transmit(modem, cfg.channel, message)
  if not ok then
    modem = nil
    modemError = "modem detached"
    if modemLabel then
      modemLabel:setText("!net")
      modemLabel:setForeground(colors.red)
    end
  end
  return ok
end

sendDiscover = function()
  sendRaw({ t = "discover", name = cfg.name })
end

openModem = function()
  closeModem()
  local found, side, err = ha.openModem(cfg.channel)
  if found then
    modem, modemSide, modemError = found, side, nil
    ha.log("client modem", side, "channel", cfg.channel)
    sendDiscover()
  else
    modem, modemSide, modemError = nil, nil, err or "no modem"
  end
  if modemLabel then
    if modem then
      modemLabel:setText(ha.fit("+" .. cfg.network, 5))
      modemLabel:setForeground(colors.lime)
    else
      modemLabel:setText("!net")
      modemLabel:setForeground(colors.red)
    end
  end
end

closeModem = function(channel)
  if modem then
    pcall(modem.close, channel or cfg.channel)
  end
  modem = nil
end

queueCommand = function(id, value)
  outbox[id] = value
  if modem and not flushTimer then
    flushTimer = os.startTimer(0.2)
  end
end

flushOutbox = function()
  if not modem then
    return
  end
  local pending = outbox
  outbox = {}
  for id, value in pairs(pending) do
    local device = cfg.devices[id]
    if device and isOnline(device) then
      if sendRaw({ t = "cmd", action = "set", value = value, to = id }) then
        lastSent[id] = value
        lastSentAt[id] = ha.now()
      else
        outbox[id] = value
      end
    end
  end
end

toggleDevice = function(id)
  local device = cfg.devices[id]
  if not device or not isOnline(device) then
    return false
  end
  device.value = not device.value
  markStateDirty()
  refreshDeviceCards(id)
  if not sendRaw({ t = "cmd", action = "toggle", to = id }) then
    device.value = not device.value
    refreshDeviceCards(id)
    return false
  end
  return true
end

setDimmerValue = function(id, value)
  local device = cfg.devices[id]
  if not device or not isOnline(device) then
    return false
  end
  local level = ha.round(ha.clamp(value, 0, 15))
  device.value = level
  markStateDirty()
  queueCommand(id, level)
  refreshDeviceCards(id)
  return true
end

applyGroupTarget = function(group, sendAll)
  local members = #group.members
  if members == 0 then
    return
  end
  local targetOn = ha.round(group.value * members / 15)
  for index, id in ipairs(group.members) do
    local device = cfg.devices[id]
    if device and isOnline(device) then
      local desired = index <= targetOn
      if sendAll or device.value ~= desired then
        if not sendAll then
          if outbox[id] == desired then
            -- already pending
          elseif lastSent[id] == desired and lastSentAt[id] and ha.now() - lastSentAt[id] < 10000 then
            -- recently sent, give the device time to confirm
          else
            queueCommand(id, desired)
          end
        else
          queueCommand(id, desired)
          if device.value ~= desired then
            device.value = desired
            markStateDirty()
          end
        end
      end
    end
  end
end

reconcileGroups = function()
  for _, group in pairs(cfg.groups) do
    applyGroupTarget(group, false)
  end
end

setGroupValue = function(gid, value)
  local group = cfg.groups[gid]
  if not group then
    return false
  end
  group.value = ha.round(ha.clamp(value, 0, 15))
  markDirty()
  applyGroupTarget(group, true)
  refreshCard("g" .. gid)
  return true
end

---------------------------------------------------------------------------
-- widget transport
---------------------------------------------------------------------------

requestWidget = function(id, hash)
  if not hash then
    return
  end
  local last = lastWidgetReq[id]
  local now = ha.now()
  if last and last.hash == hash and now - last.time < 10000 then
    return
  end
  lastWidgetReq[id] = { hash = hash, time = now }
  sendRaw({ t = "widget_req", hash = hash, to = id })
end

ensureWidget = function(id, hash)
  if not hash then
    return
  end
  local device = cfg.devices[id]
  if not device then
    return
  end
  if widgetSources[hash] then
    return
  end
  local cached = ha.readFile(CACHE_DIR .. "/" .. hash .. ".lua")
  if cached then
    widgetSources[hash] = cached
    scheduleRebuild(true)
    return
  end
  if device.widgetMissingHash == hash then
    return
  end
  requestWidget(id, hash)
end

saveWidgetSource = function(hash, source)
  if ha.hash(source) ~= hash then
    ha.log("widget hash mismatch", hash)
    return false
  end
  ha.ensureDir(CACHE_DIR)
  ha.writeFile(CACHE_DIR .. "/" .. hash .. ".lua", source)
  widgetSources[hash] = source
  scheduleRebuild(true)
  return true
end

---------------------------------------------------------------------------
-- devices / pairing
---------------------------------------------------------------------------

adoptDevice = function(id)
  local entry = discovered[id] or {}
  local widgetHash = entry.widgetHash
  if not widgetHash and type(entry.widget) == "table" then
    widgetHash = entry.widget.hash
  end
  cfg.devices[id] = {
    id = id,
    name = entry.name or ("Device " .. tostring(id)),
    kind = entry.kind or "switch",
    side = entry.side or "?",
    value = entry.value,
    pos = entry.pos,
    lastSeen = entry.lastSeen or ha.now(),
    widgetHash = widgetHash,
    pairedAt = ha.now(),
  }
  pendingPairs[id] = nil
  pendingUnpairs[id] = nil
  pendingUnpairAt[id] = nil
  saveNow()
  ha.log("adopted device", id)
  ensureWidget(id, widgetHash)
  scheduleRebuild(true)
  if overlayScreen == "pair" then
    defer(renderOverlay)
  end
end

removeDevice = function(id, silent)
  cfg.devices[id] = nil
  pendingPairs[id] = nil
  lastSent[id] = nil
  lastSentAt[id] = nil
  outbox[id] = nil
  cfg.labels["d" .. tostring(id)] = nil
  cfg.favorites["d" .. tostring(id)] = nil

  for gid, group in pairs(cfg.groups) do
    local members = {}
    for _, member in ipairs(group.members) do
      if member ~= id then
        members[#members + 1] = member
      end
    end
    group.members = members
    if #members == 0 then
      cfg.groups[gid] = nil
      cfg.labels["g" .. gid] = nil
      cfg.favorites["g" .. gid] = nil
    end
  end

  saveNow()
  if not silent then
    ha.log("removed device", id)
  end
  scheduleRebuild(true)
  if overlayScreen == "device" and overlayArg == "d" .. tostring(id) then
    closeOverlay()
  end
end

pairDevice = function(id)
  if cfg.devices[id] then
    return
  end
  pendingPairs[id] = { attempts = 1, last = ha.now() }
  sendRaw({ t = "pair", name = cfg.name, to = id })
  if overlayScreen == "pair" then
    defer(renderOverlay)
  end
end

unpairDevice = function(id)
  pendingUnpairs[id] = true
  pendingUnpairAt[id] = ha.now()
  sendRaw({ t = "unpair", to = id })
  removeDevice(id, true)
end

local function pairedFlag(message)
  if type(message.paired) ~= "table" then
    return nil
  end
  for _, raw in ipairs(message.paired) do
    if tonumber(raw) == clientId then
      return true
    end
  end
  return false
end

local function handleHello(id, message)
  local entry = discovered[id]
  local isNew = entry == nil
  entry = entry or {}
  entry.name = ha.safeText(message.name, 24)
  if entry.name == "" then
    entry.name = "Device " .. tostring(id)
  end
  entry.kind = message.kind or entry.kind or "switch"
  entry.side = message.side or entry.side
  entry.lastSeen = ha.now()
  entry.value = message.value
  if type(message.pos) == "table" then
    entry.pos = message.pos
  end
  entry.open = message.open ~= false
  if type(message.widget) == "table" then
    entry.widgetHash = message.widget.hash
    entry.widget = message.widget
  end
  entry.pairedFlag = pairedFlag(message)
  discovered[id] = entry

  local device = cfg.devices[id]
  if device then
    local oldName = device.name
    local oldKind = device.kind
    local oldHash = device.widgetHash
    device.name = entry.name
    device.kind = entry.kind
    device.side = entry.side or device.side
    device.lastSeen = entry.lastSeen
    device.value = entry.value
    if entry.pos then
      device.pos = entry.pos
    end
    if entry.widgetHash then
      device.widgetHash = entry.widgetHash
    end
    markStateDirty()

    if entry.pairedFlag == false and not pendingPairs[id] then
      ha.log("device forgot this client", id)
      removeDevice(id, true)
      if isNew and overlayScreen == "pair" then
        defer(renderOverlay)
      end
      return
    end

    if pendingUnpairs[id] and entry.pairedFlag ~= false then
      sendRaw({ t = "unpair", to = id })
    end
    if entry.pairedFlag == false then
      pendingUnpairs[id] = nil
      pendingUnpairAt[id] = nil
    end

    if entry.widgetHash and entry.widgetHash ~= oldHash then
      device.widgetMissingHash = nil
      markDirty()
      scheduleRebuild(true)
    end
    if entry.widgetHash then
      ensureWidget(id, entry.widgetHash)
    end
    if oldName ~= device.name or oldKind ~= device.kind then
      markDirty()
      scheduleRebuild(true)
    end
    refreshDeviceCards(id)
  else
    if entry.pairedFlag == true and pendingPairs[id] then
      adoptDevice(id)
    elseif entry.pairedFlag == false then
      pendingUnpairs[id] = nil
    end
  end

  if isNew and overlayScreen == "pair" then
    defer(renderOverlay)
  end
end

local function handleState(id, message)
  local device = cfg.devices[id]
  if not device then
    return
  end
  local entry = discovered[id]
  if not entry then
    entry = { name = device.name, kind = device.kind }
    discovered[id] = entry
  end
  entry.lastSeen = ha.now()
  entry.value = message.value
  if type(message.pos) == "table" then
    entry.pos = message.pos
    device.pos = message.pos
  end
  device.lastSeen = entry.lastSeen
  device.value = message.value
  markStateDirty()
  refreshDeviceCards(id)
end

local function handleWidgetChunk(id, message)
  if not cfg.devices[id] then
    return
  end
  local hash = message.hash
  local index = tonumber(message.i)
  local total = tonumber(message.n)
  local data = message.data
  if type(hash) ~= "string" or not index or not total then
    return
  end
  if index < 1 or index > total or total > 128 or type(data) ~= "string" or #data > ha.WIDGET_CHUNK then
    return
  end

  local rx = widgetRx[id]
  if not rx or rx.hash ~= hash or rx.total ~= total then
    rx = { hash = hash, total = total, parts = {}, count = 0 }
    widgetRx[id] = rx
  end
  if not rx.parts[index] then
    rx.parts[index] = data
    rx.count = rx.count + 1
  end
  if rx.count == total then
    local complete = true
    for i = 1, total do
      if not rx.parts[i] then
        complete = false
        break
      end
    end
    widgetRx[id] = nil
    if complete then
      local source = table.concat(rx.parts)
      if saveWidgetSource(hash, source) then
        local device = cfg.devices[id]
        if device then
          device.widgetHash = hash
          device.widgetMissingHash = nil
          markDirty()
        end
      end
    end
  end
end

handleMessage = function(message)
  if type(message) ~= "table" or not ha.isMessage(message, cfg.network) then
    return
  end
  if message.to ~= nil and tonumber(message.to) ~= clientId then
    return
  end
  local from = tonumber(message.from)
  if not from or from == clientId then
    return
  end

  local kind = message.t
  if kind == "hello" then
    handleHello(from, message)
  elseif kind == "state" then
    handleState(from, message)
  elseif kind == "pair_ack" then
    if not cfg.devices[from] then
      adoptDevice(from)
    else
      pendingPairs[from] = nil
    end
  elseif kind == "pair_denied" then
    pendingPairs[from] = nil
    lastPairMessage = ha.safeText(message.reason or "pairing denied", 40)
    if overlayScreen == "pair" then
      defer(renderOverlay)
    end
  elseif kind == "unpaired" then
    if cfg.devices[from] then
      removeDevice(from, true)
    end
    pendingPairs[from] = nil
    pendingUnpairs[from] = nil
    pendingUnpairAt[from] = nil
  elseif kind == "widget" then
    handleWidgetChunk(from, message)
  elseif kind == "widget_none" then
    local device = cfg.devices[from]
    if device and device.widgetHash then
      device.widgetMissingHash = device.widgetHash
      markDirty()
    end
  end
end

---------------------------------------------------------------------------
-- overlay screens
---------------------------------------------------------------------------

local screenTitles = {
  menu = "Setup",
  pair = "Pair devices",
  groups = "Groups",
  group_edit = "Edit group",
  filters = "Sort & filters",
  network = "Network",
  updates = "Updates",
  device = "Details",
}

closeOverlay = function()
  overlayVisible = false
  activeScroll = nil
  activeScrollHeight = 0
  overlayScreen = nil
  overlayArg = nil
  overlayParent = nil
  overlay:clearFocusedChild()
  overlay:hide()
  saveNow()
  defer(function()
    rebuildHome(true)
    refreshAllCards()
  end)
end

overlayBack = function()
  local parent = overlayParent
  if overlayScreen == "menu" or parent == nil then
    closeOverlay()
  else
    openScreen(parent, nil, parent == "menu" and nil or "menu")
  end
end

openScreen = function(name, arg, parent)
  overlayScreen = name
  overlayArg = arg
  overlayParent = parent
  overlayVisible = true
  overlay:show()
  if not overlayRenderQueued then
    overlayRenderQueued = true
    defer(function()
      overlayRenderQueued = false
      renderOverlay()
    end)
  end
end

local function overlayHeader(title)
  overlay:removeChildren()
  overlay:clearFocusedChild()
  activeScroll = nil
  activeScrollHeight = 0

  local heading = overlay:addLabel()
    :setPosition(1, 1)
    :setSize(math.max(1, W - 9), 1)
    :setText(ha.fit(title, W - 9))
  heading:setForeground(colors.white)
  local backButton = overlay:addButton()
    :setPosition(W - 7, 1)
    :setSize(5, 1)
    :setText("Back")
  backButton:onClick(function()
    overlayBack()
  end)
  local closeButton = overlay:addButton()
    :setPosition(W - 1, 1)
    :setSize(1, 1)
    :setText("X")
  closeButton:onClick(function()
    closeOverlay()
  end)
  return overlay:addFrame()
    :setPosition(1, 2)
    :setSize(W, H - 1)
    :setBackground(colors.black)
end

local function addMenuButton(panel, y, text, action)
  local button = panel:addButton()
    :setPosition(1, y)
    :setSize(W - 2, 1)
    :setText(ha.fit(text, W - 2))
  button:onClick(action)
  return button
end

buildMenuScreen = function()
  local panel = overlayHeader(screenTitles.menu)
  local y = 1
  local newDevices = 0
  for id in pairs(discovered) do
    if not cfg.devices[id] then
      newDevices = newDevices + 1
    end
  end

  addMenuButton(panel, y, "Pair devices" .. (newDevices > 0 and (" (" .. newDevices .. ")") or ""), function()
    openScreen("pair", nil, "menu")
  end)
  y = y + 2
  addMenuButton(panel, y, "Groups (" .. tostring((function()
    local count = 0
    for _ in pairs(cfg.groups) do
      count = count + 1
    end
    return count
  end)()) .. ")", function()
    openScreen("groups", nil, "menu")
  end)
  y = y + 2
  addMenuButton(panel, y, "Sort & filters", function()
    openScreen("filters", nil, "menu")
  end)
  y = y + 2
  addMenuButton(panel, y, "Network", function()
    openScreen("network", nil, "menu")
  end)
  y = y + 2
  addMenuButton(panel, y, "Updates" .. (updateState.available and (" (v" .. updateState.available.version .. ")") or ""), function()
    openScreen("updates", nil, "menu")
  end)
  y = y + 2
  addMenuButton(panel, y, "Refresh GPS", function()
    requestGpsFix()
    sendDiscover()
  end)
  y = y + 2

  panel:addLabel()
    :setPosition(1, math.max(y, H - 4))
    :setSize(W - 2, 3)
    :setText(string.format(
      "%s / ch %d\nmodem: %s\n%d devices, %d groups",
      cfg.network,
      cfg.channel,
      modem and ("ok (" .. tostring(modemSide) .. ")") or (modemError or "missing"),
      (function()
        local count = 0
        for _ in pairs(cfg.devices) do
          count = count + 1
        end
        return count
      end)(),
      (function()
        local count = 0
        for _ in pairs(cfg.groups) do
          count = count + 1
        end
        return count
      end)()
    ))
end

buildPairScreen = function()
  local panel = overlayHeader(screenTitles.pair)
  local scan = panel:addButton()
    :setPosition(1, 1)
    :setSize(8, 1)
    :setText("Scan")
  scan:onClick(function()
    sendDiscover()
    defer(renderOverlay)
  end)

  local pairedCount = 0
  for _ in pairs(cfg.devices) do
    pairedCount = pairedCount + 1
  end
  local status = panel:addLabel()
    :setPosition(10, 1)
    :setSize(W - 11, 1)
    :setText(ha.fit(
      (lastPairMessage and (lastPairMessage .. " ") or "")
        .. tostring(pairedCount) .. " paired",
      W - 11
    ))

  local scroll = panel:addScrollableFrame()
    :setPosition(1, 3)
    :setSize(W, H - 3)
    :setBackground(colors.black)
    :setDirection("vertical")
  activeScroll = scroll
  activeScrollHeight = 0

  local unpaired = {}
  for id, entry in pairs(discovered) do
    if not cfg.devices[id] then
      unpaired[#unpaired + 1] = { id = id, entry = entry }
    end
  end
  table.sort(unpaired, function(a, b)
    return a.entry.name:lower() < b.entry.name:lower()
  end)

  local y = 1
  for _, item in ipairs(unpaired) do
    local entry = item.entry
    local id = item.id
    local online = (ha.now() - (entry.lastSeen or 0)) < ha.OFFLINE_MS
    scroll:addLabel()
      :setPosition(1, y)
      :setSize(W - 8, 1)
      :setText(ha.fit(entry.name or ("Device " .. id), W - 8))
    local meta = string.format("%s #%d", entry.kind or "?", id)
    scroll:addLabel()
      :setPosition(1, y + 1)
      :setSize(W - 8, 1)
      :setText(ha.fit(meta, W - 8))
      :setForeground(online and colors.lime or colors.red)

    local pending = pendingPairs[id] ~= nil
    local button = scroll:addButton()
      :setPosition(W - 7, y)
      :setSize(7, 1)
    if pending then
      button:setText("Wait")
      button:disable()
    elseif entry.open == false then
      button:setText("Closed")
      button:disable()
    else
      button:setText("Pair")
      button:onClick(function()
        pairDevice(id)
      end)
    end
    y = y + 3
  end

  if #unpaired == 0 then
    scroll:addLabel()
      :setPosition(1, 1)
      :setSize(W - 2, 4)
      :setText("No unpaired devices seen.\nStart the device app and make sure\nnetwork and channel match.")
    y = 5
  end
  activeScrollHeight = y
  scroll:addLabel()
    :setPosition(1, y)
    :setSize(W - 2, 1)
    :setText("Unpair from a widget's details screen.")
    :setForeground(colors.gray)
end

buildGroupsScreen = function()
  local panel = overlayHeader(screenTitles.groups)
  local add = panel:addButton()
    :setPosition(1, 1)
    :setSize(12, 1)
    :setText("New group")
  add:onClick(function()
    openScreen("group_edit", nil, "groups")
  end)

  local scroll = panel:addScrollableFrame()
    :setPosition(1, 3)
    :setSize(W, H - 3)
    :setBackground(colors.black)
    :setDirection("vertical")
  activeScroll = scroll
  activeScrollHeight = 0

  local groups = {}
  for gid, group in pairs(cfg.groups) do
    groups[#groups + 1] = group
  end
  table.sort(groups, function(a, b)
    return a.name:lower() < b.name:lower()
  end)

  local y = 1
  for _, group in ipairs(groups) do
    local online, on = groupStats(group)
    scroll:addLabel()
      :setPosition(1, y)
      :setSize(W - 8, 1)
      :setText(ha.fit(group.name, W - 8))
    scroll:addLabel()
      :setPosition(1, y + 1)
      :setSize(W - 8, 1)
      :setText(ha.fit(string.format(
        "%d%%  %d/%d on  %d/%d online",
        ha.pct(group.value),
        ha.round(group.value * #group.members / 15),
        #group.members,
        online,
        #group.members
      ), W - 8))
    local edit = scroll:addButton()
      :setPosition(W - 7, y)
      :setSize(7, 1)
      :setText("Edit")
    edit:onClick(function()
      openScreen("group_edit", group.id, "groups")
    end)
    y = y + 3
  end

  if #groups == 0 then
    scroll:addLabel()
      :setPosition(1, 1)
      :setSize(W - 2, 4)
      :setText("No groups yet.\nA group is a set of on/off switch\ndevices controlled by one slider.")
    y = 5
  end
  activeScrollHeight = y
end

buildGroupEditScreen = function()
  local panel = overlayHeader(screenTitles.group_edit)
  local gid = overlayArg
  local group = gid and cfg.groups[gid] or nil
  local selected = {}
  local memberOrder = {}
  if group then
    for _, id in ipairs(group.members) do
      selected[id] = true
      memberOrder[#memberOrder + 1] = id
    end
  end
  local function ordinalOf(id)
    for index, member in ipairs(memberOrder) do
      if member == id then
        return index
      end
    end
    return nil
  end

  local eligible = {}
  for id, device in pairs(cfg.devices) do
    if device.kind == "switch" then
      local owner = groupOfDevice(id)
      if not owner or (group and owner == group.id) then
        eligible[#eligible + 1] = device
      end
    end
  end
  table.sort(eligible, function(a, b)
    return a.name:lower() < b.name:lower()
  end)

  panel:addLabel():setPosition(1, 1):setSize(W - 2, 1):setText("Name")
  local nameInput = panel:addInput()
    :setPosition(1, 2)
    :setSize(W - 2, 1)
    :setInputLimit(24)
    :setValue(group and group.name or ("Group " .. tostring((function()
      local count = 0
      for _ in pairs(cfg.groups) do
        count = count + 1
      end
      return count + 1
    end)())))

  panel:addLabel():setPosition(1, 4):setSize(W - 2, 1):setText("Members: ^/v = order")
  local errorLabel = panel:addLabel()
    :setPosition(1, H - 4)
    :setSize(W - 2, 1)
    :setText("")
    :setForeground(colors.red)

  local listHeight = math.max(2, H - 9)
  local scroll = panel:addScrollableFrame()
    :setPosition(1, 5)
    :setSize(W, listHeight)
    :setBackground(colors.black)
    :setDirection("vertical")
  activeScroll = scroll
  activeScrollHeight = math.max(0, #eligible)

  local rows = {}
  local function refreshRows()
    for id, row in pairs(rows) do
      local position = ordinalOf(id)
      if position then
        row.toggle:setText(string.format(
          "[x] %d. %s",
          position,
          ha.fit(row.device.name, W - 11)
        ))
        row.up:show()
        row.down:show()
        row.up:enable(position > 1)
        row.down:enable(position < #memberOrder)
      else
        row.toggle:setText("[ ] " .. ha.fit(row.device.name, W - 8))
        row.up:hide()
        row.down:hide()
      end
    end
  end

  local function toggleMember(id)
    if selected[id] then
      selected[id] = nil
      for index, member in ipairs(memberOrder) do
        if member == id then
          table.remove(memberOrder, index)
          break
        end
      end
    else
      selected[id] = true
      memberOrder[#memberOrder + 1] = id
    end
    refreshRows()
  end

  local function moveMember(id, delta)
    local position = ordinalOf(id)
    if not position then
      return
    end
    local target = position + delta
    if target < 1 or target > #memberOrder then
      return
    end
    memberOrder[position], memberOrder[target] = memberOrder[target], memberOrder[position]
    refreshRows()
  end

  local y = 1
  for _, device in ipairs(eligible) do
    local toggle = scroll:addButton()
      :setPosition(1, y)
      :setSize(W - 3, 1)
    local up = scroll:addButton()
      :setPosition(W - 2, y)
      :setSize(1, 1)
      :setText("^")
    local down = scroll:addButton()
      :setPosition(W - 1, y)
      :setSize(1, 1)
      :setText("v")
    rows[device.id] = {
      device = device,
      toggle = toggle,
      up = up,
      down = down,
    }
    toggle:onClick(function()
      toggleMember(device.id)
    end)
    up:onClick(function()
      moveMember(device.id, -1)
    end)
    down:onClick(function()
      moveMember(device.id, 1)
    end)
    y = y + 1
  end
  refreshRows()
  if #eligible == 0 then
    scroll:addLabel()
      :setPosition(1, 1)
      :setSize(W - 2, 3)
      :setText("No free switch devices.\nPair a switch device first, or remove it\nfrom another group.")
  end

  local save = panel:addButton()
    :setPosition(1, H - 3)
    :setSize(group and math.floor((W - 2) / 2) or (W - 2), 1)
    :setText("Save")
  save:onClick(function()
    local name = ha.safeText(nameInput:getValue(), 24)
    if name == "" then
      errorLabel:setText("Name cannot be empty")
      return
    end
    local members = {}
    for _, id in ipairs(memberOrder) do
      if selected[id] and cfg.devices[id] then
        members[#members + 1] = id
      end
    end
    if #members == 0 then
      errorLabel:setText("Select at least one device")
      return
    end
    local on = 0
    for _, id in ipairs(members) do
      if cfg.devices[id].value == true then
        on = on + 1
      end
    end
    local targetId = group and group.id or nil
    if not targetId then
      repeat
        targetId = "g" .. tostring(ha.now()) .. "_" .. tostring(math.random(1000, 9999))
      until not cfg.groups[targetId]
    end
    cfg.groups[targetId] = {
      id = targetId,
      name = name,
      members = members,
      value = valueForCount(on, #members),
      createdAt = group and group.createdAt or ha.now(),
    }
    saveNow()
    scheduleRebuild(true)
    openScreen("groups", nil, "menu")
  end)

  if group then
    local delete = panel:addButton()
      :setPosition(math.floor((W - 2) / 2) + 2, H - 3)
      :setSize(math.ceil((W - 2) / 2), 1)
      :setText("Delete")
      :setBackground(colors.red)
    delete:onClick(function()
      cfg.groups[group.id] = nil
      cfg.labels["g" .. group.id] = nil
      cfg.favorites["g" .. group.id] = nil
      saveNow()
      scheduleRebuild(true)
      openScreen("groups", nil, "menu")
    end)
  end
end

buildFiltersScreen = function()
  local panel = overlayHeader(screenTitles.filters)
  local sort = panel:addButton()
    :setPosition(1, 1)
    :setSize(W - 2, 1)
    :setText("Sort by: " .. (cfg.sort == "distance" and "distance" or "name"))
  sort:onClick(function()
    cfg.sort = cfg.sort == "distance" and "name" or "distance"
    sort:setText("Sort by: " .. (cfg.sort == "distance" and "distance" or "name"))
    markDirty()
  end)

  local showOffline = panel:addButton()
    :setPosition(1, 3)
    :setSize(W - 2, 1)
    :setText((cfg.filters.showOffline and "[x] " or "[ ] ") .. "Show offline widgets")
  showOffline:onClick(function()
    cfg.filters.showOffline = not cfg.filters.showOffline
    showOffline:setText((cfg.filters.showOffline and "[x] " or "[ ] ") .. "Show offline widgets")
    markDirty()
  end)

  local favorites = panel:addButton()
    :setPosition(1, 5)
    :setSize(W - 2, 1)
    :setText((cfg.filters.favoritesOnly and "[x] " or "[ ] ") .. "Favorites only")
  favorites:onClick(function()
    cfg.filters.favoritesOnly = not cfg.filters.favoritesOnly
    favorites:setText((cfg.filters.favoritesOnly and "[x] " or "[ ] ") .. "Favorites only")
    markDirty()
  end)

  panel:addLabel():setPosition(1, 7):setSize(W - 2, 1):setText("Label filters")
  local clear = panel:addButton()
    :setPosition(W - 11, 7)
    :setSize(10, 1)
    :setText("Clear")
  clear:onClick(function()
    cfg.filters.labels = {}
    markDirty()
    defer(renderOverlay)
  end)

  local labels = {}
  local seen = {}
  for key, list in pairs(cfg.labels) do
    for _, label in ipairs(list) do
      if not seen[label] then
        seen[label] = true
        labels[#labels + 1] = label
      end
    end
  end
  for label in pairs(cfg.filters.labels) do
    if not seen[label] then
      seen[label] = true
      labels[#labels + 1] = label
    end
  end
  table.sort(labels)

  local scroll = panel:addScrollableFrame()
    :setPosition(1, 8)
    :setSize(W, math.max(2, H - 9))
    :setBackground(colors.black)
    :setDirection("vertical")
  activeScroll = scroll
  activeScrollHeight = math.max(0, #labels)

  local y = 1
  for _, label in ipairs(labels) do
    local button = scroll:addButton()
      :setPosition(1, y)
      :setSize(W - 1, 1)
      :setText((cfg.filters.labels[label] and "[x] " or "[ ] ") .. ha.fit(label, W - 6))
    button:onClick(function()
      if cfg.filters.labels[label] then
        cfg.filters.labels[label] = nil
      else
        cfg.filters.labels[label] = true
      end
      button:setText((cfg.filters.labels[label] and "[x] " or "[ ] ") .. ha.fit(label, W - 6))
      markDirty()
    end)
    y = y + 1
  end
  if #labels == 0 then
    scroll:addLabel()
      :setPosition(1, 1)
      :setSize(W - 2, 3)
      :setText("No labels yet. Open a widget's\ndetails screen to add labels.")
  end
end

buildNetworkScreen = function()
  local originalNetwork, originalChannel = cfg.network, cfg.channel
  local panel = overlayHeader(screenTitles.network)
  panel:addLabel():setPosition(1, 1):setSize(W - 2, 1):setText("Pocket name")
  local nameInput = panel:addInput()
    :setPosition(1, 2)
    :setSize(W - 2, 1)
    :setInputLimit(24)
    :setValue(cfg.name)

  panel:addLabel():setPosition(1, 4):setSize(W - 2, 1):setText("Network name")
  local netInput = panel:addInput()
    :setPosition(1, 5)
    :setSize(W - 2, 1)
    :setInputLimit(24)
    :setValue(cfg.network)

  panel:addLabel():setPosition(1, 7):setSize(W - 2, 1):setText("Radio channel")
  local channelInput = panel:addInput()
    :setPosition(1, 8)
    :setSize(W - 2, 1)
    :setInputLimit(5)
    :setValue(tostring(cfg.channel))

  local gpsSwitch = panel:addSwitch()
    :setPosition(W - 4, 10)
    :setSize(4, 1)
    :setValue(cfg.gps)
  panel:addLabel():setPosition(1, 10):setSize(W - 6, 1):setText("Use GPS")

  panel:addButton():setPosition(1, 12):setSize(W - 2, 1):setText("Apply"):onClick(function()
    local newName = ha.safeText(nameInput:getValue(), 24)
    if newName ~= "" then
      cfg.name = newName
    end
    local newNetwork = ha.safeText(netInput:getValue(), 24)
    if newNetwork ~= "" then
      cfg.network = newNetwork
    end
    local newChannel = tonumber(channelInput:getValue())
    if newChannel and newChannel >= 1 and newChannel <= 65535 then
      cfg.channel = math.floor(newChannel)
    end
    cfg.gps = gpsSwitch:getValue() and true or false
    local changed = cfg.network ~= originalNetwork or cfg.channel ~= originalChannel
    saveNow()
    closeModem(originalChannel)
    openModem()
    if changed then
      for _, device in pairs(cfg.devices) do
        device.lastSeen = 0
      end
      discovered = {}
    end
    requestGpsFix()
    sendDiscover()
    scheduleRebuild(true)
    openScreen("menu", nil, "menu")
  end)

  local refresh = panel:addButton()
    :setPosition(1, 13)
    :setSize(W - 2, 1)
    :setText("Refresh GPS now")
  refresh:onClick(function()
    requestGpsFix()
  end)

  panel:addLabel()
    :setPosition(1, 15)
    :setSize(W - 2, 4)
    :setText("Network and channel must match\non every device and pocket.\nModem: " .. (modem and "ok" or (modemError or "missing")))
    :setForeground(colors.gray)
end

buildUpdatesScreen = function()
  local panel = overlayHeader(screenTitles.updates)
  local current = updater.currentVersion()
  panel:addLabel()
    :setPosition(1, 1)
    :setSize(W - 2, 1)
    :setText(ha.fit("Installed: " .. current .. " (" .. updater.installedChannel() .. ")", W - 2))

  local status
  if updateState.doneVersion then
    status = "Updated to " .. updateState.doneVersion .. ". Restart with Ctrl+T."
  elseif updateState.installing then
    status = updateState.message or "Installing update..."
  elseif updateState.checking then
    status = "Checking for updates..."
  elseif updateState.error then
    status = "Error: " .. updateState.error
  elseif updateState.available then
    status = "Update " .. updateState.available.version .. " is available"
  elseif updateState.latest then
    status = "Up to date (" .. updateState.latest.version .. ")"
  else
    status = "Not checked"
  end
  panel:addLabel()
    :setPosition(1, 2)
    :setSize(W - 2, 2)
    :setText(ha.fit(status, (W - 2) * 2))
    :setForeground(updateState.error and colors.red or colors.lightGray)

  panel:addLabel():setPosition(1, 4):setSize(W - 2, 1):setText("Update channel")

  local function selectChannel(channel)
    if cfg.updateChannel == channel then
      return
    end
    cfg.updateChannel = channel
    markDirty()
    saveNow()
    updateState.doneVersion = nil
    startUpdateCheck(true)
    defer(renderOverlay)
  end

  local stable = panel:addButton()
    :setPosition(1, 5)
    :setSize(W - 2, 1)
    :setText("Stable - latest release")
  if cfg.updateChannel == "stable" then
    stable:setBackground(colors.lime)
    stable:setForeground(colors.black)
  end
  stable:onClick(function()
    selectChannel("stable")
  end)

  local nightly = panel:addButton()
    :setPosition(1, 6)
    :setSize(W - 2, 1)
    :setText("Nightly - main branch")
  if cfg.updateChannel == "nightly" then
    nightly:setBackground(colors.lime)
    nightly:setForeground(colors.black)
  end
  nightly:onClick(function()
    selectChannel("nightly")
  end)

  local check = panel:addButton()
    :setPosition(1, 8)
    :setSize(W - 2, 1)
    :setText("Check now")
  check:onClick(function()
    startUpdateCheck(true)
    defer(renderOverlay)
  end)

  local info = updateState.available
  local notes = ""
  if info then
    notes = info.notes or ""
    if notes == "" then
      notes = "A newer version is available."
    end
  elseif updateState.latest then
    notes = "No newer " .. cfg.updateChannel .. " build was found."
  end
  panel:addLabel()
    :setPosition(1, 10)
    :setSize(W - 2, 4)
    :setText(ha.fit(notes, (W - 2) * 4))
    :setForeground(colors.gray)

  if info and info.installer and info.installer ~= "" then
    local install = panel:addButton()
      :setPosition(1, 15)
      :setSize(W - 2, 1)
      :setText("Install " .. info.version)
      :setBackground(colors.lime)
      :setForeground(colors.black)
    install:onClick(function()
      startUpdateInstall(info)
    end)
  end

  panel:addLabel()
    :setPosition(1, 17)
    :setSize(W - 2, 2)
    :setText("Configs are preserved. Restart after installing.")
    :setForeground(colors.gray)
end

buildDeviceScreen = function()
  local panel = overlayHeader(screenTitles.device)
  local key = overlayArg
  if not key then
    closeOverlay()
    return
  end
  local item = buildItemForKey(key)
  if not item then
    closeOverlay()
    return
  end

  if item.isGroup then
    panel:addLabel():setPosition(1, 1):setSize(W - 2, 1):setText(ha.fit(item.name, W - 2))
    panel:addLabel():setPosition(1, 2):setSize(W - 2, 1):setText(string.format(
      "Group | %d members | %d%%",
      item.members,
      ha.pct(item.group.value)
    ))
    panel:addLabel():setPosition(1, 3):setSize(W - 2, 1):setText(string.format(
      "online %d/%d | on %d",
      item.onlineCount,
      item.members,
      item.onCount
    ))
  else
    panel:addLabel():setPosition(1, 1):setSize(W - 2, 1):setText(ha.fit(item.name, W - 2))
    panel:addLabel():setPosition(1, 2):setSize(W - 2, 1):setText(ha.fit(string.format(
      "%s | id %d | side %s",
      item.kind,
      item.deviceId,
      item.device.side or "?"
    ), W - 2))
    panel:addLabel():setPosition(1, 3):setSize(W - 2, 1):setText(ha.fit(string.format(
      "%s | %s | seen %s",
      item.online and "online" or "offline",
      ha.distanceText(item.distance),
      ha.humanAge(item.device.lastSeen)
    ), W - 2))
    panel:addLabel():setPosition(1, 4):setSize(W - 2, 1):setText(ha.fit(
      "last: " .. tostring(item.state) .. " | widget " .. tostring(item.device.widgetHash or "fallback"),
      W - 2
    ))
  end

  local favorite = panel:addButton()
    :setPosition(1, 6)
    :setSize(W - 2, 1)
    :setText((cfg.favorites[key] and "[x] Favorite" or "[ ] Favorite"))
  favorite:onClick(function()
    cfg.favorites[key] = not cfg.favorites[key] or nil
    favorite:setText((cfg.favorites[key] and "[x] Favorite" or "[ ] Favorite"))
    markDirty()
    scheduleRebuild(true)
  end)

  panel:addLabel():setPosition(1, 8):setSize(W - 2, 1):setText("Labels")
  local labelInput = panel:addInput()
    :setPosition(1, 9)
    :setSize(W - 8, 1)
    :setInputLimit(20)
    :setDefaultText("new label")
  local addLabelButton = panel:addButton()
    :setPosition(W - 7, 9)
    :setSize(7, 1)
    :setText("Add")
  addLabelButton:onClick(function()
    local label = ha.normLabel(labelInput:getValue())
    if not label then
      return
    end
    local listForKey = cfg.labels[key] or {}
    if not ha.listContains(listForKey, label) then
      listForKey[#listForKey + 1] = label
      table.sort(listForKey)
      cfg.labels[key] = listForKey
      markDirty()
      saveNow()
    end
    defer(renderOverlay)
  end)

  local labels = cfg.labels[key] or {}
  local labelScroll = panel:addScrollableFrame()
    :setPosition(1, 11)
    :setSize(W, math.max(2, H - 15))
    :setBackground(colors.black)
    :setDirection("vertical")
  activeScroll = labelScroll
  activeScrollHeight = math.max(0, #labels)

  local y = 1
  for _, label in ipairs(labels) do
    local button = labelScroll:addButton()
      :setPosition(1, y)
      :setSize(W - 1, 1)
      :setText("x " .. ha.fit(label, W - 4))
    button:onClick(function()
      local remaining = {}
      for _, value in ipairs(cfg.labels[key] or {}) do
        if value ~= label then
          remaining[#remaining + 1] = value
        end
      end
      if #remaining == 0 then
        cfg.labels[key] = nil
      else
        cfg.labels[key] = remaining
      end
      markDirty()
      saveNow()
      defer(renderOverlay)
    end)
    y = y + 1
  end
  if #labels == 0 then
    labelScroll:addLabel():setPosition(1, 1):setSize(W - 2, 2):setText("No labels")
  end

  if item.isGroup then
    local edit = panel:addButton()
      :setPosition(1, H - 3)
      :setSize(W - 2, 1)
      :setText("Edit group")
    edit:onClick(function()
      openScreen("group_edit", item.groupId, "groups")
    end)
    local delete = panel:addButton()
      :setPosition(1, H - 2)
      :setSize(W - 2, 1)
      :setText("Delete group")
      :setBackground(colors.red)
    delete:onClick(function()
      cfg.groups[item.groupId] = nil
      cfg.labels["g" .. item.groupId] = nil
      cfg.favorites["g" .. item.groupId] = nil
      saveNow()
      closeOverlay()
    end)
  else
    local unpair = panel:addButton()
      :setPosition(1, H - 4)
      :setSize(W - 2, 1)
      :setText("Unpair device")
      :setBackground(colors.red)
    unpair:onClick(function()
      unpairDevice(item.deviceId)
      closeOverlay()
    end)
  end
end

renderOverlay = function()
  if not overlayVisible or not overlayScreen then
    overlay:hide()
    return
  end
  overlay:show()
  if overlayScreen == "menu" then
    buildMenuScreen()
  elseif overlayScreen == "pair" then
    buildPairScreen()
  elseif overlayScreen == "groups" then
    buildGroupsScreen()
  elseif overlayScreen == "group_edit" then
    buildGroupEditScreen()
  elseif overlayScreen == "filters" then
    buildFiltersScreen()
  elseif overlayScreen == "network" then
    buildNetworkScreen()
  elseif overlayScreen == "updates" then
    buildUpdatesScreen()
  elseif overlayScreen == "device" then
    buildDeviceScreen()
  else
    closeOverlay()
  end
end

---------------------------------------------------------------------------
-- timers / runtime
---------------------------------------------------------------------------

local function scrollFrame(frame, delta, contentHeight)
  local _, offset = frame:getOffset()
  local maxOffset = math.max(0, (contentHeight or 0) - frame:getHeight())
  frame:setOffset(0, ha.clamp(offset + delta, 0, maxOffset))
end

tick = function()
  tickCount = tickCount + 1
  clockLabel:setText(ha.clockText())
  if dirty and ha.now() - lastSave > 2000 then
    saveNow()
  elseif stateDirty and ha.now() - lastSave > 60000 then
    saveNow()
  end

  if modem then
    modemLabel:setText(ha.fit("+" .. cfg.network, 5))
    modemLabel:setForeground(colors.lime)
  else
    modemLabel:setText("!net")
    modemLabel:setForeground(colors.red)
    if tickCount % 10 == 0 then
      openModem()
    end
  end

  requestGpsFix()

  if tickCount % ha.DISCOVER_SECONDS == 0 then
    sendDiscover()
  end

  local now = ha.now()
  for id, pending in pairs(pendingPairs) do
    if cfg.devices[id] then
      pendingPairs[id] = nil
    elseif now - pending.last >= 5000 then
      if pending.attempts >= 4 then
        pendingPairs[id] = nil
        lastPairMessage = "Pairing timed out for #" .. tostring(id)
        if overlayScreen == "pair" then
          defer(renderOverlay)
        end
      else
        pending.attempts = pending.attempts + 1
        pending.last = now
        sendRaw({ t = "pair", name = cfg.name, to = id })
      end
    end
  end

  for id in pairs(pendingUnpairs) do
    if discovered[id] and discovered[id].pairedFlag == true then
      if not pendingUnpairAt[id] or now - pendingUnpairAt[id] >= 5000 then
        pendingUnpairAt[id] = now
        sendRaw({ t = "unpair", to = id })
      end
    end
  end

  if next(outbox) and modem and not flushTimer then
    flushTimer = os.startTimer(0.2)
  end
  reconcileGroups()
  refreshAllCards()
end

---------------------------------------------------------------------------
-- UI construction
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

local title = main:addLabel()
  :setPosition(1, 1)
  :setSize(W - 6, 1)
  :setText(ha.fit("Home Assistant", W - 6))
  :setForeground(colors.white)

modemLabel = main:addLabel()
  :setPosition(W - 5, 1)
  :setSize(5, 1)
  :setTextAlign("right")
  :setText("!net")
  :setForeground(colors.red)

sortButton = main:addButton()
  :setPosition(1, 2)
  :setSize(10, 1)
  :setText("Sort:Name")
sortButton:onClick(function()
  cfg.sort = cfg.sort == "distance" and "name" or "distance"
  markDirty()
  sortButton:setText(cfg.sort == "distance" and "Sort:Dist" or "Sort:Name")
  rebuildHome(true)
end)

local filterButton = main:addButton()
  :setPosition(11, 2)
  :setSize(8, 1)
  :setText("Filters")
filterButton:onClick(function()
  openScreen("filters", nil, "menu")
end)

local setupButton = main:addButton()
  :setPosition(19, 2)
  :setSize(7, 1)
  :setText("Setup")
setupButton:onClick(function()
  openScreen("menu", nil, nil)
end)

summaryLabel = main:addLabel()
  :setPosition(1, 3)
  :setSize(W - 9, 1)
  :setText("")
  :setForeground(colors.gray)

updateButton = main:addButton()
  :setPosition(W - 8, 3)
  :setSize(8, 1)
  :setText("")
  :setBackground(colors.lime)
  :setForeground(colors.black)
  :hide()
updateButton:onClick(function()
  openScreen("updates", nil, "menu")
end)

list = main:addScrollableFrame()
  :setPosition(1, 4)
  :setSize(W, H - 4)
  :setBackground(colors.black)
  :setDirection("vertical")

local footer = main:addFrame()
  :setPosition(1, H)
  :setSize(W, 1)
  :setBackground(colors.black)
  :setForeground(colors.lightGray)
  :setZIndex(20)

clockLabel = footer:addLabel()
  :setPosition(1, 1)
  :setSize(W, 1)
  :setText(ha.clockText())
  :setTextAlign("right")
  :setForeground(colors.lightGray)

overlay = main:addFrame()
  :setPosition(1, 1)
  :setSize(W, H)
  :setBackground(colors.black)
  :setForeground(colors.white)
  :setZIndex(100)
  :hide()

openModem()
rebuildHome(false)
for id, device in pairs(cfg.devices) do
  if device.widgetHash then
    ensureWidget(id, device.widgetHash)
  end
end
clockLabel:setText(ha.clockText())

local tickTimer = os.startTimer(1)

basalt.onEvent(function(event, p1, p2, p3, p4, p5)
  if event == "modem_message" then
    local side, channel, reply, message, distance = p1, p2, p3, p4, p5
    if channel == ha.GPS_CHANNEL then
      local found = gpsLocator:handleModem(side, channel, reply, message, distance)
      if found then
        setOwnPosition(found)
      end
    elseif channel == cfg.channel and (not modemSide or side == modemSide) then
      local ok, err = pcall(handleMessage, message)
      if not ok then
        ha.log("client message error:", err)
      end
    end
    return
  elseif event == "timer" then
    local found = gpsLocator:handleTimer(p1)
    if found then
      setOwnPosition(found)
    end
    if p1 == tickTimer then
      tickTimer = os.startTimer(1)
      tick()
    elseif flushTimer and p1 == flushTimer then
      flushTimer = nil
      flushOutbox()
    end
    return
  elseif event == "key" then
    local key = p1
    if overlayVisible and activeScroll then
      if key == keys.up then
        scrollFrame(activeScroll, -2, activeScrollHeight)
        return false
      elseif key == keys.down then
        scrollFrame(activeScroll, 2, activeScrollHeight)
        return false
      elseif key == keys.pageUp then
        scrollFrame(activeScroll, -6, activeScrollHeight)
        return false
      elseif key == keys.pageDown then
        scrollFrame(activeScroll, 6, activeScrollHeight)
        return false
      end
    elseif not overlayVisible then
      if key == keys.up then
        scrollFrame(list, -2, listContentHeight)
        return false
      elseif key == keys.down then
        scrollFrame(list, 2, listContentHeight)
        return false
      elseif key == keys.pageUp then
        scrollFrame(list, -6, listContentHeight)
        return false
      elseif key == keys.pageDown then
        scrollFrame(list, 6, listContentHeight)
        return false
      elseif keys.home and key == keys.home then
        scrollFrame(list, -listContentHeight, listContentHeight)
        return false
      elseif keys["end"] and key == keys["end"] then
        scrollFrame(list, listContentHeight, listContentHeight)
        return false
      end
    end
    return
  elseif event == "terminate" then
    saveNow()
    return
  end
end)

startUpdateCheck(false)

basalt.autoUpdate()
