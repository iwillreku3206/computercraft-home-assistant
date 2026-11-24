# ComputerCraft Home Assistant

A small home-automation UI for **CC: Tweaked**, built on
[Basalt](https://github.com/Pyroxenium/Basalt), designed around an **advanced
pocket computer** client and ender-modem devices.

The pocket computer is a shell: each physical device advertises a Lua widget
script over the modem. The client caches that script, executes it in a small
sandbox, and gives it a card in the main scrollable list. If a device is
offline, the last cached script is used and the controls are disabled.

## A note on how this was written

**This project was vibe coded.** It was built by prompting an AI assistant
rather than written line by line by hand. The code is tested (Lua and Python
syntax checks in `make check`, plus CraftOS-PC smoke tests of the UI), but
expect the fingerprints of that process: uneven comments, the occasional
over-engineered corner, and design choices justified by "it worked when we
tried it" more than by a written spec. Read before you trust.

## Requirements

- CC: Tweaked with HTTP enabled (for the one-time Basalt download).
- An **advanced** computer or pocket computer for every device and the client.
  Basalt refuses to run on monochrome terminals.
- An ender modem on every device and on the pocket computer.
- Redstone-capable computers for `switch` / `dimmer` devices.
- GPS hosts for distance sorting (optional, but required for real distances).

## What you get

| Component | Install path | Run | Purpose |
|---|---|---|---|
| Client | `/ha.lua` + `/ha/` | `ha` | Pocket UI, widgets, pairing, groups, filters |
| Switch device | `/switch.lua` | `switch` | On/off redstone output |
| Dimmer device | `/dimmer.lua` | `dimmer` | 0-15 analog redstone output |
| Group slider | client-side | — | Controls a set of switch devices from 0-15 (%) |
| Shared support | `/ha/lib/` | — | Protocol, modem, config, GPS, device UI |

Each device type lives in its own folder:

```
main/       pocket client (dynamic widget shell)
switch/     switch device app + widget script
dimmer/     dimmer device app + widget script
group/      grouped slider widget
shared/     protocol/config/modem/GPS + generic device app
Makefile    build/check entry point
installers/ Python installer generator
dist/       generated, self-contained installers
```

## Install

### Default: one command, all apps

On each ComputerCraft computer, install everything with:

```text
wget run https://github.com/iwillreku3206/computercraft-home-assistant/releases/latest/download/install-all.lua
```

Then start the program for that computer:

```text
ha        # pocket client
switch    # switch device
dimmer    # dimmer device
```

`install-all.lua` installs the client and both device apps. Only the program you
run on a computer matters; configs are created at runtime.

At the end, the installer prompts for:

- **Computer label** — blank leaves the current label unchanged.
- **Startup program** — `1` = `ha`, `2` = `switch`, `3` = `dimmer`, `0` = leave
  `/startup.lua` unchanged. Only installed apps are offered.

The startup choice is inserted as a managed `shell.run(...)` block at the top
of `/startup.lua`; existing startup content is preserved and the block is
replaced safely on later installs. If a startup program is selected, the
installer restarts the computer so the new startup applies immediately. The
menu is defined once in `installers/startup.lua` and embedded into every
generated installer.

Stable is the default channel. For the nightly build from `main`:

```text
wget run https://github.com/iwillreku3206/computercraft-home-assistant/releases/download/nightly/install-all.lua
```

### Individual installers

Use these when a computer should only receive one role.

Stable (latest release):

| Installer | URL |
|---|---|
| Client | `https://github.com/iwillreku3206/computercraft-home-assistant/releases/latest/download/install-client.lua` |
| Switch | `https://github.com/iwillreku3206/computercraft-home-assistant/releases/latest/download/install-switch.lua` |
| Dimmer | `https://github.com/iwillreku3206/computercraft-home-assistant/releases/latest/download/install-dimmer.lua` |
| All | `https://github.com/iwillreku3206/computercraft-home-assistant/releases/latest/download/install-all.lua` |

Nightly (prerelease built from `main`):

| Installer | URL |
|---|---|
| Client | `https://github.com/iwillreku3206/computercraft-home-assistant/releases/download/nightly/install-client.lua` |
| Switch | `https://github.com/iwillreku3206/computercraft-home-assistant/releases/download/nightly/install-switch.lua` |
| Dimmer | `https://github.com/iwillreku3206/computercraft-home-assistant/releases/download/nightly/install-dimmer.lua` |
| All | `https://github.com/iwillreku3206/computercraft-home-assistant/releases/download/nightly/install-all.lua` |

Examples:

```text
# Stable client
wget run https://github.com/iwillreku3206/computercraft-home-assistant/releases/latest/download/install-client.lua

# Nightly switch device
wget run https://github.com/iwillreku3206/computercraft-home-assistant/releases/download/nightly/install-switch.lua
```

The installer downloads Basalt 1.7.0 to `/basalt-ha.lua` (a private copy) if it
is not already present. The apps prefer that file and fall back to `/basalt.lua`
only if it is also version 1.7.0. This avoids breaking other Basalt programs on
the same computer.

The apps target Basalt 1.7.0's API. The 1.7.1 release is a property-system
rewrite with an incompatible public API, so it is not used.

The installer also applies two fixes to Basalt 1.7.0's minified `Slider`:
`Slider.draw` references a position variable that the minifier dropped, and
the click/drag handler compares absolute mouse coordinates against relative
positions, so sliders below the first row cannot be clicked. Both fixes are
applied only to `/basalt-ha.lua`.

### Rebuilding the installers

The generator is a standalone Python 3 script with no third-party
dependencies:

```bash
make build
# or:
python3 installers/build.py
```

`make check` verifies that `dist/` is current and syntax-checks all Lua
sources and generated installers. `make clean` removes generated installers.
The generator reads the source folders and writes `dist/install-*.lua`. The
generated files are self-contained single-file installers and can be served
from any HTTP host. They contain no external project URLs, only the pinned
Basalt 1.7.0 URL.

### In-app updates

There are two update channels:

| Channel | Source | Default |
|---|---|---|
| Stable | latest GitHub release | yes |
| Nightly | prerelease built from `main` on every push | no |

The client and device apps check the selected channel on startup. When a newer
build is available it is downloaded and installed automatically. Automatic
updates skip the installer's label/startup prompts, preserve configs, verify
that `/ha/version` changed to the expected release, then restart the computer.
The update line and **Install** button remain visible only as a retry path if
an automatic download or install fails.

Open **Setup > Updates** on the pocket to switch between **Stable** and
**Nightly** or to check now; switching channels also triggers an automatic
update. A manual **Install** click still runs the installer interactively.

The updater uses these fixed manifests for
`iwillreku3206/computercraft-home-assistant`:

```text
stable:  https://github.com/iwillreku3206/computercraft-home-assistant/releases/latest/download/update.json
nightly: https://github.com/iwillreku3206/computercraft-home-assistant/releases/download/nightly/update.json
```

A manifest looks like:

```json
{
  "version": "0.2.0",
  "channel": "stable",
  "notes": "What changed",
  "installers": {
    "client": "https://.../install-client.lua",
    "switch": "https://.../install-switch.lua",
    "dimmer": "https://.../install-dimmer.lua"
  }
}
```

`version.txt` contains the stable version. Builds default to the stable
channel and that version:

```bash
make build
```

Nightly builds override both:

```bash
make build CHANNEL=nightly VERSION=0.1.0.123
```

Device apps follow the channel they were installed from; use the stable or
nightly installer on that device to change it.

### Updating an existing install

Installers only replace program files. They do not touch:

- `/ha/client.cfg`
- `/ha/switch.cfg` or `/ha/dimmer.cfg`
- `/ha/cache/widgets/`
- the downloaded `/basalt-ha.lua` when it is already 1.7.0

To update manually:

1. Run the relevant stable or nightly installer with `wget run` (or use
   **Setup > Updates** on the client).
2. The installer prompts for an optional new computer label and startup
   program; blank label input and startup choice `0` leave them unchanged.
3. If a startup program was selected, the installer restarts the computer and
   the chosen app starts automatically. Otherwise stop the old app (Ctrl+T)
   and start it again: `ha`, `switch`, or `dimmer`.

Choose the installer for what changed:

| Changed | Rerun on |
|---|---|
| Client UI, filters, clock, updates, widget shell | pocket: `install-client.lua` |
| Switch device or shared device code | switch computer: `install-switch.lua` |
| Dimmer device or shared device code | dimmer computer: `install-dimmer.lua` |
| Protocol or shared library | every client and device |

Pairings, labels, favorites, groups and last-known state are preserved, so no
re-pairing is required after a normal update.

### GitHub Actions

The workflows in `.github/workflows/` run:

- **CI** on pushes and pull requests: build the installers, verify that the
  committed `dist/` output is current, and run `make check` with Lua 5.1.
- **Release** on `v*` tags: verify the tag matches `version.txt`, build
  stable installers, generate the stable `update.json`, and attach everything
  to the GitHub release.
- **Nightly** on pushes to `main`: build a nightly from the current `main`
  checkout with a version like `0.1.0.<run-number>`, update the `nightly`
  prerelease, and replace its installers/manifest.

To publish a stable update, bump `version.txt`, rebuild/commit `dist/`,
commit, and push a matching tag such as `v0.2.0`. Nightly updates are
automatic on pushes to `main`.

## First-run setup

### 1. Configure each device

Run `switch` or `dimmer`. The device screen shows its name, redstone sides,
network, channel, modem state and redstone output. A new device name defaults to the
computer label; if that is blank it falls back to `Switch <id>` or
`Dimmer <id>`. Existing installs that still have the old auto-generated name
adopt the computer label when one is set.

Open **Configure** to set:

- device name
- redstone sides — one toggle per side; enable every output that should carry
  the same value (`top`, `bottom`, `left`, `right`, `front`, `back`)
- network name (default `home`)
- radio channel (default `48721`)
- whether new pocket computers may pair
- whether to use GPS

The device stores its state and configuration in `/ha/switch.cfg` or
`/ha/dimmer.cfg`, and restores the redstone output on reboot.

### 2. Configure the pocket

Run `ha`. The bottom status bar shows the in-game day/time and the real time. The Setup
screen contains:

- **Pair devices** — scans for devices and pairs/unpairs them.
- **Groups** — combines switch devices into one slider.
- **Sort & filters** — sort by name/distance, favorites-only, offline filter,
  and label filters.
- **Network** — pocket name, network name, channel, GPS toggle.
- **Updates** — choose Stable or Nightly, check now, or retry a failed
  automatic install.
- **Refresh GPS** — re-locates the pocket.

Long device and group names scroll in card titles and detail views instead of
being cut off. The client keeps a separate `/ha/client.cfg` per pocket computer. Favorites,
labels, filters, groups and pairings are therefore per-user.

### 3. Pair and use

In the device's Configure screen, leave **Allow new pairing** on. On the
pocket, open **Setup > Pair devices**, wait for the device to appear, and press
**Pair**. The device accepts and sends its widget script.

Tap a widget's **title** to open its details screen, where you can favorite it,
add/remove labels, or unpair it.

Keyboard scrolling works with up/down and page up/page down on both the main
list and overlay lists.

## Groups

A group is a client-side widget that controls a set of **switch** devices.
Each member is a normal on/off redstone output. The group slider is 0-15 and is
displayed as a percentage.

For a group of `N` devices and slider value `v`:

```
target on count = round(v * N / 15)
```

The first `target` members **in the group's member order** are turned on.
Open the group editor and use the `^`/`v` buttons on a selected member to
change that order. New members are appended to the end. Offline members are
skipped for immediate commands and reconciled when they reconnect. Group
membership is stored on the pocket, while each device keeps its own redstone
sides configuration.

A group needs at least one paired switch device. A device can be in only one
group.

## Offline behaviour

The client considers a paired device online if it has sent a hello/state in the
last 15 seconds. Devices broadcast a hello every 5 seconds and the client sends
a discovery request periodically.

- Offline widgets stay in the list, with their last known state and a red
  status.
- Widget controls are disabled while offline.
- Group targets are re-sent to members after they come back.
- Client-side commands are best-effort; the next hello reconciles the UI.

## Time and distance

- Clock: in-game day and 24-hour in-game time via `os.day()` and
  `os.time()`/`textutils.formatTime`, plus real host time via
  `os.epoch("local")`.
- Distance: devices and the pocket send the GPS ping directly on modem channel
  `65534` and process the responses through the Basalt event loop. Devices
  report their position in their hello/state messages. If either position is
  unknown, the distance is `?` and distance sorting places the widget after
  known ones. (`gps.locate` cannot be used inside a Basalt schedule: Basalt's
  schedule resumption drops the modem distance field needed to trilaterate.)
- Every widget card shows its distance on the right of the title row. The
  text is green while the device/group is online and red while offline. Group
  distances are the average of their members.
- While GPS is enabled, the client refreshes its own fix about once per second.
  The widget list re-evaluates its filters, distances and distance order every
  tick, but only rebuilds the list when the resulting item order changes,
  preserving scroll position during ordinary GPS movement.
- GPS location runs in a Basalt schedule, so the UI continues to process
  events.

### If GPS distances show `?`

- Run `gps locate` on the pocket and on a device; both should print
  coordinates. GPS hosts must be reachable from both.
- Make sure the pocket and every device were updated together; the GPS
  transport lives in the shared library.
- Allow a few seconds after startup. The client polls once per second and each
  device refreshes its own position every five seconds.
- Distance only appears once both sides have a fix. Previously known
  positions are kept until a new fix arrives.

## Widget script transport

The device is the authority for its widget:

1. The device reads its installed widget (`/ha/widgets/switch.lua` or
   `/ha/widgets/dimmer.lua`).
2. It advertises a content hash in its `hello` message.
3. The client asks for the script if it has no cached copy.
4. The device sends the source in 4 KiB chunks over the modem.
5. The client verifies the hash, caches it in `/ha/cache/widgets/<hash>.lua`,
   compiles it in a sandbox, and calls it to build the card contents.

The sandbox exposes math/string/table, colors, limited time functions and the
widget context (`ctx:addButton`, `ctx:addSlider`, `ctx:send`, ...). It does not
expose the filesystem, shell or HTTP APIs. This is a convenience boundary, not
a hardened security system: only pair devices you trust.

The client also ships fallback copies of the bundled widgets so an offline
device can still be displayed before its script has been fetched.

While a switch is a member of a group, the group target is authoritative: the
client will correct local toggles back to the group's requested on/off split.
Remove the device from the group to use it independently.

### Widget API

A widget script returns a function:

```lua
return function(ctx)
    local button = ctx:addButton()
        :setPosition(1, 1)
        :setSize(ctx.w, 1)
        :setText("Toggle")

    button:onClick(function()
        if ctx.online then
            ctx:send("toggle")
        end
    end)

    return function(state, online)
        button:setText(state and "Turn off" or "Turn on")
        if online then button:enable() else button:disable() end
    end
end
```

Useful context fields/methods:

- `ctx.w`, `ctx.h` — card content size.
- `ctx.state` — current device value (boolean for switch, 0-15 for dimmer).
- `ctx.online` — device online state.
- `ctx.group` — for grouped widgets: `{ members, on, online }`.
- `ctx:send(action, value)` — `toggle` for switches, `set` for sliders.
- `ctx:addButton/addLabel/addSlider/addSwitch/addInput/addFrame/...`.
- `ctx:setTitle(text)`, `ctx:setStatus(text, colour)`, `ctx:log(...)`.

The update function is optional. It receives `(state, online)`.

To create a new device type (program + widget), see
[docs/creating-a-device.md](docs/creating-a-device.md).

## Protocol summary

All messages use network channel `48721` (configurable), protocol name
`omp-ha`, and a shared network name. Payloads are Lua tables:

| Type | Direction | Main fields |
|---|---|---|
| `discover` | client → devices | `from`, `name` |
| `hello` | device → clients | `kind`, `name`, `side`, `sides`, `value`, `pos`, `open`, `paired`, `widget` |
| `state` | device → clients | `value`, `pos` |
| `pair` / `pair_ack` / `pair_denied` | both | pairing handshake |
| `unpair` / `unpaired` | both | forget pairing |
| `cmd` | client → device | `action` (`set` / `toggle`), `value` |
| `widget_req` | client → device | `hash` |
| `widget` / `widget_end` | device → client | `hash`, `i`, `n`, `data` |
| `widget_none` | device → client | no script available |

`side` is kept as the first selected side for compatibility; `sides` is the
full set of redstone outputs.

Pairing is remembered on both sides. If a device forgets a client, the client
drops the pairing on the next hello. If a client unpairs, it stops accepting
the device even if the unpair message was lost; pair again to re-add it.

## Configuration files

- `/ha/client.cfg` — client only: name, network, channel, sort, GPS,
  update channel, favorites, labels, filters, paired devices, groups, last
  known states.
- `/ha/switch.cfg`, `/ha/dimmer.cfg` — device only: name, sides, network,
  channel, pairing-open flag, GPS flag, paired clients, last output state.
- `/ha/cache/widgets/<hash>.lua` — cached widget scripts.
- `/ha/version`, `/ha/channel` — generated updater metadata, rewritten by
  installers (not user config).

Configs are written as Lua tables with `textutils.serialize`, so they can be
inspected and edited with the in-game editor.

## Limitations

- One device app per computer (both use the same computer ID and modem).
- An advanced (colour) terminal is required by Basalt.
- The UI is laid out for a 26x20 pocket screen; larger screens work but the
  home toolbar stays left-aligned.
- Basalt is installed as `/basalt-ha.lua` to keep the pinned, patched version
  independent of any other Basalt installation.
- There is no redstone output on pocket computers; device apps must run on a
  computer with redstone.
- GPS requires GPS hosts and a wireless/ender modem; coordinates are cached
  until the next successful locate.

## License

MIT. See [LICENSE](LICENSE).
