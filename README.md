# my-reactor-controller

ComputerCraft controller for **Extreme Reactors 2** (MC 1.20.1 Forge, CC:Tweaked), built for an
arbitrary number of reactors and turbines on one wired network. Fork of
[Kasra-G/ReactorController](https://github.com/Kasra-G/ReactorController) (the graph-style UI),
with multi-entity support, full turbine control, and turbine safety added.

Uses the Extreme Reactors **Modernized Object API** (`getEnergyStats()`, `getFuelStats()`,
`getControlRodsLevels()`, `getFluidFlowRate*()`, ...), verified against the mod source
(`ZeroNoRyouki/ExtremeReactors2`, branch `1.20`).

## What it does

- **Any number of reactors + turbines**, hot-pluggable (attach/detach handled live).
- **Reactor modes auto-detected** via `isActivelyCooled()`:
  - *Passively cooled* → standalone power. Rod PID holds the aggregate energy buffer inside a
    configurable band, load-following the grid drain.
  - *Actively cooled* → steam supplier. Rod PID drives steam **production to match the turbines'
    actual consumption** (summed `getFluidFlowRate()`), so no excess steam is ever created; rods
    insert automatically when the turbines idle.
- **Turbine control — one law, three parts:**
  1. **Safety governor** (highest priority): at `safeRPM` (1950) coils force-engage and steam is
     clamped; at `ceilingRPM` (2000) steam cuts to zero. RPM can never cross the ceiling.
  2. **Coils = the power tap:** engaged/disengaged from the turbine's *own* internal RF buffer
     with hysteresis (below 30% → generate, above 70% → idle).
  3. **Steam PI** holds **1800 RPM at all times** by throttling `setFluidFlowRateMax`. Coils on →
     holding 1800 needs full steam → max power at peak efficiency. Coils off → holding 1800 needs
     a trickle → spun-up standby with near-zero fuel burn.
- **Monitor UI:** aggregate header + a card per reactor and per turbine (bar-graph style kept from
  the original). Turbine cards feature an RPM gauge with the target line (per-turbine) and 2000
  redline. Cards flow to the monitor size and page (Prev/Next) if they don't fit. Buttons: Auto,
  reactors on/off, turbines on/off, plus a settings row (idleRPM, buffer band, coil band).
- **Server-lag throttle:** steering can run every N ticks with deadbands on RPM error and rod
  writes; the safety governor always runs at full tick rate.

## Install

1. Advanced Computer wired (wired modems, **activated**) to every reactor/turbine computer port
   and an Advanced Monitor (big — e.g. 8x6 for 3 reactors + 5 turbines; monitor renders at
   0.5 text scale).
2. On the computer:

   ```
   wget run https://raw.githubusercontent.com/stedmana/my-reactor-controller/main/install.lua
   ```

   The installer pulls the live file list from GitHub (no manifest), downloads `src/` +
   `startup.lua`, and offers to reboot. Re-run it any time to update.

   (Manual alternative: copy this folder's `src/` and `startup.lua` to the computer root,
   then reboot.)

Turbines are left in whatever **vent mode** they're already in — for a closed loop keep them on
"Do not vent" so water returns to the reactors.

## Configuration

Defaults live in [src/config/projectConfigs.lua](src/config/projectConfigs.lua) and are persisted
to `/defaults/control.default.conf` with user changes in `/overrides/control.override.conf`.

| Key | Default | Meaning |
| --- | --- | --- |
| `autoMode` | `true` | Master automatic control (Auto button) |
| `bufferMin` / `bufferMax` | 30 / 70 | Aggregate RF-buffer band (%) for passive reactors |
| `idleRPM` | 1800 | Turbine steam-PI target, all modes |
| `safeRPM` | 1950 | Soft brake threshold |
| `ceilingRPM` | 2000 | Hard cut threshold |
| `coilsOnBelowPct` / `coilsOffAbovePct` | 30 / 70 | Per-turbine demand hysteresis (%) |
| `turbineKp` / `turbineKi` | 1.5 / 0.35 | Steam PI gains (mB/t per RPM of error) |
| `steamWriteThreshold` | 5 | Min mB/t change before pushing a new flow cap |
| `controlIntervalTicks` | 1 | Steering pass every N ticks (safety governor always full rate) |
| `rpmDeadband` | 0 | Ignore steam-PI errors smaller than this (RPM) |
| `rodWriteThreshold` | 0 | Min rod-level change (%-points) before writing new levels |
| `entityOverrides` | `{}` | Per-peripheral overrides: reactors `bufferMin`/`bufferMax`, turbines `coilsOnBelowPct`/`coilsOffAbovePct`/`idleRPM` |
| `secondsToAverage` | 0.5 | Rolling-average window for smoothed stats |

The monitor's settings row adjusts `idleRPM` (±100, clamped to stay ≥100 RPM under `safeRPM`),
the reactor buffer band, and the turbine coil band (±5% per side, min 10% width) live; changes
persist to the overrides file.

Per-reactor rod-PID gains live in [src/classes/reactor.lua](src/classes/reactor.lua)
(`newExtremeReactor`); the stock gains are the upstream project's and behave sanely for large and
small reactors thanks to the shared band weighting.

## Headless simulator

No Minecraft needed to sanity-check changes:

```
lua test/sim.lua
```

Runs the real control loop against fake reactor/turbine physics through three demand phases and
asserts: ceiling never crossed (including induced 1990/2005 RPM overspeed), ~1800 RPM in every
mode, coils cycle with demand, steam production tracks consumption when idle, monitor renders and
buttons respond. Requires plain Lua 5.3/5.4 (`brew install lua`).

## Layout

```
startup.lua              boots /src/scripts/main.lua
src/scripts/main.lua     module loader (no auto-updater; local install)
src/scripts/controller.lua  registries, tick loop, aggregate stats, control passes
src/classes/reactor.lua  reactor wrapper + rod PID (passive: energy band, active: steam match)
src/classes/turbine.lua  turbine wrapper + safety governor + coil hysteresis + steam PI
src/classes/monitor.lua  card-grid UI (header, reactor cards, turbine RPM gauges, paging)
src/classes/*            deque, pid, vector2, touchpoint, energybuffer (from upstream)
src/util/*               draw primitives, config persistence
test/                    CC stubs + headless simulator
```
