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
- **Steam network groups (optional):** map which reactors feed which turbines so each group
  matches only its own steam demand; defaults to one shared network.
- **Flywheel mode (optional, off by default):** spin idle turbines past 2000 RPM to bank
  rotational energy for instant spike response — ⚠️ overspeed can destroy turbines in-game.
- **Efficiency calibration + optimize mode:** measure each reactor's output-vs-fuel curve with a
  rod sweep, then run at the fuel-efficient sweet spot instead of chasing maximum output.

## Installing in Minecraft

On the Advanced Computer, run:

```
wget run https://raw.githubusercontent.com/stedmana/my-reactor-controller/main/install.lua
```

The installer pulls the live file list from GitHub (no manifest), downloads `src/` +
`startup.lua`, and offers to reboot. **Re-run the same command any time to update** to the
latest version.

Setup checklist first:

1. **Advanced Computer** connected via wired modems (right-click each modem to **activate** —
   it turns red) to every reactor/turbine **computer port**.
2. **Advanced Monitor** on the same wired network (big — e.g. 8x6 for 3 reactors + 5
   turbines; the UI renders at 0.5 text scale).

Manual alternative: copy this repo's `src/` and `startup.lua` to the computer root, then
reboot.

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
| `steamGroups` | `{}` | Steam network groups (`{ reactors={ids}, turbines={ids} }`); empty = one shared network |
| `flywheelMode` | `false` | Spin idle turbines past 2000 RPM at full steam for instant spike response (⚠️ overspeed — see below) |
| `flywheelCeilingRPM` | 0 | Optional flywheel RPM cap; `0` = uncapped (spin as high as possible) |
| `optimizeMode` | `"output"` | `"output"` (max output) or `"efficiency"` (hold rods at the calibrated sweet spot) |
| `calibrationSettleTicks` | 40 | Ticks held per rod step during an efficiency sweep |
| `secondsToAverage` | 0.5 | Rolling-average window for smoothed stats |

### Efficiency calibration + optimize mode

Press `Calib` to run an efficiency sweep on the first eligible reactor: it steps the control
rods across 0→100% in 5% increments, lets each step settle, and records output vs. fuel to build
an efficiency curve (saved to `/state/<id>.state.conf`, reloaded on reboot). The card shows
`CAL nn%` while sweeping and the `sweet NN` rod level once measured. A sweep refuses to start if
the grid buffer is below its band (or a turbine is generating, for steam reactors), since it
drops that reactor's output to zero mid-sweep.

`Opt` toggles `optimizeMode`: **efficiency** favors fuel economy; **output** is the default
demand-following behavior.

In efficiency mode, when every reactor in a pool (the passive reactors, or a steam group's
reactors) is calibrated, the controller runs **merit-order dispatch**: it ranks them by measured
RF-per-fuel and loads the most efficient ones first — at their sweet spot — while idling the
rest, ramping the efficient reactors past their sweet spot only when demand exceeds what the
sweet-spot points can supply. A parked reactor shows `Idled by efficiency` on its card. If a pool
isn't fully calibrated it falls back to the per-reactor sweet-spot clamp (never over-drive past
the measured sweet spot) and the even demand split.

### Steam network groups

By default every steam reactor feeds one shared network with every turbine. To split them,
list groups in `steamGroups`; each group's reactors then match only that group's turbine steam
draw:

```lua
steamGroups = {
  { reactors = { "BigReactors-Reactor_2" }, turbines = { "BigReactors-Turbine_1", "BigReactors-Turbine_2" } },
}
```

Anything not listed stays in the shared `default` group. Cards show a `G1`/`G2` badge when
groups are active.

### ⚠️ Flywheel mode (overspeed — off by default)

The `Fly` button arms flywheel mode: **idle** turbines run at full steam and climb as high as
the turbine physically allows (uncapped by default), banking rotational energy so a sudden power
spike can be served instantly by engaging the coils and dumping it. When coils engage the normal
2000 ceiling snaps back and the turbine brakes down through the band. Set `flywheelCeilingRPM`
to a positive value to hard-cap the spin-up instead of running uncapped.

**Running an ER2 turbine above 2000 RPM can make it EXPLODE, and uncapped flywheel has no upper
limit.** This mode deliberately defeats the normal 2000 RPM safety guarantee, and the in-game
high-RPM damage behavior is *not* verified — use it at your own risk. The header shows a red
warning while armed.

The monitor's settings row adjusts `idleRPM` (±100, clamped to stay ≥100 RPM under `safeRPM`),
the reactor buffer band, the turbine coil band (±5% per side, min 10% width), and the steering
interval (`Tick -/+`, 1-20 ticks) live; changes persist to the overrides file.

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
