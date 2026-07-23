# Planned Features

Ideas queued for future versions, roughly in the order they came up. Nothing here is
implemented yet; notes under each item sketch how it would fit the current architecture.

| # | Feature | Complexity | Notes |
| - | ------- | ---------- | ----- |
| 1 | Configurable battery-reserve bands | Low | extends existing config |
| 2 | Responsiveness / server-lag throttle | Low | control-interval + deadband settings |
| 3 | Reactor↔turbine steam network mapping | Medium | per-group steam cascade |
| 4 | Configurable ideal RPM (e.g. 900) | Low | already a config key; needs UI + validation |
| 5 | Flywheel mode (overspeed idle turbines) | Medium | interacts with the safety governor |
| 6 | Efficiency calibration + optimize mode | High | automated rod-sweep measurement |

---

## 1. Configurable battery-reserve bands

Control the allowed range for the battery reserves of turbines and reactors, which in turn
determines how frequently they adjust.

- Today: global `bufferMin`/`bufferMax` (reactors) and `coilsOnBelowPct`/`coilsOffAbovePct`
  (turbines) in `CONTROL_CONFIG`.
- Planned: expose these on the monitor UI, and allow **per-entity overrides** so e.g. one
  turbine can run a tight band (fast cycling, steady output) while others run wide bands
  (slow cycling, less churn).
- Wider band = fewer coil flips / rod moves = fewer peripheral writes.

## 2. Responsiveness setting (server-lag reduction)

A setting for how responsive power sources are to changing demand — make control rods and
turbine flow adjust less frequently to reduce the chance of lagging the server.

- Add `controlIntervalTicks` (run the control pass every N ticks instead of every tick) and
  a **deadband** (ignore errors smaller than X RPM / X mB/t / X% buffer).
- `steamWriteThreshold` already exists for turbine flow writes; extend the same idea to rod
  writes (`rodWriteThreshold`, min % change before pushing new levels).
- Safety governor stays at full tick rate regardless — only the *steering* slows down.

## 3. Steam network mapping (reactor ↔ turbine groups)

Mark which reactors are connected to which turbines — or declare that all steam-producing
reactors share one network with all turbines — so the script knows which reactors to adjust
for changing steam production.

- Today: single shared steam network assumed; all active reactors chase the aggregate
  turbine draw (split evenly).
- Planned: a `steamGroups` config mapping reactor peripheral names to turbine peripheral
  names. Each group runs its own steam-match cascade (production target = that group's
  turbine draw; band-seek on that group's tanks).
- Default stays "one big network" when no groups are defined.
- UI: show group id on reactor/turbine cards.

## 4. Configurable ideal RPM

Allow changing the "ideal" RPM target — e.g. 900 RPM instead of 1800.

- `idleRPM` is already a config key; the steam PI targets whatever it says.
- Needed: monitor UI to change it, validation (must stay well under `safeRPM`), and the
  turbine-card gauge target line already draws from config so it follows automatically.
- Could be per-turbine (different turbines tuned to different sweet spots).

## 5. Flywheel mode (high-RPM idle spin-up) — **off by default**

Toggle: idle turbines spin up to very high RPM so a big power spike can be served instantly
by engaging the coils and burning off stored rotational energy.

- Directly conflicts with the 2000 RPM safety ceiling, so this needs care:
  - Separate `flywheelRPM` target and `flywheelCeilingRPM`, used **only** while the mode is
    on and the turbine is idle (coils off).
  - The moment coils engage (power needed), the normal governor rules resume as RPM falls
    back through the normal band.
  - Hard requirement before shipping: verify in-game what actually happens to an ER2 turbine
    at high RPM (damage? efficiency cliff? nothing?) and document it.
- UI: prominent indicator on the turbine card when flywheel mode is armed (gauge rescales).

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
