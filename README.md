# CCScripts

A collection of [CC:Tweaked](https://cc.tweaked.cc/) scripts for **Minecraft 1.21.1**.

CC:Tweaked is a Minecraft mod that adds programmable computers and turtles using the
[Lua](https://www.lua.org/) programming language. This repository holds my personal
collection of scripts, programs, and utilities written for it.

## Environment

| Component | Version |
| --- | --- |
| Minecraft | 1.21.1 |
| CC:Tweaked | 1.21.1 (NeoForge / Fabric builds as available) |
| Lua | 5.1 (as shipped with CC:Tweaked / Cobalt) |

## Repository structure

```
CCScripts/
├── programs/   # Standalone programs run from the shell (e.g. `wget`'d onto a computer)
├── libs/       # Reusable modules / APIs loaded with `require` or `os.loadAPI`
├── turtles/    # Turtle-specific scripts (movement, mining, building)
└── README.md
```

> Folders are created on demand as scripts are added.

## Scripts

### `programs/colony_monitor.lua` — MineColonies Colony Monitor

A modern, SCADA-inspired dashboard that turns an Advanced Monitor into a live
overview of your MineColonies colony. Polls the **Advanced Peripherals**
`colony_integrator` every few seconds and renders four touch-driven views:

- **Dashboard** — citizens/capacity, happiness, building & visitor counts, live
  capacity & mood gauges, an alerts panel (under attack, idle/hungry citizens,
  low happiness), citizen-status breakdown, and the colony's active requests.
- **Buildings** — every structure with type, `Lv x/y` level (colour-coded), and
  status (OK / BUILDING / RUIN, guarded). Dynamic, non-truncating columns.
- **Citizens** — every citizen with job, state, mood and food saturation.
  Dynamic, non-truncating columns.
- **Research** — a real **node tree**: each research is a bordered, colour-coded
  node connected to its parent/children by junction lines, grouped by branch.
  Larger than the screen? **pan by tapping the edges** (left/right/up/down).

**Requirements:**

| Component | |
| --- | --- |
| Minecraft | 1.21.1 |
| CC:Tweaked | 1.21.1 |
| MineColonies | (any recent 1.21.1 build) |
| Advanced Peripherals | 0.7.61 (`colony_integrator` peripheral) |
| Hardware | 1× **Advanced Monitor** (touch-capable, for colour) + a Computer adjacent to a Colony Integrator next to your Town Hall |

**Setup:**

1. Place an **Advanced Monitor** next to (or wired to) the computer.
2. Place a **Colony Integrator** (Advanced Peripherals) adjacent to the colony
   (within range of the Town Hall). The script auto-detects both.
3. Download and run:

   ```lua
   wget run https://raw.githubusercontent.com/<owner>/CCScripts/main/programs/colony_monitor.lua colony_monitor
   colony_monitor
   ```

**Controls (fully touch-driven — no keyboard needed):** tap the **tabs** to
switch views; tap the **`<` / `>`** footer buttons (or the left/right halves of
the footer) to page lists; on the Research view, tap the **edges** of the screen
to pan the tree (arrows appear at the edges when there's more to see).

**Tuning:** open the file and edit the `CONFIG` table at the top — refresh
interval, monitor/colony side overrides, text scale (0.5 = dense, good for a
wall of monitors), and an optional friendly colony name.

### `programs/ae2_monitor.lua` — AE2 / Extended AE2 Network Monitor

A SCADA dashboard for an Applied Energistics 2 (and Extended AE2) ME network.
Polls the **Advanced Peripherals** `me_bridge` every few seconds and renders
four touch-driven views on an Advanced Monitor:

- **Overview** — energy bar, avg power in/out (AE/t) and net, item-type count,
  fluid-type count, item/fluid byte storage (with gauge when the bridge exposes
  it), and a current top-5 **movers** preview.
- **Movers** — headline view: items & fluids ranked by total flow rate
  (`|in/s| + |out/s|`) over the rate window, with `IN/s`, `OUT/s`, `NET/s`
  columns.
- **Items / Fluids** — three leaderboards each: `TOP IN/s`, `TOP OUT/s`,
  `TOP STORED`.
- **Crafting** — every craftable item, flagged `crafting` when the bridge
  reports an active job (queried for the first 20 rows to stay cheap).

In/out rates are computed by diffing per-item stored counts between polls and
bucketing each poll's delta by direction (rising poll → in, falling poll → out),
summed over a rolling `windowSec` window (default 5s) and divided by elapsed
seconds. The screen redraws at `refreshHz` (default **10/s**); the bridge is
polled at `pollHz` (default 2/s). Press **`R`** to flush the rate window.

**Requirements:**

| Component | |
| --- | --- |
| Minecraft | 1.21.1 |
| CC:Tweaked | 1.21.1 |
| Applied Energistics 2 | (any recent 1.21.1 build; Extended AE2 supported) |
| Advanced Peripherals | 0.7.61+ (`me_bridge` peripheral) |
| Hardware | 1× **Advanced Monitor** (touch-capable, for colour) + a Computer adjacent to (or wired onto) the ME network via a `me_bridge` |

**Setup:**

1. Place an **Advanced Monitor** next to (or wired to) the computer.
2. Place a **`me_bridge`** (Advanced Peripherals) adjacent to the computer and
   connected to your ME network (cable to a controller / dense conduit).
3. Download and run:

   ```lua
   wget run https://raw.githubusercontent.com/<owner>/CCScripts/main/programs/ae2_monitor.lua ae2_monitor
   ae2_monitor
   ```

**Controls:** tap the **tabs** to switch views (or `left`/`right` keys); tap
**`<` / `>`** footer (or the left/right half of the footer) to page leaderboards;
**`R`** key flushes the rate window; **`r`** redraws, **`q`** quits.

**Tuning:** edit the `CONFIG` table at the top — `refreshHz` (screen redraws/s,
default 10), `pollHz` (bridge polls/s, default 2), `windowSec` (rate-averaging
window in seconds, default 5), `textScale`, `monitorSide` / `bridgeSide`
overrides, and `topN` leaderboard size. Rates are in-memory only and reset on
restart — add disk logging if you need history.

## Installing a script in-game

From a Computer/Turtle shell, download a script with `wget` and make it runnable:

```lua
wget run https://raw.githubusercontent.com/<owner>/CCScripts/main/programs/example.lua
```

Or paste the file contents into the `pastebin`/editor and save it to disk.

## Useful resources

- [CC:Tweaked documentation](https://tweaked.cc/)
- [Lua 5.1 reference](https://www.lua.org/manual/5.1/)
- [ComputerCraft Wiki](https://wiki.computercraft.cc/)

## License

Personal use unless otherwise noted in a script's header.
