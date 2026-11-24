# AGENTS.md

Guidance for agents working on this repository.

## Project

ComputerCraft Home Assistant for CC: Tweaked, built with Basalt.

The pocket computer is a **shell**: each physical device sends a Lua widget
script over an ender modem. The client caches and sandboxes that script, then
renders it as a card in a scrollable list. Do not replace this with a purely
static client-side widget registry; device-supplied widgets are a core
requirement.

## Repository layout / install mapping

| Source | Installed as | Used by |
|---|---|---|
| `main/app.lua` | `/ha.lua` | Pocket client entry point |
| `main/widget_shell.lua` | `/ha/main/widget_shell.lua` | Client card/widget shell |
| `shared/ha.lua` | `/ha/lib/ha.lua` | Client and devices |
| `shared/device_app.lua` | `/ha/lib/device_app.lua` | Switch and dimmer apps |
| `switch/app.lua` | `/switch.lua` | Switch device |
| `switch/widget.lua` | `/ha/widgets/switch.lua` | Switch widget + fallback |
| `dimmer/app.lua` | `/dimmer.lua` | Dimmer device |
| `dimmer/widget.lua` | `/ha/widgets/dimmer.lua` | Dimmer widget + fallback |
| `group/widget.lua` | `/ha/widgets/group_slider.lua` | Client-side group slider |
| `Makefile` | — | Build/check entry point |
| `installers/build.py` | — | Python generator for `dist/install-*.lua` |
| `shared/updater.lua` | `/ha/lib/updater.lua` | Client and device update check/installer runner |
| `version.txt` | `/ha/version` | Stable version used by the updater |
| installer metadata | `/ha/channel` | Installed update channel |
| `installers/startup.lua` | — | Shared startup choices and installer prompt fragment |
| `installers/release_manifest.py` | — | Generates release `update.json` |
| `.github/workflows/ci.yml` | — | Build/check on pushes and PRs |
| `.github/workflows/release.yml` | — | Stable tagged release + update manifest |
| `.github/workflows/nightly.yml` | — | Nightly prerelease built from main |
| `dist/install-*.lua` | — | Generated, self-contained installers |

Config files are runtime state and must never be embedded in installers:

- `/ha/client.cfg` — per-pocket name, network, channel, sort, filters,
  favorites, labels, paired devices, groups, update channel, last known state.
- `/ha/version`, `/ha/channel` — generated update metadata. Do not treat
  these as user config; rebuilds/installers own them.
- `/ha/switch.cfg`, `/ha/dimmer.cfg` — per-device name, side, network, channel,
  pairing-open flag, GPS flag, paired clients, last output state.
- `/ha/cache/widgets/<hash>.lua` — device-sent widget cache.

## Runtime constraints

- CC: Tweaked uses Lua 5.1. Avoid `goto`, bitwise operators, and APIs that do
  not exist in CraftOS. Keep the existing `unpack or table.unpack` fallback.
- CC file handles are called with dot syntax:
  `handle.write(data)`, `handle.readAll()`, `handle.close()`.
  Do not use colon-style `handle:write(...)`.
- App entry points prepend `"/?.lua;"` to `package.path` so
  `require("ha.lib.ha")` and `/basalt.lua` resolve from the root regardless of
  `shell.dir`. Preserve this.
- Load Basalt through `ha.requireBasalt()`. It prefers the installer's private
  `/basalt-ha.lua` and falls back to `/basalt.lua`.
- The UI requires an advanced (colour) terminal. Device apps also use Basalt;
  redstone output additionally requires a computer with redstone.

## Basalt pin and patch

- Target **Basalt 1.7.0** only.
- Basalt 1.7.1 is a property-system rewrite with an incompatible API. Never
  change the pinned version to 1.7.1 or "latest" without porting and testing
  the whole UI.
- The installer downloads Basalt 1.7.0 to `/basalt-ha.lua` and applies two
  fixes to the minified `Slider`:
  - `Slider.draw` dropped the local holding the slider's `y` position, so
    drawing errors with `attempt to perform arithmetic on ... nil`. Keep the
    `obx,oby` patch.
  - The click/drag handler passes absolute mouse coordinates into a function
    that compares them against relative positions. Sliders at `y > 1` cannot
    be clicked without the `getAbsolutePosition()` patch.
  Keep both patches idempotent.
- Do not edit `dist/*.lua` by hand. Edit sources and regenerate.

### Basalt event pitfalls

- A container's `onClick` fires before its child controls handle the click.
  Do not attach `onClick` to a card/frame that contains buttons or sliders.
  Card details are opened by the title `Label` only.
- Basalt schedules are coroutine-based. `os.sleep(0)` is used to defer UI
  rebuilds until after event dispatch. Keep deferrals for UI mutations that
  can remove the object currently handling an event.
- `ScrollableFrame` is created with `:addScrollableFrame()` and
  `:setDirection("vertical")`. There is no `Frame:setScrollable()` in 1.7.0.
- Use `setZIndex(...)` for 1.7.0. Prefer explicit colours over transparent
  backgrounds for frames; the current UI was validated that way.
- Real rendering and every overlay screen were smoke-tested under CraftOS-PC
  with Basalt 1.7.0. Preserve that coverage when changing UI structure.

## Protocol invariants

- Default modem channel: `48721`. Default network name: `home`.
- Every message has `p = "omp-ha"`, `v = 1`, `net`, `from`, and `ts`.
- Message types: `discover`, `hello`, `state`, `pair`, `pair_ack`,
  `pair_denied`, `unpair`, `unpaired`, `cmd`, `widget_req`, `widget`,
  `widget_end`, `widget_none`.
- Device IDs are computer IDs (numbers), not names. Names are display-only.
- Clients send commands only to paired devices. Devices ignore commands from
  unpaired clients.
- Pairing is remembered on both sides. A client must **not** adopt a device
  merely because its hello says it is paired; adoption requires an explicit
  pair flow (`pendingPairs`) or an existing client entry. This prevents
  forgotten devices from silently reattaching.
- Devices are considered online for 15 seconds after their last
  hello/state. Offline widgets stay in the list with last-known state.
- Device position is sent in `hello`/`state`. Both apps use
  `ha.newGpsLocator()`: a raw modem ping on channel `65534`, with responses
  processed from `basalt.onEvent`. Never call `gps.locate` inside a Basalt
  schedule; Basalt resumes schedules with only four event parameters, dropping
  the modem distance needed for trilateration.
- The client polls its own GPS about once per second while GPS is enabled and
  re-evaluates filters/sort order every tick. Rebuild the list only when the
  item signature changes, otherwise just refresh cards so scroll position and
  focus survive.
- Widget scripts are sent in 4 KiB chunks, hash-checked, cached, compiled in a
  sandbox (`ha.widgetEnv`), and fall back to bundled widgets.
- Group members are switch devices. The group value is 0–15; target on count is
  `round(value * member_count / 15)`. The first N members in `group.members`
  order are turned on. That order is user-editable in the group editor;
  preserve it when saving and do not re-sort members alphabetically. The group
  target is authoritative while a device is in a group.

## Installer startup prompt

- `installers/startup.lua` is the single source for the post-install prompt and
  the `1 = ha`, `2 = switch`, `3 = dimmer` startup choices. Generated
  installers embed it; never duplicate the choices in `build.py`.
- Offer only choices whose program file is present in the installer's `files`
  table. Prompt for the computer label first; blank input must leave the label
  unchanged.
- Startup choice `0` leaves `/startup.lua` unchanged. Otherwise insert/replace
  a single marked `shell.run(...)` block at the top while preserving all
  existing startup lines. Make repeat installs idempotent.
- If stdin is unavailable, leave both label and startup unchanged.
- `make check` syntax-checks `installers/startup.lua` and the embedded result.

## Updater invariants

- Two channels, default **stable**:
  - stable: `https://github.com/iwillreku3206/computercraft-home-assistant/releases/latest/download/update.json`
  - nightly: `https://github.com/iwillreku3206/computercraft-home-assistant/releases/download/nightly/update.json`
- The client and device apps check the selected/installed channel on startup.
  The client can switch channels in Setup > Updates; devices follow the
  channel they were installed from.
- Manifest versions are compared against `/ha/version`; nightly versions use
  `version.txt` plus the GitHub run number. Installed channel comes from
  `/ha/channel`. Do not hand-edit generated version/channel metadata.
- Installation downloads the matching installer, executes it in a controlled
  environment, and requires a program restart. Installers must preserve client
  and device configs.
- Never auto-execute an update without the user choosing **Install** on the
  client or the device.
- `make build` defaults to `CHANNEL=stable` and the version in `version.txt`,
  and must reproduce committed `dist/`. Release/nightly builds override
  `CHANNEL` and usually `VERSION`.

## Widget contract

A widget source returns:

```lua
return function(ctx)
    -- create controls with ctx:addButton/addLabel/addSlider/...
    return function(state, online, group) ... end
end
```

Keep this stable unless updating all widget scripts, the shell, the README,
and the fallback path. Useful context fields: `ctx.w`, `ctx.h`, `ctx.state`,
`ctx.online`, `ctx.group`, `ctx:send(action, value)`. Commands are `toggle`
for switches and `set` for dimmers/groups.

## Build and verification

Always regenerate installers after changing any source file:

```bash
make build
# or:
python3 installers/build.py
```

Run the full check (generated installers are current + Lua/Python syntax):

```bash
make check
```

Stable builds use the defaults; nightly builds override the metadata:

```bash
make build CHANNEL=stable
make build CHANNEL=nightly VERSION=0.1.0.123
```

The workflows run CI on pushes/PRs, publish stable assets on `v*` tags, and
publish the moving `nightly` prerelease on pushes to `main`. `version.txt`
must match a stable tag (without `v`).

The root `Makefile` is the standard entry point. `make clean` removes
generated installers; `dist/` is regenerated, never edited by hand.

If CraftOS-PC is available, smoke-test the real UI. The generated installers
are self-contained except for the pinned Basalt URL. Verify:

- client startup and card/list rendering
- every overlay screen (menu, pair, groups, group edit, filters, network,
  device/group details)
- device startup, local control, configuration overlay, pairing and commands
- installer idempotence and the Basalt slider patch (`obx,oby`)
- generated installers still work as self-contained `wget run` files

Live ender-modem, GPS and redstone behaviour cannot be fully tested in
CraftOS-PC; call that out when reporting verification.

## Style / scope

- Keep plain Lua on the ComputerCraft side. Python 3 is used only for the
  installer generator and must not add third-party dependencies.
- Preserve the one-device-app-per-computer assumption; both device apps use
  the same computer ID and modem channel.
- Keep user-facing strings concise for a 26x20 pocket screen, but do not break
  larger terminals.
- Update `README.md` when changing install paths, protocol, config fields,
  widget API, group semantics, or the Basalt pin/patch.
