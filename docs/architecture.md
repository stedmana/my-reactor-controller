# Architecture

How the controller works, file by file. Written for MC 1.20.1 Forge + Extreme Reactors 2 +
CC:Tweaked, using the ER2 **Modernized Object API** (method names verified against the mod
source, `ZeroNoRyouki/ExtremeReactors2` branch `1.20`).

## Big picture

```
                 +--------------------- Advanced Computer ---------------------+
 wired modems    |                                                             |
 ("BigReactors-  |  controller.lua  20Hz tick loop + peripheral hot-plug       |
  Reactor")   -->|      |                                                      |
 ("BigReactors-  |      +--> Reactor instances  --> rod PID                    |
  Turbine")   -->|      +--> Turbine instances  --> safety / coils / steam PI  |
 ("monitor")  -->|      +--> EnergyBuffer instances (grid aggregate)           |
                 |      +--> Monitor instances   --> card-grid UI              |
                 +-------------------------------------------------------------+
```

Every device is discovered by CC peripheral type (`BigReactors-Reactor`,
`BigReactors-Turbine`, `monitor`, `energy_storage`) and can attach/detach at runtime.

### The control cascade

Three loops, layered so each one only needs local information:

1. **Turbine demand (fastest):** each turbine watches its **own internal RF buffer**. Below
   `coilsOnBelowPct` → engage coils (generate); above `coilsOffAbovePct` → disengage (idle).
   Wide hysteresis because the internal buffers are small and would otherwise flap.
2. **Turbine speed:** a steam PI holds `idleRPM` (1800) **at all times** by throttling
   `setFluidFlowRateMax`. Coils on → holding 1800 takes lots of steam → max power at the
   efficiency sweet spot. Coils off → holding 1800 takes a trickle → hot standby, near-zero
   fuel. A **safety governor** overrides everything near the ceiling (see below).
3. **Reactor rods (slowest):**
   - *Passive* reactors chase the measured **grid drain** (`rfLost`) while keeping the
     aggregate buffer in the `[bufferMin, bufferMax]` band.
   - *Active* (steam) reactors chase the turbines' **actual steam consumption**
     (summed `getFluidFlowRate()`), so when turbines idle their steam draw collapses and the
     reactor rods insert automatically — no excess steam is ever produced.

Because 1 changes what steam it takes to hold 1800 (loop 2), and loop 2 changes the steam
consumption that loop 3 targets, demand propagates turbine → steam → rods with no explicit
coordination.

### Turbine safety governor

Runs first in every control pass, on **instantaneous** RPM (not the smoothed average):

| condition | action |
| --- | --- |
| `rpm >= ceilingRPM` (2000) | steam cap → 0, coils forced on (brake), PI integral dumped |
| `rpm >= safeRPM` (1950) | coils forced on, steam clamped ≤ 25% of the turbine's max |
| otherwise | normal coil/PI control |

The governor ignores the PI entirely, so a mistuned PI cannot push a turbine past the
ceiling. Verified in the simulator including induced 1990/2005 RPM overspeed states.

The governor also ignores `controlIntervalTicks`: when the steering pass is throttled to
every N ticks (server-lag reduction), the governor still runs on every tick.

### Per-entity overrides + responsiveness

`CONTROL_CONFIG.entityOverrides[peripheralID]` overrides selected globals per entity
(reactors: `bufferMin`/`bufferMax`; turbines: `coilsOnBelowPct`/`coilsOffAbovePct`/`idleRPM`),
resolved through `_G.getEntitySetting`. `idleRPM` is always clamped to
`[100, safeRPM - 100]` (`_G.clampIdleRPM`) so no target can brush the governor.
Responsiveness knobs: `controlIntervalTicks` (steering every N ticks), `rpmDeadband`
(ignore small steam-PI errors), `rodWriteThreshold` (skip small rod writes, mirroring
`steamWriteThreshold`).

### Grid drain derivation (why turbines "just work" with passive reactors)

`rfLost = passiveGeneration + storedLastTick - storedThisTick`, where `stored*` sums **all**
RF buffers (passive reactor batteries + turbine buffers). Turbine generation is deliberately
*excluded* from the generation term: it appears in the buffer delta instead, so when turbines
cover the load, `rfLost` shrinks and passive reactors throttle down on their own.

## Module reference

Modules are plain scripts executed once at boot; each registers a global (`_G.Reactor`,
`_G.Monitor`, ...) rather than using `require`. Load order is handled by
`src/scripts/main.lua` (`LOAD_FIRST` list, then everything else sorted).

### src/scripts/main.lua
Boot: run every module, wait 1s for multiblocks to report, write/read configs, call `main()`.

### src/scripts/controller.lua
The hub. Owns the registries (`_G.reactors/_G.turbines/_G.energyBuffers/_G.monitors`),
`overallStats` (all aggregates incl. per-reactor demand shares), the tick-synchronized
`loop()` (see file comments for the yield trick), and `eventListener()` for touches and
peripheral hot-plug. Exposes `setReactors` / `setTurbines` / `toggleAutoMode` for the UI and
`_G.__test` for the headless simulator.

### src/classes/reactor.lua
One instance per reactor. `update()` reads all stats once per tick into rolling averages;
`updateRods()` is the weighted PID described above. Notables:
- `setRods()` achieves **fractional** insertion by setting some rods 1% deeper than others.
- PID gains are **negative** (insertion is inversely related to output).
- The buffer error is normalized to per-mille of capacity so gains transfer across sizes.

### src/classes/turbine.lua
One instance per turbine. `update()` mirrors the reactor pattern; `updateControl(config)` is
the three-step law (governor → coil hysteresis → steam PI). Notables:
- `flowMaxMax` (throttle ceiling) is read from the peripheral, never assumed 2000.
- Writes are rate-limited: coils only on change, steam only when it moves ≥
  `steamWriteThreshold` mB/t — keeps 20Hz control from spamming the server.
- The PI integral carries the steady-state steam for the current mode, so flipping coils
  migrates smoothly to the new equilibrium.
- `getBladeEfficiency` is feature-detected (`getBladeEffiency` typo on older mod builds).

### src/classes/energybuffer.lua
Tick-to-tick RF store tracker (this-tick vs last-tick + averages). One per passive reactor
battery, per turbine buffer, and per generic `energy_storage` peripheral. The last/this
deltas are what make the `rfLost` derivation work.

### src/classes/monitor.lua
Card-grid UI. Header (aggregates + Auto/Rctrs/Turbs/Prev/Next buttons via Touchpoint, plus a
settings row: idleRPM ±100, buffer band ±5%/side, coil band ±5%/side — all persisted), then
one card per reactor (mode badge, buffer/rod bars, temps, output) and per turbine (RPM gauge
with 1800 target line + 2000 redline, power, steam in/cap, coil state, own-buffer bar).
Layout flows to monitor size (0.5 text scale) and pages on overflow. Buttons are added with
`pcall` so small monitors degrade instead of erroring. Rendering goes through an off-screen
`window` (`setVisible(false)` … `(true)`) to avoid flicker.

### src/classes/deque.lua, vector2.lua, touchpoint.lua
Support: O(1) rolling-average window; 2D vector wrapper; vendored button library (Lyqyd,
MIT) — see each file's header.

### src/util/draw.lua
The four drawing primitives everything uses: `drawBox`, `drawFilledBox`,
`drawFilledBoxWithBorder` (paintutils under a `term.redirect`), and `drawText` (blit).

### src/util/config.lua + src/config/projectConfigs.lua
`CONTROL_CONFIG` holds every tunable (documented inline + in the README table).
Persistence splits `/defaults` (rewritten each boot) from `/overrides` (only user-changed
keys), so updates that change defaults don't clobber user tweaks.

### install.lua
Standalone installer: queries the GitHub tree API for the live file list, downloads `src/` +
`startup.lua` to the computer root. Re-run to update.

## Test harness (test/)

`lua test/sim.lua` (plain Lua 5.3/5.4, no Minecraft):
- `cc_stubs.lua` fakes the CC environment — `colors`, `term`/`window` as character grids
  (writes are clipped like CC, so layout bugs surface), `paintutils`, `vector`,
  `peripheral` registry, tick-driven `os.clock`, in-memory `fs`, `textutils`.
- `sim.lua` builds fake devices with rough physics (rotor: torque/drag/friction/inertia;
  reactors: rod-proportional output; proportional grid draw), then drives the **real**
  control loop through heavy-load → idle → heavy-load phases and asserts the invariants
  (ceiling never crossed, ~1800 RPM everywhere, coils cycle with demand, steam production
  tracks consumption when idle, UI renders, buttons respond to synthetic touches).

Conventions worth knowing before editing:
- **Globals-based modules:** files execute top-to-bottom and publish one `_G.X`; no require.
- **Per-tick idempotency:** every `update(tick)` early-returns if already run for that tick.
- **Peripheral access only via bound closures** created in the `new*` constructors — nothing
  else touches raw peripherals, which is what makes the sim's fakes drop-in.
- **Write rate-limiting** on every peripheral setter that runs at 20Hz.
