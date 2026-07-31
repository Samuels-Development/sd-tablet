<div align="center">

# sd-tablet

**An in-game tablet for FiveM, and a companion to [sd-phone](https://github.com/Samuels-Development/sd-phone).**
Same apps, same accounts, same character, **the same data**. Every message, contact, mail thread, note, photo, installed app and setting is the phone's, because there is only one copy of it and both devices read it. Nothing syncs, because nothing has to.

If sd-tablet is useful to you, please ⭐ the repo. Issues and pull requests are always welcome.

[![Release](https://img.shields.io/github/v/release/Samuels-Development/sd-tablet?label=Release&logo=github)](https://github.com/Samuels-Development/sd-tablet/releases)
[![Stars](https://img.shields.io/github/stars/Samuels-Development/sd-tablet?label=Stars&logo=github)](https://github.com/Samuels-Development/sd-tablet)
[![Discord](https://img.shields.io/discord/842045164951437383?label=Discord&logo=discord&logoColor=white)](https://discord.gg/FzPehMQaBQ)
[![Documentation](https://img.shields.io/badge/Docs-docs.samueldev.shop-94DD0C)](https://docs.samueldev.shop/resources/phone/)

![Requires](https://img.shields.io/badge/Requires-sd--phone-ef4444)
![Framework](https://img.shields.io/badge/Framework-QBCore%20%7C%20QBox%20%7C%20ESX-3b82f6)
![Database](https://img.shields.io/badge/Database-none%20of%20its%20own-3b82f6)

[**sd-phone**](https://github.com/Samuels-Development/sd-phone) · [**Documentation**](https://docs.samueldev.shop/resources/phone/) · [**Store**](https://fivem.samueldev.shop) · [**Discord**](https://discord.gg/FzPehMQaBQ)

</div>

---

> [!IMPORTANT]
> **sd-tablet is a companion script. It does not work on its own.**
> It is not a standalone phone, a fork, or a second copy of anything. It ships no apps, no database
> tables and no server logic of its own; it renders sd-phone's UI and forwards every action into
> sd-phone's client and server. **A running [sd-phone](https://github.com/Samuels-Development/sd-phone)
> is a hard dependency** and is declared as one in `fxmanifest.lua`, so the resource will refuse to
> start without it.

## What it is

A second device for the same character. Pick up the tablet and you are looking at the same phone
you already had, on a bigger screen: the same Messages threads, the same Photogram account, the
same wallet, the same installed apps, the same wallpaper and passcode.

There is no pairing step, no sync, no "tablet account". There is one set of player data on
sd-phone's server and two devices that read it, so anything you do on one is simply already true on
the other.

| | |
|---|---|
| **Shared with the phone** | Messages, contacts, mail, notes, photos, app accounts and logins, wallet, settings, passcode and Face Unlock, installed apps, notifications, badges |
| **The tablet's own** | Home screen arrangement, and the device itself: item, keybind, hold pose and prop |
| **Not available** | Voice calls, the payphone UI, the admin panel, the first-run setup wizard, the flashlight |

## Why no calls

The one thing the tablet cannot do is **place or answer a voice call**: no dialler, no FaceTime, no
payphones. The Phone app is not merely hidden, it is rejected by app id, so no notification, deep
link, Control Center entry or custom-app SDK call can open it.

That refusal lives inside **sd-phone** (`client/companion.lua`), on the far side of the seam, which
means it holds even for a modified tablet build.

## How it works

sd-tablet contains no apps. sd-phone's client already owns every NUI callback (~460 of them, many
built at runtime) and every live push the UI needs, so the tablet borrows all of it over the
companion bus in `sd-phone/client/companion.lua`:

| direction | mechanism |
| --- | --- |
| tablet UI → sd-phone | every action is posted as `{ action, payload }` to one NUI callback, `rpc`, and forwarded as `sd-phone:client:companion:invoke` with a token; the answer comes back on `sd-phone:client:companion:reply` |
| sd-phone → tablet UI | sd-phone re-emits every NUI push as `sd-phone:client:companion:push` while the mirror is armed; the tablet filters out the phone's own hardware and re-sends the rest into its own frame |
| focus | sd-phone re-routes `SetNuiFocus` / `SetNuiFocusKeepInput` to the companion while it owns the screen, which is what makes the forwarded Camera app work |

The UI is not copied either. sd-tablet builds **sd-phone's own `web/src`** against a tablet device
profile, so there is exactly one copy of the interface and it cannot drift between the two devices.

Only one device is ever on screen: opening the tablet closes the phone, and opening the phone
closes the tablet.

### Files

```
fxmanifest.lua
configs/config.lua     settings index
configs/tablet.lua     item, keybind, prop/anim, movement, safety blocks, status bar
configs/apps.lua       dock, wallpaper, app catalog (no phone app)
client/main.lua        open/close, keybind, item open, the tablet's sd-phone:open payload, exports
client/policy.lua      DENY / LOCAL / push-filter tables
client/rpc.lua         the single RegisterNUICallback('rpc') dispatcher
client/bridge.lua      token-matched invoke/reply to sd-phone, with a watchdog
client/mirror.lua      sd-phone's pushes and focus, applied to our frame
server/main.lua        usable tablet item + the server-side ownership gate
web/device.ts          the tablet device profile: geometry, home grid, capabilities
web/                   the NUI (built, see below)
```

## Installation

### Dependencies

| Resource | What it is for |
| --- | --- |
| [sd-phone](https://github.com/Samuels-Development/sd-phone) | **Required.** Every app, every callback and all player data. The tablet is inert without it. |
| [ox_lib](https://github.com/CommunityOx/ox_lib) | Shared library |

sd-tablet does **not** touch the database and has no SQL of its own.

### 1. Start the resource

Drop `sd-tablet` **next to `sd-phone`** in your resources folder, then start it after sd-phone:

```cfg
ensure ox_lib
ensure oxmysql
ensure sd-phone
ensure sd-tablet
```

> [!NOTE]
> "Next to sd-phone" is not cosmetic. The UI build resolves sd-phone's source through a relative
> path (`../../sd-phone/web/src`), so if the two resources are not siblings the build cannot find
> it. If sd-phone lives in a category folder such as `[sd]`, put sd-tablet in the same one.

### 2. Build the NUI

The tablet renders the *same source tree* as sd-phone, built against the tablet device profile in
`web/device.ts` (screen geometry, home grid, `calls: false`, `rpcAction: 'rpc'`).

```bash
cd web
bun install
bun run build
```

npm works too, if you would rather not install bun:

```bash
cd web
npm install
npm run build
```

That writes `web/build/`, which `fxmanifest.lua` serves as `ui_page`. `server/main.lua` prints a
warning at boot if it is missing, so a source checkout never opens to a silent blank screen.

`web/build` is **not** committed. Rebuild it before every deploy.

### 3. Add the tablet item

The item name is `Item` in `configs/tablet.lua` (default `tablet`). Set `RequireItem = false` there
if you would rather everyone had the keybind without carrying anything, or `Item = false` to drop
item-based opening entirely.

**ox_inventory**, in `ox_inventory/data/items.lua`:

```lua
['tablet'] = {
    label       = 'Tablet',
    weight      = 700,
    stack       = false,
    close       = true,
    description = 'A tablet. Everything your phone does, except calls.',
    client      = { image = 'tablet.png' },
    server      = { export = 'sd-tablet.useTablet' },
},
```

The export name is derived from the item name (`tablet` → `useTablet`), so a renamed item needs a
matching `server.export`.

**QBCore / QBox**, in `qb-core/shared/items.lua`:

```lua
['tablet'] = {
    name = 'tablet', label = 'Tablet', weight = 700, type = 'item',
    image = 'tablet.png', unique = true, useable = true, shouldClose = true,
    description = 'A tablet. Everything your phone does, except calls.'
},
```

**ESX**:

```sql
INSERT INTO `items` (`name`, `label`, `weight`, `rare`, `can_remove`)
VALUES ('tablet', 'Tablet', 1, 0, 1);
```

Also supported with no extra configuration: tgiann, jaksam, qs / qs-pro, origen, codem,
qb-inventory, ps-inventory, lj-inventory. The same backend list sd-phone supports.

### 4. Open it

Press <kbd>F2</kbd>, or use the `tablet` item.

## Configuration

Almost everything is configured in **sd-phone**, not here. Mail accounts, message limits, banking,
garages, cell towers, Wi-Fi, the app back-ends: the tablet reaches all of it through sd-phone, so
there is one place to change each of them and the two devices can never disagree.

`configs/tablet.lua` holds only what belongs to this device: its item, its keybind, its hold
animation and prop, its movement rules, its safety blocks, and its cosmetic status bar.

A few values in there are deliberate duplicates of sd-phone settings and **must match them**:

| sd-tablet | sd-phone |
| --- | --- |
| `Tablet.Mail.Domain` | `configs/mail.lua` → `Domain` |
| `Tablet.Number` | `configs/phone.lua` → `Number` |
| `Tablet.AllowMovement` | `configs/phone.lua` → `AllowMovement` |
| `Tablet.AllowMovementInCamera` | `configs/phone.lua` → `AllowMovementInCamera` |

The first two are display-only, since the tablet never mints an address or a number, but a mismatch
means the same address is formatted two different ways on the two devices.

The movement pair matters more. The Camera app's viewfinder belongs to sd-phone and the tablet only
forwards it, so that pair is how the tablet works out *which* camera sd-phone took the view with:
movement allowed means sd-phone's scripted camera, which animates nothing and leaves the hold pose
and the hand prop where they are; movement off means GTA's native cell-cam, which pins the ped and
spawns a phone prop of its own, so the tablet's pose stands down for it. A mismatch either deletes
the tablet out of the player's hands mid-shot or leaves it in them next to a phone GTA put there.

`configs/apps.lua` decides which apps the tablet is *capable* of showing. It does **not** decide
which are installed: that list is the player's, lives on sd-phone's server, and is shared. Every
`id` used there must also exist in sd-phone's `configs/apps.lua`.

### The one thing that is not shared

The **home screen arrangement**, and it cannot be. A layout is a flat slot array whose page
boundaries are that device's own `cols * rows`: 40 on the tablet against the phone's 24. The same
array read on the other device would put every icon past page one in a different cell.

Both layouts live in one row on sd-phone's server, under an envelope keyed by device id, and each
device reads and writes only its own key. A layout stored before the tablet existed carries over as
the phone's, so upgrading changes nothing for existing players.

## Exports

```lua
-- client
exports['sd-tablet']:isOpen()               --> boolean
exports['sd-tablet']:isLocked()             --> boolean
exports['sd-tablet']:open()                 --> boolean opened
exports['sd-tablet']:close()
exports['sd-tablet']:openApp(appId, link)   --> boolean accepted

-- server
exports['sd-tablet']:hasTablet(source)      --> boolean
```

`exports['sd-phone']:openApp(...)` still targets the **phone**, and opens it, which closes the
tablet. Use the tablet's own `openApp` to launch something on this device.

## Limitations

**Unique phones / SIM cards.** If sd-phone runs with `configs/uniqueandsim.lua` → `Enabled = true`,
the tablet **refuses to open** and says so. Under that mode the acting identity is resolved from the
SIM in the player's *active phone*; a tablet has no SIM tray and no device identity, so it has no
identity to act as. Opening it would show the wrong player's data, or none. sd-tablet detects the
mode at boot and gates both open paths.

**No calls.** By design, and enforced inside sd-phone.

**No admin panel.** `/phoneadmin` is a phone overlay; the tablet build does not include it, so
opening the panel **closes the tablet** and hands the screen back to sd-phone, the same exclusion
the phone itself gets. Remove the `sd-phone:admin:` prefix from `client/policy.lua` to change that.

**Payphones close nothing.** sd-phone's payphone UI opens straight from an `ox_target` option, and
it takes NUI focus without announcing anything the tablet could hear. Used with the tablet out, the
booth's keypad renders in sd-phone's frame while the cursor stays on the tablet's, and neither is
clickable until the tablet is closed. Close the tablet before you pick up a payphone. Fixable in one
line on sd-phone's side, see `openPayphone` in its `client/payphone.lua`.

**No flashlight.** A tablet has no torch. The lockscreen button reports permanently off.

## License

GPL-3.0-or-later, the same as sd-phone.
