# Creating your own device

A device is a ComputerCraft program plus a Lua widget script. The program owns
the hardware and the state; the widget script is sent to the pocket computer
and rendered inside a card. The pocket has no device-specific code, so a new
device type does not require changing the client.

This guide covers the supported path: reuse `shared/device_app.lua` and write a
widget. It also documents the wire protocol for devices that do not use the
shared app.

## 1. What the client requires

- A **kind** string (for example `fan`). The client stores it with the device
  and uses it for three things only:
  - the fallback widget path `/ha/widgets/<kind>.lua` on the pocket,
  - card height (`switch` cards are 3 rows; every other kind gets 4),
  - group membership (only `kind == "switch"` devices can be grouped).
- A state value that survives `textutils.serialize` (boolean or number).
- Support for two commands: `toggle` and `set`.
  - `ctx:send("set", value)` always reaches the device as an **integer 0-15**;
    the client clamps and rounds it.
  - Group reconciliation sends `set` with a **boolean** to switch members.
  - `toggle` means "the device decides the next state". `device_app.lua`
    implements it as `setValue(not state)`, which is only meaningful for
    boolean states; for anything else, use `set`.
- Commands are only sent while the client considers the device online (a
  hello/state within the last 15 seconds). A device must therefore keep
  heartbeating.
- One device app per computer, because the device ID is the computer ID and
  every app uses the same modem channel.

## 2. Reusing the shared device app

`device_app.lua` already implements pairing, heartbeat, GPS, widget chunk
transport, config persistence and a Basalt screen with a Configure overlay. A
device app is a table of hardware-specific callbacks.

### Spec fields

| Field | Meaning |
|---|---|
| `kind` | Client-facing kind string; also the fallback widget name |
| `title` | Heading used by the Configure overlay |
| `defaultName` | Name used until the user renames the device |
| `configPath` | Per-kind config file, e.g. `/ha/fan.cfg` |
| `widgetPath` | Where this computer keeps its widget script |
| `defaultConfig()` | Fresh config table (include `version = 1`) |
| `defaultState` | Initial state |
| `sanitize(value)` | Return a valid state, or `nil` to reject |
| `stateLabel(value)` | Text shown on the device screen |
| `apply(side, value)` | Drive the hardware for a state |
| `clear(side)` | Switch a side off when the side changes |
| `buildControl(parent, api)` | Build the local controls; return `update(value)` |

`api` provides `w`/`h`, `getValue()`, `setValue(value)` and `apply()`. Call
`setValue` from UI callbacks: it sanitizes, persists, drives the hardware,
refreshes the screen and broadcasts a `state` message.

`update(value)` is called after every state change, including remote commands;
use it to refresh the controls you built. Do not rebuild controls inside it.

### Example: a four-step fan

`fan/app.lua`:

```lua
-- Resolve /ha/... and /basalt.lua from the root regardless of shell.dir.
package.path = "/?.lua;" .. package.path

local ha = require("ha.lib.ha")
local run = require("ha.lib.device_app")

local LEVELS = {
  { value = 0, label = "Off" },
  { value = 5, label = "Low" },
  { value = 10, label = "Med" },
  { value = 15, label = "High" },
}

local function levelName(value)
  for _, level in ipairs(LEVELS) do
    if level.value == value then
      return level.label
    end
  end
  return tostring(value)
end

run({
  kind = "fan",
  title = "Fan",
  defaultName = "Fan " .. tostring(os.getComputerID()),
  configPath = "/ha/fan.cfg",
  widgetPath = "/ha/widgets/fan.lua",

  defaultConfig = function()
    return {
      version = 1,
      id = os.getComputerID(),
      kind = "fan",
      name = "Fan " .. tostring(os.getComputerID()),
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

  -- Accept 0-15 (from the widget) and booleans (from group-style set
  -- commands), then snap to the nearest physical step.
  sanitize = function(value)
    if type(value) == "boolean" then
      return value and 15 or 0
    end
    local number = tonumber(value)
    if number == nil then
      return nil
    end
    number = ha.clamp(number, 0, 15)
    local best = 0
    for _, level in ipairs(LEVELS) do
      if math.abs(number - level.value) < math.abs(number - best) then
        best = level.value
      end
    end
    return best
  end,

  stateLabel = function(value)
    return string.format("Fan: %s (%d/15)", levelName(value), value)
  end,

  apply = function(side, value)
    redstone.setAnalogOutput(side, value)
  end,

  clear = function(side)
    redstone.setAnalogOutput(side, 0)
  end,

  buildControl = function(parent, api)
    local buttons = {}
    local width = math.floor(api.w / #LEVELS)

    for index, level in ipairs(LEVELS) do
      local button = parent:addButton()
        :setPosition((index - 1) * width + 1, 1)
        :setSize(index == #LEVELS and (api.w - width * (#LEVELS - 1)) or width, 1)
        :setText(level.label)
      button:onClick(function()
        api.setValue(level.value)
      end)
      buttons[#buttons + 1] = button
    end

    return function(value)
      for index, level in ipairs(LEVELS) do
        buttons[index]:setBackground(
          level.value == value and colors.green or colors.gray
        )
      end
    end
  end,
})
```

The app must be the program the user runs, so install it as `/fan.lua` and
make it the entry point. `switch/app.lua` and `dimmer/app.lua` are the same
shape and can be used as references.

### Example: the widget

`fan/widget.lua` (installed on the device at `/ha/widgets/fan.lua`, and on the
pocket as the fallback):

```lua
-- Widget script sent by a fan device to the pocket computer.
return function(ctx)
  local levels = {
    { value = 0, label = "Off" },
    { value = 5, label = "Low" },
    { value = 10, label = "Med" },
    { value = 15, label = "High" },
  }

  local stateLabel = ctx:addLabel()
    :setPosition(1, 1)
    :setSize(ctx.w, 1)
    :setText("")

  local buttons = {}
  local width = math.floor(ctx.w / #levels)

  for index, level in ipairs(levels) do
    local button = ctx:addButton()
      :setPosition((index - 1) * width + 1, 2)
      :setSize(index == #levels and (ctx.w - width * (#levels - 1)) or width, 1)
      :setText(level.label)
    button:onClick(function()
      if ctx.online then
        ctx:send("set", level.value)
      end
    end)
    buttons[index] = button
  end

  local function update(state, online)
    local value = tonumber(state) or 0
    for _, button in ipairs(buttons) do
      if online then
        button:enable()
      else
        button:disable()
      end
    end
    stateLabel:setText(string.format("Level %d/15", value))
    stateLabel:setForeground(online and colors.lightGray or colors.red)
  end

  update(ctx.state, ctx.online)
  return update
end
```

## 3. Widget contract

The source is compiled in a sandbox and called once per card. It must return
the renderer:

```lua
return function(ctx)
  -- create controls here
  return function(state, online, group)
    -- update the controls
  end
end
```

The update function is optional. It runs on every state/online change and
about once per second as the client refreshes its cards. Mutate the controls
you created; do not create new ones.

### Context

| Field/method | Meaning |
|---|---|
| `ctx.w`, `ctx.h` | Card content size in cells |
| `ctx.state` | Current device state |
| `ctx.online` | Device within the 15-second online window |
| `ctx.group` | Group cards only: `{ members, on, online }` |
| `ctx.kind`, `ctx.name`, `ctx.key`, `ctx.device` | Card identity (read only) |
| `ctx:send(action, value)` | Send `toggle` or `set` to the device |
| `ctx:setTitle(text)`, `ctx:setStatus(text, color)` | Card header overrides |
| `ctx:log(...)` | Write to `/ha/debug.log` on the pocket |
| `ctx:addButton/Label/Frame/Switch/Slider/Input/Checkbox/Progressbar/List/Dropdown` | Basalt controls inside the card |

Widgets can use `math`, `string`, `table`, `coroutine`, `colors`, `textutils`,
`bit32` and a reduced `os` (`time`, `day`, `date`, `epoch`, `clock`). There is
no filesystem, shell, HTTP, peripheral or redstone access, and **no
`os.sleep`**. Treat this as a convenience boundary, not security: the client
only compiles widgets from paired devices.

### Layout

- `ctx.h` is the content height: 2 rows for `kind == "switch"`, 3 rows for
  every other kind. Controls positioned outside it are clipped.
- The card title and online/distance status occupy the row above the content.
- Keep widgets small. The device sends source in 4 KiB chunks and the client
  rejects more than 128 chunks (512 KiB); a few KiB is the practical size.

### Fallback behaviour

If the device is offline or has not yet sent its widget, the client reads
`/ha/widgets/<kind>.lua` on the pocket. Without that file it shows a generic
"Widget script unavailable" card with the last state. Install the widget on
both the device (so it can be served) and the pocket (so offline cards still
work).

## 4. Wire protocol for standalone devices

A device that does not use `device_app.lua` must implement the following.
`/ha/lib/ha.lua` provides `newMessage`, `isMessage`, `openModem`, `transmit`,
`hash`, `readFile`, `newGpsLocator` and the constants (`PROTO`, `VERSION`,
`DEFAULT_CHANNEL`, `DEFAULT_NETWORK`, `HEARTBEAT_SECONDS`, `OFFLINE_MS`,
`WIDGET_CHUNK`).

| Direction | Message | Required behaviour |
|---|---|---|
| client → device | `discover` | Reply with `hello` addressed to the sender |
| device → client | `hello` | Include `kind`, `name`, `side`, `value`, `pos`, `open`, `paired` (array of client IDs), `widget = { hash, len }` |
| client → device | `pair` | If pairing is open or the client is already paired, store the client, save, send `pair_ack`, then a `hello`; otherwise `pair_denied` with `reason` |
| client → device | `unpair` | Forget the client, send `unpaired`, then `hello` |
| client → device | `cmd` | Ignore unless the sender is paired. `toggle` flips a two-state device; `set` applies `value` |
| client → device | `widget_req` | Send `widget` chunks (`hash`, `i`, `n`, `data`) then `widget_end`; send `widget_none` if the requested hash is unknown |
| device → client | `state` | Send after every state change with `value` and `pos` |

Additional rules:

- Wrap payloads with `ha.newMessage(network, computerID, fields)` so `p`, `v`,
  `net`, `from` and `ts` are set, and transmit with
  `ha.transmit(modem, channel, message)` (transmit and receive channel are the
  same).
- Accept a message only if `ha.isMessage(message, network)` and `message.to`
  is absent or equals this computer ID. Ignore messages from yourself.
- Heartbeat a `hello` every `ha.HEARTBEAT_SECONDS`. The client drops the device
  to offline after `ha.OFFLINE_MS` without a hello/state.
- Read the widget file once at startup and hash it with `ha.hash`. Editing the
  widget requires restarting the device; the new hash makes the client fetch
  it again automatically.
- Detect a detached modem and re-open it; the client will not see the device
  until hello resumes.
- GPS is optional. If you send `pos`, use `ha.newGpsLocator()` from the event
  loop (raw ping on channel `65534`, responses handled from events). Do not
  call `gps.locate` from a Basalt schedule; Basalt resumes schedules with only
  four event parameters and drops the modem distance.

`shared/device_app.lua` is the reference implementation of all of this,
including pairing state, config persistence and the device UI.

## 5. Installing and testing

For a repo-local device type:

1. Add `fan/app.lua` and `fan/widget.lua`.
2. Add an installer target in `installers/build.py` (`/fan.lua`,
   `/ha/lib/ha.lua`, `/ha/lib/device_app.lua`, `/ha/widgets/fan.lua`) and run
   `make build`.
3. On the pocket, also install `/ha/widgets/fan.lua` as the fallback. The
   client installer only bundles the built-in widgets, so add the file to the
   client target there as well.

For a one-off device, copy the files manually to the device computer
(`/fan.lua`, `/ha/lib/ha.lua`, `/ha/lib/device_app.lua`,
`/ha/widgets/fan.lua`) and copy the widget to `/ha/widgets/fan.lua` on the
pocket.

Verify:

- The device screen shows `modem <side>: ok` and a widget hash, and the
  Configure overlay can save the name, side, network and channel.
- The pocket lists the device under Setup > Pair devices and pairing succeeds
  while **Allow new pairing** is on.
- Each widget control changes the redstone output and the device screen
  follows; the widget follows commands sent from the device screen too.
- Stopping the device leaves the card in the list with its last state and a
  red offline status after about 15 seconds.
- A widget with a syntax error logs to `/ha/debug.log` on the pocket and falls
  back to the bundled copy or the generic card.

Live ender-modem, redstone and GPS behaviour cannot be fully exercised in
CraftOS-PC; do the final checks on real computers.
