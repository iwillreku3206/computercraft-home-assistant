--[[
  updater.lua - update checking and installer execution.

  Two channels:

    stable  - latest GitHub release
    nightly - the moving "nightly" prerelease built from main

  The installed version is read from /ha/version, and the installed channel
  from /ha/channel.
]]

local ha = require("ha.lib.ha")

local updater = {}

local REPO = "https://github.com/iwillreku3206/computercraft-home-assistant"

updater.CHANNEL_URLS = {
  stable = REPO .. "/releases/latest/download/update.json",
  nightly = REPO .. "/releases/download/nightly/update.json",
}

local function trim(value)
  return ha.trim(value or "")
end

local function normalizeChannel(value)
  value = trim(value):lower()
  if value == "nightly" then
    return "nightly"
  end
  return "stable"
end

function updater.currentVersion()
  local version = trim(ha.readFile("/ha/version") or "")
  version = version:gsub("^[vV]", "")
  if version == "" then
    return "0.0.0"
  end
  return version
end

function updater.installedChannel()
  return normalizeChannel(trim(ha.readFile("/ha/channel") or ""))
end

function updater.defaultChannel()
  return updater.installedChannel()
end

function updater.manifestUrl(channel)
  return updater.CHANNEL_URLS[normalizeChannel(channel)]
end

local function versionParts(value)
  local parts = {}
  for part in tostring(value):gsub("^[vV]", ""):gmatch("%d+") do
    parts[#parts + 1] = tonumber(part) or 0
  end
  return parts
end

function updater.compareVersions(a, b)
  local left, right = versionParts(a), versionParts(b)
  local count = math.max(#left, #right)
  for index = 1, count do
    local l = left[index] or 0
    local r = right[index] or 0
    if l > r then
      return 1
    elseif l < r then
      return -1
    end
  end
  return 0
end

local function fetch(url)
  if not http then
    return nil, "HTTP is disabled"
  end
  local ok, response = pcall(http.get, url)
  if not ok or not response then
    return nil, "request failed"
  end
  local data = response.readAll()
  response.close()
  if not data then
    return nil, "empty response"
  end
  return data
end

-- Returns { channel, version, notes, installer, current,
--           installedChannel, newer, switching } or nil, error.
function updater.check(channel, target)
  channel = normalizeChannel(channel)
  target = target or "client"

  local url = updater.manifestUrl(channel)
  if not url then
    return nil, "unknown update channel"
  end

  local body, err = fetch(url)
  if not body then
    return nil, err
  end

  local ok, manifest = pcall(textutils.unserializeJSON, body)
  if not ok or type(manifest) ~= "table" then
    return nil, "invalid update manifest"
  end

  local version = trim(manifest.version or "")
  if version == "" then
    return nil, "manifest has no version"
  end

  local manifestChannel = normalizeChannel(manifest.channel or channel)

  local installers = manifest.installers
  local installer
  if type(installers) == "table" then
    installer = installers[target]
  end
  if not installer then
    installer = manifest.installer
  end
  installer = trim(installer or "")

  local current = updater.currentVersion()
  local installedChannel = updater.installedChannel()
  return {
    channel = manifestChannel,
    version = version,
    notes = type(manifest.notes) == "string" and manifest.notes or "",
    installer = installer,
    current = current,
    installedChannel = installedChannel,
    newer = updater.compareVersions(version, current) > 0,
    switching = manifestChannel ~= installedChannel,
  }
end

function updater.download(url, name)
  url = trim(url)
  if url == "" then
    return nil, "no installer URL"
  end

  local body, err = fetch(url)
  if not body then
    return nil, err
  end
  if #body < 1000 then
    return nil, "download is too small to be an installer"
  end

  ha.ensureDir("/ha/update")
  local path = "/ha/update/" .. (name or "installer") .. ".lua"
  if not ha.writeFile(path, body) then
    return nil, "could not write " .. path
  end
  return path
end

function updater.install(source)
  if type(source) ~= "string" or source == "" then
    return false, "empty installer"
  end

  local env = setmetatable({
    print = function(...)
      ha.log("update", ...)
    end,
  }, { __index = _G })

  local chunk, err = ha.compile(source, "=ha-update", env)
  if not chunk then
    return false, err
  end
  local ok, result = pcall(chunk)
  if not ok then
    return false, result
  end
  return true
end

function updater.installFile(path)
  local source = ha.readFile(path)
  if not source then
    return false, "could not read " .. tostring(path)
  end
  return updater.install(source)
end

return updater
