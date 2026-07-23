# Planned Features

Ideas queued for future versions, roughly in the order they came up. Notes under each item
sketch how it fits the current architecture.

| # | Feature | Complexity | Status |
| - | ------- | ---------- | ------ |
| 1 | Configurable battery-reserve bands | Low | **Implemented** (2026-07) |
| 2 | Responsiveness / server-lag throttle | Low | **Implemented** (2026-07) |
| 3 | Reactor↔turbine steam network mapping | Medium | **Implemented** (2026-07) |
| 4 | Configurable ideal RPM (e.g. 900) | Low | **Implemented** (2026-07) |
| 5 | Flywheel mode (overspeed idle turbines) | Medium | **Implemented** (2026-07) |
| 6 | Efficiency calibration + optimize mode | High | planned |

---

## 1. Configurable battery-reserve bands — IMPLEMENTED

Control the allowed range for the battery reserves of turbines and reactors, which in turn
determines how frequently they adjust.

- Global bands adjustable from the monitor settings row: `Buf -/+` widens/narrows
  `bufferMin`/`bufferMax` and `Coil -/+` widens/narrows `coilsOnBelowPct`/`coilsOffAbovePct`,
  5% per side per touch, refusing to collapse below 10% width. Persisted as overrides.
- **Per-entity overrides** via `CONTROL_CONFIG.entityOverrides` (config file): reactors honor
  `bufferMin`/`bufferMax`, turbines honor `coilsOnBelowPct`/`coilsOffAbovePct`.
- Wider band = fewer coil flips / rod moves = fewer peripheral writes.

## 2. Responsiveness setting (server-lag reduction) — IMPLEMENTED

A setting for how responsive power sources are to changing demand — make control rods and
turbine flow adjust less frequently to reduce the chance of lagging the server.

- `controlIntervalTicks` runs the steering pass (rod PID, coils, steam PI) every N ticks.
- `rpmDeadband` zeroes steam-PI errors smaller than N RPM.
- `rodWriteThreshold` skips rod writes moving less than N %-points (edges 0/100 always write),
  mirroring the existing `steamWriteThreshold` for turbine flow.
- Safety governor still runs at full tick rate — only the *steering* slows down (verified in
  the simulator with an induced overspeed on a non-steering tick).

## 3. Steam network mapping (reactor ↔ turbine groups) — IMPLEMENTED

Mark which reactors are connected to which turbines — or declare that all steam-producing
reactors share one network with all turbines — so the script knows which reactors to adjust
for changing steam production.

- `CONTROL_CONFIG.steamGroups` is a list of `{ reactors = {...}, turbines = {...} }` by
  peripheral id. Each group runs its own steam-match cascade: its active reactors chase only
  that group's summed turbine steam draw and band-seek on that group's own steam tanks
  (`controller.lua` `updateSteamGroups`; `reactor.lua` reads its group's numbers).
- Any reactor/turbine not named in a group falls into the implicit `default` group, so an
  empty list reproduces the original single-network behavior exactly.
- UI: reactor/turbine cards show a `G1`/`G2` badge when more than one group is configured.

## 4. Configurable ideal RPM — IMPLEMENTED

Allow changing the "ideal" RPM target — e.g. 900 RPM instead of 1800.

- Monitor settings row: `RPM -/+` steps global `idleRPM` by 100, clamped to
  `[100, safeRPM - 100]` (validation lives in `clampIdleRPM`, applied both in the UI and in
  the turbine control law so a hand-edited config can't defeat it).
- Per-turbine targets via `entityOverrides` (e.g. `{ ["BigReactors-Turbine_2"] = { idleRPM = 900 } }`);
  the turbine-card gauge target line and "idle @N" text follow the effective per-turbine value.

## 5. Flywheel mode (high-RPM idle spin-up) — IMPLEMENTED, **off by default**

Toggle: idle turbines spin up to very high RPM so a big power spike can be served instantly
by engaging the coils and burning off stored rotational energy.

- Config: `flywheelMode` (off by default), `flywheelCeilingRPM` (0 = uncapped).
- While armed AND a turbine is idle (coils disengaged), it runs at FULL steam and the safety
  governor's ceiling is lifted — uncapped by default, so the rotor climbs as high as it
  physically can; a positive `flywheelCeilingRPM` hard-caps it instead. The instant coils are
  demanded (power needed) the normal 2000 ceiling snaps back and the governor brakes the
  overspeed off into the grid — exactly the "burn stored rotational energy" behavior.
- Armed via the `Fly` header button (`toggleFlywheel`).
- UI: turbine gauge rescales past 2000 (dynamically when uncapped) with a magenta `FLYWHEEL`
  indicator and the 2000 line marked; the header shows a red armed/EXPLODE warning banner.
- ⚠️ **Still unverified in-game:** running a turbine above 2000 RPM may damage or destroy it.
  This mode deliberately defeats the normal 2000 RPM guarantee. Simulator confirms the control
  logic (spin-up, ceiling cap, brake-on-demand, clean disarm) but NOT the in-game damage
  model. Use at your own risk.

## 6. Efficiency measurement + optimize mode

Measure each setup's efficiency (mB of fuel per RF generated) and add a setting to choose
between **maximize efficiency** and **maximize output**.

Sketch of the calibration routine:

- Passive reactors: sweep control-rod insertion in 5% steps, wait for output to stabilize
  after each jump, record RF/t and fuel mB/t at each step -> efficiency curve
  (`getFuelConsumedLastTick` + `getEnergyProducedLastTick` give both numbers directly).
- Active (steam) reactors: same sweep, but record steam mB/t per fuel mB/t, and also how
  many turbines the steam output at that step can effectively run (steam / per-turbine
  full-load draw).
- Linked turbines: attribute fuel cost through the steam network — turbine efficiency =
  RF/t out per fuel mB/t of the reactors producing its steam (needs feature #3 groups to
  attribute correctly).
- Store curves per entity (config/state file); "optimize efficiency" mode then picks the
  rod-level operating point from the curve instead of pure demand-following, while
  "maximize output" keeps today's behavior.

Open questions / feasibility notes:

- Multi-reactor shared steam networks muddy attribution (which reactor's fuel made the steam
  a given turbine ate?). Pro-rating by each reactor's share of steam production is probably
  good enough.
- Calibration takes real time (stabilization wait per step x 20 steps) — needs a UI flow:
  explicit "calibrate" button per reactor, progress display, and it should refuse to run
  while demand is high.
- Reactor efficiency also drifts with fuel reactivity/fertility; curves may need occasional
  re-calibration.
